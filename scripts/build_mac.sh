#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "🛑 Stopping running VirtualDisplayHost..."
pkill -f VirtualDisplayHost 2>/dev/null || true
sleep 0.5

# Clean old build
echo "🧹 Cleaning old build..."
rm -rf .build

# Build fresh
echo "🔨 Building macOS Host..."
swift build -c release

# Create .app bundle
APP_NAME="VirtualDisplayHost"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "📦 Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp .build/release/VirtualDisplayHost "$APP_DIR/Contents/MacOS/"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VirtualDisplayHost</string>
    <key>CFBundleIdentifier</key>
    <string>com.virtualdisplay.host</string>
    <key>CFBundleName</key>
    <string>Virtual Display Host</string>
    <key>CFBundleDisplayName</key>
    <string>Virtual Display Host</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo ""
echo "✅ Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"
