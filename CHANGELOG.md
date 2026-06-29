# Changelog

All notable changes to Side Screen will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- mDNS auto-discovery for wireless mode
- Audio streaming
- Multi-touch gestures
- Stylus/pen support

---

<a id="0.11.0"></a>
## [0.11.0] - 2026-06-29

Headless auto-start. The Mac host can launch at login and start streaming automatically, so a Mac with no display of its own can boot up and serve the tablet with nothing to press on the Mac — the tablet's own Connect (USB) / Reconnect (Wireless) button is the only thing you touch. Building on the headless groundwork contributed by @shhrohan (#25), reworked to keep wireless mode and the existing settings UI intact, and to start the server *declaratively at launch* rather than reacting to USB plug/unplug events.

### Added
- **Launch at Login.** Registers the host as a login item (`SMAppService`) so it starts silently in the background after you log in. New toggle in the Settings → "Startup" group.
- **Auto-start streaming on launch + Startup mode.** When enabled, the server starts automatically when the app opens, in the connection mode (USB or Wireless) you choose. The server then stays up and listens; the tablet connects/reconnects whenever, with no action required on the Mac.
- **Self-healing USB bridge.** `adb reverse` is now re-established automatically whenever a device is present but the forward is missing (replug, adb-server restart, …), instead of only on the USB connect edge.

### Notes
- The server lifecycle is no longer tied to USB plug/unplug — it does not auto-stop on disconnect, so the virtual display (and your window layout) persists across tablet reconnects. The tablet's existing Connect / Reconnect buttons remain the connection path; nothing on the Mac needs pressing.
- First-time setup still needs a screen once (to grant Screen Recording permission); afterwards the Mac can run fully headless. For wireless headless use, pin the Mac to a static IP / DHCP reservation — automatic discovery (mDNS) is still planned.

### Installation
- **macOS**: Open `SideScreen-0.11.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Requires macOS 13 (Ventura) or later.
- **Android**: Install `SideScreen-0.11.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.10.1"></a>
## [0.10.1] - 2026-06-12

Wireless connection fix. Several people reported the tablet connecting at the TCP level but the Mac never responding — the loading screen hung forever and only flipped to "Couldn't reach Mac" when the server stopped. This was most common on mobile hotspots and carrier-NAT networks. Contributed by @akashraj9828 (#26, closes #10).

### Fixed
- **Wireless connection hangs in "Connecting…" on many networks.** The Mac host enabled TCP Fast Open on its listener, but the Android client uses standard TCP (no TFO). On networks with middleboxes (mobile hotspot, carrier NAT), the connection's `NWConnection` stayed in `.preparing` and never reached `.ready`, so the auth handshake never ran and the Mac stayed silent at the application layer — even though the TCP handshake itself completed. Removing the Fast Open option lets the connection establish normally. USB was unaffected (loopback has no middleboxes), which is why it always worked. `noDelay` (Nagle's algorithm disabled) — the optimization that actually matters for streaming latency — is kept.

### Installation
- **macOS**: Open `SideScreen-0.10.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Requires macOS 13 (Ventura) or later.
- **Android**: Install `SideScreen-0.10.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.10.0"></a>
## [0.10.0] - 2026-06-12

Compatibility release: H.264 fallback for tablets that have no HEVC decoder (e-ink devices like the Onyx Boox line), macOS 13 Ventura support for older Intel Macs, and a custom-resolution Apply that actually applies.

### Added
- **H.264 fallback for devices without an HEVC decoder.** Side Screen streamed HEVC only, so tablets whose firmware ships no HEVC decoder (e.g. Onyx Boox Nova Air C) connected fine but showed a black screen — frames arrived, nothing could decode them. The Android client now probes `MediaCodecList` once at connect and, when HEVC is missing, advertises it to the Mac, which switches the encoder to H.264 (Main profile) and clamps the encode resolution to the 1920×1088 floor that every AVC hardware decoder meets — preserving aspect ratio, 16-aligned. Devices with HEVC keep streaming HEVC exactly as before; the fallback only activates where today there was nothing. Thanks to Devin Lange for the report and the adb diagnostics that pinned the root cause.
- **macOS 13 (Ventura) support.** The deployment target dropped from macOS 14 to 13, so 2017+ Intel Macs stuck on Ventura can run the host. The binary was already universal (arm64 + x86_64); only one macOS 14-only API stood in the way. App-bundle metadata (`LSMinimumSystemVersion`) now matches. Heads-up: ScreenCaptureKit and the virtual-display private API are less battle-tested on 13 — reports welcome.

### Fixed
- **Custom resolution "Apply" did nothing.** Three stacked bugs: the W/H fields only committed their text when you pressed Return (clicking Apply read stale values, and locale formatting injected grouping separators like "1.920"); nothing listened for resolution changes while the server ran, so even a committed change sat idle until a manual stop/start; and out-of-range values were rejected silently. Now Apply reads exactly what you typed, the server restarts itself (~2 s, the tablet reconnects) whenever the resolution changes mid-run — picker rows included — the applied custom value shows up highlighted in the resolution list, and out-of-range input disables Apply and shows the supported range (640–7680 × 480–4320).

### Notes
- Two new wire-protocol messages (`9` client-is-AVC-only, `10` codec-selected), both strictly opt-in: an old Mac safely ignores type 9 (payload-free by design), and type 10 is only ever sent to clients that asked. Every mixed old/new pairing on HEVC-capable devices behaves byte-identically to 0.9.1. The one combination that still can't stream — AVC-only tablet against an old Mac — now shows "update the Mac app" on the tablet instead of a silent black screen. Update both sides to get the fallback.
- H.264 is a less efficient codec than HEVC; on AVC-only devices expect the clamped resolution (e.g. a 1872×1404 panel streams at 1440×1088) and slightly softer text than an HEVC device would get. That trade buys a working screen on hardware that previously had none.

### Installation
- **macOS**: Open `SideScreen-0.10.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Now requires macOS 13 (Ventura) or later — was 14.
- **Android**: Install `SideScreen-0.10.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.9.1"></a>
## [0.9.1] - 2026-05-18

Hotfix for a "cursor trail" / ghost-cursor artifact visible on shaky WiFi (e.g. iPhone hotspot) under 0.9.0. Android-only — Mac host is unchanged.

### Fixed
- **Cursor trail / ghost cursors on WiFi jitter.** When a brief WiFi burst saturated MediaCodec's input pool on Android, the decoder kept receiving P-frames whose reference state had quietly diverged from the encoder's. The mismatch painted ghost cursors at old positions until the next scheduled keyframe arrived (~1 s later). The client now **force-requests a fresh keyframe** the moment the input pool exhausts, bypassing the 1 s / 500 ms / 500 ms throttle chain that was holding recovery back — the reference rebuilds in ~150 ms instead. The pipeline keeps feeding through the recovery so the cursor stays live (a brief trail is visible while the keyframe is in flight, then it clears). A new 200 ms throttle on forced requests prevents the host being keyframe-flooded under sustained congestion.

### Installation
- **macOS**: 0.9.0 DMG works — no Mac changes in this release. Otherwise install `SideScreen-0.9.1-mac-universal.dmg` and run `sudo xattr -cr /Applications/SideScreen.app` if Gatekeeper complains.
- **Android**: Install `SideScreen-0.9.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.9.0"></a>
## [0.9.0] - 2026-05-18

Stream resilience pass — faster recovery after backgrounding/reconnect, less lag pile-up on rapidly changing content, and two latent bugs squashed in the wire layer. Contributed by @luisdavim (#16, relates to #13).

### Added
- **Keyframe tracking and recovery**. The Android client now parses per-frame metadata from the Mac host (keyframe flag + capture timestamp), waits for a fresh keyframe before feeding the decoder after startup or codec error, and explicitly requests a keyframe from the host on demand. Returning to Side Screen from home / multi-task now recovers in ~50–100 ms instead of staying garbled until the next scheduled keyframe (~1 s). An opt-in handshake message keeps older clients on the legacy frame format so mixed versions still work.
- **Stale decoder-output drop**. When the decoder's output queue piles up under heavy scenes (fast terminal scroll, large window scroll, etc.), frames whose decoder-pipeline latency exceeds 100 ms are dropped rather than rendered. Cursor and touch feel stay live instead of slowly trailing reality.

### Fixed
- **Touch thread priority was being set on the wrong thread.** `Executors.newSingleThreadExecutor` runs the thread factory on the caller, so the `Process.setThreadPriority(THREAD_PRIORITY_DISPLAY)` call inside the factory was elevating whichever thread happened to call `connect()` instead of `TouchThread` itself. The priority call now runs from inside the worker, so touch handling actually gets the boost under CPU pressure.
- **Coalesced messages on the Mac host could silently lose touch/ping events.** The Mac input loop read up to 22 bytes per receive and processed only the first message; when TCP combined a touch frame plus a ping into one segment, the trailing message was dropped. Replaced with a buffered parser that consumes one message at a time and keeps the rest for the next round.
- **Async diagnostic log writes.** `DiagLog` no longer blocks on file I/O on the calling thread — writes run on a dedicated single-thread executor. Helps on devices where the previous synchronous `appendText` showed up in input latency profiles.

### Notes
- This release adds three new wire-protocol message types (`6` video-frame-with-metadata, `7` keyframe-request, `8` client-supports-metadata) but keeps the legacy type `0` path. Mixed pairs are safe: a new Android client + old Mac host falls back to legacy frames; a new Mac host + old Android client never sees the new types because the client doesn't advertise capability. Update both sides to get the recovery benefits.

### Installation
- **macOS**: Open `SideScreen-0.9.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.9.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.8.1"></a>
## [0.8.1] - 2026-05-12

Small fix on top of the 0.8.0 wireless release. Wireless mode (QR pairing, auto-reconnect, paired-devices management) and everything else from 0.8.0 stay the same — this patch only fixes a UI bug in the Mac Status section.

### Fixed
- **Info tooltips next to status rows now show their hint text.** Clicking the `ⓘ` icon next to a status row previously opened an empty horizontal bar instead of the explanation. Now it pops up the hint properly (e.g. what "ADB reverse" or "Listening on" actually mean).

### Installation
- **macOS**: Open `SideScreen-0.8.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: APK from 0.8.0 still works — no Android changes in this release. Otherwise install `SideScreen-0.8.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.8.0"></a>
## [0.8.0] - 2026-05-09

Wireless connection mode — Android client can now connect to the Mac host over WiFi LAN via one-time QR pairing, no USB cable required. USB mode unchanged and remains the default.

### Added
- **Wireless mode** — pair via QR scan, auto-reconnect on every launch, secure by token. Built on the same short-GOP encoder pipeline that landed in 0.7.0, so quality matches USB whenever your WiFi is healthy.
- **Mode-aware status checklist** — Mac status section now adapts to your connection mode. USB mode tells you when ADB is missing (with the `brew install` command right there). Wireless mode shows your WiFi state and listening address.
- **Paired devices on Mac** — see every tablet you've paired with, forget devices individually, or rotate the auth token to revoke access for all of them at once.

### Changed
- Android connection screen now has a top-level **USB / Wireless** segmented switcher. Manual host/port entry stays in the USB tab unchanged.
- **Default port changed from 8888 to 54321** (8888 collides with HP printers, Splunk, Jupyter, and many dev tools — fresh installs now default to 54321; existing users keep their saved value).
- Status section rows now have an `info.circle` icon next to each label — hover to see what the row means and how to fix it.

### Notes
- Wireless adds 10–50 ms of latency depending on WiFi quality. For text/web/video it's not noticeable. For drawing precision or fast-paced gaming, USB still wins.
- The token authorizing wireless connections is generated on first launch and stored locally — anyone with your Mac's QR can pair, so don't share it broadcast-style. "Reset Token" on Mac revokes all paired devices.

### Installation
- **macOS**: Open `SideScreen-0.8.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.8.0-android.apk` (enable "Unknown sources" if needed). Wireless mode requires camera permission to scan the pairing QR.
- **First wireless pairing**: open Side Screen on Mac → toggle to Wireless tab → scan the displayed QR with the Android app's Wireless tab.

---

<a id="0.7.1"></a>
## [0.7.1] - 2026-05-06

Hotfix — Mac app was being quarantined as malware by macOS XProtect on install.

### Fixed
- **Mac app flagged as virus and auto-moved to Trash on 0.7.0**: the new "Reset Permission" helper from #8 spawned `tccutil reset ScreenCapture <bundle-id>` from inside the app. This is the exact pattern XProtect's YARA rules use to detect TCC-bypass malware (Atomic Stealer / Cthulhu Stealer family). Combined with the existing ad-hoc signature and `disable-library-validation` / `allow-unsigned-executable-memory` entitlements, the binary scored high enough to be quarantined automatically. The auto-reset feature has been removed; stale-TCC handling is back to 0.6.8 behavior — users who hit it after a reinstall need to remove the SideScreen entry manually under System Settings → Privacy & Security → Screen Recording. All other 0.7.0 improvements (short-GOP encoding, instant decode handshake, default 60 Hz, touch parsing gate, Arrange Displays shortcut, decoder latency log) are preserved.

### Installation
- **macOS**: Open `SideScreen-0.7.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged" or "cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.7.1-android.apk` (enable "Unknown sources" if needed)
- **If you installed 0.7.0 and the app was moved to Trash by macOS**: empty Trash first, then download 0.7.1 fresh — the 0.7.0 binary was rejected by XProtect, redownloading the same file won't help. After installing 0.7.1, run the `xattr -cr` command above.

---

<a id="0.7.0"></a>
## [0.7.0] - 2026-05-05

User-experience improvements (permission recovery, display arrangement) and pipeline performance work to reduce input lag on high-resolution tablets.

### Fixed
- **Stuck Screen Recording permission after reinstall** (#8): when macOS holds onto a stale TCC entry from a previous SideScreen install, `CGRequestScreenCaptureAccess()` no-ops silently and the user is locked out. The Status section now detects this state (preflight returns false despite a previous successful grant), surfaces a "Permission stuck" banner, and offers a one-click "Reset Permission" button that runs `tccutil reset ScreenCapture com.sidescreen.app`. If the spawn fails, a fallback banner shows the exact command with a Copy button.
- **Input lag on dynamic content / high-res tablets** (#13): the encoder previously used all-intra (every frame a keyframe), producing 3-5x more data per frame than necessary. This saturated tablet decode/compose pipelines at high panel resolutions and starved Mac WindowServer rendering when capturing fast-changing content. Switched to short-GOP IPP encoding (1 keyframe per second, P-frames in between), which keeps frame-loss recovery within 1 second over reliable USB-C TCP while dramatically lowering per-frame work end-to-end.
- **Touch parsing wasted CPU when touch was disabled**: incoming touch frames from the client were parsed and dispatched to the main queue even when host-side touch control was off; only the `guard` in the handler discarded them. Touch frames now drop early without parsing or dispatch when `touchEnabled` is off; ping/pong continues unaffected.
- **Slow first frame after client connects on idle screen**: with short-GOP encoding, a client connecting during a static screen would wait up to a full second for the next scheduled keyframe before its decoder could start. The host now forces an IDR keyframe the moment a client appears, replays the last cached pixel buffer if capture is currently idle, and drops orphan P-frames at the streaming server until that first keyframe is sent — so a fresh decoder always starts on a sync frame. (Cherry-picked from #15 — thanks to @luisdavim for the contribution and @busybox11 for testing.)

### Changed
- **Default refresh rate is now 60 Hz** for new installs (was 120 Hz). 120 fps stream on a 120 Hz tablet leaves zero VSync headroom — any pipeline jitter immediately queues frames. 60 fps gives 2:1 headroom on 120 Hz panels and a 16.7 ms budget on 60 Hz panels. Existing users keep their saved value; users can still opt back to 120 from settings.
- **Display Configuration UI**: refresh-rate selector moved into its own section, full-width custom buttons replace the native segmented picker, and the resolution list height now adapts to whether "Show all" is on.

### Added
- **"Arrange Displays…" shortcut** (#12) in the Display Configuration section. Opens System Settings → Displays directly on the arrangement pane.
- **Decoder pipeline latency log** on the Android client. Every 60 output frames, DiagLog records average/max decoder input-to-output latency plus available input buffer count, so users reporting lag can attach a log that pinpoints whether the bottleneck is decoder queuing, compose/present, or upstream Mac.

---

<a id="0.6.8"></a>
## [0.6.8] - 2026-03-18

Bug fixes — connection reliability and stream stability.

### Fixed
- **ADB race condition on first connect**: `setupADBReverse()` now completes before the streaming server starts. Previously, the server could begin listening before the ADB tunnel was established, causing the tablet to show "Mac Server Running" in red on first install. Includes automatic retry (up to 3×) to handle first-time USB authorization delays.
- **SCStream false-positive restart on idle screen**: When the display was idle (no content changes), macOS stops delivering frames as an optimization. The frame flow monitor incorrectly treated this as a stream crash and triggered unnecessary restarts, eventually falling back to CGDisplayStream. The monitor now sends a keepalive frame from the last captured buffer instead of restarting. Real SCStream errors are still handled via the error delegate.

---

<a id="0.6.5"></a>
## [0.6.5] - 2026-03-17

HiDPI support and Universal Binary.

### Added
- **HiDPI / Retina mode**: Virtual display now supports HiDPI scaling. macOS renders at 2× physical pixels for sharp, Retina-quality output — even at lower logical resolutions (e.g. choose 1280×800 logical on a 2K tablet for comfortable UI size with full sharpness).
- **Universal Binary**: Mac app now ships as a Universal Binary (arm64 + x86_64), supporting both Apple Silicon and Intel Macs natively.

---

<a id="0.6.2"></a>
## [0.6.2] - 2026-03-17

Universal Binary build system.

### Changed
- Build pipeline updated to produce Universal Binary (arm64 + x86_64).

---

<a id="0.5.2"></a>
## [0.5.2] - 2026-02-21

Documentation update — ADB prerequisite instructions.

### Added
- ADB installation guide in README and website for users who don't have `adb` installed (Homebrew + `android-platform-tools`)
- Clarified that the Mac app requires `adb` to show "Running" status

### Website
- Added ADB prerequisite note to download section

---

<a id="0.2.3"></a>
## [0.2.3] - 2026-02-19

Packaging and documentation fixes.

### Fixed
- Ad-hoc code signing for macOS DMG to reduce Gatekeeper issues
- Gatekeeper workaround (`xattr -cr`) added to website, README, and release notes
- Removed outdated `TAASD` folder references from README and CONTRIBUTING
- Simplified installation guide — users download from GitHub Releases instead of building from source
- Removed redundant terminal code block from website "How It Works" section

---

<a id="0.2.2"></a>
## [0.2.2] - 2026-02-19

Bug fixes and UX improvements for website and DMG installer.

### Fixed
- DMG installer now includes Applications folder shortcut for drag-and-drop installation
- Theme toggle button vertically centered in website header
- Hero action buttons no longer overlap with stats section above
- Removed outdated `adb reverse` manual instructions — Mac app handles port forwarding automatically

### Improved
- Faster scroll-in animations (0.6s → 0.3s) for snappier website experience
- Updated website FAQ and README to reflect automatic ADB setup

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
- Professional README with badges, hero section, and structured docs

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

[Unreleased]: https://github.com/tranvuongquocdat/SideScreen/compare/0.6.8...HEAD
[0.6.8]: https://github.com/tranvuongquocdat/SideScreen/compare/0.6.5...0.6.8
[0.6.5]: https://github.com/tranvuongquocdat/SideScreen/compare/0.6.2...0.6.5
[0.6.2]: https://github.com/tranvuongquocdat/SideScreen/compare/0.5.2...0.6.2
[0.5.2]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.3...0.5.2
[0.2.3]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.2...0.2.3
[0.2.2]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/tranvuongquocdat/SideScreen/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/tranvuongquocdat/SideScreen/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/tranvuongquocdat/SideScreen/releases/tag/0.1.0
