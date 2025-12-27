<a id="readme-top"></a>

<div align="center">

<!-- Logo placeholder - replace with actual logo -->
<img src="resources/logo/sidescreen-icon.png" alt="Side Screen Logo" width="128"/>

</div>

<h1 align="center">Side Screen</h1>

<div align="center">

<p>
  <a href="https://github.com/tranvuongquocdat/SideScreen/releases/latest">
    <img src="https://img.shields.io/github/v/release/tranvuongquocdat/SideScreen?style=flat&label=Latest&labelColor=444" alt="Latest release">
  </a>
  <a href="https://github.com/tranvuongquocdat/SideScreen/releases">
    <img src="https://img.shields.io/github/downloads/tranvuongquocdat/SideScreen/total?label=Downloads" alt="Total downloads">
  </a>
</p>

![Swift](https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![macOS](https://img.shields.io/badge/macOS_14+-000000?style=for-the-badge&logo=apple&logoColor=white)
![Android](https://img.shields.io/badge/Android_8+-3DDC84?style=for-the-badge&logo=android&logoColor=white)

**Turn your Android tablet into a second display for your Mac via USB-C.**

Low latency. Hardware accelerated. Gaming ready.

</div>

<!-- Hero Screenshot Placeholder -->
<div align="center">
  <img src="resources/screenshots/hero.png" alt="Side Screen Demo" width="800"/>
  <p><em>Your tablet becomes an extension of your Mac workspace</em></p>
</div>

---

## Table of Contents

- [About](#about)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Support](#support)
- [License](#license)

---

## About

**Side Screen** transforms your Android tablet into a wireless-free second display for macOS. Unlike wireless solutions, it uses USB-C for a stable, low-latency connection that's perfect for productivity and even gaming.

Built with performance in mind:
- **H.265/HEVC** hardware encoding & decoding
- **USB connection** for reliable, lag-free streaming
- **Touch support** with input prediction for responsive interaction
- **Gaming mode** with up to 120 FPS and optimized bitrate

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Features

### Virtual Display
Create a true virtual display on your Mac - not just screen mirroring. Drag windows to your tablet just like a real monitor.

<!-- Screenshot: Virtual display in action -->

### Low Latency Streaming
Hardware-accelerated H.265 encoding on Mac and decoding on Android ensures smooth, real-time video with minimal delay.

<!-- Screenshot: Performance stats -->

### Touch & Input Support
Use your tablet's touchscreen to interact with macOS. Touch prediction compensates for network latency.

<!-- Screenshot: Touch interaction -->

### Gaming Mode
Enable Gaming Boost for optimized settings: higher bitrate, lower latency, up to 120 FPS support.

<!-- Screenshot: Gaming mode settings -->

### Customizable Settings
Configure resolution, frame rate, bitrate, and quality to match your needs and device capabilities.

<div align="center">
  <img src="resources/screenshots/settings-mac.png" alt="macOS Settings" width="400"/>
  <img src="resources/screenshots/settings-android.png" alt="Android Settings" width="300"/>
</div>

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Requirements

### macOS Host
- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac
- USB-C port

### Android Client
- Android 8.0 (API 26) or later
- Hardware H.265 decoder support
- USB-C cable

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Installation

### One-Command Setup

```bash
# Clone the repository
git clone https://github.com/tranvuongquocdat/SideScreen.git
cd SideScreen/TAASD

# Run the installation script
./scripts/install.sh
```

This will:
1. Build the macOS app
2. Build and install the Android APK
3. Set up USB port forwarding

### Manual Installation

<details>
<summary>Build macOS app manually</summary>

```bash
cd MacHost
swift build -c release

# Create app bundle
mkdir -p SideScreen.app/Contents/MacOS
cp .build/release/SideScreen SideScreen.app/Contents/MacOS/
```

</details>

<details>
<summary>Build Android app manually</summary>

```bash
cd AndroidClient
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

</details>

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Usage

### Quick Start

1. **Connect** your tablet to your Mac via USB-C

2. **Setup port forwarding** (required once per connection):
   ```bash
   adb reverse tcp:8888 tcp:8888
   ```

3. **Launch Side Screen** on your Mac
   - The app runs in the menu bar
   - Click to open settings

4. **Open Side Screen** on your Android tablet
   - Tap "Connect" to start streaming

5. **Use your tablet** as a second display!

### Menu Bar Controls

| Icon | Description |
|------|-------------|
| Settings | Open configuration window |
| Stats | View real-time performance |
| Quit | Close the application |

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Configuration

### Display Settings

| Setting | Options | Description |
|---------|---------|-------------|
| Resolution | 1920x1200, 1920x1080, custom | Virtual display resolution |
| Frame Rate | 30, 60, 90, 120 FPS | Target refresh rate |
| Bitrate | 10-50 Mbps | Video encoding bitrate |
| Quality | Low, Medium, High | Encoding quality preset |

### Gaming Boost

Enable for optimized gaming performance:
- Automatically sets 50 Mbps bitrate
- Switches to Low quality for minimum latency
- Enables high frame rate mode

### Advanced Settings

<details>
<summary>Android client advanced options</summary>

- **Host**: Default `localhost` (change for network mode)
- **Port**: Default `8888`
- **Stats Overlay**: Show/hide performance metrics
- **Button Position**: Customize settings button location

</details>

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Troubleshooting

### Connection Issues

**"Connection refused" on Android**

Make sure port forwarding is set up:
```bash
adb reverse tcp:8888 tcp:8888
```

**App not detecting tablet**

1. Enable USB debugging on Android
2. Accept the USB debugging prompt
3. Verify with `adb devices`

### Performance Issues

**High latency or stuttering**

- Lower the resolution or frame rate
- Ensure both devices support H.265 hardware codec
- Use a high-quality USB-C cable

**Virtual display not appearing**

- Grant Screen Recording permission to the Mac app
- The app requires accessibility permissions for some features

### Screen Recording Permission

On first launch, macOS will ask for Screen Recording permission:

1. Open **System Preferences** > **Privacy & Security** > **Screen Recording**
2. Enable **Side Screen**
3. Restart the app

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Contributing

We welcome contributions! Here's how you can help:

- **Star** this repository to help others discover it
- **Report bugs** by opening an issue
- **Suggest features** through the issue tracker
- **Submit PRs** for improvements

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## Support

If you find Side Screen useful, consider supporting development:

<div align="center">

[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=github-sponsors&logoColor=white)](https://github.com/sponsors/tranvuongquocdat)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/sidescreen)

</div>

<p align="right"><a href="#readme-top">Back to top</a></p>

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

Made with passion for the Mac community

[Report Bug](https://github.com/tranvuongquocdat/SideScreen/issues) · [Request Feature](https://github.com/tranvuongquocdat/SideScreen/issues) · [Discussions](https://github.com/tranvuongquocdat/SideScreen/discussions)

</div>

<p align="right"><a href="#readme-top">Back to top</a></p>
