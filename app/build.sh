#!/bin/bash
# Build and install Claude Monitor menu bar app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/.claude/ClaudeMonitor.app"

echo "Building Claude Monitor..."
swiftc -o "$SCRIPT_DIR/ClaudeMonitor" "$SCRIPT_DIR/Sources/main.swift" \
    -framework AppKit \
    -framework UserNotifications \
    -O \
    -target arm64-apple-macosx14.0 \
    2>&1

echo "Packaging .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$SCRIPT_DIR/ClaudeMonitor" "$APP_DIR/Contents/MacOS/"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"

# Clean up loose binary
rm -f "$SCRIPT_DIR/ClaudeMonitor"

echo "Installed to $APP_DIR"
echo ""
echo "To launch:  open $APP_DIR"
echo ""

# Launch it
open "$APP_DIR"
echo "Claude Monitor is running in your menu bar"
