#!/bin/bash
# Builds instaswitch, installs it to ~/Applications and starts it as a LaunchAgent.
set -euo pipefail

LABEL="com.pmmodlin.instaswitch"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$HOME/Applications/Instaswitch.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/instaswitch.log"

echo "→ build"
rm -rf "$BUILD/Instaswitch.app"
mkdir -p "$BUILD/Instaswitch.app/Contents/MacOS"
swiftc -O -swift-version 5 -o "$BUILD/Instaswitch.app/Contents/MacOS/instaswitch" "$ROOT/Sources/main.swift"
cp "$ROOT/Resources/Info.plist" "$BUILD/Instaswitch.app/Contents/Info.plist"
codesign --force --sign - --identifier "$LABEL" "$BUILD/Instaswitch.app"

echo "→ install to $APP"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD/Instaswitch.app" "$APP"

echo "→ LaunchAgent $PLIST"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
sed -e "s|__BINARY__|$APP/Contents/MacOS/instaswitch|" -e "s|__LOG__|$LOG|" \
    "$ROOT/Resources/launchagent.plist" > "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ done. Log: $LOG"
echo "  On first run grant Instaswitch access in System Settings → Privacy & Security → Accessibility."
