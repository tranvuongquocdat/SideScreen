#!/bin/bash
set -e

echo "📦 Creating VirtualDisplay.app..."

APP_NAME="VirtualDisplay"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Clean old app
rm -rf "$APP_DIR"

# Create app structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Build release binary
echo "🔨 Building release binary..."
cd MacHost
swift build -c release
cd ..

# Copy binary
echo "📋 Copying binary..."
cp MacHost/.build/release/VirtualDisplayHost "$MACOS_DIR/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.virtualdisplay.host</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Sign the app with ad-hoc signature and entitlements
echo "🔏 Signing app..."
if [ -f "MacHost/VirtualDisplay.entitlements" ]; then
    codesign --force --deep --sign - --entitlements MacHost/VirtualDisplay.entitlements "$APP_DIR"
    echo "✅ App signed with entitlements"
else
    codesign --force --deep --sign - "$APP_DIR"
    echo "✅ App signed (ad-hoc)"
fi

echo "✅ Created $APP_DIR"
echo ""
echo "To run: open $APP_DIR"
echo "Or: ./$APP_DIR/Contents/MacOS/$APP_NAME"
