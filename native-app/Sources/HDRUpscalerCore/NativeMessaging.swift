import Foundation

// MARK: - Logging

/// All logging must go to stderr — stdout is the native messaging channel.
/// Using print() would corrupt the length-prefixed JSON protocol.
public func logInfo(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// MARK: - Message Types

/// Video rect and state from the Firefox extension content script.
public struct VideoRectMessage: Codable, Sendable, Equatable {
    public let type: String
    public let rect: DOMRect
    public let viewport: ViewportSize
    public let devicePixelRatio: Double
    public let isFullscreen: Bool
    public let paused: Bool
    public let videoNaturalWidth: Int?
    public let videoNaturalHeight: Int?
    public let url: String?
    public let tabId: Int?
    public let windowId: Int?

    public init(type: String, rect: DOMRect, viewport: ViewportSize,
                devicePixelRatio: Double, isFullscreen: Bool, paused: Bool,
                videoNaturalWidth: Int?, videoNaturalHeight: Int?,
                url: String?, tabId: Int? = nil, windowId: Int? = nil) {
        self.type = type; self.rect = rect; self.viewport = viewport
        self.devicePixelRatio = devicePixelRatio; self.isFullscreen = isFullscreen
        self.paused = paused; self.videoNaturalWidth = videoNaturalWidth
        self.videoNaturalHeight = videoNaturalHeight; self.url = url
        self.tabId = tabId; self.windowId = windowId
    }

    enum CodingKeys: String, CodingKey {
        case type, rect, viewport, devicePixelRatio, isFullscreen, paused
        case videoNaturalWidth, videoNaturalHeight, url, tabId, windowId
    }
}

public struct DOMRect: Codable, Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ViewportSize: Codable, Sendable, Equatable {
    public let width: Double, height: Double
    public init(width: Double, height: Double) {
        self.width = width; self.height = height
    }
}

/// Outgoing status message to the extension.
public struct StatusMessage: Codable, Equatable {
    public let type: String
    public let status: String
    public let message: String?
    public init(type: String, status: String, message: String?) {
        self.type = type; self.status = status; self.message = message
    }
}

/// Outgoing capture info to the extension.
public struct CaptureInfoMessage: Codable, Equatable {
    public let type: String
    public let capturing: Bool
    public let windowTitle: String?
    public let captureWidth: Int?
    public let captureHeight: Int?
    public init(type: String, capturing: Bool, windowTitle: String?,
                captureWidth: Int?, captureHeight: Int?) {
        self.type = type; self.capturing = capturing; self.windowTitle = windowTitle
        self.captureWidth = captureWidth; self.captureHeight = captureHeight
    }
}

// MARK: - Protocol Encoding / Decoding

/// Encode a message into Firefox native messaging wire format:
/// 4-byte little-endian UInt32 length + UTF-8 JSON payload.
public func encodeNativeMessage<T: Encodable>(_ message: T) throws -> Data {
    let jsonData = try JSONEncoder().encode(message)
    var length = UInt32(jsonData.count)
    var result = Data(bytes: &length, count: 4)
    result.append(jsonData)
    return result
}

/// Decode the JSON payload from native messaging wire format.
/// Returns (parsed message data, bytes consumed) or nil on EOF / short read.
public func decodeNativeMessage(from data: Data) -> (jsonData: Data, bytesConsumed: Int)? {
    guard data.count >= 4 else { return nil }
    let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }
    let totalSize = 4 + Int(length)
    guard data.count >= totalSize else { return nil }
    let jsonData = data.subdata(in: 4..<totalSize)
    return (jsonData, totalSize)
}

/// Generic incoming message — decode the type first, then parse the full payload.
struct IncomingMessage: Codable {
    let type: String
}

// MARK: - Stdin Detection

/// Check if stdin is a pipe (native messaging host mode) or a terminal (standalone mode).
public func isNativeMessagingMode() -> Bool {
    return isatty(STDIN_FILENO) == 0
}

// MARK: - Native Messaging Reader

/// Reads length-prefixed JSON messages from stdin (Firefox native messaging protocol).
/// Each message: 4 bytes (little-endian UInt32 length) + UTF-8 JSON payload.
public final class NativeMessagingReader {
    private let readQueue = DispatchQueue(label: "com.hdrupscaler.nativemsg.read", qos: .userInitiated)
    private var isRunning = false
    private let inputHandle: FileHandle

    /// Called on the read queue for each parsed video_rect message.
    public var onVideoRect: ((VideoRectMessage) -> Void)?

    /// Called when the extension disconnects (stdin EOF).
    public var onDisconnect: (() -> Void)?

    /// Called for any message type (type string + raw JSON data).
    public var onMessage: ((String, Data) -> Void)?

    /// Initialize with a custom file handle (default: stdin). Inject for testing.
    public init(inputHandle: FileHandle = .standardInput) {
        self.inputHandle = inputHandle
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    public func stop() {
        isRunning = false
    }

    private func readLoop() {
        let decoder = JSONDecoder()

        logInfo("[NativeMessaging] Read loop started")

        while isRunning {
            // Read 4-byte length prefix (little-endian UInt32)
            let lengthData = inputHandle.readData(ofLength: 4)
            guard lengthData.count == 4 else {
                logInfo("[NativeMessaging] stdin EOF — extension disconnected")
                isRunning = false
                onDisconnect?()
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard length > 0 && length < 1_048_576 else {
                logInfo("[NativeMessaging] Invalid message length: \(length), skipping")
                continue
            }

            // Read the JSON payload (handle partial reads)
            var jsonData = Data()
            var remaining = Int(length)
            while remaining > 0 {
                let chunk = inputHandle.readData(ofLength: remaining)
                if chunk.isEmpty {
                    logInfo("[NativeMessaging] stdin EOF during payload read")
                    isRunning = false
                    onDisconnect?()
                    return
                }
                jsonData.append(chunk)
                remaining -= chunk.count
            }

            // Parse message type
            do {
                let envelope = try decoder.decode(IncomingMessage.self, from: jsonData)
                onMessage?(envelope.type, jsonData)

                switch envelope.type {
                case "video_rect":
                    let msg = try decoder.decode(VideoRectMessage.self, from: jsonData)
                    onVideoRect?(msg)

                case "video_lost":
                    logInfo("[NativeMessaging] Video lost — extension reports no active video")
                    onVideoRect?(VideoRectMessage(
                        type: "video_lost",
                        rect: DOMRect(x: 0, y: 0, width: 0, height: 0),
                        viewport: ViewportSize(width: 0, height: 0),
                        devicePixelRatio: 1.0, isFullscreen: false, paused: true,
                        videoNaturalWidth: nil, videoNaturalHeight: nil, url: nil
                    ))

                default:
                    logInfo("[NativeMessaging] Unknown message type: \(envelope.type)")
                }
            } catch {
                if let jsonStr = String(data: jsonData, encoding: .utf8) {
                    logInfo("[NativeMessaging] Parse error: \(error) — raw: \(jsonStr.prefix(300))")
                }
            }
        }
    }
}

// MARK: - Native Messaging Writer

/// Writes length-prefixed JSON messages to stdout (Firefox native messaging protocol).
public final class NativeMessagingWriter {
    private let writeQueue = DispatchQueue(label: "com.hdrupscaler.nativemsg.write", qos: .utility)
    private let encoder = JSONEncoder()
    private let outputHandle: FileHandle

    /// Initialize with a custom file handle (default: stdout). Inject for testing.
    public init(outputHandle: FileHandle = .standardOutput) {
        self.outputHandle = outputHandle
    }

    /// Send an Encodable message to the extension.
    public func send<T: Encodable>(_ message: T) {
        writeQueue.async { [encoder, outputHandle] in
            do {
                let jsonData = try encoder.encode(message)
                var length = UInt32(jsonData.count)
                let lengthData = Data(bytes: &length, count: 4)
                outputHandle.write(lengthData)
                outputHandle.write(jsonData)
            } catch {
                logInfo("[NativeMessaging] Write error: \(error)")
            }
        }
    }

    /// Synchronous send (for testing).
    public func sendSync<T: Encodable>(_ message: T) throws {
        let jsonData = try encoder.encode(message)
        var length = UInt32(jsonData.count)
        let lengthData = Data(bytes: &length, count: 4)
        outputHandle.write(lengthData)
        outputHandle.write(jsonData)
    }

    public func sendStatus(_ status: String, message: String? = nil) {
        send(StatusMessage(type: "status", status: status, message: message))
    }

    public func sendCaptureInfo(capturing: Bool, windowTitle: String?, captureWidth: Int? = nil, captureHeight: Int? = nil) {
        send(CaptureInfoMessage(
            type: "capture_info", capturing: capturing, windowTitle: windowTitle,
            captureWidth: captureWidth, captureHeight: captureHeight
        ))
    }
}
