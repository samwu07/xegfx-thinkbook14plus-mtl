#!/bin/bash
# install.sh [uninstall] -- builds brightkeys and runs it at login as a LaunchAgent of this user (no sudo):
# Control-Option-Up/Down change the native brightness (XeGfxIntelFB 0.9.7+) through DisplayServices, the system slider's
# API, in steps of 1/16. No permission needed.
#   bash /Volumes/PKG/metal-stack/desktop/brightkeys/install.sh
#   bash /Volumes/PKG/metal-stack/desktop/brightkeys/install.sh uninstall
#   log show --last 10m --predicate 'subsystem == "local.brightkeys"'       what it did
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; BIN="$HOME/Library/Application Support/brightkeys/brightkeys"
PL="$HOME/Library/LaunchAgents/local.brightkeys.plist"; LBL=local.brightkeys
launchctl bootout "gui/$(id -u)/$LBL" 2>/dev/null || true
if [ "${1:-}" = uninstall ]; then rm -f "$PL" "$BIN"; echo "brightkeys removed"; exit 0; fi
mkdir -p "$(dirname "$BIN")" "$(dirname "$PL")"
clang -fobjc-arc -O2 -framework Cocoa -framework Carbon -F/System/Library/PrivateFrameworks -framework DisplayServices -o "$BIN" "$HERE/brightkeys.m"
codesign -s - -f "$BIN" > /dev/null 2>&1 || true
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LBL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PL"
sleep 1
launchctl print "gui/$(id -u)/$LBL" 2>/dev/null | grep -E '^\s*state' || true
echo "brightkeys installed: Control-Option-Up/Down change the brightness (log: subsystem local.brightkeys)"
