/**
 * HDR Upscaler — Background Script
 *
 * Bridges the content script(s) and the native HDR Upscaler app.
 * Connects to the native messaging host and forwards video rect/state
 * messages. Only forwards messages from the currently active tab.
 *
 * Features:
 * - Message queuing: buffers messages while native host is connecting
 * - Active tab filtering: only processes video from the focused tab
 * - Auto-reconnect on disconnect with exponential backoff
 * - Forwards native host status back to content scripts
 */

const NATIVE_HOST_NAME = "com.hdrupscaler.app";
const MAX_QUEUE_SIZE = 5;
const MAX_RECONNECT_DELAY = 30000;

let port = null;
let reconnectTimeout = null;
let reconnectDelay = 1000;
let messageQueue = [];
let activeTabId = null;
let isConnecting = false;

// ── Active Tab Tracking ─────────────────────────────────────────────

/**
 * Track which tab is active so we only forward video from the focused tab.
 * This prevents background tabs' videos from interfering.
 */
browser.tabs.onActivated.addListener(async (activeInfo) => {
  activeTabId = activeInfo.tabId;
  // When switching tabs, send video_lost for the old tab's video
  // (the new tab's content script will send its own video_rect if it has one)
  if (port) {
    try {
      port.postMessage({ type: "video_lost" });
    } catch (e) {
      // Ignore
    }
  }
});

// Initialize active tab
browser.tabs
  .query({ active: true, currentWindow: true })
  .then((tabs) => {
    if (tabs[0]) activeTabId = tabs[0].id;
  })
  .catch(() => {});

// ── Native Messaging Connection ─────────────────────────────────────

/**
 * Connect to the native messaging host.
 */
function connectNative() {
  if (port || isConnecting) return;
  isConnecting = true;

  try {
    port = browser.runtime.connectNative(NATIVE_HOST_NAME);
    isConnecting = false;
    reconnectDelay = 1000; // Reset backoff on successful connect
    console.log("[HDR Upscaler] Connected to native host");

    // Flush queued messages
    flushQueue();

    port.onMessage.addListener((msg) => {
      console.log("[HDR Upscaler] From native:", JSON.stringify(msg));
      handleNativeMessage(msg);
    });

    port.onDisconnect.addListener((p) => {
      const error = p.error?.message || browser.runtime.lastError?.message || "unknown reason";
      console.warn("[HDR Upscaler] Native host disconnected:", error);
      port = null;
      isConnecting = false;
      scheduleReconnect();
    });
  } catch (e) {
    console.error("[HDR Upscaler] Failed to connect:", e.message);
    port = null;
    isConnecting = false;
    scheduleReconnect();
  }
}

function scheduleReconnect() {
  if (reconnectTimeout) clearTimeout(reconnectTimeout);
  console.log(`[HDR Upscaler] Reconnecting in ${reconnectDelay}ms...`);
  reconnectTimeout = setTimeout(() => {
    reconnectTimeout = null;
    connectNative();
  }, reconnectDelay);
  // Exponential backoff, capped
  reconnectDelay = Math.min(reconnectDelay * 1.5, MAX_RECONNECT_DELAY);
}

/**
 * Flush queued messages to the native host.
 */
function flushQueue() {
  if (!port || messageQueue.length === 0) return;
  const queue = messageQueue;
  messageQueue = [];

  for (const msg of queue) {
    try {
      port.postMessage(msg);
    } catch (e) {
      console.error("[HDR Upscaler] Flush error:", e);
      port = null;
      messageQueue = queue; // Re-queue remaining
      scheduleReconnect();
      return;
    }
  }
  console.log(`[HDR Upscaler] Flushed ${queue.length} queued message(s)`);
}

/**
 * Send a message to the native host, with queueing fallback.
 */
function sendToNative(msg) {
  if (port) {
    try {
      port.postMessage(msg);
      return;
    } catch (e) {
      console.error("[HDR Upscaler] Send error:", e);
      port = null;
      scheduleReconnect();
    }
  }

  // Queue the message (keep only the latest N to avoid stale data)
  messageQueue.push(msg);
  if (messageQueue.length > MAX_QUEUE_SIZE) {
    messageQueue.shift();
  }

  // Ensure we're trying to connect
  if (!port && !isConnecting && !reconnectTimeout) {
    connectNative();
  }
}

// ── Message Handling ────────────────────────────────────────────────

/**
 * Handle messages from the native host.
 */
function handleNativeMessage(msg) {
  if (!msg || !msg.type) return;

  switch (msg.type) {
    case "status":
      console.log(`[HDR Upscaler] Native status: ${msg.status} — ${msg.message || ""}`);
      break;

    case "capture_info":
      console.log(
        `[HDR Upscaler] Capture: ${msg.capturing ? "active" : "inactive"}` +
          (msg.windowTitle ? ` — ${msg.windowTitle}` : "") +
          (msg.captureWidth ? ` (${msg.captureWidth}x${msg.captureHeight})` : "")
      );
      break;

    default:
      console.log("[HDR Upscaler] Unknown native message:", msg.type);
  }
}

/**
 * Forward messages from content scripts to the native host.
 * Only processes messages from the active tab.
 */
browser.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || !msg.type) return;

  // Only forward from the active tab (ignore background tabs' videos)
  if (sender.tab && sender.tab.id !== activeTabId) {
    return;
  }

  // Enrich with tab context
  if (sender.tab) {
    msg.tabId = sender.tab.id;
    msg.windowId = sender.tab.windowId;
  }

  // For iframe content scripts, note which frame it came from
  if (sender.frameId !== undefined) {
    msg.frameId = sender.frameId;
  }

  sendToNative(msg);
});

// ── Tab Close / Navigation ──────────────────────────────────────────

/**
 * When the active tab navigates or closes, notify the native host.
 */
browser.tabs.onRemoved.addListener((tabId) => {
  if (tabId === activeTabId) {
    sendToNative({ type: "video_lost" });
  }
});

browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  // When a tab starts loading a new page, the previous video is gone
  if (tabId === activeTabId && changeInfo.status === "loading") {
    sendToNative({ type: "video_lost" });
  }
});

// ── Startup ─────────────────────────────────────────────────────────

// Connect immediately on extension load
connectNative();
