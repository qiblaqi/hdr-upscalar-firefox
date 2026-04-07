import AppKit
import Metal
import QuartzCore

/// Borderless overlay window with a CAMetalLayer for EDR/HDR output.
/// Positioned exactly over the captured window region.
final class OverlayWindow {
    private let device: MTLDevice
    private var window: NSWindow?
    private var metalLayer: CAMetalLayer?

    init(device: MTLDevice) {
        self.device = device
    }

    func show(frame: NSRect) {
        if window == nil {
            createWindow()
        }
        applyFrame(frame)
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            window?.orderFront(nil)
        } else {
            window?.orderOut(nil)
        }
    }

    func updateFrame(_ frame: NSRect) {
        applyFrame(frame)
    }

    func present(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let drawable = metalLayer?.nextDrawable() else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        // Texture should already be at native resolution (pipeline handles downscaling)
        let copySize = MTLSize(
            width: min(texture.width, drawable.texture.width),
            height: min(texture.height, drawable.texture.height),
            depth: 1
        )

        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: copySize,
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        commandBuffer.present(drawable)
    }

    // MARK: - Private

    private func applyFrame(_ frame: NSRect) {
        guard let window = window else { return }

        // ScreenCaptureKit / CGWindowList gives screen coordinates with top-left origin (Quartz).
        // NSWindow uses bottom-left origin (Cocoa). We must flip Y using the correct screen,
        // not NSScreen.main, to handle multi-display setups properly.
        let screenFrame = screenContaining(quartzRect: frame)?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let flippedY = screenFrame.maxY - frame.origin.y - frame.height
        let nsFrame = NSRect(x: frame.origin.x, y: flippedY, width: frame.width, height: frame.height)
        window.setFrame(nsFrame, display: true)

        // Drawable matches window size at Retina resolution
        let scale = window.backingScaleFactor
        metalLayer?.drawableSize = CGSize(
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    /// Find which NSScreen contains the given Quartz (top-left origin) rect.
    /// Returns nil if no screen contains the rect center.
    private func screenContaining(quartzRect: NSRect) -> NSScreen? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryHeight = primaryScreen.frame.height
        let cocoaY = primaryHeight - quartzRect.origin.y - quartzRect.height
        let cocoaCenter = NSPoint(
            x: quartzRect.midX,
            y: cocoaY + quartzRect.height / 2
        )

        return NSScreen.screens.first { NSPointInRect(cocoaCenter, $0.frame) }
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView()
        window.contentView = view

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.framebufferOnly = false
        layer.contentsGravity = .resizeAspectFill

        view.wantsLayer = true
        view.layer = layer

        self.window = window
        self.metalLayer = layer
    }
}
