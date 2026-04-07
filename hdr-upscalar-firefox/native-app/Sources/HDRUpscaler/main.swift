import AppKit
import Metal
import ScreenCaptureKit

/// HDR Upscaler — pure native macOS app.
/// Captures Firefox window via ScreenCaptureKit, applies MetalFX upscale + EDR remap, displays via overlay.

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

/// Centralized app state.
enum AppState: CustomStringConvertible {
    case idle
    case selecting
    case starting(windowID: CGWindowID)
    case capturing(windowID: CGWindowID)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .selecting: return "selecting"
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
    private var regionSelector: RegionSelector?

    private var selectTask: Task<Void, Never>?

    // Video region crop — nil means full window
    private var videoRegion: CGRect?
    // Last known window frame (Quartz coords) for region offset calculation
    private var lastWindowFrame: CGRect?

    private var state: AppState = .idle {
        didSet {
            print("[HDR Upscaler] State: \(oldValue) → \(state)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[HDR Upscaler] Error: Metal is not supported")
            NSApp.terminate(nil)
            return
        }
        self.device = device
        print("[HDR Upscaler] Metal device: \(device.name)")

        do {
            pipeline = try HDRPipeline(device: device)
            let edr = NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 2.0
            print("[HDR Upscaler] Pipeline ready (EDR headroom: \(String(format: "%.1f", edr))x)")
        } catch {
            print("[HDR Upscaler] Pipeline error: \(error)")
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

        statusBar?.onSelectVideoRegion = { [weak self] in
            self?.startRegionSelection()
        }

        statusBar?.onResetVideoRegion = { [weak self] in
            self?.resetVideoRegion()
        }

        statusBar?.onQuit = {
            NSApp.terminate(nil)
        }

        capture = ScreenCapture(device: device)

        capture?.onFrame = { [weak self] texture, width, height in
            self?.pipeline?.processFrame(inputTexture: texture, width: width, height: height)
        }

        capture?.onCaptureStarted = { [weak self] snapshot in
            guard let self = self else { return }
            self.state = .capturing(windowID: snapshot.windowID)
            self.lastWindowFrame = snapshot.frame
            self.pipeline?.start(windowFrame: snapshot.frame)
            self.startWindowTracking(windowID: snapshot.windowID)
            self.statusBar?.updateStatus(capturing: true, windowTitle: snapshot.title.isEmpty ? "Firefox" : snapshot.title)

            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let inputW = Int(snapshot.frame.width * scale)
            let inputH = Int(snapshot.frame.height * scale)
            self.statusBar?.updateAvailableFactors(inputWidth: inputW, inputHeight: inputH)
        }

        Task {
            await startWithPermissionCheck()
        }
    }

    // MARK: - Video Region Selection

    private func startRegionSelection() {
        guard let frame = lastWindowFrame else {
            print("[HDR Upscaler] No window frame known yet")
            return
        }

        // Pause the overlay while selecting
        pipeline?.setTabVisible(false)

        regionSelector = RegionSelector()
        regionSelector?.onRegionSelected = { [weak self] selectedRect in
            self?.applyVideoRegion(selectedRect)
        }
        regionSelector?.show(windowFrame: frame)
    }

    private func applyVideoRegion(_ screenRect: CGRect) {
        guard let windowFrame = lastWindowFrame else { return }

        // Convert screen-absolute rect to window-relative rect
        let relativeX = screenRect.origin.x - windowFrame.origin.x
        let relativeY = screenRect.origin.y - windowFrame.origin.y
        let relativeRect = CGRect(
            x: max(0, relativeX),
            y: max(0, relativeY),
            width: min(screenRect.width, windowFrame.width - max(0, relativeX)),
            height: min(screenRect.height, windowFrame.height - max(0, relativeY))
        )

        self.videoRegion = relativeRect
        self.statusBar?.setHasVideoRegion(true)

        print("[HDR Upscaler] Video region set: \(Int(relativeRect.origin.x)),\(Int(relativeRect.origin.y)) \(Int(relativeRect.width))x\(Int(relativeRect.height)) (relative to window)")

        // Update capture to only stream this region
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.capture?.updateCaptureRect(relativeRect)
                // Update overlay to cover only the video region
                let videoScreenRect = CGRect(
                    x: windowFrame.origin.x + relativeRect.origin.x,
                    y: windowFrame.origin.y + relativeRect.origin.y,
                    width: relativeRect.width,
                    height: relativeRect.height
                )
                self.pipeline?.updateOverlayFrame(videoScreenRect)
                self.pipeline?.setTabVisible(true)

                // Update available factors for the smaller capture size
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                let inputW = Int(relativeRect.width * scale)
                let inputH = Int(relativeRect.height * scale)
                self.statusBar?.updateAvailableFactors(inputWidth: inputW, inputHeight: inputH)

                print("[HDR Upscaler] Capture cropped to video region (\(inputW)x\(inputH) pixels)")
            } catch {
                print("[HDR Upscaler] Failed to update capture rect: \(error)")
                self.pipeline?.setTabVisible(true)
            }
        }
    }

    private func resetVideoRegion() {
        videoRegion = nil
        statusBar?.setHasVideoRegion(false)
        print("[HDR Upscaler] Video region reset to full window")

        // Restart capture for full window
        guard case .capturing(let windowID) = state else { return }
        Task { [weak self] in
            guard let self = self, let capture = self.capture else { return }
            // Re-find and restart capture to reset sourceRect
            let windows = try? await capture.findFirefoxWindows()
            if let target = windows?.first(where: { $0.windowID == windowID }) {
                try? await capture.startCapture(window: target)
            }
        }
    }

    // MARK: - Startup

    private func startWithPermissionCheck() async {
        guard let capture = capture else { return }

        print("[HDR Upscaler] Checking Screen Recording permission...")

        let hasPermission = await capture.checkPermission()
        if !hasPermission {
            print("")
            print("╔══════════════════════════════════════════════════════════╗")
            print("║  Screen Recording permission required!                  ║")
            print("║                                                         ║")
            print("║  1. Open System Settings → Privacy & Security           ║")
            print("║     → Screen Recording                                  ║")
            print("║  2. Enable access for Terminal (or your IDE)            ║")
            print("║  3. Restart this app                                    ║")
            print("╚══════════════════════════════════════════════════════════╝")
            print("")
            return
        }

        print("[HDR Upscaler] Permission OK")
        scheduleWindowSelection()
    }

    // MARK: - Firefox Window Selection (single-flight)

    private func scheduleWindowSelection(after delay: TimeInterval = 0) {
        selectTask?.cancel()
        selectTask = Task { [weak self] in
            guard let self = self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self.selectFirefoxWindow()
        }
    }

    private func selectFirefoxWindow() async {
        guard let capture = capture else { return }

        if case .selecting = state { return }
        if case .starting = state { return }
        state = .selecting

        do {
            let windows = try await capture.findFirefoxWindows()

            if windows.isEmpty {
                print("[HDR Upscaler] No Firefox windows found. Waiting...")
                state = .idle
                scheduleWindowSelection(after: 3)
                return
            }

            let target = windows.first!

            if !capture.shouldRestart(for: target) {
                print("[HDR Upscaler] Already capturing this window, skipping restart")
                if case .capturing(let id) = state, id == target.windowID {
                } else {
                    state = .capturing(windowID: target.windowID)
                }
                return
            }

            print("[HDR Upscaler] Found Firefox: \"\(target.title ?? "untitled")\" (\(Int(target.frame.width))x\(Int(target.frame.height)))")

            state = .starting(windowID: target.windowID)
            try await capture.startCapture(window: target)

        } catch {
            print("[HDR Upscaler] Capture failed: \(error.localizedDescription)")
            print("[HDR Upscaler] Retrying in 5s...")
            state = .idle
            scheduleWindowSelection(after: 5)
        }
    }

    // MARK: - Window Position Tracking

    private func startWindowTracking(windowID: CGWindowID) {
        windowTracker?.invalidate()
        windowTracker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.trackWindowPosition(windowID: windowID)
            }
        }
    }

    private func trackWindowPosition(windowID: CGWindowID) {
        guard let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = windowList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let w = boundsDict["Width"] as? CGFloat,
              let h = boundsDict["Height"] as? CGFloat else {
            windowTracker?.invalidate()
            windowTracker = nil
            pipeline?.stop()
            statusBar?.updateStatus(capturing: false, windowTitle: "Not connected")
            print("[HDR Upscaler] Firefox window closed. Stopping capture and waiting for new window...")
            state = .idle
            videoRegion = nil
            statusBar?.setHasVideoRegion(false)
            Task { [weak self] in
                guard let self = self else { return }
                await self.capture?.stopCapture()
                self.scheduleWindowSelection(after: 0.5)
            }
            return
        }

        let windowFrame = CGRect(x: x, y: y, width: w, height: h)
        lastWindowFrame = windowFrame

        // If video region is set, position overlay over just the video area
        if let region = videoRegion {
            let videoScreenRect = CGRect(
                x: windowFrame.origin.x + region.origin.x,
                y: windowFrame.origin.y + region.origin.y,
                width: region.width,
                height: region.height
            )
            pipeline?.updateOverlayFrame(videoScreenRect)
        } else {
            pipeline?.updateOverlayFrame(windowFrame)
        }

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let isFront = frontApp.bundleIdentifier?.localizedCaseInsensitiveContains("firefox") ?? false
            pipeline?.setTabVisible(isFront)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        selectTask?.cancel()
        windowTracker?.invalidate()
        pipeline?.stop()
        regionSelector?.dismiss()
        let capture = self.capture
        Task { await capture?.stopCapture() }
    }
}
