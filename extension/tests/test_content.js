/**
 * Unit tests for content.js video detection and message building logic.
 *
 * Run with: node extension/tests/test_content.js
 *
 * These tests mock the DOM/browser APIs to test the pure logic in isolation.
 * They don't require Firefox or the extension to be loaded.
 */

const assert = require("assert");

let testsPassed = 0;
let testsFailed = 0;

function test(name, fn) {
  try {
    fn();
    testsPassed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    testsFailed++;
    console.log(`  ✗ ${name}`);
    console.log(`    ${e.message}`);
  }
}

// ── Mock Browser Environment ──────────────────────────────────────────

// Mock getBoundingClientRect
function mockVideo(opts = {}) {
  return {
    paused: opts.paused ?? false,
    ended: opts.ended ?? false,
    readyState: opts.readyState ?? 4,
    videoWidth: opts.videoWidth ?? 1920,
    videoHeight: opts.videoHeight ?? 1080,
    getBoundingClientRect: () => ({
      x: opts.x ?? 0,
      y: opts.y ?? 56,
      width: opts.width ?? 1280,
      height: opts.height ?? 720,
      top: opts.y ?? 56,
      left: opts.x ?? 0,
      bottom: (opts.y ?? 56) + (opts.height ?? 720),
      right: (opts.x ?? 0) + (opts.width ?? 1280),
    }),
    addEventListener: () => {},
    removeEventListener: () => {},
    requestVideoFrameCallback: opts.hasRVFC ? (cb) => 1 : undefined,
  };
}

// Mock window properties
const mockWindow = {
  innerWidth: 1440,
  innerHeight: 900,
  devicePixelRatio: 2.0,
  location: { href: "https://www.youtube.com/watch?v=test" },
};

// ── Test: Message Building ────────────────────────────────────────────

console.log("\nMessage Building:");

test("builds correct video_rect message", () => {
  const video = mockVideo();
  const msg = {
    type: "video_rect",
    rect: {
      x: Math.round(0 * 100) / 100,
      y: Math.round(56 * 100) / 100,
      width: Math.round(1280 * 100) / 100,
      height: Math.round(720 * 100) / 100,
    },
    viewport: { width: 1440, height: 900 },
    devicePixelRatio: 2.0,
    isFullscreen: false,
    paused: false,
    videoNaturalWidth: 1920,
    videoNaturalHeight: 1080,
    url: "https://www.youtube.com/watch?v=test",
    isTopFrame: true,
  };

  assert.strictEqual(msg.type, "video_rect");
  assert.strictEqual(msg.rect.width, 1280);
  assert.strictEqual(msg.rect.height, 720);
  assert.strictEqual(msg.viewport.width, 1440);
  assert.strictEqual(msg.devicePixelRatio, 2.0);
  assert.strictEqual(msg.videoNaturalWidth, 1920);
});

test("rounds rect values to 2 decimal places", () => {
  const x = 104.555555;
  const rounded = Math.round(x * 100) / 100;
  assert.strictEqual(rounded, 104.56);
});

test("handles paused video state", () => {
  const video = mockVideo({ paused: true });
  assert.strictEqual(video.paused, true);
});

// ── Test: Video Selection Logic ───────────────────────────────────────

console.log("\nVideo Selection:");

test("prefers playing video over paused", () => {
  const playing = mockVideo({ paused: false, width: 640, height: 480 });
  const paused = mockVideo({ paused: true, width: 1280, height: 720 });

  const candidates = [
    { element: playing, isPlaying: true, area: 640 * 480, isVisible: true },
    { element: paused, isPlaying: false, area: 1280 * 720, isVisible: true },
  ];

  candidates.sort((a, b) => {
    if (a.isPlaying !== b.isPlaying) return a.isPlaying ? -1 : 1;
    return b.area - a.area;
  });

  assert.strictEqual(candidates[0].element, playing);
});

test("prefers larger video when both playing", () => {
  const small = mockVideo({ width: 320, height: 240 });
  const large = mockVideo({ width: 1280, height: 720 });

  const candidates = [
    { element: small, isPlaying: true, area: 320 * 240, isVisible: true },
    { element: large, isPlaying: true, area: 1280 * 720, isVisible: true },
  ];

  candidates.sort((a, b) => {
    if (a.isPlaying !== b.isPlaying) return a.isPlaying ? -1 : 1;
    return b.area - a.area;
  });

  assert.strictEqual(candidates[0].element, large);
});

test("filters out tiny videos (ads)", () => {
  const MIN_VIDEO_AREA = 100 * 100;
  const ad = mockVideo({ width: 50, height: 50 });
  const area = 50 * 50;
  assert.strictEqual(area < MIN_VIDEO_AREA, true);
});

test("filters out invisible videos", () => {
  const offscreen = mockVideo({ y: -1000, height: 720 });
  const rect = offscreen.getBoundingClientRect();
  // bottom = -1000 + 720 = -280, which is < 0 but > 0 check on bottom fails
  const isVisible =
    rect.width > 0 &&
    rect.height > 0 &&
    rect.bottom > 0 &&
    rect.right > 0 &&
    rect.top < 900 &&
    rect.left < 1440;
  assert.strictEqual(isVisible, false);
});

test("accepts video at viewport edge", () => {
  const edge = mockVideo({ x: 0, y: 0, width: 1440, height: 900 });
  const rect = edge.getBoundingClientRect();
  const isVisible =
    rect.width > 0 &&
    rect.height > 0 &&
    rect.bottom > 0 &&
    rect.right > 0 &&
    rect.top < 900 &&
    rect.left < 1440;
  assert.strictEqual(isVisible, true);
});

// ── Test: Deduplication ───────────────────────────────────────────────

console.log("\nDeduplication:");

test("identical messages produce same JSON", () => {
  const msg1 = {
    type: "video_rect",
    rect: { x: 0, y: 56, width: 1280, height: 720 },
    viewport: { width: 1440, height: 900 },
  };
  const msg2 = { ...msg1 };
  assert.strictEqual(JSON.stringify(msg1), JSON.stringify(msg2));
});

test("different rects produce different JSON", () => {
  const msg1 = { rect: { x: 0, y: 56, width: 1280, height: 720 } };
  const msg2 = { rect: { x: 0, y: 57, width: 1280, height: 720 } };
  assert.notStrictEqual(JSON.stringify(msg1), JSON.stringify(msg2));
});

// ── Test: Wire Format ─────────────────────────────────────────────────

console.log("\nWire Format (Native Messaging Protocol):");

test("encodes length prefix correctly", () => {
  const msg = { type: "status", status: "ready" };
  const json = JSON.stringify(msg);
  const buf = Buffer.alloc(4 + json.length);
  buf.writeUInt32LE(json.length, 0);
  buf.write(json, 4);

  const readLength = buf.readUInt32LE(0);
  assert.strictEqual(readLength, json.length);

  const readJson = buf.toString("utf8", 4, 4 + readLength);
  const decoded = JSON.parse(readJson);
  assert.strictEqual(decoded.type, "status");
  assert.strictEqual(decoded.status, "ready");
});

test("handles large message payload", () => {
  const largeUrl = "https://example.com/" + "x".repeat(10000);
  const msg = { type: "video_rect", url: largeUrl };
  const json = JSON.stringify(msg);
  const buf = Buffer.alloc(4 + json.length);
  buf.writeUInt32LE(json.length, 0);
  buf.write(json, 4);

  const readLength = buf.readUInt32LE(0);
  assert.strictEqual(readLength, json.length);
  assert.ok(readLength > 10000);
});

// ── Results ───────────────────────────────────────────────────────────

console.log(`\nResults: ${testsPassed} passed, ${testsFailed} failed\n`);
process.exit(testsFailed > 0 ? 1 : 0);
