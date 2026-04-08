import Foundation
import CoreGraphics

/// Maps DOM viewport coordinates (from the Firefox extension) to fractional coordinates
/// within the ScreenCaptureKit capture frame.
///
/// The key insight: the capture frame includes the full Firefox window (title bar, tab bar,
/// address bar, content area). The extension reports the video rect relative to the viewport
/// (content area only). By knowing the viewport height and the capture height, we can infer
/// the browser chrome offset.
///
/// DOM viewport coords → device pixels → fractional rect within capture frame.
public struct CoordinateMapper {

    /// Convert a DOM viewport rect to a fractional rect (0.0–1.0) within the capture frame.
    ///
    /// - Parameters:
    ///   - videoRect: The video element's DOMRect from `getBoundingClientRect()`, in CSS pixels
    ///   - viewport: The browser viewport size (`window.innerWidth/Height`), in CSS pixels
    ///   - devicePixelRatio: `window.devicePixelRatio` (e.g. 2.0 for Retina)
    ///   - captureWidth: Width of the ScreenCaptureKit capture texture in pixels
    ///   - captureHeight: Height of the ScreenCaptureKit capture texture in pixels
    /// - Returns: Fractional CGRect (0.0–1.0) for use with `HDRPipeline.setVideoRegion()`
    public static func mapToCapture(
        videoRect: DOMRect,
        viewport: ViewportSize,
        devicePixelRatio: Double,
        captureWidth: Int,
        captureHeight: Int
    ) -> CGRect {
        let dpr = max(devicePixelRatio, 1.0)

        // Viewport height in device pixels
        let vpHeightPx = viewport.height * dpr
        let vpWidthPx = viewport.width * dpr

        // Chrome height = total capture height minus viewport content area height
        // This accounts for title bar, tab bar, address bar, bookmarks bar, etc.
        let chromeHeightPx = max(0, Double(captureHeight) - vpHeightPx)

        // Horizontal: viewport maps directly to the capture width.
        // If there's a sidebar, Firefox reports a smaller innerWidth (viewport),
        // and the content area still starts at the left edge of the viewport.
        // The capture frame width equals window width × DPR, and viewport.width × DPR
        // may be smaller if sidebars are open, but the viewport origin is at the left of
        // the content area, which corresponds to (captureWidth - vpWidthPx) from the left
        // of the capture frame (sidebar is on the left in Firefox).
        // For simplicity and correctness: the viewport's X=0 maps to captureWidth - vpWidthPx.
        let leftOffsetPx = max(0, Double(captureWidth) - vpWidthPx)

        // Video rect in device pixels, offset by chrome
        let pixelX = leftOffsetPx + videoRect.x * dpr
        let pixelY = chromeHeightPx + videoRect.y * dpr
        let pixelW = videoRect.width * dpr
        let pixelH = videoRect.height * dpr

        // Convert to fractional coordinates
        let fracX = pixelX / Double(captureWidth)
        let fracY = pixelY / Double(captureHeight)
        let fracW = pixelW / Double(captureWidth)
        let fracH = pixelH / Double(captureHeight)

        // Clamp to valid range
        let clampedX = max(0, min(1, fracX))
        let clampedY = max(0, min(1, fracY))
        let clampedW = max(0, min(1 - clampedX, fracW))
        let clampedH = max(0, min(1 - clampedY, fracH))

        return CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    /// Check if a mapped region is valid (has meaningful size).
    public static func isValidRegion(_ rect: CGRect) -> Bool {
        return rect.width > 0.01 && rect.height > 0.01
    }
}
