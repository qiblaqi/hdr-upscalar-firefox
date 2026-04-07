import AppKit

/// Overlay that lets the user click-drag to select a rectangular region within the Firefox window.
/// The panel is positioned exactly over the window, so drag coordinates directly give
/// window-relative positions — no multi-display coordinate conversion needed.
final class RegionSelector {
    private var panel: NSPanel?
    private var selectionView: SelectionView?

    /// Called with the selected region as a fractional rect (0.0–1.0) relative to the window.
    /// This avoids Quartz/Cocoa coordinate conversion issues on multi-display setups.
    var onRegionSelected: ((CGRect) -> Void)?

    /// Show the selection overlay positioned exactly over the given window frame.
    /// `windowFrame` is in Quartz coordinates (top-left origin, from CGWindowListCopyWindowInfo).
    func show(windowFrame: CGRect) {
        // Convert Quartz (top-left) to Cocoa (bottom-left) for NSPanel positioning
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryHeight = primaryScreen.frame.height
        let cocoaY = primaryHeight - windowFrame.origin.y - windowFrame.height

        let panelFrame = NSRect(
            x: windowFrame.origin.x,
            y: cocoaY,
            width: windowFrame.width,
            height: windowFrame.height
        )

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces]

        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: windowFrame.width, height: windowFrame.height))
        view.windowWidth = windowFrame.width
        view.windowHeight = windowFrame.height
        view.onComplete = { [weak self] fractionalRect in
            self?.handleSelection(fractionalRect)
        }
        view.onCancel = { [weak self] in
            self?.dismiss()
        }

        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
        self.selectionView = view

        print("[RegionSelector] Drag over the video area. Press Escape to cancel.")
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        selectionView = nil
    }

    private func handleSelection(_ fractionalRect: CGRect) {
        guard fractionalRect.width > 0.03 && fractionalRect.height > 0.03 else {
            print("[RegionSelector] Selection too small, cancelled")
            dismiss()
            return
        }

        print("[RegionSelector] Selected: \(String(format: "%.1f%%", fractionalRect.origin.x * 100)),\(String(format: "%.1f%%", fractionalRect.origin.y * 100)) \(String(format: "%.1f%%", fractionalRect.width * 100))x\(String(format: "%.1f%%", fractionalRect.height * 100))")
        dismiss()
        onRegionSelected?(fractionalRect)
    }
}

// MARK: - Selection View

private class SelectionView: NSView {
    var windowWidth: CGFloat = 0
    var windowHeight: CGFloat = 0
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = dragStart else { return }
        isDragging = false
        let end = convert(event.locationInWindow, from: nil)

        // View coordinates: (0,0) is bottom-left of the panel (which covers the window exactly)
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)

        // Convert to fractional coordinates (0.0–1.0) relative to window
        // Flip Y: view has bottom-left origin, but we want top-left to match texture coordinates
        let fracX = x / windowWidth
        let fracY = 1.0 - (y + h) / windowHeight
        let fracW = w / windowWidth
        let fracH = h / windowHeight

        let fractionalRect = CGRect(
            x: max(0, min(1, fracX)),
            y: max(0, min(1, fracY)),
            width: max(0, min(1 - max(0, fracX), fracW)),
            height: max(0, min(1 - max(0, fracY), fracH))
        )

        onComplete?(fractionalRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        guard isDragging, let start = dragStart, let end = dragEnd else {
            let text = "Drag to select the video area\nPress Escape to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(in: NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            ), withAttributes: attrs)
            return
        }

        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)
        let selRect = NSRect(x: x, y: y, width: w, height: h)

        NSColor.clear.setFill()
        selRect.fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selRect)
        path.lineWidth = 2.0
        path.stroke()

        let label = "\(Int(w)) × \(Int(h))"
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let labelSize = label.size(withAttributes: labelAttrs)
        label.draw(in: NSRect(
            x: selRect.midX - labelSize.width / 2,
            y: selRect.maxY + 8,
            width: labelSize.width + 8, height: labelSize.height + 4
        ), withAttributes: labelAttrs)
    }
}
