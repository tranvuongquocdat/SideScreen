#!/bin/bash
set -e

echo "=== SideScreen Linux Host Build ==="
echo

# Check dependencies
check_cmd() {
    if ! command -v "$1" &> /dev/null; then
        echo "WARNING: $1 not found. $2"
    else
        echo "  Found: $1 ($(command -v $1))"
    fi
}

echo "Checking dependencies..."
check_cmd cmake "Please install cmake 3.20+"
check_cmd g++ "Please install g++ (sudo apt install build-essential)"
check_cmd pkg-config "Please install pkg-config"

echo
echo "Optional dependencies (install for full functionality):"
echo "  sudo apt install qt6-base-dev libpipewire-0.3-dev libva-dev"
echo "  sudo apt install ffmpeg libavcodec-dev libavutil-dev libswscale-dev"
echo "  sudo apt install libx11-dev libxext-dev libxrandr-dev libxcomposite-dev libxfixes-dev"
echo "  sudo apt install libxdo-dev xdotool adb"
echo

# Configure
echo "Configuring with CMake..."
cmake -B build -DCMAKE_BUILD_TYPE=Release "$@"

# Build
echo
echo "Building..."
cmake --build build -j$(nproc)

echo
echo "=== Build successful! ==="
echo "Output: build/SideScreen"
echo
echo "To install: sudo cmake --install build"
