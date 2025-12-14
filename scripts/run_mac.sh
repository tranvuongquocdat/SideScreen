#!/bin/bash

# Run macOS Host App

set -e

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

cd "$(dirname "$0")/../MacHost"

# Build if needed
if [ ! -f ".build/release/VirtualDisplayHost" ]; then
    echo "🔨 Building first..."
    swift build -c release
fi

echo ""
echo -e "${COLOR_GREEN}🚀 Starting Virtual Display Host...${COLOR_NC}"
echo ""
echo -e "${COLOR_YELLOW}Server will listen on port 8888${COLOR_NC}"
echo "Press Ctrl+C to stop"
echo ""

# Run the app
.build/release/VirtualDisplayHost
