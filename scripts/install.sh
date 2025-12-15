#!/bin/bash
set -e

# Navigate to project root (parent of scripts directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "🚀 Installing Virtual Display..."
echo ""

# Check ADB connection first
echo "📱 Checking ADB connection..."
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi
echo "  ✓ Android device connected"
echo ""

# Build macOS app
echo "📦 Building macOS app..."
cd MacHost
swift build -c release
cd ..
echo "  ✓ macOS app built"

# Create macOS .app bundle
echo "📦 Creating macOS .app bundle..."
APP_NAME="VirtualDisplay.app"
APP_DIR="$APP_NAME/Contents"
rm -rf "$APP_NAME"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy executable
cp MacHost/.build/release/VirtualDisplayHost "$APP_DIR/MacOS/VirtualDisplay"

# Create Info.plist
cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Virtual Display</string>
    <key>CFBundleDisplayName</key>
    <string>Virtual Display</string>
    <key>CFBundleIdentifier</key>
    <string>com.virtualdisplay.host</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>VirtualDisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "  ✓ macOS .app bundle created: $APP_NAME"
echo ""

# Build Android app
echo "📦 Building Android app..."
cd AndroidClient
./gradlew assembleDebug
cd ..
echo "  ✓ Android app built"
echo ""

# Install Android app
echo "📱 Installing Android app..."
adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk
echo "  ✓ Android app installed"
echo ""

# Setup ADB reverse (with retry)
echo "🔧 Setting up USB port forwarding..."
adb reverse --remove tcp:8888 2>/dev/null || true
sleep 1
adb reverse tcp:8888 tcp:8888

# Verify ADB reverse is active
echo "🔍 Verifying port forwarding..."
if adb reverse --list | grep -q "tcp:8888"; then
    echo "  ✓ Port 8888 forwarded successfully"
else
    echo "  ⚠️  Port forwarding setup but verification failed"
    echo "  Run './scripts/setup-usb.sh' if connection issues occur"
fi
echo ""

echo "✅ Installation complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To start streaming:"
echo "  1. Start Mac app: open VirtualDisplay.app"
echo "     (or run: MacHost/.build/release/VirtualDisplayHost)"
echo "  2. Open 'Virtual Display' app on Android"
echo "  3. Tap CONNECT button"
echo ""
echo "💡 Troubleshooting:"
echo "  • Connection fails: ./scripts/setup-usb.sh"
echo "  • Check server: lsof -i :8888"
echo "  • Check forwarding: adb reverse --list"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
