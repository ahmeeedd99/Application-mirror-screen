#!/bin/bash
# Build the helper and install it as a login item that runs forever in the background.
# Usage: ./install.sh ["Part of your iPad's name"]
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.user.ipad-main-display"
DEST="$HOME/.local/share/ipad-main-display"
BIN="$DEST/ipad-main-display"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ipad-main-display.log"
NAME="${1:-}"

if [ "$(uname)" != "Darwin" ]; then echo "This must be run on the Mac."; exit 1; fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed to build. Run: xcode-select --install   (then re-run this)"; exit 1
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

echo "Building..."
clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreGraphics -framework IOKit \
  -o "$BIN" src/ipad-main-display.m

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NAME_ARGS=""
if [ -n "$NAME" ]; then
  NAME_ARGS="    <string>--name</string>
    <string>$(printf '%s' "$NAME" | xml_escape)</string>"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>run</string>
$NAME_ARGS
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST"

GUI="gui/$(id -u)"
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST"
launchctl enable "$GUI/$LABEL"
launchctl kickstart -k "$GUI/$LABEL"

echo
echo "Installed. It starts at every login and watches for your iPad on USB."
echo "Log: $LOG"
echo "Diagnostics: $BIN doctor"
