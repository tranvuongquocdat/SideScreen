# Publishing Side Screen on Google Play

Checklist for getting the Android client onto the Play Store. The Mac host is unaffected.

## 1. One-time: create the upload keystore

Run once on your Mac. **Keep the `.jks` file and the passwords somewhere safe (password manager).** If the key is lost you cannot ship updates to the same listing — although with Play App Signing (enabled by default for new apps) Google can reset a lost *upload* key on request.

```bash
keytool -genkeypair -v \
  -keystore ~/sidescreen-upload.jks \
  -alias sidescreen-upload \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Side Screen, O=Side Screen, C=VN"
```

It will prompt for a keystore password and a key password (use the same for both to keep it simple).

Never commit the keystore. `*.jks` and `*.keystore` are git-ignored.

## 2. One-time: add GitHub Secrets

Repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | output of `base64 -i ~/sidescreen-upload.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `sidescreen-upload` |
| `ANDROID_KEY_PASSWORD` | key password |

Or via CLI:

```bash
gh secret set ANDROID_KEYSTORE_BASE64 -R tranvuongquocdat/SideScreen < <(base64 -i ~/sidescreen-upload.jks)
gh secret set ANDROID_KEYSTORE_PASSWORD -R tranvuongquocdat/SideScreen
gh secret set ANDROID_KEY_ALIAS -R tranvuongquocdat/SideScreen --body sidescreen-upload
gh secret set ANDROID_KEY_PASSWORD -R tranvuongquocdat/SideScreen
```

Once set, every tag push (`release.yml`) produces both `SideScreen-<ver>-android.apk` (attached to the GitHub Release) and `SideScreen-<ver>-android.aab` (workflow artifact only, not attached to the release) signed with the upload key. Without the secrets the build silently falls back to the debug key (fine for CI on forks, not for Play).

To build a signed bundle locally:

```bash
export SIDESCREEN_KEYSTORE_PATH=~/sidescreen-upload.jks
export SIDESCREEN_KEYSTORE_PASSWORD=...
export SIDESCREEN_KEY_ALIAS=sidescreen-upload
export SIDESCREEN_KEY_PASSWORD=...
cd AndroidClient && ./gradlew bundleRelease
# → app/build/outputs/bundle/release/app-release.aab
```

## 3. Play Console: create the app

Play Console → **Create app**
- App name: `Side Screen`
- Default language: English (United States)
- App or game: App · Free
- Accept the declarations.

### Store listing (Grow → Store presence → Main store listing)

- **Short description** (≤ 80 chars):
  `Turn your Android tablet into a second display for your Mac — USB-C or Wi-Fi.`
- **Full description**: see `resources/play-store/full-description.txt`.
- **App icon**: `resources/play-store/icon-512.png` (512×512, no alpha).
- **Feature graphic**: `resources/play-store/feature-graphic-1024x500.png`.
- **Phone screenshots** (min 2, 16:9 or 9:16, 320–3840 px): take on a phone or tablet in portrait; `resources/screenshots/android_*.png` can be reused if they meet the size rules.
- **7-inch and 10-inch tablet screenshots**: required for the tablet listing. Take landscape screenshots of the app mirroring a Mac desktop.
- **Category**: Tools. **Tags**: Productivity.
- **Contact email**: your developer email. **Website**: `https://github.com/tranvuongquocdat/SideScreen`.

### Policy section (Monitor and manage → Policy → App content)

- **Privacy policy URL**: `https://github.com/tranvuongquocdat/SideScreen/blob/main/PRIVACY_POLICY.md`
- **Ads**: No, the app does not contain ads.
- **App access**: All functionality is available without special access. (Reviewers need a Mac to see streaming; add a note: "Requires the free Side Screen macOS host from the GitHub releases page. Without a Mac the app shows the connection screen only.")
- **Content rating**: fill the IARC questionnaire → Utility/Productivity; answer No to everything → rated Everyone.
- **Target audience**: 18 and over (simplest; avoids the Families policy).
- **News app**: No. **COVID-19 app**: No. **Government app**: No.
- **Data safety**:
  - Does your app collect or share any of the required user data types? **No.**
  - Is all user data encrypted in transit? N/A (no data collected). Choose "No data collected".
  - The CAMERA permission is used for QR scanning only; no images are collected.
- **Health apps / Financial features**: None.
- **Advertising ID**: No.

## 4. Testing track before production

Personal developer accounts created after Nov 2023 must run a **closed test with at least 12 testers opted in for 14 consecutive days** before they may apply for production access.

1. Testing → **Closed testing** → Create track (e.g. `beta`) → Upload the `.aab`.
2. Testers tab → create an email list and add at least 12 Gmail addresses (friends, GitHub issue contributors who volunteered, community). Share the opt-in link with them; they must click **Become a tester** *and install the app*.
3. Keep the track live ≥ 14 days. Push updates to it freely; the clock keeps running.
4. After 14 days: Dashboard → **Apply for production access**, answer the short questionnaire (what you tested, feedback received).
5. Once approved: Production → Create release → Upload the `.aab` → Review → Roll out. First review usually takes 1–7 days.

Tip: recruit testers through a pinned GitHub issue/Discussion ("Help test Side Screen on Google Play — 12 testers needed").

## 5. Each later release

1. Bump `VERSION`, update `CHANGELOG.md`, tag and push as usual. `versionCode` is derived from `VERSION` (`major*10000 + minor*100 + patch`) so every release has a strictly higher code.
2. Download `SideScreen-<ver>-android.aab` from the workflow run: Actions → Release → the run for the tag → Artifacts → `android-apk`.
3. Play Console → Production → Create release → upload → paste release notes from `CHANGELOG.md` → Roll out.

## 6. Android developer verification (sideloading, separate from Play)

The "Android developer verification" page in Play Console (Package names tab) registers packages for distribution *outside* Play. From 2026 (some countries) / 2027 (global) certified devices will refuse to install unregistered apps. Register `com.sidescreen.app` there together with the signing certificate so the APK on GitHub Releases keeps installing. Use the same upload key for the GitHub APK so the fingerprint matches:

```bash
keytool -list -v -keystore ~/sidescreen-upload.jks -alias sidescreen-upload | grep SHA256
```
