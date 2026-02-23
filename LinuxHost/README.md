# SideScreen — Linux Host

Turn your Android tablet into a second display for Ubuntu/Linux via USB-C.

## Features

- Virtual display creation via xrandr
- H.265/HEVC hardware encoding (VA-API, NVENC via FFmpeg, software fallback)
- Screen capture via PipeWire (Wayland) or X11 (XShm)
- Ultra-low latency streaming (<30ms target)
- Full touch input with gesture support (tap, scroll, drag, pinch)
- Gaming Boost mode (1 Gbps, 120Hz)
- System tray app with settings window (Qt 6)
- Auto ADB setup

## Requirements

- Ubuntu 22.04+ (or any Linux with X11/Wayland)
- GPU with VA-API or NVENC support (software fallback available)
- USB-C port
- Qt 6

## Install Dependencies

```bash
# Required
sudo apt install qt6-base-dev cmake build-essential pkg-config adb

# Screen capture
sudo apt install libpipewire-0.3-dev                    # Wayland
sudo apt install libx11-dev libxext-dev libxrandr-dev \
                 libxcomposite-dev libxfixes-dev         # X11

# Video encoding
sudo apt install libva-dev                               # VA-API
sudo apt install libavcodec-dev libavutil-dev libswscale-dev  # FFmpeg

# Touch input
sudo apt install libxdo-dev xdotool
```

## Build

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

Or manually:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

Output: `build/SideScreen`

## Usage

1. Connect your Android tablet via USB-C
2. Run `./build/SideScreen`
3. Open the SideScreen Android app on your tablet
4. Tap Connect — your tablet is now a second display!

## Architecture

```
Virtual Display → PipeWire/X11 Capture → H.265 Encode → TCP Send
                                                            ↕ USB-C (ADB)
                                            Touch Handler ← TCP Receive
```

## Supported Display Servers

| Feature | X11 | Wayland |
|---|---|---|
| Screen Capture | XShm (fast) | PipeWire |
| Virtual Display | xrandr | Limited |
| Touch Input | libxdo/xdotool | xdotool |

## Protocol Compatibility

Uses the same binary TCP protocol as the macOS and Windows hosts. The Android client works with all three hosts without any changes.

## License

MIT — see [LICENSE](../LICENSE)
