<a id="readme-top"></a>

<div align="center">

<img src="resources/logo/sidescreen-icon.png" alt="Side Screen" width="128"/>

<h1>Side Screen</h1>

<p><em>Turn your Android tablet into a second display for macOS — USB-C or wireless over WiFi</em></p>

<p>
  <img src="https://img.shields.io/github/v/release/tranvuongquocdat/SideScreen?style=for-the-badge&label=version&color=blue" alt="Version">
  <a href="https://github.com/tranvuongquocdat/SideScreen/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/tranvuongquocdat/SideScreen?style=for-the-badge&color=34C759" alt="License">
  </a>
  <a href="https://github.com/tranvuongquocdat/SideScreen/stargazers">
    <img src="https://img.shields.io/github/stars/tranvuongquocdat/SideScreen?style=for-the-badge&color=FF9500" alt="Stars">
  </a>
  <a href="https://github.com/tranvuongquocdat/SideScreen/releases">
    <img src="https://img.shields.io/github/downloads/tranvuongquocdat/SideScreen/total?style=for-the-badge&color=8E44AD&label=downloads" alt="Downloads">
  </a>
</p>

![Swift](https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![macOS](https://img.shields.io/badge/macOS_13+-000000?style=for-the-badge&logo=apple&logoColor=white)
![Android](https://img.shields.io/badge/Android_8+-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Universal Binary](https://img.shields.io/badge/Universal_Binary-Apple_Silicon_+_Intel-000000?style=for-the-badge&logo=apple&logoColor=white)

</div>

---

<div align="center">
  <img src="resources/screenshots/hero_screenshot.jpeg" alt="Side Screen — Mac + Android tablet as second display" width="800"/>
</div>

---

## About

Side Screen brings true second-display functionality to your Android tablet — over USB-C cable for the lowest latency, or wirelessly over WiFi after a one-time QR pair. Something macOS doesn't natively support either way.

While Apple's Sidecar only works with iPads, millions of Android tablets sit unused as potential workstations. Side Screen bridges that gap with hardware-accelerated H.265 streaming, sub-16ms pipeline latency on USB, and full touch input — making your tablet feel like a real monitor, not a laggy mirror.

Built entirely open-source, Side Screen is designed to be fast, lightweight, and seamlessly integrated.

For full details, features, and documentation, please visit **[sidescreen.dev](https://sidescreen.dev)**

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Features

### USB-C or Wireless

Two ways to connect, same picture quality. **USB-C** plugs in the cable for the lowest possible latency — adb-reverse port forwarding is set up automatically. **Wireless** lets you scan a QR code from the Mac once and the tablet auto-reconnects on every future launch over WiFi (5 GHz strongly recommended). The auth token is generated locally and stays on your Mac; reset it any time to revoke access.

### Virtual Display

Create a true virtual display on your Mac. Drag windows to your tablet like a real monitor — not mirroring, but extending.

<div align="center">
  <img src="resources/screenshots/feature_virtual_display.png" alt="Virtual Display in macOS Display Preferences" width="600"/>
</div>

### Ultra-Low Latency

Hardware-accelerated H.265 encoding on Mac and decoding on Android. Async pipeline architecture delivers frames in under 30ms.

<div align="center">
  <img src="resources/screenshots/android_performance.png" alt="Low Latency Streaming with Stats Overlay" width="700"/>
</div>

### Touch Support

Use your tablet's touchscreen to interact with macOS. Touch prediction compensates for network latency, making taps and drags feel natural.

### HiDPI (Retina) Support

Enable HiDPI mode to render at 2× resolution internally — text and icons are sharp at any logical resolution, just like a MacBook Retina display. Perfect for users with 2K/4K tablets who want a readable workspace without sacrificing sharpness.

### Gaming Mode

Enable Gaming Boost for optimized settings: 1 Gbps bitrate, ultra-low latency encoding, 120 FPS.

### Customizable

Configure resolution (up to 4K/8K), frame rate (30–120 FPS), bitrate (20–5000 Mbps), and quality presets from the Mac app.

<div align="center">
  <img src="resources/screenshots/mac_settings_1.png" alt="macOS Settings — Display & FPS" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/mac_settings_2.png" alt="macOS Settings — Streaming & Status" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/android_settings.png" alt="Android — Connection Screen" height="500"/>
</div>

### Headless / portable Mac (new in 0.11.0)

Run a Mac with no display of its own — a Mac Studio or Mini on the go, or a laptop in clamshell — using the tablet as its only screen. Enable Launch at Login and Auto-start streaming, and the Mac boots straight into serving the tablet, with nothing to press on the Mac.

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Requirements

| | macOS Host | Android Client |
|---|---|---|
| **OS** | macOS 13 (Ventura)+ | Android 8.0 (API 26)+ |
| **Hardware** | Apple Silicon or Intel | H.265 hardware decoder |
| **USB mode** | USB-C port + `adb` (`brew install android-platform-tools`) | USB-C cable + USB Debugging enabled |
| **Wireless mode** | Same WiFi network as the tablet (5 GHz recommended) | Camera (for QR scan) + Google Play Services (for ML Kit barcode) |

---

## Installation

Download the latest release from [**GitHub Releases**](https://github.com/tranvuongquocdat/SideScreen/releases):

- **macOS**: Download `.dmg`, open it, drag Side Screen to Applications
- **Android**: Download `.apk`, install on your tablet (enable "Unknown sources" if needed). Port forwarding is handled automatically by the Mac app.

> **⚠️ macOS Gatekeeper**
> If macOS says the app is "damaged", open Terminal and run:
> ```bash
> sudo xattr -cr /Applications/SideScreen.app
> ```
> Then open the app again. This is needed because the app is not notarized with an Apple Developer certificate.

> **⚠️ ADB Required**
> The Mac app needs `adb` to communicate with your Android device. If the app doesn't show "Running" after launch, you likely need to install ADB:
>
> 1. Install Homebrew (if you don't have it):
>    ```bash
>    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
>    ```
> 2. Install ADB:
>    ```bash
>    brew install --cask android-platform-tools
>    ```

<details>
<summary><strong>Build from source (for developers)</strong></summary>

```bash
git clone https://github.com/tranvuongquocdat/SideScreen.git
cd SideScreen

# macOS
cd MacHost && swift build -c release

# Android
cd AndroidClient && ./gradlew assembleDebug
```
</details>

---

## Usage

### USB mode (default — lowest latency)

1. Connect tablet to Mac via **USB-C**
2. Launch **Side Screen** on Mac (runs in menu bar — port forwarding is set up automatically)
3. Open **Side Screen** on tablet → keep on the **USB** tab → tap **Connect**
4. Done — drag windows to your new display

### Wireless mode (new in 0.8.0 — no cable)

1. Launch **Side Screen** on Mac → toggle to the **Wireless** tab → a QR code appears
2. Open **Side Screen** on tablet → switch to the **Wireless** tab → tap **Scan QR Code** → grant camera permission → aim at the QR on the Mac
3. The tablet remembers the Mac. Subsequent launches auto-reconnect — no rescan.

Wireless mode requires both devices to be on the same WiFi network. **5 GHz is strongly recommended** — 2.4 GHz can introduce noticeable jitter on dynamic content. If you need to revoke access, click **Reset Token (forget all)** on the Mac and re-pair each tablet.

USB mode remains the lowest-latency option for drawing or fast-paced gaming. Wireless adds 10–50 ms depending on WiFi quality.

### Headless mode (new in 0.11.0 — no Mac interaction)

In Settings → Startup, turn on **Launch at Login** and **Auto-start streaming on launch**, then pick the **Startup mode** (USB or Wireless). On your next login the server starts automatically — just open Side Screen on the tablet and tap Connect (USB) or Reconnect (Wireless).

First-time setup still needs a screen once to grant Screen Recording permission; after that the Mac runs fully headless. For wireless headless use, give the Mac a static IP or DHCP reservation, and consider enabling macOS Screen Sharing as a fallback way in.

---

## Configuration

| Setting | Options | Default |
|---------|---------|---------|
| Resolution | 720p to 8K, 30+ presets + custom | 1920x1200 |
| Frame Rate | 30, 60, 90, 120 FPS | 120 |
| Bitrate | 20–5000 Mbps | 1000 Mbps |
| Quality | Ultra Low, Low, Medium, High | Ultra Low |
| HiDPI (Retina) | On/Off | Off |
| Gaming Boost | On/Off (1 Gbps, 120 Hz) | Off |
| Touch Input | On/Off | On |
| Pen / Draw Mode | On/Off | Off |

---

## Troubleshooting

<details>
<summary><strong>"SideScreen is damaged" on macOS</strong></summary>

This happens because the app is not notarized by Apple. Run this command to fix it:
```bash
sudo xattr -cr /Applications/SideScreen.app
```
Then open the app again.
</details>

<details>
<summary><strong>"Connection refused" on Android</strong></summary>

The Mac app sets up `adb reverse` automatically when streaming starts. If it still fails, make sure `adb` is installed (via Android SDK or Homebrew: `brew install android-platform-tools`) and your device has USB debugging enabled.
</details>

<details>
<summary><strong>High latency or stuttering</strong></summary>

- Lower resolution or frame rate
- Ensure H.265 hardware codec support on your device
- For USB mode, use a high-quality USB-C cable (not charge-only)
- For wireless mode, ensure both devices are on **5 GHz WiFi**, not 2.4 GHz; reduce refresh rate to 60 Hz if jitter persists
</details>

<details>
<summary><strong>Wireless: "Couldn't reach Mac" / connection times out</strong></summary>

- Both devices must be on the same WiFi network (and same subnet — some mesh routers isolate "guest" devices)
- Click **Start** on the Mac before scanning the QR — the listener only binds when the server is running
- If the Mac changes WiFi or its LAN IP, scan a fresh QR (the cached one points to the old address)
- macOS may prompt for **Local Network** permission on first wireless toggle — grant it; without it, LAN inbound is silently dropped
</details>

<details>
<summary><strong>Wireless: "Re-pair required" after restart / reinstall</strong></summary>

The Mac's auth token resets when you click **Reset Token (forget all)** or reinstall the app. Tap **Scan QR Code** on the Android client and scan the new QR shown on the Mac.
</details>

<details>
<summary><strong>Virtual display not appearing</strong></summary>

Grant Screen Recording permission: **System Preferences → Privacy & Security → Screen Recording → Enable Side Screen**
</details>

---

## Contributing

Contributions are welcome!

- ⭐ **Star** this repo to help others discover it
- 🐛 **Report bugs** via [Issues](https://github.com/tranvuongquocdat/SideScreen/issues)
- 💡 **Suggest features** via [Issues](https://github.com/tranvuongquocdat/SideScreen/issues)
- 🔧 **Submit PRs** — see [CONTRIBUTING.md](CONTRIBUTING.md)

---

## Support

If Side Screen is useful to you, consider supporting development:

<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/tranvuongqk)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=github-sponsors&logoColor=white)](https://github.com/sponsors/tranvuongquocdat)
[![VietQR](https://img.shields.io/badge/Vietnam-VietQR-DA251D?style=for-the-badge&logoColor=white)](https://sidescreen.dev/donate.html)

</div>

🇻🇳 Vietnamese users — scan VietQR for a local bank transfer (no international fees) at [sidescreen.dev/donate](https://sidescreen.dev/donate.html).

---

## License

[MIT License](LICENSE) — free for personal and commercial use.

---

<div align="center">

Made with ❤️ by **Tran Vuong Quoc Dat**

[Report Bug](https://github.com/tranvuongquocdat/SideScreen/issues) · [Request Feature](https://github.com/tranvuongquocdat/SideScreen/issues) · [Discussions](https://github.com/tranvuongquocdat/SideScreen/discussions)

</div>
