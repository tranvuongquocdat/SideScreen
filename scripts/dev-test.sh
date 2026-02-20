#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================="
echo "  Side Screen - Dev Test"
echo "======================================="
echo ""

# 1. Build macOS
echo "[1/4] Building macOS..."
cd "$ROOT_DIR/MacHost"
swift build -c release 2>&1 | tail -3
echo "  OK"

# 2. Build Android
echo "[2/4] Building Android..."
cd "$ROOT_DIR/AndroidClient"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew assembleDebug -q
APK="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo "  OK"

# 3. Install APK on device
echo "[3/4] Installing APK..."
if adb devices | grep -q "device$"; then
    adb install -r "$APK" 2>&1 | tail -1
else
    echo "  No device connected, skipping install"
fi

# 4. Run macOS app
echo "[4/4] Starting macOS app..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

APP_BIN="$ROOT_DIR/MacHost/.build/release/SideScreen"
adb reverse tcp:8888 tcp:8888 2>/dev/null || true
"$APP_BIN" &
APP_PID=$!

echo ""
echo "======================================="
echo "  Ready to test!"
echo "  Mac app running (PID: $APP_PID)"
echo "  Open Side Screen on your tablet"
echo "======================================="
echo ""
read -p "Test result? [y=OK / n=failed]: " RESULT

kill $APP_PID 2>/dev/null || true

if [ "$RESULT" = "y" ]; then
    echo ""
    echo "Test passed. Ready to push."
else
    echo ""
    echo "Test failed. Fix and re-run."
    exit 1
fi
