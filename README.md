# HDR Upscaler for Firefox (macOS)

A native macOS companion app + Firefox extension that upscales video resolution and converts SDR content to HDR in real time during browser playback.

## What It Does

- **Video Upscaling**: Enhances video resolution (e.g. 720p/1080p to 4K) using Apple's MetalFX spatial upscaler, running at sub-2ms per frame on Apple Silicon
- **SDR-to-HDR Conversion**: Applies inverse tone mapping (ITU-R BT.2446 Method B) to expand standard dynamic range video into HDR, outputting genuine EDR (Extended Dynamic Range) signal on supported displays
- **Firefox Integration**: A lightweight WebExtension communicates with the native app via a local WebSocket server to intercept and enhance video playback

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon Mac (M1 or later)
- Firefox 115+
- HDR-capable display (for HDR output; upscaling works on any display)

## Architecture Overview

The system uses a hybrid architecture:

1. **Firefox WebExtension** - Detects video elements, extracts media URLs, and manages the overlay lifecycle
2. **Native Companion App (Swift/Metal)** - Performs GPU-accelerated upscaling (MetalFX) and SDR-to-HDR conversion (Metal compute shaders), outputs EDR content via `CAMetalLayer`
3. **Local WebSocket Server** - Bridges communication between the extension and native app with minimal latency

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full technical design.

## Project Status

This project is in early development (Sprint 1 - Planning & Architecture).

## License

TBD
