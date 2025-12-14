#!/bin/bash

# Virtual Display - Cleanup Tunnel Script
# Removes all ADB reverse tunnels

set -e

COLOR_GREEN='\033[0;32m'
COLOR_NC='\033[0m'

echo "🧹 Cleaning up ADB reverse tunnels..."

adb reverse --remove-all

echo -e "${COLOR_GREEN}✅ All tunnels removed${COLOR_NC}"
