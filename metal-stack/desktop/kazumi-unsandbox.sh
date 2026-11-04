#!/bin/bash
# kazumi-unsandbox.sh [undo] -- re-sign /Applications/Kazumi.app (ad-hoc, com.example.kazumi 2.4.2) without its App
# Sandbox entitlement, so it can reach the Intel GPU on the XeGfx desktop. Why (2026-11-03): Kazumi is a Flutter app,
# which needs a Metal device to draw; the sandbox denies "file-read-data /dev/dri", so the Intel Vulkan driver finds
# "zero physical devices" in it, the plugin refuses, and Flutter logs "Unable to create FlutterView" -- no window.
# Every other entitlement (network client/server, downloads, user-selected files) is kept. Its sandbox container held
# only macOS defaults (8 KB), so there is no data to move. Run as your normal user (the app is yours); then add it to
# the allow-list:  echo '!Kazumi' | sudo tee -a /Library/GPUBundles/nvmtl-allow.txt
#   bash /Volumes/PKG/metal-stack/desktop/kazumi-unsandbox.sh          backup to ~/Kazumi-backup-20261103, then re-sign
#   bash /Volumes/PKG/metal-stack/desktop/kazumi-unsandbox.sh undo     put the original (sandboxed) app back
set -euo pipefail
A=/Applications/Kazumi.app; B="$HOME/Kazumi-backup-20261103"
if [ "${1:-}" = undo ]; then
  [ -d "$B/Kazumi.app" ] || { echo "no backup at $B/Kazumi.app"; exit 1; }
  pkill -x Kazumi 2>/dev/null || true
  rm -rf "$A"; ditto "$B/Kazumi.app" "$A"; codesign -v "$A" && echo "original Kazumi restored (sandboxed again)"
  exit 0
fi
[ -d "$A" ] || { echo "no $A"; exit 1; }
pkill -x Kazumi 2>/dev/null || true; sleep 1
if [ ! -d "$B/Kazumi.app" ]; then mkdir -p "$B"; ditto "$A" "$B/Kazumi.app"; codesign -v "$B/Kazumi.app"; echo "backup: $B/Kazumi.app"; fi
E=$(mktemp -t kazumi-ent).plist
codesign -d --entitlements :- "$A" > "$E" 2>/dev/null
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$E" 2>/dev/null || echo "(no app-sandbox entitlement to remove)"
echo "entitlements kept:"; plutil -p "$E"
codesign --force --deep --sign - --entitlements "$E" "$A"
codesign -v --deep "$A"
n=$(codesign -d --entitlements :- "$A" 2>/dev/null | grep -c app-sandbox || true)
rm -f "$E"
echo "re-signed without the sandbox (app-sandbox entries: $n). Next: echo '!Kazumi' | sudo tee -a /Library/GPUBundles/nvmtl-allow.txt"
