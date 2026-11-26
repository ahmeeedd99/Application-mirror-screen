#!/bin/bash
# Stop and completely remove the background helper.
set -u
LABEL="com.user.ipad-main-display"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.local/share/ipad-main-display"
rm -f "$HOME/Library/Logs/ipad-main-display.log"
echo "Removed the helper, its launch file and its log."
