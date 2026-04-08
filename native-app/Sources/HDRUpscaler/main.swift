import AppKit
import Metal
import ScreenCaptureKit
import HDRUpscalerCore

/// HDR Upscaler — native macOS app.
///
/// Two modes of operation:
/// 1. **Native messaging mode** (launched by Firefox extension): reads video position from
///    stdin, captures Firefox window, processes video ROI, displays in preview window.
/// 2. **Standalone mode** (launched directly): auto-discovers Firefox windows and processes
///    the full window. Useful for development/testing without the extension.

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

/// Centralized app state.
enum AppState: CustomStringConvertible {
    case idle
    case connecting       // Extension connected, waiting for first video_rect
    case starting(windowID: CGWindowID)
    case capturing(windowID: CGWindowID)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .starting(let id): return "starting(\(id))"
        case .capturing(let id): return "capturing(\(id))"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: HDRPipeline?
    private var capture: ScreenCapture?
    private var device: MTLDevice?
    private var statusBar: StatusBarMenu?
    private var windowTracker: Timer?

    // Native messaging (only active in native messaging mode)
    private var nativeReader: NativeMessagingReader?
    private var nativeWriter: NativeMessagingWriter?
    private var isNativeMode = false

    // Standalone mode: auto-discover task
    private var selectTask: Task<Void, Never>?

    // Last known capture dimensions (for coordinate mapping)
    private var lastCaptureWidth: Int = 0
    private var lastCaptureHeight: Int = 0

    // Last known video natural size
    private var lastVideoSize: CGSize = CGSize(width: 1280, height: 720)

    // Guard against multiple simultaneous capture-start attempts
    private var captureStartInProgress = false

    private var state: AppState = .idle {
        didSet {
            logInfo("[HDR Upscaler] State: \(oldValue) → \(state)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let device = MTLCreateSystemDefaultDevice() else {
            logInfo("[HDR Upscaler] Error: Metal is not supported")
            NSApp.terminate(nil)
            return
        }
        self.device = device
        logInfo("[HDR Upscaler] Metal device: \(device.name)")

        do {
            pipeline = try HDRPipeline(device: device)
            let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0
            logInfo("[HDR Upscaler] Pipeline ready (EDR headroom: \(String(format: "%.1f", edr))x)")
        } catch {
            logInfo("[HDR Upscaler] Pipeline error: \(error)")
            NSApp.terminate(nil)
            return
        }

        // Setup menu bar
        statusBar = StatusBarMenu()
        statusBar?.setup()
        statusBar?.setCurrentFactor(2.0)
        statusBar?.setCurrentIntensity(0.3)

        statusBar?.onUpscaleFactorChanged = { [weak self] factor in
            self?.pipeline?.setUpscaleFactor(factor)
        }

        statusBar?.onHDRIntensityChanged = { [weak self] intensity in
            self?.pipeline?.setHDRIntensity(intensity)
        }

        statusBar?.onQuit = {
            NSApp.terminate(nil)
        }

        // Setup capture
        capture = ScreenCapture(device: device)

        capture?.onFrame = { [weak self] texture, width, height in
            guard let self = self else { return }
            self.lastCaptureWidth = width
            self.lastCaptureHeight = height
            self.pipeline?.processFrame(inputTexture: texture, width: width, height: height)
        }

        capture?.onCaptureStarted = { [weak self] snapshot in
            guard let self = self else { return }
            self.captureStartInProgress = false
            self.state = .capturing(windowID: snapshot.windowID)
            self.statusBar?.updateStatus(capturing: true, windowTitle: snapshot.title.isEmpty ? "Firefox" : snapshot.title)

            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let inputW = Int(snapshot.frame.width * scale)
            let inputH = Int(snapshot.frame.height * scale)
            self.statusBar?.updateAvailableFactors(inputWidth: inputW, inputHeight: inputH)

            // Start the pipeline with the video's natural size
            self.pipeline?.start(videoSize: self.lastVideoSize)

            // Start window existence tracking
            self.startWindowTracking(windowID: snapshot.windowID)

            // Notify extension that capture started
            self.nativeWriter?.sendCaptureInfo(
                capturing: true,
                windowTitle: snapshot.title,
                captureWidth: inputW,
                captureHeight: inputH
            )
        }

        // Detect mode: native messaging (stdin is pipe) vs standalone (stdin is tty)
        isNativeMode = isNativeMessagingMode()

        if isNativeMode {
            logInfo("[HDR Upscaler] Mode: Native Messaging (launched by Firefox extension)")
            setupNativeMessaging()
        } else {
            logInfo("[HDR Upscaler] Mode: Standalone (no extension — auto-discovering Firefox windows)")
            setupStandaloneMode()
        }
    }

    // MARK: - Native Messaging Mode

    private func setupNativeMessaging() {
        nativeWriter = NativeMessagingWriter()
        nativeReader = NativeMessagingReader()

        nativeReader?.onVideoRect = { [weak self] msg in
            DispatchQueue.main.async {
                self?.handleVideoRect(msg)
            }
        }

        nativeReader?.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                self?.handleExtensionDisconnect()
            }
        }

        nativeReader?.start()

        state = .connecting
        statusBar?.updateStatus(capturing: false, windowTitle: "Waiting for extension...")

        // Send ready status to extension
        nativeWriter?.sendStatus("ready", message: "HDR Upscaler native host started")

        Task { await checkPermission() }
    }

    private func handleVideoRect(_ msg: VideoRectMessage) {
        // Handle video_lost
        if msg.type == "video_lost" {
            logInfo("[HDR Upscaler] Extension reports: video lost")
            pipeline?.clearVideoRegion()
            pipeline?.stop()
            statusBar?.updateStatus(capturing: false, windowTitle: "No video detected")
            if case .capturing = state {
                Task { await capture?.stopCapture() }
            }
            captureStartInProgress = false
            state = .connecting
            nativeWriter?.sendCaptureInfo(capturing: false, windowTitle: nil)
            return
        }

        // Store natural size for preview window aspect ratio
        if let nw = msg.videoNaturalWidth, let nh = msg.videoNaturalHeight, nw > 0, nh > 0 {
            lastVideoSize = CGSize(width: nw, height: nh)
        }

        // If not yet capturing, find Firefox window and start
        switch state {
        case .idle, .connecting:
            startFirefoxCapture()
        default:
            break
        }

        // Map DOM coordinates to capture-frame fractional rect
        guard lastCaptureWidth > 0 && lastCaptureHeight > 0 else { return }

        let roi = CoordinateMapper.mapToCapture(
            videoRect: msg.rect,
            viewport: msg.viewport,
            devicePixelRatio: msg.devicePixelRatio,
            captureWidth: lastCaptureWidth,
            captureHeight: lastCaptureHeight
        )

        if CoordinateMapper.isValidRegion(roi) {
            pipeline?.setVideoRegion(roi)

            // Update available factors based on ROI size
            let roiW = Int(roi.width * CGFloat(lastCaptureWidth))
            let roiH = Int(roi.height * CGFloat(lastCaptureHeight))
            statusBar?.updateAvailableFactors(inputWidth: roiW, inputHeight: roiH)
        }

        // Update preview window title with video URL domain
        if let url = msg.url, let host = URL(string: url)?.host {
            pipeline?.previewWindow.setTitle("HDR Preview — \(host)")
        }
    }

    private func handleExtensionDisconnect() {
        logInfo("[HDR Upscaler] Extension disconnected — stdin closed")
        pipeline?.stop()
        windowTracker?.invalidate()
        windowTracker = nil
        captureStartInProgress = false
        Task { await capture?.stopCapture() }
        state = .idle
        statusBar?.updateStatus(capturing: false, windowTitle: "Extension disconnected")

        // In native messaging mode, stdin close means Firefox killed the host.
        // The process should exit so Firefox can restart it fresh on next connectNative().
        logInfo("[HDR Upscaler] Exiting — will be restarted by Firefox on next connect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Standalone Mode (no extension — for dev/testing)

    private func setupStandaloneMode() {
        logInfo("[HDR Upscaler] Standalone: will auto-discover Firefox windows and process full window")
        statusBar?.updateStatus(capturing: false, windowTitle: "Searching for Firefox...")

        Task { await startWithPermissionCheck() }
    }

    private func startWithPermissionCheck() async {
        let hasPermission = await checkPermission()
        if hasPermission {
            scheduleWindowSelection()
        }
    }

    private func scheduleWindowSelection(after delay: TimeInterval = 0) {
        selectTask?.cancel()
        selectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self?.selectFirefoxWindow()
        }
    }

    private func selectFirefoxWindow() async {
        guard let capture = capture else { return }
        if case .starting = state { return }
        if case .capturing = state { return }

        do {
            let windows = try await capture.findFirefoxWindows()
            if windows.isEmpty {
                logInfo("[HDR Upscaler] No Firefox windows found. Waiting...")
                state = .idle
                statusBar?.updateStatus(capturing: false, windowTitle: "No Firefox found — waiting...")
                scheduleWindowSelection(after: 3)
                return
            }

            let target = windows.first!
            if !capture.shouldRestart(for: target) { return }

            logInfo("[HDR Upscaler] Found Firefox: \"\(target.title ?? "untitled")\" (\(Int(target.frame.width))x\(Int(target.frame.height)))")
            state = .starting(windowID: target.windowID)
            try await capture.startCapture(window: target)

        } catch {
            logInfo("[HDR Upscaler] Capture failed: \(error.localizedDescription)")
            state = .idle
            scheduleWindowSelection(after: 5)
        }
    }

    // MARK: - Firefox Window Capture (shared)

    private func startFirefoxCapture() {
        // Prevent multiple simultaneous capture attempts
        guard !captureStartInProgress else { return }
        switch state {
        case .idle, .connecting: break
        default: return
        }
        captureStartInProgress = true

        Task { [weak self] in
            guard let self = self, let capture = self.capture else {
                await MainActor.run { self?.captureStartInProgress = false }
                return
            }

            let hasPermission = await capture.checkPermission()
            guard hasPermission else {
                logInfo("[HDR Upscaler] Screen Recording permission not granted")
                self.statusBar?.updateStatus(capturing: false, windowTitle: "Need Screen Recording permission")
                self.captureStartInProgress = false
                return
            }

            do {
                let windows = try await capture.findFirefoxWindows()
                guard let target = windows.first else {
                    logInfo("[HDR Upscaler] No Firefox window found — retrying in 2s")
                    self.statusBar?.updateStatus(capturing: false, windowTitle: "No Firefox window found")
                    self.captureStartInProgress = false
                    // Will retry on next video_rect message
                    return
                }

                if !capture.shouldRestart(for: target) {
                    self.captureStartInProgress = false
                    return
                }

                self.state = .starting(windowID: target.windowID)
                try await capture.startCapture(window: target)
                // captureStartInProgress cleared in onCaptureStarted callback

            } catch {
                logInfo("[HDR Upscaler] Capture failed: \(error)")
                self.state = .connecting
                self.statusBar?.updateStatus(capturing: false, windowTitle: "Capture failed — will retry")
                self.captureStartInProgress = false
            }
        }
    }

    @discardableResult
    private func checkPermission() async -> Bool {
        guard let capture = capture else { return false }

        let hasPermission = await capture.checkPermission()
        if !hasPermission {
            logInfo("")
            logInfo("╔══════════════════════════════════════════════════════════╗")
            logInfo("║  Screen Recording permission required!                  ║")
            logInfo("║                                                         ║")
            logInfo("║  1. Open System Settings → Privacy & Security           ║")
            logInfo("║     → Screen Recording                                  ║")
            logInfo("║  2. Enable access for Terminal (or your IDE)            ║")
            logInfo("║  3. Restart this app                                    ║")
            logInfo("╚══════════════════════════════════════════════════════════╝")
            logInfo("")
        } else {
            logInfo("[HDR Upscaler] Screen Recording permission OK")
        }
        return hasPermission
    }

    // MARK: - Window Existence Tracking

    /// Lightweight timer that checks if the Firefox window still exists.
    /// We don't track position (no overlay to move) — just detect disappearance.
    private func startWindowTracking(windowID: CGWindowID) {
        windowTracker?.invalidate()
        windowTracker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkWindowExists(windowID: windowID)
            }
        }
    }

    private func checkWindowExists(windowID: CGWindowID) {
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           !windowList.isEmpty {
            return // Window still exists
        }

        windowTracker?.invalidate()
        windowTracker = nil
        pipeline?.stop()
        captureStartInProgress = false
        logInfo("[HDR Upscaler] Firefox window closed — stopping capture")
        statusBar?.updateStatus(capturing: false, windowTitle: "Firefox window closed")
        Task { await capture?.stopCapture() }

        if isNativeMode {
            state = .connecting
            nativeWriter?.sendCaptureInfo(capturing: false, windowTitle: nil)
            // Will restart when next video_rect comes in
        } else {
            state = .idle
            scheduleWindowSelection(after: 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeReader?.stop()
        selectTask?.cancel()
        windowTracker?.invalidate()
        pipeline?.stop()
        let capture = self.capture
        Task { await capture?.stopCapture() }
    }
}
