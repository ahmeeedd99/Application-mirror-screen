#!/bin/bash
# Build the helper from source and install it as a per-user background agent.
# Usage: ./install.sh ["exact iPad name"]
#   With no name, the iPad is detected and pinned automatically if exactly one is nearby.
# Needs no sudo and downloads nothing.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

LABEL="com.user.ipad-main-display"
DEST="$HOME/.local/share/ipad-main-display"
BIN="$DEST/ipad-main-display"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ipad-main-display.log"
NAME="${1:-}"

[ "$(uname)" = "Darwin" ] || { echo "Run this on the Mac, not elsewhere."; exit 1; }
[ "$(id -u)" -ne 0 ]      || { echo "Do not use sudo. Run as your normal user."; exit 1; }
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed to build. Run:  xcode-select --install"
  echo "When that finishes, run ./install.sh again."; exit 1
fi
case "$NAME" in *[[:cntrl:]]*) echo "Name contains control characters."; exit 1;; esac

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod 700 "$DEST"

echo "Building from source..."
clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreGraphics -framework IOKit \
  -o "$BIN" src/ipad-main-display.m
chmod 700 "$BIN"

# Pin to one iPad so we can never connect to a different Sidecar device by mistake.
if [ -z "$NAME" ]; then
  DEVICES="$("$BIN" list 2>/dev/null || true)"
  COUNT="$(printf '%s' "$DEVICES" | grep -c . || true)"
  if [ "$COUNT" = "1" ]; then
    NAME="$DEVICES"; echo "Pinned to the only Sidecar device found: \"$NAME\""
  elif [ "$COUNT" -gt 1 ]; then
    echo "Several Sidecar devices are nearby:"; printf '  %s\n' "$DEVICES"
    echo "Re-run with the one you want:  ./install.sh \"<name>\""; exit 1
  else
    echo "No iPad was visible to Sidecar right now. Installing unpinned: it will connect"
    echo "only if exactly one device is available. (Re-run with a name any time to pin.)"
  fi
fi

# Every value written into the XML is escaped.
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NAME_ARGS=""
if [ -n "$NAME" ]; then
  NAME_ARGS="    <string>--name</string>
    <string>$(esc "$NAME")</string>"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(esc "$BIN")</string>
    <string>run</string>
$NAME_ARGS
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$(esc "$LOG")</string>
  <key>StandardErrorPath</key><string>$(esc "$LOG")</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
chmod 600 "$PLIST"

GUI="gui/$(id -u)"
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST"
launchctl enable "$GUI/$LABEL"
launchctl kickstart -k "$GUI/$LABEL"

echo
echo "Installed and running. It starts at every login and watches for your iPad on USB."
echo "  Watch it:    tail -f \"$LOG\""
echo "  Diagnostics: \"$BIN\" doctor"
echo "  Remove:      ./uninstall.sh"
