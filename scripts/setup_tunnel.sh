#!/bin/bash

# Virtual Display - Setup USB Tunnel Script
# This script sets up ADB reverse tunnel for streaming video to Android device

set -e

PORT=8888
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m' # No Color

echo "🔧 Virtual Display - Setup ADB Tunnel"
echo "======================================"

# Check if ADB is installed
if ! command -v adb &> /dev/null; then
    echo -e "${COLOR_RED}❌ ADB not found!${COLOR_NC}"
    echo "Please install Android Platform Tools:"
    echo "  brew install android-platform-tools"
    exit 1
fi

echo -e "${COLOR_GREEN}✅ ADB found: $(adb version | head -1)${COLOR_NC}"

# Check if device is connected
echo ""
echo "🔍 Checking for connected devices..."
DEVICES=$(adb devices | grep -v "List" | grep "device$" | wc -l)

if [ "$DEVICES" -eq 0 ]; then
    echo -e "${COLOR_RED}❌ No Android device connected!${COLOR_NC}"
    echo ""
    echo "Please:"
    echo "  1. Connect your tablet via USB-C"
    echo "  2. Enable USB Debugging on the tablet:"
    echo "     Settings > Developer Options > USB Debugging"
    echo "  3. Accept the debugging prompt on the tablet"
    echo ""
    echo "Then run this script again."
    exit 1
fi

echo -e "${COLOR_GREEN}✅ Device connected${COLOR_NC}"
adb devices -l

# Setup reverse tunnel
echo ""
echo "🔗 Setting up reverse tunnel on port $PORT..."

adb reverse tcp:$PORT tcp:$PORT

if [ $? -eq 0 ]; then
    echo -e "${COLOR_GREEN}✅ Tunnel established!${COLOR_NC}"
    echo ""
    echo -e "${COLOR_YELLOW}📱 Now you can:${COLOR_NC}"
    echo "  1. Start the Mac host app"
    echo "  2. Open the Virtual Display app on your tablet"
    echo "  3. Tap 'Connect' (it will connect to localhost:$PORT)"
    echo ""
    echo "The tunnel will forward localhost:$PORT on Android to your Mac"
else
    echo -e "${COLOR_RED}❌ Failed to setup tunnel${COLOR_NC}"
    exit 1
fi

# List active reverse tunnels
echo "Active reverse tunnels:"
adb reverse --list
