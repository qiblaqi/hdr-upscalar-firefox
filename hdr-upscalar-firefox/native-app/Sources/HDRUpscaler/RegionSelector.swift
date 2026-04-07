import AppKit

/// Full-screen overlay that lets the user click-drag to select a rectangular region.
/// Used to select the video player area within the Firefox window.
final class RegionSelector {
    private var panel: NSPanel?
    private var selectionView: SelectionView?

    /// Called with the selected region in screen coordinates (Quartz top-left origin).
    /// Returns nil if the user cancels (press Escape or click without dragging).
    var onRegionSelected: ((NSRect) -> Void)?

    /// Show the selection overlay on the screen containing the given window frame.
    func show(windowFrame: NSRect) {
        // Find the screen that contains the window
        let screen = NSScreen.screens.first { screen in
            screen.frame.intersects(windowFrame)
        } ?? NSScreen.main ?? NSScreen.screens.first!

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        panel.level = .screenSaver  // above everything
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces]

        let view = SelectionView(frame: screen.frame)
        view.windowFrame = windowFrame
        view.screenFrame = screen.frame
        view.onComplete = { [weak self] rect in
            self?.handleSelection(rect)
        }
        view.onCancel = { [weak self] in
            self?.dismiss()
        }

        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)

        // Make our app temporarily active so we can receive mouse events
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
        self.selectionView = view

        print("[RegionSelector] Select the video area by clicking and dragging. Press Escape to cancel.")
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        selectionView = nil
    }

    private func handleSelection(_ rect: NSRect) {
        guard rect.width > 50 && rect.height > 50 else {
            print("[RegionSelector] Selection too small, cancelled")
            dismiss()
            return
        }

        print("[RegionSelector] Selected region: \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))")
        dismiss()
        onRegionSelected?(rect)
    }
}

// MARK: - Selection View

/// Custom view that handles click-drag to draw a selection rectangle.
private class SelectionView: NSView {
    var windowFrame: NSRect = .zero
    var screenFrame: NSRect = .zero
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Set crosshair cursor
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
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

        // Build rect from drag points (Cocoa coordinates, bottom-left origin)
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)
        let cocoaRect = NSRect(x: x, y: y, width: w, height: h)

        // Convert to screen coordinates
        guard let windowObj = window else { return }
        let screenRect = windowObj.convertToScreen(cocoaRect)

        // Convert Cocoa (bottom-left origin) to Quartz (top-left origin)
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryHeight = primaryScreen.frame.height
        let quartzRect = NSRect(
            x: screenRect.origin.x,
            y: primaryHeight - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )

        onComplete?(quartzRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw semi-transparent overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        // Draw selection rectangle
        guard isDragging, let start = dragStart, let end = dragEnd else {
            // Draw instruction text
            let text = "Click and drag to select the video area\nPress Escape to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            text.draw(in: textRect, withAttributes: attrs)
            return
        }

        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let w = abs(end.x - start.x)
        let h = abs(end.y - start.y)
        let selRect = NSRect(x: x, y: y, width: w, height: h)

        // Clear the selected area (make it transparent to show what's being selected)
        NSColor.clear.setFill()
        selRect.fill()

        // Draw border
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selRect)
        path.lineWidth = 2.0
        path.stroke()

        // Draw size label
        let label = "\(Int(w)) × \(Int(h))"
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let labelSize = label.size(withAttributes: labelAttrs)
        let labelRect = NSRect(
            x: selRect.midX - labelSize.width / 2,
            y: selRect.maxY + 8,
            width: labelSize.width + 8,
            height: labelSize.height + 4
        )
        label.draw(in: labelRect, withAttributes: labelAttrs)
    }
}
