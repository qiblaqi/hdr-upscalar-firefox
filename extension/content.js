/**
 * HDR Upscaler — Content Script
 *
 * Finds the primary <video> element on the page (including inside iframes and
 * shadow DOMs), tracks its position and playback state, and sends updates to
 * the background script which forwards them to the native HDR Upscaler app.
 *
 * Runs in every frame (all_frames: true in manifest) so it can find videos
 * inside iframes. Each frame independently reports its video; the background
 * script picks the best one from the active tab.
 *
 * Tracking strategy:
 * - MutationObserver watches for <video> elements entering/leaving the DOM
 * - requestVideoFrameCallback() for frame-accurate timing when available
 * - Fallback to setInterval polling at ~10 Hz for rect/state updates
 * - Deduplication: only sends when rect or state actually changes
 */

(function () {
  "use strict";

  // Avoid double-injection (Firefox can re-inject on navigation)
  if (window.__hdrUpscalerContentLoaded) return;
  window.__hdrUpscalerContentLoaded = true;

  let activeVideo = null;
  let pollInterval = null;
  let lastSentJSON = "";
  let observer = null;
  let reScanInterval = null;
  let vfcCallbackId = null; // requestVideoFrameCallback handle
  let isTopFrame = window === window.top;

  const POLL_INTERVAL_MS = 100; // 10 Hz rect polling
  const RESCAN_INTERVAL_MS = 3000; // Re-scan for new videos
  const MIN_VIDEO_AREA = 100 * 100; // Ignore tiny videos (ads, thumbnails)

  // ── Video Discovery ─────────────────────────────────────────────────

  /**
   * Find all <video> elements, including those inside shadow DOMs.
   */
  function findAllVideos(root = document) {
    const videos = Array.from(root.querySelectorAll("video"));

    // Also search inside shadow roots (custom players like Bilibili, Vimeo)
    const allElements = root.querySelectorAll("*");
    for (const el of allElements) {
      if (el.shadowRoot) {
        videos.push(...findAllVideos(el.shadowRoot));
      }
    }

    return videos;
  }

  /**
   * Find the best video element on the page.
   * Picks the largest playing (or paused-but-visible) video.
   */
  function findBestVideo() {
    const videos = findAllVideos();
    if (videos.length === 0) return null;

    const candidates = videos
      .map((v) => {
        const rect = v.getBoundingClientRect();
        return {
          element: v,
          rect,
          area: rect.width * rect.height,
          isPlaying: !v.paused && !v.ended && v.readyState > 2,
          isVisible:
            rect.width > 0 &&
            rect.height > 0 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < window.innerHeight &&
            rect.left < window.innerWidth,
        };
      })
      .filter((c) => c.isVisible && c.area >= MIN_VIDEO_AREA);

    if (candidates.length === 0) return null;

    // Playing videos first, then largest area
    candidates.sort((a, b) => {
      if (a.isPlaying !== b.isPlaying) return a.isPlaying ? -1 : 1;
      return b.area - a.area;
    });

    return candidates[0].element;
  }

  // ── Message Building ────────────────────────────────────────────────

  /**
   * Build the message payload for the current video state.
   *
   * For iframes: rect is relative to this frame's viewport. The background
   * script only uses messages from the top frame OR from the frame that has
   * the active video. For now, iframes report their own rects — the Swift
   * side can handle the iframe offset via the viewport/capture mapping.
   *
   * Note: In an iframe, getBoundingClientRect() returns coords relative to
   * the iframe's viewport, which is correct for the coordinate mapper since
   * ScreenCaptureKit captures the full window including iframes rendered inline.
   * However, the viewport size and DPR should come from the top window for
   * correct chrome-height calculation. For iframes, we report the iframe's own
   * viewport which may cause a small chrome-offset error. This is acceptable
   * for the MVP; a future fix can use window.top.innerHeight via postMessage.
   */
  function buildMessage(video) {
    const rect = video.getBoundingClientRect();

    return {
      type: "video_rect",
      rect: {
        x: Math.round(rect.x * 100) / 100,
        y: Math.round(rect.y * 100) / 100,
        width: Math.round(rect.width * 100) / 100,
        height: Math.round(rect.height * 100) / 100,
      },
      viewport: {
        width: window.innerWidth,
        height: window.innerHeight,
      },
      devicePixelRatio: window.devicePixelRatio || 1.0,
      isFullscreen: !!(
        document.fullscreenElement || document.webkitFullscreenElement
      ),
      paused: video.paused,
      videoNaturalWidth: video.videoWidth || null,
      videoNaturalHeight: video.videoHeight || null,
      url: window.location.href,
      isTopFrame: isTopFrame,
    };
  }

  // ── Messaging ───────────────────────────────────────────────────────

  /**
   * Safely send a message to the background script.
   * Catches errors that occur when the background script isn't ready or
   * the extension is being reloaded.
   */
  function safeSendMessage(msg) {
    try {
      browser.runtime.sendMessage(msg).catch((err) => {
        // Silently ignore "Could not establish connection" errors.
        // This happens during extension reload or if background script isn't ready.
        if (
          !err.message?.includes("Could not establish connection") &&
          !err.message?.includes("Receiving end does not exist")
        ) {
          console.warn("[HDR Upscaler] sendMessage error:", err.message);
        }
      });
    } catch (e) {
      // Synchronous errors (extension context invalidated)
    }
  }

  /**
   * Send an update if something changed.
   */
  function sendUpdate() {
    if (!activeVideo) return;

    // Check if video is still in the DOM
    if (!document.contains(activeVideo) && !isInShadowDOM(activeVideo)) {
      handleVideoLost();
      return;
    }

    const msg = buildMessage(activeVideo);
    const json = JSON.stringify(msg);

    // Deduplicate: only send if something actually changed
    if (json === lastSentJSON) return;
    lastSentJSON = json;

    safeSendMessage(msg);
  }

  /**
   * Check if an element is inside a shadow DOM (and thus not in document).
   */
  function isInShadowDOM(el) {
    let node = el;
    while (node) {
      if (node instanceof ShadowRoot) return true;
      node = node.parentNode;
    }
    return false;
  }

  /**
   * Notify that the video has been lost.
   */
  function handleVideoLost() {
    const wasTracking = activeVideo !== null;
    stopTracking();

    if (wasTracking) {
      safeSendMessage({ type: "video_lost", isTopFrame });
    }

    // Try to find a new video after a short delay
    setTimeout(scanForVideo, 1000);
  }

  // ── Tracking ────────────────────────────────────────────────────────

  /**
   * Start tracking a video element.
   */
  function startTracking(video) {
    if (activeVideo === video) return;

    stopTracking();
    activeVideo = video;

    const w = video.videoWidth || "?";
    const h = video.videoHeight || "?";
    console.log(`[HDR Upscaler] Tracking video: ${w}x${h} (${isTopFrame ? "top" : "iframe"})`);

    // Immediate first send
    sendUpdate();

    // Use requestVideoFrameCallback if available — gives frame-accurate timing
    if ("requestVideoFrameCallback" in video) {
      startVideoFrameCallback(video);
    }

    // Also poll with setInterval as a fallback / supplement
    // (rVFC only fires when video is playing; we still need to detect
    //  scroll, resize, pause, etc.)
    pollInterval = setInterval(sendUpdate, POLL_INTERVAL_MS);

    // Listen for key state changes
    video.addEventListener("play", sendUpdate);
    video.addEventListener("pause", sendUpdate);
    video.addEventListener("seeked", sendUpdate);
    video.addEventListener("resize", onVideoResize);
    video.addEventListener("enterpictureinpicture", sendUpdate);
    video.addEventListener("leavepictureinpicture", sendUpdate);
    video.addEventListener("emptied", onVideoSrcChange);
    video.addEventListener("loadedmetadata", onVideoSrcChange);

    document.addEventListener("fullscreenchange", sendUpdate);
    window.addEventListener("resize", sendUpdate);
    window.addEventListener("scroll", sendUpdate, { passive: true });

    // Stop the periodic re-scan while we're tracking
    if (reScanInterval) {
      clearInterval(reScanInterval);
      reScanInterval = null;
    }
  }

  /**
   * Use requestVideoFrameCallback for frame-accurate timing.
   * This fires each time the video compositor receives a new frame.
   */
  function startVideoFrameCallback(video) {
    function onFrame(now, metadata) {
      sendUpdate();
      // Re-register for the next frame
      if (activeVideo === video) {
        vfcCallbackId = video.requestVideoFrameCallback(onFrame);
      }
    }
    vfcCallbackId = video.requestVideoFrameCallback(onFrame);
  }

  /**
   * Handle video src change (same element, different content).
   */
  function onVideoSrcChange() {
    lastSentJSON = ""; // Force a new update
    sendUpdate();
  }

  /**
   * Handle video intrinsic size change.
   */
  function onVideoResize() {
    lastSentJSON = ""; // Force update with new dimensions
    sendUpdate();
  }

  /**
   * Stop tracking the current video.
   */
  function stopTracking() {
    if (pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
    }

    if (activeVideo) {
      // Cancel requestVideoFrameCallback
      if (vfcCallbackId !== null && "cancelVideoFrameCallback" in activeVideo) {
        activeVideo.cancelVideoFrameCallback(vfcCallbackId);
        vfcCallbackId = null;
      }

      activeVideo.removeEventListener("play", sendUpdate);
      activeVideo.removeEventListener("pause", sendUpdate);
      activeVideo.removeEventListener("seeked", sendUpdate);
      activeVideo.removeEventListener("resize", onVideoResize);
      activeVideo.removeEventListener("enterpictureinpicture", sendUpdate);
      activeVideo.removeEventListener("leavepictureinpicture", sendUpdate);
      activeVideo.removeEventListener("emptied", onVideoSrcChange);
      activeVideo.removeEventListener("loadedmetadata", onVideoSrcChange);
    }

    document.removeEventListener("fullscreenchange", sendUpdate);
    window.removeEventListener("resize", sendUpdate);
    window.removeEventListener("scroll", sendUpdate);

    activeVideo = null;
    lastSentJSON = "";

    // Restart periodic re-scan
    if (!reScanInterval) {
      reScanInterval = setInterval(scanForVideo, RESCAN_INTERVAL_MS);
    }
  }

  // ── DOM Observation ─────────────────────────────────────────────────

  /**
   * Scan the DOM for a suitable video to track.
   */
  function scanForVideo() {
    const best = findBestVideo();
    if (best) {
      startTracking(best);
    } else if (activeVideo) {
      handleVideoLost();
    }
  }

  /**
   * Watch for video elements being added/removed from the DOM.
   */
  function setupObserver() {
    observer = new MutationObserver((mutations) => {
      let needsScan = false;

      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType !== Node.ELEMENT_NODE) continue;
          if (node.nodeName === "VIDEO" || node.querySelector?.("video")) {
            needsScan = true;
            break;
          }
          // Also check shadow roots on new elements
          if (node.shadowRoot?.querySelector("video")) {
            needsScan = true;
            break;
          }
        }
        if (needsScan) break;

        for (const node of mutation.removedNodes) {
          if (node.nodeType !== Node.ELEMENT_NODE) continue;
          if (
            node === activeVideo ||
            node.contains?.(activeVideo) ||
            node.nodeName === "VIDEO"
          ) {
            needsScan = true;
            break;
          }
        }
        if (needsScan) break;
      }

      if (needsScan) {
        // Debounce: wait a tick for the DOM to settle
        setTimeout(scanForVideo, 100);
      }
    });

    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  }

  // ── Initialization ──────────────────────────────────────────────────

  setupObserver();
  scanForVideo();

  // Periodic re-scan for lazily-loaded videos (only when not tracking)
  reScanInterval = setInterval(scanForVideo, RESCAN_INTERVAL_MS);

  // Cleanup on page unload
  window.addEventListener("unload", () => {
    stopTracking();
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    if (reScanInterval) {
      clearInterval(reScanInterval);
      reScanInterval = null;
    }
  });
})();
