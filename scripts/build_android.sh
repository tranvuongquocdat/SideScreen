#!/bin/bash
set -e

echo "🔨 Building Android Client..."
cd "$(dirname "$0")/../AndroidClient"
./gradlew assembleDebug
echo "✅ Build successful!"
echo ""
echo "APK: AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "To install: adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
