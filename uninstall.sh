#!/bin/bash
# Stop and remove the background helper.
set -u
LABEL="com.user.ipad-main-display"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.local/share/ipad-main-display"
echo "Removed. (Log left at ~/Library/Logs/ipad-main-display.log)"
