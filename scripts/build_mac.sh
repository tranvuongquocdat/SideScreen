#!/bin/bash
set -e

echo "🔨 Building macOS Host..."
cd "$(dirname "$0")/../MacHost"
swift build -c release
echo "✅ Build successful!"
echo ""
echo "To run: MacHost/.build/release/VirtualDisplayHost"
