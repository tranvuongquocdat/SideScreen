# Screenshot Capture Guide — Side Screen

This guide describes how to capture each screenshot used in the README. Placeholder SVGs are currently in place; replace them with real screenshots following the instructions below.

---

## 1. App Icon

| | |
|---|---|
| **File** | `resources/logo/sidescreen-icon.png` |
| **Size** | 128 x 128 px |
| **Format** | PNG (transparent background preferred) |

**What to capture:**
- The Side Screen app icon at 128x128 resolution
- Should have rounded corners consistent with macOS icon style
- If you have an `.icns` or high-res source, export at 128px

**How to capture:**
1. Open the app icon source file (e.g., in Figma, Sketch, or Preview)
2. Export as PNG at 128x128
3. Ensure transparency is preserved if the icon has rounded corners
4. Save to `resources/logo/sidescreen-icon.png`

**Tips:**
- Use `sips -z 128 128 icon.png` on macOS to resize if needed
- Keep the file under 50KB

---

## 2. Hero Screenshot

| | |
|---|---|
| **File** | `resources/screenshots/hero.png` (or `hero.gif`) |
| **Size** | 800–1000 px wide |
| **Format** | PNG or GIF |

**What to capture:**
- Your Mac screen with the Side Screen menu bar app running
- An Android tablet connected via USB-C, displaying the extended screen
- Ideally show a window being dragged from the Mac onto the tablet
- A GIF (~5 seconds) of the drag action is ideal for maximum impact

**How to capture (static):**
1. Connect your tablet and start Side Screen on both devices
2. Arrange your Mac and tablet side by side on a desk
3. Open a recognizable app window (e.g., Safari, Notes) and position it half on each screen
4. Take a photo or use a screen capture tool that captures both devices
5. Crop and resize to 800–1000px wide
6. Save to `resources/screenshots/hero.png`

**How to capture (GIF):**
1. Use a tool like [Kap](https://getkap.co/) or [LICEcap](https://www.cockos.com/licecap/)
2. Record ~5 seconds of dragging a window from Mac to tablet
3. Export as GIF, keep under 2MB if possible
4. Save to `resources/screenshots/hero.gif` and update the README `src` accordingly

**Tips:**
- Clean up your desktop before capturing — hide unrelated icons and windows
- Use a neutral wallpaper on both devices
- If photographing physical devices, ensure good lighting and a clean background

---

## 3. Virtual Display Feature

| | |
|---|---|
| **File** | `resources/screenshots/feature-virtual-display.png` |
| **Size** | 700 px wide |
| **Format** | PNG |

**What to capture (Option A — Display Preferences):**
- macOS System Settings > Displays, showing the virtual display arrangement
- The virtual display created by Side Screen should be visible alongside your main display

**What to capture (Option B — Window Drag):**
- A Mac screenshot showing a window mid-drag onto the virtual display area

**How to capture:**
1. Open **System Settings > Displays** (or **System Preferences > Displays** on older macOS)
2. Ensure Side Screen is running and the virtual display is visible in the arrangement
3. Take a screenshot with `Cmd + Shift + 4`, then select the Displays area
4. Crop to show just the relevant portion
5. Resize to 700px wide
6. Save to `resources/screenshots/feature-virtual-display.png`

**Tips:**
- Annotate with arrows or highlights if the virtual display is hard to distinguish
- Use `sips -Z 700 screenshot.png` to resize proportionally

---

## 4. Performance Stats

| | |
|---|---|
| **File** | `resources/screenshots/feature-performance.png` |
| **Size** | 500 px wide |
| **Format** | PNG |

**What to capture:**
- The Android app's stats/performance overlay while streaming
- Should clearly show FPS, bitrate, and latency values
- Ideally show good numbers (e.g., 60 FPS, 20 Mbps, <30ms latency)

**How to capture:**
1. Connect and start streaming to the tablet
2. Enable the stats overlay in the Android app (if available) or use the debug info display
3. Take a screenshot on the Android device (`Power + Volume Down`)
4. Transfer to Mac via `adb pull` or file transfer
5. Crop to focus on the overlay area
6. Resize to 500px wide
7. Save to `resources/screenshots/feature-performance.png`

**Tips:**
- Wait for the stream to stabilize before capturing — you want consistent, impressive numbers
- Dark background behind the overlay makes the text more readable

---

## 5. macOS Settings Window

| | |
|---|---|
| **File** | `resources/screenshots/settings-mac.png` |
| **Size** | 380 px wide |
| **Format** | PNG |

**What to capture:**
- The Side Screen macOS settings window (frosted glass / vibrancy UI)
- All settings should be visible: resolution, frame rate, bitrate, quality, gaming mode toggle

**How to capture:**
1. Click the Side Screen menu bar icon to open settings
2. Use `Cmd + Shift + 4`, then press `Space` to capture just the window
3. This gives you a clean window capture with shadow
4. Resize to ~380px wide
5. Save to `resources/screenshots/settings-mac.png`

**Tips:**
- The window shadow from macOS window capture adds a nice touch — keep it
- Set resolution to a typical value (1920x1200) and bitrate to 20 Mbps for the screenshot
- If the frosted glass effect is not visible, make sure you have content behind the window

---

## 6. Android Settings Dialog

| | |
|---|---|
| **File** | `resources/screenshots/settings-android.png` |
| **Size** | 280 px wide |
| **Format** | PNG |

**What to capture:**
- The Android app's settings dialog/screen
- Show all configurable options visible in one view

**How to capture:**
1. Open the Side Screen app on Android
2. Navigate to the settings screen
3. Take a screenshot on the device (`Power + Volume Down`)
4. Transfer to Mac via `adb pull /sdcard/Pictures/Screenshots/<file> .`
5. Crop to just the settings dialog (not the full tablet screen)
6. Resize to ~280px wide
7. Save to `resources/screenshots/settings-android.png`

**Tips:**
- Use a device with a clean status bar (or crop it out)
- If the dialog has a dark theme, that pairs well with the macOS frosted glass look

---

## General Screenshot Tips

- **Window size consistency:** When capturing Mac windows, try to keep them at a consistent size across screenshots.
- **Retina displays:** macOS captures at 2x on Retina displays. Use `sips -Z <width> file.png` to resize to the target pixel width.
- **Crop tightly:** Remove unnecessary surrounding space. Focus on the relevant UI.
- **File size:** Keep each image under **500KB**. Use [TinyPNG](https://tinypng.com/) or `pngquant` to compress.
- **Naming convention:** Use lowercase, hyphen-separated names: `feature-virtual-display.png`, not `Feature_VirtualDisplay.png`.
- **Format:** Use PNG for static screenshots, GIF for animations. Avoid JPEG for UI screenshots (compression artifacts).

---

> **After capturing all screenshots, delete this file and the placeholder SVGs.**
