import XCTest
import CoreGraphics
@testable import HDRUpscalerCore

final class CoordinateMapperTests: XCTestCase {

    // MARK: - Basic Mapping

    /// Standard case: 1280x720 video on a 1440x900 viewport, 2x Retina,
    /// Firefox window with ~148px chrome (title + tab + address bar at 2x).
    func testStandardVideoMapping() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 80, y: 56, width: 1280, height: 720),
            viewport: ViewportSize(width: 1440, height: 900),
            devicePixelRatio: 2.0,
            captureWidth: 2880,   // 1440 * 2
            captureHeight: 1948   // 900*2 + chrome(148px at 2x = ~148)
        )

        // Chrome height = 1948 - 900*2 = 148px
        // pixelX = 0 + 80*2 = 160, fracX = 160/2880 ≈ 0.0556
        // pixelY = 148 + 56*2 = 260, fracY = 260/1948 ≈ 0.1335
        // pixelW = 1280*2 = 2560, fracW = 2560/2880 ≈ 0.8889
        // pixelH = 720*2 = 1440, fracH = 1440/1948 ≈ 0.7393

        XCTAssertEqual(roi.origin.x, 160.0 / 2880.0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 260.0 / 1948.0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 2560.0 / 2880.0, accuracy: 0.001)
        XCTAssertEqual(roi.height, 1440.0 / 1948.0, accuracy: 0.001)
    }

    /// Video fills the entire viewport (e.g. fullscreen mode).
    func testFullscreenVideo() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: 0, width: 1440, height: 900),
            viewport: ViewportSize(width: 1440, height: 900),
            devicePixelRatio: 2.0,
            captureWidth: 2880,
            captureHeight: 1800  // No chrome in fullscreen
        )

        // Chrome = 1800 - 1800 = 0
        // Full viewport → full capture
        XCTAssertEqual(roi.origin.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(roi.height, 1.0, accuracy: 0.001)
    }

    /// 1x DPI (non-Retina external display).
    func testNonRetina() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: 0, width: 1280, height: 720),
            viewport: ViewportSize(width: 1920, height: 1080),
            devicePixelRatio: 1.0,
            captureWidth: 1920,
            captureHeight: 1154  // 1080 + 74px chrome
        )

        let chromeH = 1154.0 - 1080.0 // 74
        XCTAssertEqual(roi.origin.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, chromeH / 1154.0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 1280.0 / 1920.0, accuracy: 0.001)
        XCTAssertEqual(roi.height, 720.0 / 1154.0, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    /// DPR clamped to minimum 1.0 when extension reports 0 or negative.
    func testDPRClampedToMinimum() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: 0, width: 100, height: 100),
            viewport: ViewportSize(width: 1000, height: 1000),
            devicePixelRatio: 0.0,   // Invalid — should clamp to 1.0
            captureWidth: 1000,
            captureHeight: 1000
        )

        // DPR clamped to 1.0, chrome = 1000 - 1000*1 = 0
        XCTAssertEqual(roi.origin.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 0.1, accuracy: 0.001)
        XCTAssertEqual(roi.height, 0.1, accuracy: 0.001)
    }

    /// Video partially off-screen (negative y from scrolling).
    func testVideoPartiallyOffScreen() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: -200, width: 1280, height: 720),
            viewport: ViewportSize(width: 1440, height: 900),
            devicePixelRatio: 2.0,
            captureWidth: 2880,
            captureHeight: 1948
        )

        // pixelY = 148 + (-200)*2 = 148 - 400 = -252
        // fracY = -252/1948 → clamped to 0
        // height gets clamped too: min(1 - 0, 1440/1948)
        XCTAssertEqual(roi.origin.y, 0.0, accuracy: 0.001)
        XCTAssertTrue(roi.height > 0)
        XCTAssertTrue(roi.height <= 1.0)
    }

    /// Zero-size capture (degenerate input).
    func testZeroCaptureSize() {
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: 0, width: 100, height: 100),
            viewport: ViewportSize(width: 100, height: 100),
            devicePixelRatio: 1.0,
            captureWidth: 0,
            captureHeight: 0
        )

        // Division by zero → NaN → clamp should handle
        // Just verify it doesn't crash
        XCTAssertFalse(roi.width.isNaN)
    }

    // MARK: - Sidebar

    /// Firefox with sidebar open (viewport narrower than capture).
    func testSidebarOpen() {
        // Window is 1440pt wide at 2x = 2880px capture
        // Sidebar takes 300px (CSS) → viewport is 1140px wide
        let roi = CoordinateMapper.mapToCapture(
            videoRect: DOMRect(x: 0, y: 0, width: 1140, height: 720),
            viewport: ViewportSize(width: 1140, height: 900),
            devicePixelRatio: 2.0,
            captureWidth: 2880,
            captureHeight: 1948
        )

        // leftOffset = 2880 - 1140*2 = 2880 - 2280 = 600px
        // pixelX = 600 + 0 = 600, fracX = 600/2880 ≈ 0.2083
        XCTAssertEqual(roi.origin.x, 600.0 / 2880.0, accuracy: 0.001)
        // Video width = 1140*2 = 2280, fracW = 2280/2880 ≈ 0.7917
        XCTAssertEqual(roi.width, 2280.0 / 2880.0, accuracy: 0.001)
    }

    // MARK: - Validity Check

    func testValidRegion() {
        XCTAssertTrue(CoordinateMapper.isValidRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        XCTAssertTrue(CoordinateMapper.isValidRegion(CGRect(x: 0, y: 0, width: 0.02, height: 0.02)))
    }

    func testInvalidRegion() {
        XCTAssertFalse(CoordinateMapper.isValidRegion(CGRect(x: 0, y: 0, width: 0.005, height: 0.005)))
        XCTAssertFalse(CoordinateMapper.isValidRegion(CGRect(x: 0, y: 0, width: 0, height: 0)))
        XCTAssertFalse(CoordinateMapper.isValidRegion(CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.5)))
    }
}
