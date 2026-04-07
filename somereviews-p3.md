My direct judgment: the project is **architecturally close to a good prototype**, but the control plane is still fragile. The biggest problems are:

1. **state management is split across `AppDelegate`, `ScreenCapture`, and the timer, so restart logic races itself**,
2. **all the display/scale math assumes `NSScreen.main`**, which will break on mixed-DPI or multi-display setups,
3. **you are doing frame processing on the main thread**, which is the wrong place for a real-time capture pipeline,
4. **the “HDR” part is currently an EDR expansion pass over captured browser pixels**, so the visual result can look impressive, but it is not the same as preserving source HDR semantics.    

Here is the thorough review, from highest priority downward.

## 1. `main.swift`: this is where most of the instability originates

The most important issue is that `AppDelegate` is coordinating too much mutable state while also being marked `@unchecked Sendable`. That is a dangerous promise: this class owns UI objects, timers, capture state, and pipeline state, so it should be treated as main-thread-bound, not concurrency-safe. `applicationDidFinishLaunching`, menu updates, overlay control, and retry scheduling are all AppKit-driven. This class should be `@MainActor`, not `@unchecked Sendable`. 

A second major problem is that `selectFirefoxWindow()` can schedule overlapping retries. It retries after 3 seconds when no windows are found, retries after 5 seconds on failure, and is also called again from `trackWindowPosition()` when the window disappears. There is no cancellation token and no “selection already in progress” guard, so you can end up with multiple concurrent `selectFirefoxWindow()` tasks all trying to start capture on different candidates. That explains a lot of the stop/start churn you saw earlier. 

A third problem is that window disappearance currently stops only the pipeline, not the capture stream. In `trackWindowPosition`, when the window lookup fails, you call `pipeline?.stop()`, invalidate the timer, update status, and immediately re-enter selection, but you do **not** stop the active `SCStream` there. That leaves `ScreenCapture` running until it errors out on its own. This is why your logs showed pipeline stop messages before the ScreenCaptureKit error arrived.  

This file also inherits the earlier `onCaptureStarted` design problem. It still expects a full `SCWindow` in the callback and then uses that directly to start the pipeline and tracker. After the fix I recommended last turn, this should consume a snapshot value instead of `SCWindow`.  

What I would change here:

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pipeline: HDRPipeline?
    private var capture: ScreenCapture?
    private var device: MTLDevice?
    private var statusBar: StatusBarMenu?
    private var windowTracker: Timer?
    private var selectTask: Task<Void, Never>?
    private var isSelectingWindow = false
}
```

And make selection single-flight:

```swift
@MainActor
private func scheduleWindowSelection(after delay: TimeInterval = 0) {
    selectTask?.cancel()
    selectTask = Task { [weak self] in
        guard let self else { return }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        await self.selectFirefoxWindow()
    }
}
```

Then in `trackWindowPosition`, stop capture too:

```swift
Task { [weak self] in
    guard let self else { return }
    await self.capture?.stopCapture()
    self.pipeline?.stop()
    self.windowTracker?.invalidate()
    self.statusBar?.updateStatus(capturing: false, windowTitle: "Not connected")
    self.scheduleWindowSelection(after: 0.5)
}
```

---

## 2. `ScreenCapture.swift`: still the right abstraction, but it is using the wrong thread model and the wrong display assumptions

This file is much better than the outer coordinator, but two weaknesses remain.

The first is performance: `didOutputSampleBuffer` converts the pixel buffer to a Metal texture, then dispatches `onFrame` onto the main queue. That means your real-time pipeline work begins on the UI thread. For a menu-bar app doing 30fps capture plus MetalFX plus compute plus present, that is the wrong queue. The main thread should handle menu/UI/window frame updates; frame processing should move to a dedicated serial processing queue. 

The second is scale selection. `startCapture(window:)` and `updateCaptureRect(_:)` both derive output size from `NSScreen.main?.backingScaleFactor`. That is brittle. ScreenCaptureKit exposes filter/display-related pixel scaling information, and Apple’s API surface explicitly includes `SCContentFilter.pointPixelScale`; relying on `NSScreen.main` couples capture size to the wrong display in multi-monitor and mixed-retina environments.  ([Apple Developer][1])

You also already know about the Sendable capture warning on `SCWindow`; that still needs the snapshot fix or at least `@preconcurrency import ScreenCaptureKit`. Swift’s diagnostic is specifically about capturing a non-Sendable value inside a `@Sendable` closure.  ([Apple Developer][2])

The highest-value change here is to introduce a processing queue:

```swift
private let processingQueue = DispatchQueue(label: "hdr-upscaler.frame-processing", qos: .userInteractive)
```

and then:

```swift
processingQueue.async { [weak self] in
    self?.onFrame?(texture, width, height)
}
```

Also, after your earlier failure mode, I would still keep the stricter Firefox filter and the “revalidate window by `windowID` before start” fix. The code you uploaded still lacks those protections. 

---

## 3. `OverlayWindow.swift`: this file has two hard logic bugs

This class has the most suspicious UI/display behavior in the project.

First, `window.hidesOnDeactivate = true` is logically incompatible with your use case. This overlay exists to sit over Firefox while Firefox is the active app. But as soon as Firefox becomes active, your own accessory app is deactivated, so this setting invites the overlay to disappear exactly when it should remain visible. 

Second, `window.level = .normal` is too low for a persistent click-through overlay intended to stay above another app’s content. Even if `orderFront(nil)` works momentarily, Firefox can retake z-order. For your design, the overlay needs a higher level, typically a floating level or a purpose-built panel/window configuration. 

There is also a major coordinate-system bug: `applyFrame(_:)` flips Y using `NSScreen.main?.frame.height`. That works only if the captured window is on the main screen and the global coordinate system lines up exactly how you expect. On multi-display setups, or even on vertically stacked displays, this will place the overlay incorrectly. This ties back to the same “wrong screen” assumption I flagged in `ScreenCapture.swift`.  ([Apple Developer][1])

The fix here is conceptual:

* stop using `NSScreen.main` for coordinate conversion,
* determine which display the target window is on,
* convert from global Quartz coordinates to that screen’s Cocoa coordinates,
* remove `hidesOnDeactivate`,
* raise the window level.

At minimum:

```swift
window.hidesOnDeactivate = false
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

---

## 4. `HDRPipeline.swift`: solid skeleton, but two architectural mismatches

The good news: the overall processing order is coherent — capture texture, optional MetalFX upscale, compute pass, present. That part makes sense.  

The first mismatch is thread affinity. `HDRPipeline` touches AppKit state indirectly through `NSScreen.main` and directly through `OverlayWindow`, but it is also doing GPU work every frame. Right now it is used from the main queue because `ScreenCapture` dispatches frames there. That hides thread-safety problems, but it also forces your render path onto the UI thread. This class should be split conceptually into “GPU pipeline” and “overlay UI control,” or at least isolate the UI bits onto the main actor and keep frame encoding on a processing queue.   

The second mismatch is the meaning of “HDR.” Your `HDRParams.maxEDR` comes from `NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue`, and the shader expands bright SDR values into EDR space. That can produce a brighter, wider-gamut-looking result, but it does not mean you preserved browser HDR metadata or reconstructed true mastered HDR highlights. Apple’s MetalFX perceptual mode is intended for input/output in a perceptual 0–1 color space, and your pipeline then performs an additional manual expansion step after that. So this is better described as **SDR-to-EDR remapping with upscaling**, not end-to-end HDR fidelity.   ([Apple Developer][3])

Other notes in this file:

* `frameCount` never resets on `start()`, so logs span multiple sessions and become misleading. 
* `updateParamsBuffer()` also uses `NSScreen.main`, so the same wrong-display issue appears here. 
* runtime compilation of the `.metal` source from a bundled text file is okay for a prototype, but it is a more fragile deployment model than a precompiled Metal library. 

---

## 5. `Upscaler.swift`: clean, but one latent bug and one product-level concern

This file is tidy. The scaler lifecycle is simple and sane. 

The latent bug is in `configure(...)`: you re-create the scaler only when dimensions change, but not when `inputPixelFormat` changes. Right now your capture path always uses BGRA8Unorm, so this is harmless in practice. But the function signature implies format is part of the configuration, and the cache key currently ignores it. If you later add an `.rgba16Float` or `_srgb` path, this will bite you. 

The product-level concern is expectations. Apple’s MetalFX spatial scaler is optimized for anti-aliased, noise-controlled render inputs; Apple’s own WWDC guidance frames perceptual mode around tone-mapped 0–1 sRGB-like inputs. That is a good fit for game rendering and decent for stable UI/video frames, but it is not a magic “browser-video super-resolution” engine. It will not invent detail the way a content-trained video SR model might. ([Apple Developer][4]) 

---

## 6. `StatusBarMenu.swift`: this one is mostly fine

This is the cleanest file in the set. The logic is straightforward, callbacks are simple, and the rebuild strategy is acceptable for a small menu-bar utility. 

Only minor notes:

* long window titles can make the status menu header ugly,
* `rebuildMenu()` on every status tick is fine here, though you could update only changed items,
* factor labels are hardcoded, which is okay because your allowed set is fixed. 

This file is not where your runtime pain is coming from.

---

## 7. Cross-file architectural issues

These matter more than any one line bug.

### A. You need a real state machine

Right now the system state is inferred from:

* `capture.isCapturing`
* `pipeline.isActive`
* whether `windowTracker` exists
* whether some retry closure has already been scheduled
* whether `capturedWindow` still exists

That is too implicit. Centralize it into something like:

```swift
enum AppState {
    case idle
    case selecting
    case starting(windowID: CGWindowID)
    case capturing(windowID: CGWindowID)
    case restarting
}
```

That alone will remove a lot of duplicated retry logic.   

### B. Your coordinate model is inconsistent

`ScreenCapture`, `OverlayWindow`, and `HDRPipeline` all query `NSScreen.main`. They should instead share one authoritative notion of the target display and pixel scale. Apple’s ScreenCaptureKit API surface explicitly exposes content filters and scaling metadata for this reason.    ([Apple Developer][1])

### C. Your “frontmost app == overlay visible” rule is too coarse

`trackWindowPosition` hides/shows the overlay based on whether the frontmost app’s bundle identifier contains “firefox”. That is app-level visibility, not target-window visibility. If Firefox has multiple windows, devtools, picture-in-picture, dialogs, or a background window arrangement, this heuristic will show or hide the overlay at the wrong time. 

### D. Your prototype currently processes every frame end-to-end, with no backpressure policy

That means if capture outruns rendering, you can build latency instead of dropping stale frames. A real-time viewer usually wants “latest frame wins,” not “process every historical frame.”  

---

## 8. What is already good

A lot is already on the right track:

* the project separation is sensible: capture, pipeline, overlay, menu, app bootstrap are at least split into distinct files, which makes refactoring feasible.  
* `Upscaler` is simple and readable. 
* `HDRPipeline` has a coherent render graph for a prototype. 
* `StatusBarMenu` is clean and low-risk. 

So this is not a rewrite-from-zero situation. It is a “fix the control plane and display model” situation.

## The order I would refactor in

1. Make `AppDelegate` `@MainActor` and remove `@unchecked Sendable`. 
2. Replace ad hoc retries with one cancellable selection task. 
3. Stop capture explicitly when the tracked window disappears.  
4. Move frame processing off the main queue. 
5. Remove all `NSScreen.main` assumptions from capture size, EDR headroom, and overlay positioning.    ([Apple Developer][1])
6. Fix `OverlayWindow` level and deactivate behavior. 
7. Reword product claims internally from “HDR upscaler” to “EDR overlay remapper + upscaler,” unless you later add a true HDR-aware source path.  ([Apple Developer][3])

The next highest-value file to inspect is `Package.swift`, because it determines whether your Metal source and resources are bundled the way this pipeline assumes.

[1]: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale?utm_source=chatgpt.com "pointPixelScale | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init%28desktopindependentwindow%3A%29?changes=latest_minor&utm_source=chatgpt.com "init(desktopIndependentWindow:)"
[3]: https://developer.apple.com/documentation/metalfx/mtlfxspatialscalercolorprocessingmode/perceptual?utm_source=chatgpt.com "MTLFXSpatialScalerColorProces..."
[4]: https://developer.apple.com/la/videos/play/wwdc2022/10103/?time=594&utm_source=chatgpt.com "Boost performance with MetalFX Upscaling - WWDC22"

