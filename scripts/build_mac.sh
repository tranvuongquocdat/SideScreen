#!/bin/bash

# Build macOS Host App

set -e

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

echo "🔨 Building macOS Host..."
echo ""

cd "$(dirname "$0")/../MacHost"

# Build with Swift Package Manager
swift build -c release

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${COLOR_GREEN}✅ Build successful!${COLOR_NC}"
    echo ""
    echo -e "${COLOR_YELLOW}To run:${COLOR_NC}"
    echo "  .build/release/VirtualDisplayHost"
    echo ""
    echo "Or use the run script:"
    echo "  ./scripts/run_mac.sh"
else
    echo "❌ Build failed"
    exit 1
fi
