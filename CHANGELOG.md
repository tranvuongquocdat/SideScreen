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

<a id="1.1.0"></a>
## [1.1.0] - 2026-02-19

Performance overhaul targeting sub-30ms end-to-end latency.

### Performance Improvements
- SCStream `queueDepth` optimization (-33ms worst-case capture latency)
- Async MediaCodec API with Choreographer vsync alignment on Android
- Pipeline decoupling: capture, encode, and send stages now run independently
- Timestamp accuracy fixes on both macOS and Android
- TCP_NODELAY and BufferedInputStream optimizations for network layer
- Touch path latency reduction (removed verbose logging from hot path)

### Developer Experience
- SwiftLint integration for macOS codebase
- ktlint integration for Android codebase
- GitHub Actions CI/CD for automated builds and lint checks
- DockDoor-style README with badges, hero section, and structured docs

### Website
- Updated performance claims to reflect <30ms latency target
- Added hero stats section with latency, FPS, and codec info
- Placeholder image instructions for all screenshot locations

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

[Unreleased]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.1...HEAD
[0.2.1]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/tranvuongquocdat/SideScreen/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/tranvuongquocdat/SideScreen/releases/tag/0.1.0
