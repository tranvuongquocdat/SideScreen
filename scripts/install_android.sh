#!/bin/bash

# Build and install Android app to connected device

set -e

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

echo "📱 Building and installing Android app..."
echo ""

cd "$(dirname "$0")/../AndroidClient"

# Build APK
./gradlew assembleDebug

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${COLOR_GREEN}✅ Build successful!${COLOR_NC}"

    # Install to device
    echo ""
    echo "📲 Installing to device..."
    adb install -r app/build/outputs/apk/debug/app-debug.apk

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${COLOR_GREEN}✅ App installed!${COLOR_NC}"
        echo ""
        echo -e "${COLOR_YELLOW}Next steps:${COLOR_NC}"
        echo "  1. Setup tunnel: ./scripts/setup_tunnel.sh"
        echo "  2. Start Mac host: ./scripts/run_mac.sh"
        echo "  3. Open Virtual Display app on tablet and tap Connect"
    else
        echo "❌ Installation failed"
        exit 1
    fi
else
    echo "❌ Build failed"
    exit 1
fi
