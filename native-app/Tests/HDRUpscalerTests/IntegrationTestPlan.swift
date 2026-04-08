import XCTest
import Foundation
@testable import HDRUpscalerCore

/// Integration tests for the end-to-end native messaging pipeline.
///
/// These tests verify the full data path:
///   Extension JSON → Wire Protocol → NativeMessagingReader → CoordinateMapper → Pipeline ROI
///
/// They use pipes to simulate Firefox native messaging without needing the browser.
final class IntegrationTestPlan: XCTestCase {

    // MARK: - End-to-End: Extension Message → Coordinate ROI

    /// Simulate the full flow: extension sends video_rect → reader parses → mapper produces ROI.
    func testExtensionMessageToROI() throws {
        let pipe = Pipe()

        // Simulate what the extension sends (YouTube 1080p video)
        let extensionPayload = """
        {
            "type": "video_rect",
            "rect": {"x": 0, "y": 56, "width": 1280, "height": 720},
            "viewport": {"width": 1440, "height": 900},
            "devicePixelRatio": 2.0,
            "isFullscreen": false,
            "paused": false,
            "videoNaturalWidth": 1920,
            "videoNaturalHeight": 1080,
            "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "tabId": 1,
            "windowId": 1
        }
        """.data(using: .utf8)!

        // Encode in wire format
        var length = UInt32(extensionPayload.count)
        var wireData = Data(bytes: &length, count: 4)
        wireData.append(extensionPayload)
        pipe.fileHandleForWriting.write(wireData)
        pipe.fileHandleForWriting.closeFile()

        // Reader parses it
        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)
        let expectation = XCTestExpectation(description: "Message parsed")
        var parsedMsg: VideoRectMessage?

        reader.onVideoRect = { msg in
            parsedMsg = msg
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        guard let msg = parsedMsg else {
            XCTFail("No message received")
            return
        }

        // Now feed it through the coordinate mapper
        // Simulating a capture of 2880x1948 (1440x974 window at 2x, 74px chrome at 2x = 148px)
        let captureWidth = 2880
        let captureHeight = 1948

        let roi = CoordinateMapper.mapToCapture(
            videoRect: msg.rect,
            viewport: msg.viewport,
            devicePixelRatio: msg.devicePixelRatio,
            captureWidth: captureWidth,
            captureHeight: captureHeight
        )

        // Verify the ROI makes sense
        XCTAssertTrue(CoordinateMapper.isValidRegion(roi), "ROI should be valid")
        XCTAssertGreaterThan(roi.width, 0.5, "Video should take >50% of capture width")
        XCTAssertGreaterThan(roi.height, 0.3, "Video should take >30% of capture height")
        XCTAssertGreaterThan(roi.origin.y, 0.0, "Video should be offset from top by chrome")

        // Verify pixel-level correctness
        let roiPixelX = Int(roi.origin.x * CGFloat(captureWidth))
        let roiPixelY = Int(roi.origin.y * CGFloat(captureHeight))
        let roiPixelW = Int(roi.width * CGFloat(captureWidth))
        let roiPixelH = Int(roi.height * CGFloat(captureHeight))

        XCTAssertEqual(roiPixelX, 0, "Video starts at left edge")
        XCTAssertEqual(roiPixelW, 2560, "1280 CSS px * 2.0 DPR = 2560 device px")
        XCTAssertEqual(roiPixelH, 1440, "720 CSS px * 2.0 DPR = 1440 device px")

        // Chrome height = 1948 - 900*2 = 148
        // Video Y = 148 + 56*2 = 260
        XCTAssertEqual(roiPixelY, 260, "Video top = chrome(148) + rect.y(56)*2")
    }

    /// Simulate fullscreen transition: chrome disappears, video fills window.
    func testFullscreenTransition() throws {
        let pipe = Pipe()

        let fullscreenPayload = """
        {
            "type": "video_rect",
            "rect": {"x": 0, "y": 0, "width": 1440, "height": 900},
            "viewport": {"width": 1440, "height": 900},
            "devicePixelRatio": 2.0,
            "isFullscreen": true,
            "paused": false,
            "videoNaturalWidth": 1920,
            "videoNaturalHeight": 1080,
            "url": "https://www.youtube.com/watch?v=test"
        }
        """.data(using: .utf8)!

        var length = UInt32(fullscreenPayload.count)
        var wireData = Data(bytes: &length, count: 4)
        wireData.append(fullscreenPayload)
        pipe.fileHandleForWriting.write(wireData)
        pipe.fileHandleForWriting.closeFile()

        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)
        let expectation = XCTestExpectation(description: "Fullscreen message parsed")
        var parsedMsg: VideoRectMessage?

        reader.onVideoRect = { msg in
            parsedMsg = msg
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        guard let msg = parsedMsg else {
            XCTFail("No message received")
            return
        }

        XCTAssertTrue(msg.isFullscreen)

        // In fullscreen, capture is exactly viewport * DPR (no chrome)
        let roi = CoordinateMapper.mapToCapture(
            videoRect: msg.rect,
            viewport: msg.viewport,
            devicePixelRatio: msg.devicePixelRatio,
            captureWidth: 2880,  // 1440 * 2
            captureHeight: 1800  // 900 * 2 (no chrome)
        )

        // Should fill the entire capture frame
        XCTAssertEqual(roi.origin.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(roi.height, 1.0, accuracy: 0.001)
    }

    // MARK: - Bidirectional: Reader + Writer through pipe pair

    /// Test a round-trip: writer sends → reader receives through connected pipes.
    func testReaderWriterRoundTrip() throws {
        let pipe = Pipe()

        let writer = NativeMessagingWriter(outputHandle: pipe.fileHandleForWriting)
        let reader = NativeMessagingReader(inputHandle: pipe.fileHandleForReading)

        let outMsg = VideoRectMessage(
            type: "video_rect",
            rect: DOMRect(x: 50, y: 100, width: 800, height: 600),
            viewport: ViewportSize(width: 1024, height: 768),
            devicePixelRatio: 1.5,
            isFullscreen: false,
            paused: true,
            videoNaturalWidth: 1280,
            videoNaturalHeight: 960,
            url: "https://vimeo.com/12345"
        )

        // Writer sends, then close so reader gets EOF after the message
        try writer.sendSync(outMsg)
        pipe.fileHandleForWriting.closeFile()

        let expectation = XCTestExpectation(description: "Round trip")
        var received: VideoRectMessage?

        reader.onVideoRect = { msg in
            received = msg
            expectation.fulfill()
        }

        reader.start()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.rect.x, 50)
        XCTAssertEqual(received?.rect.width, 800)
        XCTAssertEqual(received?.viewport.width, 1024)
        XCTAssertEqual(received?.devicePixelRatio, 1.5)
        XCTAssertTrue(received?.paused == true)
        XCTAssertEqual(received?.url, "https://vimeo.com/12345")
    }
}

// MARK: - Manual Integration Test Checklist
//
// These require a running Firefox with the extension installed + the native app built.
// Run manually, not in CI.
//
// ## Setup
// 1. cd native-app && swift build
// 2. ./native-messaging-host/install.sh
// 3. Load extension in Firefox: about:debugging → Load Temporary Add-on → extension/manifest.json
//
// ## Test Cases
//
// ### TC-1: Basic video detection
// - Open YouTube, play a video
// - Verify in Swift app stderr: "[NativeMessaging] Read loop started"
// - Verify: "[HDRPipeline] Video region set: ..."
// - Verify preview window appears with video content
//
// ### TC-2: Tab switching
// - Open video in tab A, open text page in tab B
// - Switch to tab B → verify: "video_lost" received, pipeline stops
// - Switch back to tab A → verify: pipeline restarts with correct ROI
//
// ### TC-3: Fullscreen
// - Enter fullscreen on YouTube video
// - Verify ROI becomes ~100% of capture (no chrome offset)
// - Exit fullscreen → verify ROI shrinks back with chrome offset
//
// ### TC-4: Scroll
// - Open a page with embedded video (not fullscreen player)
// - Scroll the video partially off-screen
// - Verify ROI updates (y changes, height may clip)
//
// ### TC-5: Page navigation
// - While processing video, navigate to a different URL
// - Verify: "video_lost" sent, pipeline stops
// - Navigate to a page with video → verify pipeline restarts
//
// ### TC-6: Extension disconnect
// - While processing, disable the extension in about:addons
// - Verify Swift app detects stdin EOF and exits cleanly
//
// ### TC-7: Multi-display
// - Move Firefox to external display
// - Verify capture still works and ROI is correct
// - Verify preview window EDR headroom matches the preview window's display
//
// ### TC-8: Standalone mode (no extension)
// - Run the Swift binary directly from Terminal: .build/debug/HDRUpscaler
// - Verify it detects standalone mode and auto-discovers Firefox
// - Verify it processes the full window (no ROI crop)
//
// ### TC-9: Bilibili / Shadow DOM
// - Open a Bilibili video page
// - Verify content script finds <video> inside shadow DOM
// - Verify rect and processing work correctly
