@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Metal
import AppKit

/// Sendable snapshot of an SCWindow — safe to pass across concurrency boundaries.
struct WindowSnapshot: Sendable {
    let windowID: CGWindowID
    let title: String
    let frame: CGRect
    let appName: String
}

/// Captures frames from a selected window using ScreenCaptureKit.
/// Outputs MTLTexture per frame via the onFrame callback.
final class ScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let device: MTLDevice
    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private let captureQueue = DispatchQueue(label: "com.hdrupscaler.capture", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "com.hdrupscaler.processing", qos: .userInteractive)

    // Currently captured window
    private(set) var capturedWindow: SCWindow?
    private(set) var isCapturing = false

    // Callback for each captured frame
    var onFrame: ((MTLTexture, Int, Int) -> Void)?  // (texture, width, height)

    // Callback when capture starts (sends Sendable snapshot, not SCWindow)
    var onCaptureStarted: ((WindowSnapshot) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - Window Selection

    /// Check and request Screen Recording permission
    func checkPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if content.windows.isEmpty && content.displays.isEmpty {
                print("[ScreenCapture] Screen Recording permission not granted.")
                print("[ScreenCapture] Go to: System Settings → Privacy & Security → Screen Recording")
                print("[ScreenCapture] Add Terminal (or your IDE) and restart the app.")
                return false
            }
            return true
        } catch {
            print("[ScreenCapture] Permission check failed: \(error)")
            return false
        }
    }

    /// Get all available Firefox windows, filtered to exclude transient/titleless windows.
    /// Sorted largest-first so the main browser window is first.
    func findFirefoxWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        return content.windows
            .filter { window in
                let appName = window.owningApplication?.applicationName ?? ""
                let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                // Require: Firefox app, non-empty title (excludes transient windows),
                // and minimum size to avoid popups/tooltips
                return appName.localizedCaseInsensitiveContains("firefox")
                    && !title.isEmpty
                    && window.frame.width >= 800
                    && window.frame.height >= 600
            }
            .sorted { lhs, rhs in
                let la = lhs.frame.width * lhs.frame.height
                let ra = rhs.frame.width * rhs.frame.height
                return la > ra
            }
    }

    /// Check if we should restart capture for a new window (skip if same window already running)
    func shouldRestart(for newWindow: SCWindow) -> Bool {
        guard let current = capturedWindow else { return true }
        return current.windowID != newWindow.windowID
    }

    // MARK: - Capture Lifecycle

    /// Revalidate a window by ID against current shareable content.
    /// Returns nil if the window no longer exists or is off-screen.
    private func refreshWindow(windowID: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == windowID }
    }

    /// Start capturing a specific window.
    /// Revalidates the window before starting to avoid capturing stale/transient windows.
    func startCapture(window: SCWindow) async throws {
        await stopCapture()

        // Revalidate: the window may have disappeared since findFirefoxWindows()
        guard let freshWindow = try await refreshWindow(windowID: window.windowID) else {
            print("[ScreenCapture] Window disappeared before capture start: \(window.windowID)")
            return
        }

        self.capturedWindow = freshWindow

        let filter = SCContentFilter(desktopIndependentWindow: freshWindow)

        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(freshWindow.frame.width * scale)
        config.height = Int(freshWindow.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        // CRITICAL: Set self.stream BEFORE startCapture() to prevent deallocation
        // during the async gap
        self.stream = newStream

        // Retry logic — ScreenCaptureKit can fail transiently after permission grant
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await newStream.startCapture()
                lastError = nil
                break
            } catch {
                lastError = error
                print("[ScreenCapture] Attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 300_000_000) // 300ms between retries
                }
            }
        }

        if let error = lastError {
            self.stream = nil
            self.capturedWindow = nil
            throw error
        }

        self.isCapturing = true

        print("[ScreenCapture] Capturing: \(freshWindow.owningApplication?.applicationName ?? "?") — \"\(freshWindow.title ?? "untitled")\" (\(config.width)x\(config.height))")

        // Build a Sendable snapshot — safe to pass across concurrency boundaries
        let snapshot = WindowSnapshot(
            windowID: freshWindow.windowID,
            title: freshWindow.title ?? "",
            frame: freshWindow.frame,
            appName: freshWindow.owningApplication?.applicationName ?? ""
        )

        let callback = onCaptureStarted
        await MainActor.run {
            callback?(snapshot)
        }
    }

    /// Stop capture and wait for the stream to fully shut down.
    /// Async to avoid the race where a new stream starts while the old one is still alive.
    func stopCapture() async {
        guard let stream = stream else {
            // Clear state even if stream is already nil (defensive)
            self.stream = nil
            self.isCapturing = false
            self.capturedWindow = nil
            return
        }

        do {
            try await stream.stopCapture()
        } catch {
            print("[ScreenCapture] stopCapture error: \(error)")
        }

        self.stream = nil
        self.isCapturing = false
        self.capturedWindow = nil
        print("[ScreenCapture] Stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Convert CVPixelBuffer -> MTLTexture (zero-copy via texture cache)
        guard let texture = makeTexture(from: pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Dispatch to dedicated processing queue — keep main thread free for UI
        processingQueue.async { [weak self] in
            self?.onFrame?(texture, width, height)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapture] Stream stopped with error: \(error)")
        // Clean up ALL state so nothing is stale
        self.stream = nil
        self.capturedWindow = nil
        self.isCapturing = false
    }

    // MARK: - Texture Conversion

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    deinit {
        // Best-effort cleanup in deinit — can't await here
        if let stream = stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        isCapturing = false
        capturedWindow = nil
    }
}
