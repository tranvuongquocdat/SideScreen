#!/bin/bash
# Quick script to setup USB port forwarding

echo "🔧 Setting up USB port forwarding..."

# Remove any existing reverse rules for port 8888
adb reverse --remove tcp:8888 2>/dev/null || true

# Setup reverse for port 8888
adb reverse tcp:8888 tcp:8888

# Verify
echo ""
echo "📋 Active port forwarding:"
adb reverse --list

echo ""
if adb reverse --list | grep -q "tcp:8888"; then
    echo "✅ Port 8888 forwarding active - ready to connect!"
else
    echo "❌ Port forwarding failed - check USB connection"
    exit 1
fi
