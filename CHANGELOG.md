# Changelog

All notable changes to Side Screen will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- WiFi Direct support (wireless mode)
- Audio streaming
- Multi-touch gestures
- Stylus/pen support

---

<a id="1.0.0"></a>
## [1.0.0] - 2025-12-27

Initial public release of Side Screen.

### Features

#### macOS Host
- Virtual display creation using CGVirtualDisplay API
- Screen capture with ScreenCaptureKit
- H.265/HEVC hardware encoding via VideoToolbox
- TCP streaming server (port 8888)
- Settings window with Apple design language
  - Resolution selection (1920x1200, 1920x1080, custom)
  - Frame rate options (30, 60, 90, 120 FPS)
  - Bitrate control (10-50 Mbps)
  - Quality presets (Low, Medium, High)
- Gaming Boost mode for optimized low-latency streaming
- Menu bar integration with real-time performance stats

#### Android Client
- H.265/HEVC hardware decoding via MediaCodec
- TCP client with automatic reconnection
- Full-screen video rendering
- Touch input with prediction for latency compensation
- Floating draggable settings button
- Real-time stats overlay (FPS, bitrate, resolution)
- Performance mode for sustained CPU/GPU performance
- Device rotation support
- Material Design 3 UI

### Technical Highlights
- Hardware-accelerated video pipeline on both platforms
- TCP_NODELAY for minimum network latency
- Frame dropping for frames older than 50ms
- Input prediction using linear extrapolation
- High-priority threads for display operations
- Choreographer-based vsync alignment on Android

---

## Version History Format

Each release follows this format:

```
## [Version] - YYYY-MM-DD

### New Features
- Feature descriptions

### Improvements
- Performance and UX improvements

### Bug Fixes
- Bug fix descriptions

### Breaking Changes
- Any breaking changes (if applicable)
```

---

[Unreleased]: https://github.com/user/SideScreen/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/user/SideScreen/releases/tag/v1.0.0
