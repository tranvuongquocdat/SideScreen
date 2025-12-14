#!/bin/bash
set -e

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
echo "  1. Start Mac server: MacHost/.build/release/VirtualDisplayHost"
echo "  2. Open 'Virtual Display' app on Android"
echo "  3. Tap CONNECT button"
echo ""
echo "💡 Troubleshooting:"
echo "  • Connection fails: ./scripts/setup-usb.sh"
echo "  • Check server: lsof -i :8888"
echo "  • Check forwarding: adb reverse --list"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
