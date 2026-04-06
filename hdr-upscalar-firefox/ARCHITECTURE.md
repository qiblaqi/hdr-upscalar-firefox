# Architecture & Blueprint

## System Overview

```
+-------------------+       WebSocket        +------------------------+
|  Firefox          | <--------------------> |  Native macOS App      |
|  WebExtension     |   (localhost:9800)     |  (Swift / Metal)       |
|                   |                         |                        |
|  - Detect <video> |                         |  - MetalFX Upscaler    |
|  - Extract URL    |                         |  - HDR Compute Shader  |
|  - Control overlay|                         |  - EDR CAMetalLayer    |
+-------------------+                         +------------------------+
                                                        |
                                                        v
                                              +-------------------+
                                              |  macOS Display    |
                                              |  (EDR / HDR)      |
                                              +-------------------+
```

## Component Design

### 1. Firefox WebExtension

**Purpose**: Detect video playback, extract media information, and coordinate with the native app.

**Key Files**:
- `extension/manifest.json` - WebExtension manifest (Manifest V3)
- `extension/content.js` - Content script injected into web pages
- `extension/background.js` - Service worker managing native messaging
- `extension/popup.html` - User controls (enable/disable, quality settings)

**Responsibilities**:
- Detect `<video>` elements via MutationObserver
- Extract video source URL and position/dimensions on screen
- Send video metadata to native app via WebSocket
- Listen for user preferences (upscale factor, HDR intensity)

### 2. Native Companion App (Swift)

**Purpose**: GPU-accelerated video processing pipeline.

**Key Modules**:

#### 2a. Video Decode (`VideoDecoder.swift`)
- Use `AVAssetReader` / `AVSampleBufferDisplayLayer` to decode video from URL
- Output `CVPixelBuffer` frames in `kCVPixelFormatType_32BGRA`
- Sync playback via `CMTime` timestamps

#### 2b. MetalFX Upscaler (`Upscaler.swift`)
- Create `MTLFXSpatialScalerDescriptor` once at startup
- Configure input/output texture dimensions (e.g. 1080p in, 4K out)
- Per frame: copy `CVPixelBuffer` to input `MTLTexture`, encode upscale pass, read output texture
- Sub-2ms GPU time per frame on M1+

#### 2c. HDR Shader Pipeline (`HDRPipeline.swift` + `sdr_to_hdr.metal`)
- Metal compute shader implementing the full color pipeline:

```metal
// Pseudocode for SDR-to-HDR compute shader
kernel void sdr_to_hdr(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 sdr = inTex.read(gid);

    // Step 1: Linearize (remove BT.1886 gamma)
    float3 linear = pow(sdr.rgb, 2.4);

    // Step 2: BT.709 -> BT.2020 gamut mapping
    float3x3 M = float3x3(
        float3(0.6274, 0.0691, 0.0164),
        float3(0.3293, 0.9195, 0.0880),
        float3(0.0433, 0.0114, 0.8956)
    );
    float3 bt2020 = M * linear;

    // Step 3: Inverse tone mapping (BT.2446 Method B)
    float peakNits = 600.0; // configurable
    float3 expanded = inverseToneMap_BT2446(bt2020, peakNits);

    // Step 4: Apply PQ (ST 2084) OETF
    float3 pq = linearToPQ(expanded);

    outTex.write(float4(pq, 1.0), gid);
}
```

**Color Pipeline Steps**:
1. **Linearize**: Remove BT.1886 EOTF (gamma 2.4) to get linear light
2. **Gamut map**: 3x3 matrix from BT.709 to BT.2020 primaries
3. **Inverse tone map**: ITU-R BT.2446 Method B segmented curve, expanding 100-nit SDR to configurable peak (400-1000 nits)
4. **PQ encode**: Apply ST 2084 perceptual quantizer OETF

#### 2d. Display Output (`OverlayWindow.swift`)
- Borderless `NSWindow` positioned over Firefox's video area
- `CAMetalLayer` with:
  - `wantsExtendedDynamicRangeContent = true`
  - `pixelFormat = .rgba16Float`
  - `colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)`
- Renders upscaled + HDR frames at display refresh rate via `CVDisplayLink`

#### 2e. WebSocket Server (`WebSocketServer.swift`)
- Lightweight local server on `ws://localhost:9800`
- JSON message protocol for commands (play, pause, resize, settings)
- Binary frames for any pixel data transfer if needed

### 3. Communication Protocol

```json
// Extension -> Native: Video detected
{
    "type": "video_detected",
    "url": "https://example.com/video.mp4",
    "rect": { "x": 100, "y": 200, "width": 1280, "height": 720 },
    "windowId": 42
}

// Extension -> Native: Settings update
{
    "type": "settings",
    "upscaleFactor": 2,
    "hdrEnabled": true,
    "peakBrightness": 600,
    "hdrIntensity": 0.8
}

// Native -> Extension: Status
{
    "type": "status",
    "state": "playing",
    "fps": 60,
    "resolution": "3840x2160",
    "hdrActive": true
}
```

## Technology Decisions

### Upscaling: MetalFX Spatial (chosen) vs MLX vs VTFrameProcessor

| Criteria | MetalFX Spatial | MLX (SR model) | VTFrameProcessor |
|----------|----------------|-----------------|-------------------|
| Latency | <2ms/frame | 50-200ms/frame | ~5-15ms/frame |
| 60fps capable | Yes | No | Likely |
| Quality | Good (algorithmic) | Excellent (ML) | Good (ML, Apple-tuned) |
| Setup complexity | Low | High (port model) | Low |
| macOS version | 13.0+ | 14.0+ | 15.4+ |
| Availability | Shipping | No SR models | Very new |

**Decision**: MetalFX Spatial is chosen for v1. It is the fastest, simplest to integrate, and supports the widest range of macOS versions. VTFrameProcessor is a strong candidate for v2 once macOS 15.4 adoption grows.

### HDR Conversion: Shader-based ITM (chosen) vs ML-based

| Criteria | BT.2446 Shader | ML Model (HDRTVDM) |
|----------|---------------|---------------------|
| Latency | <1ms/frame | 100ms+/frame |
| Quality | Good (standardized) | Excellent |
| Real-time | Yes | No |
| Complexity | Low | High |

**Decision**: Shader-based inverse tone mapping using ITU-R BT.2446 Method B. It is real-time, well-documented by international standard, and produces good results. ML-based enhancement could be explored as an optional quality mode in future sprints.

### Why a Native App (not pure WebExtension)?

Firefox's WebExtension sandbox cannot:
- Access Metal, MetalFX, or Core ML APIs
- Output EDR/HDR pixel values to the macOS compositor
- Use `requestVideoFrameCallback` (not supported in Firefox)

A native companion app is required for genuine HDR output and hardware-accelerated upscaling.

## Processing Pipeline (per frame)

```
Video URL (from extension)
    |
    v
AVAssetReader (decode)
    |
    v
CVPixelBuffer (SDR, e.g. 1080p)
    |
    v
MTLTexture (input)
    |
    v
MetalFX Spatial Upscaler  --> MTLTexture (upscaled, e.g. 4K, still SDR)
    |
    v
SDR-to-HDR Compute Shader --> MTLTexture (4K, HDR/PQ)
    |
    v
CAMetalLayer (EDR output)  --> Display
```

## Directory Structure

```
hdr-upscalar-firefox/
├── README.md
├── ARCHITECTURE.md
├── BUGS.md
├── todo.md
├── extension/                  # Firefox WebExtension
│   ├── manifest.json
│   ├── content.js
│   ├── background.js
│   ├── popup.html
│   ├── popup.js
│   └── icons/
├── native-app/                 # macOS companion app (Swift)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── main.swift
│   │   ├── VideoDecoder.swift
│   │   ├── Upscaler.swift
│   │   ├── HDRPipeline.swift
│   │   ├── sdr_to_hdr.metal
│   │   ├── OverlayWindow.swift
│   │   └── WebSocketServer.swift
│   └── Resources/
└── docs/
    └── color-pipeline.md
```

## Future Considerations (out of scope for v1)

- **VTFrameProcessor integration** for ML-enhanced upscaling on macOS 15.4+
- **Temporal upscaling** using MetalFX temporal scaler with motion vectors
- **Frame interpolation** for 30fps -> 60fps conversion
- **Per-scene adaptive tone mapping** using scene-cut detection
- **DRM content handling** (currently out of scope; DRM-protected streams cannot be intercepted)
- **Dolby Vision profile generation** with dynamic metadata (RPU)
