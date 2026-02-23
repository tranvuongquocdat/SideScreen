# SideScreen — Windows Host

Turn your Android tablet into a second display for Windows via USB-C.

## Features

- Creates a true virtual Windows display (appears in Display Settings)
- H.265/HEVC hardware encoding (NVENC, AMF, QuickSync)
- Ultra-low latency streaming (<30ms target)
- Full touch input with gesture support (tap, scroll, drag, pinch)
- Gaming Boost mode (1 Gbps, 120Hz)
- System tray app with settings window
- Auto ADB setup

## Requirements

- Windows 10 1903+ (64-bit)
- GPU with H.265 encode: NVIDIA GTX 1000+ / AMD RX 400+ / Intel 6th gen+
- USB-C port
- [Virtual Display Driver](https://github.com/MolotovCherry/virtual-display-rs) installed
- Qt 6.7+

## Build

### Prerequisites

- Visual Studio 2022 (with C++ workload)
- CMake 3.20+
- Qt 6.7+ (set `CMAKE_PREFIX_PATH` or use Qt installer)

### Optional SDKs (for enhanced encoder support)

- [NVIDIA Video Codec SDK](https://developer.nvidia.com/video-codec-sdk) — set `-DNVCODEC_SDK_DIR=path`
- [AMD AMF SDK](https://github.com/GPUOpen-LibrariesAndSDKs/AMF) — set `-DAMF_SDK_DIR=path`

### Build Commands

```bat
scripts\build.bat
```

Or manually:

```bat
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

Output: `build\Release\SideScreen.exe`

## Usage

1. Install the [Virtual Display Driver](https://github.com/MolotovCherry/virtual-display-rs)
2. Connect your Android tablet via USB-C
3. Run `SideScreen.exe`
4. Open the SideScreen Android app on your tablet
5. Tap Connect — your tablet is now a second display!

## Architecture

```
Virtual Display → DXGI Capture → H.265 Encode → TCP Send
                                                    ↕ USB-C (ADB)
                                    Touch Handler ← TCP Receive
```

## Protocol Compatibility

Uses the same binary TCP protocol as the macOS host. The Android client works with both hosts without any changes.

## License

MIT — see [LICENSE](../LICENSE)
