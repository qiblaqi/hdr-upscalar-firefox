import XCTest
import Foundation
@testable import HDRUpscalerCore

final class NativeMessagingTests: XCTestCase {

    // MARK: - Message Encoding / Decoding (Wire Format)

    /// Verify the 4-byte length prefix + JSON format.
    func testEncodeNativeMessage() throws {
        let msg = StatusMessage(type: "status", status: "ready", message: "hello")
        let data = try encodeNativeMessage(msg)

        // First 4 bytes = little-endian UInt32 length of JSON
        XCTAssertTrue(data.count > 4)
        let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(length), data.count - 4)

        // Remaining bytes = valid JSON
        let jsonData = data.subdata(in: 4..<data.count)
        let decoded = try JSONDecoder().decode(StatusMessage.self, from: jsonData)
        XCTAssertEqual(decoded.type, "status")
        XCTAssertEqual(decoded.status, "ready")
        XCTAssertEqual(decoded.message, "hello")
    }

    func testDecodeNativeMessage() throws {
        let msg = StatusMessage(type: "status", status: "ok", message: nil)
        let wireData = try encodeNativeMessage(msg)

        let result = decodeNativeMessage(from: wireData)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.bytesConsumed, wireData.count)

        let decoded = try JSONDecoder().decode(StatusMessage.self, from: result!.jsonData)
        XCTAssertEqual(decoded.status, "ok")
    }

    func testDecodeNativeMessageTooShort() {
        // Less than 4 bytes → nil
        XCTAssertNil(decodeNativeMessage(from: Data([0x01, 0x02])))
    }

    func testDecodeNativeMessageIncompletePayload() throws {
        let msg = StatusMessage(type: "status", status: "ok", message: nil)
        let wireData = try encodeNativeMessage(msg)

        // Truncate the payload
        let truncated = wireData.prefix(wireData.count - 5)
        XCTAssertNil(decodeNativeMessage(from: truncated))
    }

    // MARK: - VideoRectMessage Codable

    func testVideoRectMessageRoundtrip() throws {
        let original = VideoRectMessage(
            type: "video_rect",
            rect: DOMRect(x: 104.5, y: 88.0, width: 1280.0, height: 720.0),
            viewport: ViewportSize(width: 1440, height: 900),
            devicePixelRatio: 2.0,
            isFullscreen: false,
            paused: false,
            videoNaturalWidth: 1920,
            videoNaturalHeight: 1080,
            url: "https://www.youtube.com/watch?v=test",
            tabId: 12,
            windowId: 1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoRectMessage.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    /// Extension may omit optional fields — they should decode as nil.
    func testVideoRectMessageOptionalFields() throws {
        let json = """
        {
            "type": "video_rect",
            "rect": {"x": 0, "y": 0, "width": 640, "height": 480},
            "viewport": {"width": 1024, "height": 768},
            "devicePixelRatio": 1.0,
            "isFullscreen": false,
            "paused": true
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(VideoRectMessage.self, from: json)
        XCTAssertEqual(msg.type, "video_rect")
        XCTAssertNil(msg.videoNaturalWidth)
        XCTAssertNil(msg.videoNaturalHeight)
        XCTAssertNil(msg.url)
        XCTAssertNil(msg.tabId)
        XCTAssertNil(msg.windowId)
        XCTAssertTrue(msg.paused)
    }

    /// Test decoding a message that matches real extension output format.
    func testRealExtensionPayload() throws {
        let json = """
        {
            "type": "video_rect",
            "rect": {"x": 0, "y": 56.25, "width": 1280, "height": 720},
            "viewport": {"width": 1440, "height": 900},
            "devicePixelRatio": 2,
            "isFullscreen": false,
            "paused": false,
            "videoNaturalWidth": 1920,
            "videoNaturalHeight": 1080,
            "url": "https://www.bilibili.com/video/BV1234567890",
            "isTopFrame": true,
            "tabId": 42,
            "windowId": 1,
            "frameId": 0
        }
        """.data(using: .utf8)!

        // Should decode without error — extra fields (isTopFrame, frameId) are ignored
        let msg = try JSONDecoder().decode(VideoRectMessage.self, from: json)
        XCTAssertEqual(msg.rect.y, 56.25)
        XCTAssertEqual(msg.videoNaturalWidth, 1920)
        XCTAssertEqual(msg.tabId, 42)
    }

    // MARK: - StatusMessage / CaptureInfoMessage

    func testStatusMessageEncoding() throws {
        let msg = StatusMessage(type: "status", status: "ready", message: nil)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "status")
        XCTAssertEqual(json["status"] as? String, "ready")
    }

    func testCaptureInfoMessageEncoding() throws {
        let msg = CaptureInfoMessage(
            type: "capture_info", capturing: true, windowTitle: "YouTube",
            captureWidth: 2880, captureHeight: 1948
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(CaptureInfoMessage.self, from: data)
        XCTAssertEqual(decoded.capturing, true)
        XCTAssertEqual(decoded.captureWidth, 2880)
    }

    // MARK: - Writer via Pipe

    /// Test that NativeMessagingWriter produces correct wire format via a pipe.
    func testWriterOutputFormat() throws {
        let pipe = Pipe()
        let writer = NativeMessagingWriter(outputHandle: pipe.fileHandleForWriting)

        let msg = StatusMessage(type: "status", status: "test", message: "hello")
        try writer.sendSync(msg)

        // Close write end so read doesn't block
        pipe.fileHandleForWriting.closeFile()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(outputData.count > 4)

        // Parse the length prefix
        let length = outputData.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(length) + 4, outputData.count)

        // Parse the JSON
        let jsonData = outputData.subdata(in: 4..<outputData.count)
        let decoded = try JSONDecoder().decode(StatusMessage.self, from: jsonData)
        XCTAssertEqual(decoded.status, "test")
        XCTAssertEqual(decoded.message, "hello")
    }

    // MARK: - Reader via Pipe

    /// Test that NativeMessagingReader correctly parses messages from a pipe.
    func testReaderParsesVideoRect() throws {
        let pipe = Pipe()

        // Write a video_rect message to the pipe
        let msg = VideoRectMessage(
            type: "video_rect",
            rect: DOMRect(x: 10, y: 20, width: 640, height: 480),
            viewport: ViewportSize(width: 1024, height: 768),
            devicePixelRatio: 2.0,
            isFullscreen: false,
            paused: false,
            videoNaturalWidth: 1920,
            videoNaturalHeight: 1080,
            url: "https://example.com"
        )
        let wireData = try encodeNativeMessage(msg)
        pipe.fileHandleForWriting.write(wireData)
        pipe.fileHandleForWriting.closeFile()

        // Setup reader with the pipe's read end
        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)

        let expectation = XCTestExpectation(description: "Received video_rect")
        var receivedMsg: VideoRectMessage?

        reader.onVideoRect = { msg in
            receivedMsg = msg
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(receivedMsg)
        XCTAssertEqual(receivedMsg?.type, "video_rect")
        XCTAssertEqual(receivedMsg?.rect.width, 640)
        XCTAssertEqual(receivedMsg?.viewport.width, 1024)
    }

    /// Test that reader calls onDisconnect when pipe closes.
    func testReaderDisconnectOnEOF() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()  // Immediately close → EOF

        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)

        let expectation = XCTestExpectation(description: "Disconnect called")
        reader.onDisconnect = {
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)
    }

    /// Test that reader handles multiple messages in sequence.
    func testReaderMultipleMessages() throws {
        let pipe = Pipe()

        let msg1 = VideoRectMessage(
            type: "video_rect",
            rect: DOMRect(x: 0, y: 0, width: 640, height: 480),
            viewport: ViewportSize(width: 1024, height: 768),
            devicePixelRatio: 1.0, isFullscreen: false, paused: false,
            videoNaturalWidth: nil, videoNaturalHeight: nil, url: nil
        )
        let msg2 = VideoRectMessage(
            type: "video_rect",
            rect: DOMRect(x: 100, y: 200, width: 1280, height: 720),
            viewport: ViewportSize(width: 1440, height: 900),
            devicePixelRatio: 2.0, isFullscreen: true, paused: false,
            videoNaturalWidth: 1920, videoNaturalHeight: 1080, url: "https://yt.com"
        )

        // Write both messages
        pipe.fileHandleForWriting.write(try encodeNativeMessage(msg1))
        pipe.fileHandleForWriting.write(try encodeNativeMessage(msg2))
        pipe.fileHandleForWriting.closeFile()

        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)

        var received: [VideoRectMessage] = []
        let expectation = XCTestExpectation(description: "Disconnect after reading all")

        reader.onVideoRect = { msg in
            received.append(msg)
        }
        reader.onDisconnect = {
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].rect.width, 640)
        XCTAssertEqual(received[1].rect.width, 1280)
        XCTAssertTrue(received[1].isFullscreen)
    }

    /// Test that reader handles video_lost message type.
    func testReaderVideoLost() throws {
        let pipe = Pipe()

        let lostJSON = #"{"type":"video_lost"}"#
        let jsonData = lostJSON.data(using: .utf8)!
        var length = UInt32(jsonData.count)
        var wireData = Data(bytes: &length, count: 4)
        wireData.append(jsonData)

        pipe.fileHandleForWriting.write(wireData)
        pipe.fileHandleForWriting.closeFile()

        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)

        let expectation = XCTestExpectation(description: "Received video_lost")
        var receivedMsg: VideoRectMessage?

        reader.onVideoRect = { msg in
            receivedMsg = msg
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedMsg?.type, "video_lost")
        XCTAssertEqual(receivedMsg?.rect.width, 0)
        XCTAssertTrue(receivedMsg?.paused == true)
    }
}
