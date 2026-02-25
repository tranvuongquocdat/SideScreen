#!/usr/bin/env bash
#
# build-deb.sh - Build a .deb package for SideScreen
#
# Usage: ./build-deb.sh [VERSION]
#   VERSION defaults to 0.5.2 if not provided.
#
# Expects the built binary at ../build/SideScreen (relative to this script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_HOST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-0.5.2}"
PACKAGE_NAME="sidescreen"
ARCH="amd64"
DEB_NAME="${PACKAGE_NAME}_${VERSION}_${ARCH}"

BINARY="$LINUX_HOST_DIR/build/SideScreen"
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

# --- Create staging directory ---
STAGING_DIR="$LINUX_HOST_DIR/build/$DEB_NAME"
rm -rf "$STAGING_DIR"

echo "==> Creating directory structure..."
mkdir -p "$STAGING_DIR/DEBIAN"
mkdir -p "$STAGING_DIR/usr/bin"
mkdir -p "$STAGING_DIR/usr/share/applications"
mkdir -p "$STAGING_DIR/usr/share/icons/hicolor/256x256/apps"

# --- Write control file ---
echo "==> Writing DEBIAN/control..."
cat > "$STAGING_DIR/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: libqt6widgets6 (>= 6.2) | qt6-base-dev (>= 6.2), libqt6network6 (>= 6.2)
Recommends: libpipewire-0.3-0, libva2, ffmpeg, libxdo3
Maintainer: SideScreen Team <sidescreen@example.com>
Description: Use your Android tablet as a second display
 SideScreen creates a virtual display on your Linux computer and
 streams it to an Android tablet, effectively turning it into a
 wireless second monitor. Supports X11 and Wayland via PipeWire,
 with optional hardware-accelerated encoding via VA-API.
Homepage: https://github.com/tranvuongquocdat/SideScreen
EOF

# --- Copy files ---
echo "==> Copying binary..."
cp "$BINARY" "$STAGING_DIR/usr/bin/sidescreen"
chmod 755 "$STAGING_DIR/usr/bin/sidescreen"

echo "==> Copying desktop entry..."
cp "$DESKTOP_FILE" "$STAGING_DIR/usr/share/applications/sidescreen.desktop"

# Copy icon if it exists
ICON_FILE="$LINUX_HOST_DIR/resources/sidescreen.png"
if [[ -f "$ICON_FILE" ]]; then
    echo "==> Copying icon..."
    cp "$ICON_FILE" "$STAGING_DIR/usr/share/icons/hicolor/256x256/apps/sidescreen.png"
else
    echo "    (No icon found at $ICON_FILE, skipping)"
fi

# --- Set permissions ---
echo "==> Setting permissions..."
find "$STAGING_DIR" -type d -exec chmod 755 {} \;
chmod 644 "$STAGING_DIR/DEBIAN/control"
chmod 644 "$STAGING_DIR/usr/share/applications/sidescreen.desktop"

# --- Build the .deb ---
OUTPUT="$LINUX_HOST_DIR/build/${DEB_NAME}.deb"
echo "==> Building .deb package..."
dpkg-deb --build "$STAGING_DIR" "$OUTPUT"

echo "==> Done! Package created: $OUTPUT"
echo "    Install with: sudo dpkg -i $OUTPUT"

# --- Cleanup staging ---
rm -rf "$STAGING_DIR"
