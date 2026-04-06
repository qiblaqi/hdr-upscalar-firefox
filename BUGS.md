# Bug Report Backlog

## Template

When filing bugs, use this format:

```
### [BUG-XXX] Short description
- **Severity**: Critical / High / Medium / Low
- **Component**: Extension | Native App | HDR Pipeline | Upscaler | WebSocket
- **Status**: Open | In Progress | Fixed | Won't Fix
- **Description**: What happens
- **Expected**: What should happen
- **Steps to Reproduce**: How to trigger it
- **Environment**: macOS version, Mac model, Firefox version, display
```

---

## Known Issues / Anticipated Bugs

### [BUG-001] Firefox does not support requestVideoFrameCallback
- **Severity**: High
- **Component**: Extension
- **Status**: Open
- **Description**: Firefox lacks `requestVideoFrameCallback`, which is the preferred API for per-frame video processing. The extension must fall back to `requestAnimationFrame` + polling `video.currentTime`, which may cause frame timing drift.
- **Expected**: Accurate per-frame sync between browser video and native overlay
- **Workaround**: Use `requestAnimationFrame` with timestamp comparison. Accept minor sync jitter until Firefox implements the API.

### [BUG-002] SDR content over-saturated on HDR displays in Firefox
- **Severity**: Medium
- **Component**: HDR Pipeline
- **Status**: Open
- **Description**: Firefox (as of 2025) has known colorspace handling issues on HDR displays (Mozilla Bug 1686431). SDR content may appear over-bright or over-saturated, which affects the baseline input to our HDR pipeline.
- **Expected**: Consistent SDR input regardless of display capabilities
- **Workaround**: Normalize input color values in the native app before applying inverse tone mapping.

### [BUG-003] Overlay window position drift on Firefox resize/scroll
- **Severity**: High
- **Component**: Native App (OverlayWindow)
- **Status**: Open
- **Description**: When the user resizes Firefox or scrolls the page, the overlay window must reposition to stay aligned with the video element. Rapid resize events may cause visible position drift or flicker.
- **Expected**: Overlay tracks video element position with no visible delay
- **Mitigation**: Use `Accessibility` API or frequent polling from the extension to report video rect changes. Debounce overlay repositioning.

### [BUG-004] DRM-protected content cannot be intercepted
- **Severity**: Medium
- **Component**: Extension
- **Status**: Won't Fix (v1)
- **Description**: DRM-protected streams (Netflix, Disney+, etc.) use Encrypted Media Extensions (EME). The extension cannot extract these video URLs, and the native app cannot decode them outside the browser's DRM sandbox.
- **Expected**: N/A - this is a platform limitation
- **Scope**: Out of scope for v1. Document as a known limitation.

### [BUG-005] MetalFX scaler creation is expensive
- **Severity**: Low
- **Component**: Upscaler
- **Status**: Open
- **Description**: Creating `MTLFXSpatialScaler` objects is GPU-expensive. If the video resolution changes mid-stream (adaptive bitrate), recreating the scaler causes a frame drop.
- **Expected**: Seamless handling of resolution changes
- **Mitigation**: Pre-create scalers for common input resolutions (360p, 480p, 720p, 1080p) at app startup.

### [BUG-006] Battery impact from continuous GPU processing
- **Severity**: Medium
- **Component**: Native App
- **Status**: Open
- **Description**: Running MetalFX + HDR compute shaders on every frame will increase GPU power draw, reducing battery life on laptops.
- **Expected**: Reasonable battery life during video playback
- **Mitigation**: Add quality presets (e.g. "Battery Saver" mode that skips upscaling and uses lighter tone mapping). Detect power source and auto-adjust.

---

## Resolved

(none yet)
