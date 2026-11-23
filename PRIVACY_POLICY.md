# Side Screen — Privacy Policy

_Last updated: 2026-11-23_

Side Screen ("the app") turns an Android tablet or phone into a second display for a Mac. This policy describes what the Android app does with your data.

## Summary

**Side Screen does not collect, store, or transmit any personal data to the developer or to any third party.** There are no accounts, no analytics, no advertising SDKs, and no crash-reporting services.

## Data the app handles on your device

- **Screen content from your Mac.** Video frames are streamed from the Side Screen Mac host to the app over USB or your local Wi-Fi network, decoded, and shown on screen. Frames are never written to storage and never leave your local network.
- **Touch and stylus input.** Taps, gestures and stylus events on the tablet are sent back to your Mac so you can control it. They are not stored.
- **Pairing information (wireless mode).** When you pair with a Mac over Wi-Fi, the app stores the Mac's local network address and a pairing key on the device so it can reconnect automatically. This data stays on your device and can be removed by forgetting the host in the app or uninstalling the app.
- **Preferences.** Settings such as resolution, orientation and connection mode are stored locally on the device.
- **Device identifier (sent to your Mac only).** The app generates a random identifier the first time it runs and sends it, with the device's name, to the Side Screen Mac host when connecting, so the Mac can bring back that tablet's own settings. It is not derived from any hardware serial, never leaves your USB cable or local network, and is reset by clearing the app's data or reinstalling.

## Permissions

| Permission | Why it is needed |
|---|---|
| Camera | Only used to scan the pairing QR code shown on the Mac in wireless mode. No photos or video are captured or stored. |
| Internet / Network state | Required to communicate with the Mac host over your local network. The app does not connect to any internet server. |
| Wake lock | Keeps the screen on while it is being used as a display. |

## Third parties

The app does not share data with third parties. It contains no analytics, advertising or tracking libraries. The ML Kit barcode-scanning library used for QR scanning runs entirely on the device.

## SideScreen Pro (Mac app)

SideScreen Pro is a separate, paid Mac app. The Android app and the free Mac app work as described above. SideScreen Pro contacts the internet in two cases:

- **License key.** When you enter your key, and about once a day after that, the app sends the key, an anonymous ID for your Mac (a one-way hash; the hardware ID itself never leaves the Mac), and your Mac's name and model to Polar (polar.sh), which sells SideScreen Pro and keeps the license keys. The name is what you see when you manage the Macs your key is used on. Purchases are handled by Polar under its own privacy policy.
- **Feedback.** Only when you press Send under About → Feedback: your note, your email address if you typed one, the app and macOS version, your Mac's model and, if you leave it ticked, the last lines of the app's log, which can include device names and addresses on your local network. The box shows exactly what will be sent. It reaches the developer as an email, relayed by Cloudflare, and is not stored anywhere else.

## Children

The app is not directed at children and does not knowingly collect any data from anyone.

## Changes

If this policy changes, the updated version will be published at the same URL and the date above will be revised.

## Contact

Questions about this policy: open an issue at https://github.com/tranvuongquocdat/SideScreen/issues or write to support@sidescreen.dev.
