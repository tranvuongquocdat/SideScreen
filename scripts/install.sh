#!/bin/bash
set -e

echo "🚀 Installing Virtual Display..."

# Build macOS app
echo "📦 Building macOS app..."
cd MacHost
swift build -c release
cd ..

# Build Android app
echo "📦 Building Android app..."
cd AndroidClient
./gradlew assembleDebug
cd ..

# Install Android app
echo "📱 Installing Android app..."
adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk

# Setup ADB reverse
echo "🔧 Setting up ADB reverse..."
adb reverse tcp:8888 tcp:8888

echo "✅ Installation complete!"
echo ""
echo "To run:"
echo "  macOS: MacHost/.build/release/VirtualDisplayHost"
echo "  Android: Open 'Virtual Display' app and tap CONNECT"
