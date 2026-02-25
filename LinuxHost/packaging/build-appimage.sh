#!/usr/bin/env bash
#
# build-appimage.sh - Build an AppImage for SideScreen
#
# Usage: ./build-appimage.sh
#
# Expects the built binary at ../build/SideScreen (relative to this script).
# Downloads linuxdeploy and the Qt plugin automatically if not present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_HOST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$LINUX_HOST_DIR/build"

BINARY="$BUILD_DIR/SideScreen"
DESKTOP_FILE="$SCRIPT_DIR/sidescreen.desktop"

# --- Validate inputs ---
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "       Build the project first: cmake --build build"
    exit 1
fi

if [[ ! -f "$DESKTOP_FILE" ]]; then
    echo "ERROR: Desktop file not found at $DESKTOP_FILE"
    exit 1
fi

# --- Download linuxdeploy if needed ---
LINUXDEPLOY="$BUILD_DIR/linuxdeploy-x86_64.AppImage"
LINUXDEPLOY_QT="$BUILD_DIR/linuxdeploy-plugin-qt-x86_64.AppImage"

if [[ ! -f "$LINUXDEPLOY" ]]; then
    echo "==> Downloading linuxdeploy..."
    curl -fSL -o "$LINUXDEPLOY" \
        "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
    chmod +x "$LINUXDEPLOY"
fi

if [[ ! -f "$LINUXDEPLOY_QT" ]]; then
    echo "==> Downloading linuxdeploy-plugin-qt..."
    curl -fSL -o "$LINUXDEPLOY_QT" \
        "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
    chmod +x "$LINUXDEPLOY_QT"
fi

# --- Create AppDir structure ---
APPDIR="$BUILD_DIR/AppDir"
rm -rf "$APPDIR"

echo "==> Creating AppDir structure..."
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"

echo "==> Copying binary..."
cp "$BINARY" "$APPDIR/usr/bin/sidescreen"
chmod 755 "$APPDIR/usr/bin/sidescreen"

echo "==> Copying desktop entry..."
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/sidescreen.desktop"

# Copy icon if available; create a placeholder if not
ICON_FILE="$LINUX_HOST_DIR/resources/sidescreen.png"
if [[ -f "$ICON_FILE" ]]; then
    echo "==> Copying icon..."
    cp "$ICON_FILE" "$APPDIR/usr/share/icons/hicolor/256x256/apps/sidescreen.png"
else
    echo "    (No icon found at $ICON_FILE)"
    echo "    Creating a minimal placeholder icon..."
    # Create a 1x1 pixel PNG as placeholder so linuxdeploy doesn't fail
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "$APPDIR/usr/share/icons/hicolor/256x256/apps/sidescreen.png"
fi

# --- Build AppImage ---
echo "==> Building AppImage with linuxdeploy..."
export QMAKE="$(which qmake6 2>/dev/null || which qmake 2>/dev/null || echo "")"
export EXTRA_QT_PLUGINS="svg;"
export OUTPUT="$BUILD_DIR/SideScreen-x86_64.AppImage"

# linuxdeploy needs APPIMAGE_EXTRACT_AND_RUN on systems without FUSE
export APPIMAGE_EXTRACT_AND_RUN=1

"$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --desktop-file "$APPDIR/usr/share/applications/sidescreen.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/sidescreen.png" \
    --plugin qt \
    --output appimage

echo "==> Done! AppImage created: $OUTPUT"
echo "    Run with: chmod +x $OUTPUT && ./$OUTPUT"

# --- Cleanup ---
rm -rf "$APPDIR"
