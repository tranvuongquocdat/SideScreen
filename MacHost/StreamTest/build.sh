#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Building StreamTest ==="
swift build -c release 2>&1

BINARY=$(swift build -c release --show-bin-path)/StreamTest

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo "Binary: $BINARY"
echo ""
echo "Usage:"
echo "  $BINARY                  # Encode test pattern → /tmp/streamtest.h265"
echo "  $BINARY --stream         # Stream to tablet on port 5555"
echo "  $BINARY --stream 6000    # Stream on custom port"
echo ""
echo "Verify H.265 output:"
echo "  ffplay /tmp/streamtest.h265"
echo "  ffprobe -show_frames /tmp/streamtest.h265"
