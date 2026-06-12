#!/bin/bash
set -e

# Navigate to project root (parent of scripts directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "🚀 Installing Side Screen..."
echo ""

# Set JAVA_HOME for Android Studio's bundled JDK
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"

# Check Java
if [ ! -d "$JAVA_HOME" ]; then
    echo "❌ Java not found at: $JAVA_HOME"
    echo "   Please install Android Studio or set JAVA_HOME manually"
    exit 1
fi

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
cd "$ROOT_DIR"
echo "  ✓ macOS app built"

# Create macOS .app bundle
echo "📦 Creating macOS .app bundle..."
APP_NAME="SideScreen.app"
APP_DIR="$APP_NAME/Contents"
rm -rf "$APP_NAME"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy executable
cp MacHost/.build/release/SideScreen "$APP_DIR/MacOS/SideScreen"

# Create Info.plist
cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
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
cd "$ROOT_DIR"
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
sleep 0.5
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
echo "  1. Start Mac app: open SideScreen.app"
echo "     (or run: MacHost/.build/release/SideScreen)"
echo "  2. Open 'Side Screen' app on Android"
echo "  3. Tap Connect"
echo ""
echo "💡 Troubleshooting:"
echo "  • Connection fails: ./scripts/setup-usb.sh"
echo "  • Check server: lsof -i :8888"
echo "  • Check forwarding: adb reverse --list"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
