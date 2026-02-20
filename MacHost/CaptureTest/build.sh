#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Building CaptureTest ==="
swift build -c release 2>&1

# Find the built binary
BINARY=$(swift build -c release --show-bin-path)/CaptureTest

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "=== Creating .app bundle ==="
APP_DIR="$SCRIPT_DIR/CaptureTest.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/CaptureTest"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.capturetest</string>
    <key>CFBundleName</key>
    <string>CaptureTest</string>
    <key>CFBundleExecutable</key>
    <string>CaptureTest</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>CaptureTest needs screen recording permission to test capture APIs on virtual displays.</string>
</dict>
</plist>
PLIST

echo "=== Code signing with entitlements ==="
codesign --force --sign - --entitlements "$SCRIPT_DIR/CaptureTest.entitlements" "$APP_DIR"

echo ""
echo "=== Build complete ==="
echo "App bundle: $APP_DIR"
echo ""
echo "Run with:"
echo "  $APP_DIR/Contents/MacOS/CaptureTest"
