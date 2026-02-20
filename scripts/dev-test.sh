#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
APP_DIR="$ROOT_DIR/SideScreen.app"

echo "======================================="
echo "  Side Screen - Dev Test (v$VERSION)"
echo "======================================="
echo ""

# 1. Build macOS
echo "[1/5] Building macOS..."
cd "$ROOT_DIR/MacHost"
swift build -c release 2>&1 | tail -3
echo "  OK"

# 2. Create .app bundle (keeps permissions across rebuilds)
echo "[2/5] Creating .app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp .build/release/SideScreen "$APP_DIR/Contents/MacOS/"

if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"
fi

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
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR" 2>/dev/null
echo "  OK"

# 3. Build Android
echo "[3/5] Building Android..."
cd "$ROOT_DIR/AndroidClient"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew assembleDebug -q
APK="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo "  OK"

# 4. Install APK on device
echo "[4/5] Installing APK..."
if adb devices | grep -q "device$"; then
    adb install -r "$APK" 2>&1 | tail -1
else
    echo "  No device connected, skipping install"
fi

# 5. Run macOS app
echo "[5/5] Starting macOS app..."
pkill -f "SideScreen.app" 2>/dev/null || true
sleep 0.5

adb reverse tcp:8888 tcp:8888 2>/dev/null || true
open "$APP_DIR"

echo ""
echo "======================================="
echo "  Ready to test!"
echo "  App: $APP_DIR"
echo "  Open Side Screen on your tablet"
echo "======================================="
echo ""
read -p "Test result? [y=OK / n=failed]: " RESULT

pkill -f "SideScreen.app" 2>/dev/null || true

if [ "$RESULT" = "y" ]; then
    echo ""
    echo "Test passed. Ready to push."
else
    echo ""
    echo "Test failed. Fix and re-run."
    exit 1
fi
