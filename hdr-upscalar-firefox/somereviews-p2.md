The main bug is your **window selection + restart flow**, not the warning.

From your file, I see three concrete issues:

1. `findFirefoxWindows()` accepts **any** Firefox window larger than `100x100`, including the titleless transient window that appears in your logs as `"" (1728x1117)`. Then `startCapture(window:)` tries to stream it, and ScreenCaptureKit returns `-3815`, which Apple documents as `noWindowList` — the stream has no capture source. ([Apple Developer][1]) Your current filter is exactly loose enough to let that happen. 

2. `startCapture(window:)` calls `stopCapture()` first, but your `stopCapture()` is **fire-and-forget**: it spawns a `Task` for `stream.stopCapture()` and returns immediately. So a new stream can start while the old one is still shutting down. That is a classic race. 

3. Your Sendable warning is real, but secondary. `DispatchQueue.main.async { callback?(window) }` captures `SCWindow` inside a `@Sendable` closure, and Swift warns because captured values in `@Sendable` closures must be concurrency-safe. ([Swift Documentation][2]) Your code does exactly that. 

Here is the order I would fix it.

## 1) Tighten window selection

Your current filter:

```swift
return app.localizedCaseInsensitiveContains("firefox")
    && window.frame.width > 100
    && window.frame.height > 100
```

That is too broad. Replace it with something like:

```swift
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Metal
import AppKit

func findFirefoxWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    return content.windows
        .filter { window in
            let appName = window.owningApplication?.applicationName ?? ""
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            return appName.localizedCaseInsensitiveContains("firefox")
                && !title.isEmpty
                && window.frame.width >= 800
                && window.frame.height >= 600
        }
        .sorted { lhs, rhs in
            let la = lhs.frame.width * lhs.frame.height
            let ra = rhs.frame.width * rhs.frame.height
            return la > ra
        }
}
```

Why this matters: your log already shows the bad candidate is the titleless one. Excluding empty titles will likely remove the main trigger immediately. 

---

## 2) Revalidate the window right before starting capture

Even if `findFirefoxWindows()` returns a good candidate, it may disappear before `SCStream.startCapture()` runs. Re-fetch shareable content and match by `windowID` right before building the filter. Apple’s capture model is built around `SCShareableContent` + `SCContentFilter`, so revalidation fits the framework properly. ([Apple Developer][3])

Add this helper:

```swift
private func refreshWindow(windowID: CGWindowID) async throws -> SCWindow? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    return content.windows.first { $0.windowID == windowID }
}
```

Then change `startCapture(window:)` so it revalidates:

```swift
func startCapture(window: SCWindow) async throws {
    await stopCapture()

    guard let freshWindow = try await refreshWindow(windowID: window.windowID) else {
        print("[ScreenCapture] Window disappeared before capture start: \(window.windowID)")
        return
    }

    self.capturedWindow = freshWindow

    let filter = SCContentFilter(desktopIndependentWindow: freshWindow)

    let config = SCStreamConfiguration()
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    config.width = Int(freshWindow.frame.width * scale)
    config.height = Int(freshWindow.frame.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 5
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.capturesAudio = false
    config.scalesToFit = true

    let newStream = SCStream(filter: filter, configuration: config, delegate: self)
    try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

    var lastError: Error?
    for attempt in 1...3 {
        do {
            try await newStream.startCapture()
            lastError = nil
            break
        } catch {
            lastError = error
            print("[ScreenCapture] Attempt \(attempt)/3 failed: \(error.localizedDescription)")
            if attempt < 3 {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    if let error = lastError {
        throw error
    }

    self.stream = newStream
    self.isCapturing = true

    print("[ScreenCapture] Capturing: \(freshWindow.owningApplication?.applicationName ?? "?") — \"\(freshWindow.title ?? "untitled")\" (\(config.width)x\(config.height))")
}
```

---

## 3) Make stop synchronous from the caller’s perspective

This is your most important structural fix.

Current code:

```swift
func stopCapture() {
    guard isCapturing, let stream = stream else { return }
    Task {
        try? await stream.stopCapture()
    }
    self.stream = nil
    self.isCapturing = false
    self.capturedWindow = nil
}
```

That clears state immediately, while the actual stream may still be alive in the background. 

Change it to:

```swift
func stopCapture() async {
    guard let stream = stream else {
        self.stream = nil
        self.isCapturing = false
        self.capturedWindow = nil
        return
    }

    do {
        try await stream.stopCapture()
    } catch {
        print("[ScreenCapture] stopCapture error: \(error)")
    }

    self.stream = nil
    self.isCapturing = false
    self.capturedWindow = nil
    print("[ScreenCapture] Stopped")
}
```

Then in `deinit`:

```swift
deinit {
    Task { await stopCapture() }
}
```

And in `startCapture(window:)` call:

```swift
await stopCapture()
```

That removes the stop/start overlap.

---

## 4) Fix the Sendable warning the right way

Apple’s frameworks still surface some non-Sendable Obj-C types, and Swift’s diagnostic is specifically about captures in `@Sendable` closures. ([Swift Documentation][2])

The clean fix is: **do not pass `SCWindow` across that closure**. Pass a snapshot struct instead.

Add:

```swift
struct WindowSnapshot: Sendable {
    let windowID: CGWindowID
    let title: String
    let frame: CGRect
    let appName: String
}
```

Change callback type:

```swift
var onCaptureStarted: ((WindowSnapshot) -> Void)?
```

Then:

```swift
let snapshot = WindowSnapshot(
    windowID: freshWindow.windowID,
    title: freshWindow.title ?? "",
    frame: freshWindow.frame,
    appName: freshWindow.owningApplication?.applicationName ?? ""
)

let callback = onCaptureStarted
await MainActor.run {
    callback?(snapshot)
}
```

You can also add:

```swift
@preconcurrency import ScreenCaptureKit
```

That suppresses module-level Sendable warnings from older annotations, but I would still keep the snapshot approach because it is the safer design. ([Swift Documentation][2])

---

## 5) Clean up stale state in `didStopWithError`

Right now:

```swift
func stream(_ stream: SCStream, didStopWithError error: Error) {
    print("[ScreenCapture] Stream stopped with error: \(error)")
    isCapturing = false
}
```

That leaves `stream` and `capturedWindow` stale. 

Change it to:

```swift
func stream(_ stream: SCStream, didStopWithError error: Error) {
    print("[ScreenCapture] Stream stopped with error: \(error)")
    self.stream = nil
    self.capturedWindow = nil
    self.isCapturing = false
}
```

If your outer controller auto-restarts capture, add a small debounce there. For `-3815`, restarting immediately usually just re-hits the same bad window state.

---

## 6) One more practical improvement: don’t restart when the same window is already running

If your polling loop repeatedly discovers the same `windowID`, skip restart:

```swift
func shouldRestart(for newWindow: SCWindow) -> Bool {
    guard let current = capturedWindow else { return true }
    return current.windowID != newWindow.windowID
}
```

That will reduce churn a lot.

---

## My diagnosis in one sentence

Your app is currently treating **“Firefox window exists”** and **“this exact `SCWindow` is stable and capturable right now”** as the same condition. They are not. The titleless transient Firefox window is slipping through your filter, then your async stop/start race makes the failure loop noisier. 

---

## I would patch these first

1. Tighten `findFirefoxWindows()`
2. Make `stopCapture()` async and awaited
3. Revalidate by `windowID` before `startCapture()`
4. Replace `SCWindow` callback payload with `WindowSnapshot`
5. Clear all state in `didStopWithError`

Paste your outer loop too — the part that calls `findFirefoxWindows()` and decides when a Firefox window is “closed” — and I can point out the exact restart logic that is amplifying this.

[1]: https://developer.apple.com/documentation/screencapturekit/scstreamerror/nowindowlist?changes=__2_5&utm_source=chatgpt.com "noWindowList | Apple Developer Documentation"
[2]: https://docs.swift.org/compiler/documentation/diagnostics/sendable-closure-captures/?utm_source=chatgpt.com "Captures in a `@Sendable` closure ..."
[3]: https://developer.apple.com/documentation/screencapturekit/scshareablecontent?utm_source=chatgpt.com "SCShareableContent | Apple Developer Documentation"

