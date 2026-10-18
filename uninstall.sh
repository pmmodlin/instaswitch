#!/bin/bash
# Stops instaswitch, removes it and gives Caps Lock back.
set -uo pipefail

LABEL="com.pmmodlin.instaswitch"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Instaswitch.app"
hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1
tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1

echo "✓ instaswitch removed, Caps Lock restored"
