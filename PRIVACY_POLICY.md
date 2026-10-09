# Side Screen — Privacy Policy

_Last updated: 2026-10-09_

Side Screen ("the app") turns an Android tablet or phone into a second display for a Mac. This policy describes what the Android app does with your data.

## Summary

**Side Screen does not collect, store, or transmit any personal data to the developer or to any third party.** There are no accounts, no analytics, no advertising SDKs, and no crash-reporting services.

## Data the app handles on your device

- **Screen content from your Mac.** Video frames are streamed from the Side Screen Mac host to the app over USB or your local Wi-Fi network, decoded, and shown on screen. Frames are never written to storage and never leave your local network.
- **Touch and stylus input.** Taps, gestures and stylus events on the tablet are sent back to your Mac so you can control it. They are not stored.
- **Pairing information (wireless mode).** When you pair with a Mac over Wi-Fi, the app stores the Mac's local network address and a pairing key on the device so it can reconnect automatically. This data stays on your device and can be removed by forgetting the host in the app or uninstalling the app.
- **Preferences.** Settings such as resolution, orientation and connection mode are stored locally on the device.

## Permissions

| Permission | Why it is needed |
|---|---|
| Camera | Only used to scan the pairing QR code shown on the Mac in wireless mode. No photos or video are captured or stored. |
| Internet / Network state | Required to communicate with the Mac host over your local network. The app does not connect to any internet server. |
| Wake lock | Keeps the screen on while it is being used as a display. |

## Third parties

The app does not share data with third parties. It contains no analytics, advertising or tracking libraries. The ML Kit barcode-scanning library used for QR scanning runs entirely on the device.

## Children

The app is not directed at children and does not knowingly collect any data from anyone.

## Changes

If this policy changes, the updated version will be published at the same URL and the date above will be revised.

## Contact

Questions about this policy: open an issue at https://github.com/tranvuongquocdat/SideScreen/issues or contact the developer through the GitHub profile.
