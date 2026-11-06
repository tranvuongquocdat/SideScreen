#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

# Clean old build
echo "Cleaning old build..."
rm -rf .build

# Build fresh (Universal Binary: arm64 + x86_64). One invocation with both
# --arch flags: separate builds overwrite each other on the Swift 6 .build layout.
echo "Building macOS Host (universal)..."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
mkdir -p ".build/release-universal"
cp "$BIN_DIR/SideScreen" .build/release-universal/SideScreen
lipo -archs .build/release-universal/SideScreen

# Create .app bundle
APP_NAME="SideScreen"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary
cp .build/release-universal/SideScreen "$APP_DIR/Contents/MacOS/"

# Sparkle (auto-update) ships as a framework next to the binary
mkdir -p "$APP_DIR/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/"

# No LaunchAgent plist needed for SMAppService.mainApp

# Copy app icon if exists
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>SUFeedURL</key>
    <string>https://github.com/tranvuongquocdat/SideScreen/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>7bJdS/tTNvOEUEobUTrH7IxJsg/FBZcmSHyzY4ZU97I=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
EOF

# Developer ID signing when SIDESCREEN_SIGN_IDENTITY is set (same flags as CI),
# otherwise ad-hoc — Gatekeeper then needs `xattr -cr` after install.
if [ -n "${SIDESCREEN_SIGN_IDENTITY:-}" ]; then
    echo "Signing as $SIDESCREEN_SIGN_IDENTITY..."
    "$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR" "$SIDESCREEN_SIGN_IDENTITY"
    if [ -n "${APPSTORE_API_KEY_P8:-}" ]; then
        "$ROOT_DIR/scripts/notarize.sh" "$APP_DIR"
    fi
else
    echo "Ad-hoc signing (set SIDESCREEN_SIGN_IDENTITY for Developer ID)..."
    "$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR" -
fi
echo "  ✓ App signed"

echo ""
echo "Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
DMG_DIR=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
DMG_PATH="$ROOT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
hdiutil create -volname "Side Screen" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
if [ -n "${SIDESCREEN_SIGN_IDENTITY:-}" ]; then
    codesign --sign "$SIDESCREEN_SIGN_IDENTITY" --timestamp "$DMG_PATH"
    [ -n "${APPSTORE_API_KEY_P8:-}" ] && "$ROOT_DIR/scripts/notarize.sh" "$DMG_PATH"
fi
rm -rf "$DMG_DIR"
echo "DMG: $DMG_PATH"
