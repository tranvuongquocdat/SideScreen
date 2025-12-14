#!/bin/bash
set -e

echo "🚀 Virtual Display - Complete Setup"
echo "===================================="
echo ""

# Colors
GREEN='\033[0.32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check requirements
echo "📋 Checking requirements..."

# Check macOS version
if ! sw_vers | grep -q "14\|15"; then
    echo "${RED}❌ macOS 14 (Sonoma) or later required${NC}"
    exit 1
fi
echo "${GREEN}✅ macOS version OK${NC}"

# Check for Android device
if ! adb devices | grep -q "device$"; then
    echo "${RED}❌ No Android device connected${NC}"
    echo "Please connect your tablet via USB and enable USB debugging"
    exit 1
fi
echo "${GREEN}✅ Android device connected${NC}"

echo ""
echo "🔨 Building apps..."

# Build macOS app
echo "${BLUE}📦 Building macOS app...${NC}"
cd MacHost
swift build -c release
cd ..
echo "${GREEN}✅ macOS build complete${NC}"

# Build Android app
echo "${BLUE}📦 Building Android app...${NC}"
cd AndroidClient
./gradlew assembleDebug --quiet
cd ..
echo "${GREEN}✅ Android build complete${NC}"

echo ""
echo "📱 Installing..."

# Install Android app
adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk
echo "${GREEN}✅ Android app installed${NC}"

# Setup ADB reverse
adb reverse tcp:8888 tcp:8888
echo "${GREEN}✅ ADB reverse configured${NC}"

# Create .app bundle
echo ""
echo "${BLUE}📦 Creating VirtualDisplay.app...${NC}"
./scripts/create-app.sh > /dev/null 2>&1
echo "${GREEN}✅ VirtualDisplay.app created${NC}"

echo ""
echo "${GREEN}✅ Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Open VirtualDisplay.app (double-click in Finder)"
echo "  2. Grant Screen Recording permission if prompted"
echo "  3. Click 'Start Server' in settings"
echo "  4. Open 'Virtual Display' app on tablet"
echo "  5. Tap 'CONNECT'"
echo ""
echo "To open Finder: ${BLUE}open .${NC}"
