#!/bin/bash
# Sign SideScreen.app for distribution. Sparkle's nested helpers are signed
# first, then the framework, then the app — `codesign --deep` is deprecated
# and does not get that order right.
#
#   scripts/sign_app.sh SideScreen.app "Developer ID Application: ..."   # hardened runtime + timestamp
#   scripts/sign_app.sh SideScreen.app -                                  # ad-hoc (forks, local builds)
set -euo pipefail

APP="${1:?usage: sign_app.sh <SideScreen.app> <identity|->}"
IDENTITY="${2:?usage: sign_app.sh <SideScreen.app> <identity|->}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/MacHost/SideScreen.entitlements"

FLAGS=(--force --options runtime)
if [ "$IDENTITY" != "-" ]; then
  FLAGS+=(--timestamp)
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
  codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE"
fi

codesign "${FLAGS[@]}" --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
