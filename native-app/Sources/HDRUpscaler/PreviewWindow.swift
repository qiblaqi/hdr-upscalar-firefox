import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import HDRUpscalerCore

/// Independent preview window with a CAMetalLayer for EDR/HDR output.
/// Unlike the old OverlayWindow, this is a normal titled/resizable window that the user can
/// freely position — it does NOT track the Firefox window.
///
/// Uses MPS to scale the pipeline output texture to fit the drawable, so the window can be
/// any size and the video fills it correctly.
final class PreviewWindow {
    private let device: MTLDevice
    private var window: NSWindow?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var isShowing = false

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
    }

    /// Show the preview window with a given video size for aspect ratio.
    func show(videoSize: CGSize) {
        if window == nil {
            createWindow()
        }

        guard let window = window else { return }

        // Only reposition if this is the first show
        if !isShowing {
            // Set initial size to match video aspect ratio (capped to reasonable screen size)
            let maxWidth: CGFloat = 1280
            let maxHeight: CGFloat = 800
            let aspect = videoSize.width / max(videoSize.height, 1)
            var w = min(maxWidth, videoSize.width)
            var h = w / max(aspect, 0.1)
            if h > maxHeight {
                h = maxHeight
                w = h * max(aspect, 0.1)
            }

            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - w / 2
                let y = screenFrame.midY - h / 2
                window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            }

            isShowing = true
        }

        window.contentAspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
        updateDrawableSize()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logInfo("[PreviewWindow] Showing — video \(Int(videoSize.width))x\(Int(videoSize.height))")
    }

    func hide() {
        window?.orderOut(nil)
        isShowing = false
    }

    /// Update the window title (e.g., video source info).
    func setTitle(_ title: String) {
        window?.title = title
    }

    /// Present a processed texture to the window.
    /// Uses MPS bilinear scale to fit the texture to the drawable size, preserving quality.
    /// The texture can be any size — MPS handles the scaling.
    func present(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let layer = metalLayer, let drawable = layer.nextDrawable() else { return }

        let drawW = drawable.texture.width
        let drawH = drawable.texture.height

        if texture.width == drawW && texture.height == drawH {
            // Exact match: fast blit path
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
            blitEncoder.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: drawW, height: drawH, depth: 1),
                to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        } else {
            // Scale texture to fit drawable
            let scale = MPSImageBilinearScale(device: device)
            scale.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: drawable.texture)
        }

        commandBuffer.present(drawable)
    }

    // MARK: - Private

    private func updateDrawableSize() {
        guard let window = window, let metalLayer = metalLayer else { return }
        let scale = window.backingScaleFactor
        let contentSize = window.contentView?.bounds.size ?? window.frame.size
        metalLayer.drawableSize = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "HDR Preview"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 180)

        let view = NSView()
        view.wantsLayer = true

        // Observe resize to update drawable size
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.updateDrawableSize()
        }
        view.postsFrameChangedNotifications = true

        window.contentView = view

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.framebufferOnly = false
        layer.contentsGravity = .resizeAspect

        view.layer = layer

        self.window = window
        self.metalLayer = layer
    }
}
