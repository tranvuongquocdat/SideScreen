#!/bin/bash
# Notarize a .app, .dmg or .zip with Apple and staple the ticket.
#
#   scripts/notarize.sh SideScreen.app
#   scripts/notarize.sh SideScreen-1.1.0-mac-universal.dmg
#
# Needs an App Store Connect API key (role: Developer):
#   APPSTORE_API_KEY_P8   path to AuthKey_XXXX.p8
#   APPSTORE_API_KEY_ID   10-char key id
#   APPSTORE_API_ISSUER_ID
# Fails (and prints Apple's log) when the submission is not Accepted.
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path.app|path.dmg|path.zip>}"
: "${APPSTORE_API_KEY_P8:?}" "${APPSTORE_API_KEY_ID:?}" "${APPSTORE_API_ISSUER_ID:?}"
KEY_ARGS=(--key "$APPSTORE_API_KEY_P8" --key-id "$APPSTORE_API_KEY_ID" --issuer "$APPSTORE_API_ISSUER_ID")

SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  # notarytool takes zip/dmg/pkg only; the ticket is stapled onto the .app afterwards.
  SUBMIT="$(mktemp -d)/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "Notarizing $(basename "$TARGET")..."
OUTPUT=$(xcrun notarytool submit "$SUBMIT" "${KEY_ARGS[@]}" --wait 2>&1) || true
echo "$OUTPUT"
SUBMISSION_ID=$(echo "$OUTPUT" | awk '/^  id:/ {print $2; exit}')

if ! echo "$OUTPUT" | grep -q "status: Accepted"; then
  echo "::error::Notarization of $(basename "$TARGET") was not accepted"
  [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" "${KEY_ARGS[@]}" || true
  exit 1
fi

xcrun stapler staple "$TARGET"
