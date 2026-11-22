#!/bin/bash
# gpu-app.sh /path/to/App.app [--undo] -- make an app open its windows on the Intel GPU desktop (XeGfx, CLEAN-07Y).
# Why: once the Intel GPU is up, macOS offers Metal, but the Metal plugin gives a device only to process names on
# /Library/GPUBundles/nvmtl-allow.txt. Metal/Flutter/SDL apps then get no device and open no window (2026-11-03: Kazumi
# "Unable to create FlutterView", LyricsBlossom, Lyricify). Sandboxed apps also cannot open /dev/dri, so even allowed,
# the Intel Vulkan driver finds "zero physical devices" in them (Kazumi before it was re-signed).
# What it does, in order:
#   1. the process name the list must match: CFBundleExecutable, else the bundle name (LyricsBlossom has no such key)
#   2. sandboxed? App Store? ad-hoc signed?
#   3. one launch with the Intel GPU (NVMTL_ENABLE=1, no file changed) and its log: does it get the GPU?
#   4. sandboxed + ad-hoc signed: asks, then re-signs a copy-backed app without com.apple.security.app-sandbox (the
#      other entitlements stay; backup in ~/GPUApp-backups/). App Store apps are refused (their receipt check).
#   5. adds "!<process name>" to the allow-list once (sudo), relaunches normally and checks it has the GPU.
# --undo removes the line again and, if this script re-signed the app, puts the original back.
# Needs the Intel desktop running (autostart / desktop-on.sh). Run as your normal user; it asks for sudo itself.
#   bash /Volumes/PKG/metal-stack/desktop/gpu-app.sh /Applications/Kazumi.app
#   bash /Volumes/PKG/metal-stack/desktop/gpu-app.sh /Applications/Kazumi.app --undo
set -uo pipefail
AL=/Library/GPUBundles/nvmtl-allow.txt
BK="$HOME/GPUApp-backups"
die() { echo "gpu-app: $*" >&2; exit 1; }
A="${1:-}"; MODE="${2:-}"
[ -n "$A" ] || die "usage: $0 /path/to/App.app [--undo]"
A="${A%/}"
[ -d "$A" ] && [ -f "$A/Contents/Info.plist" ] || die "$A is not an app bundle"
[ "$(id -u)" != 0 ] || die "run as your normal user (it calls sudo itself)"

# 1. the name getprogname() returns in the app: its executable's file name
EXE=$(plutil -extract CFBundleExecutable raw "$A/Contents/Info.plist" 2>/dev/null) || EXE=""
[ -n "$EXE" ] || EXE=$(basename "$A" .app)
[ -x "$A/Contents/MacOS/$EXE" ] || die "no executable $A/Contents/MacOS/$EXE"
BID=$(plutil -extract CFBundleIdentifier raw "$A/Contents/Info.plist" 2>/dev/null || echo "?")
case "$EXE" in *$'\n'*|*"'"*|'#'*|'-'*|'!'*) die "unusual process name '$EXE'" ;; esac
LINE="!$EXE"
SAFE=$(echo "$BID" | tr -c 'A-Za-z0-9._-' '_')

quit_app() { pkill -x "$EXE" 2>/dev/null; for i in 1 2 3 4 5; do pgrep -x "$EXE" > /dev/null || return 0; sleep 1; done; pkill -9 -x "$EXE" 2>/dev/null; sleep 1; }
# launch, wait, and classify what the Metal plugin said in this app: up / sandbox / refused / none
probe() {   # $1 = env flag for open (may be empty)
  quit_app
  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  if [ -n "$1" ]; then open -a "$A" --env "$1"; else open -a "$A"; fi
  sleep 10
  local L; L=$(log show --start "$t0" --style compact --predicate "process == \"$EXE\" AND sender == \"NVMTLDriver\"" 2>/dev/null)
  RUNNING=$(pgrep -x "$EXE" | head -1)
  if   echo "$L" | grep -F 'vk: UP in this Metal process' > /dev/null; then RESULT=up
  elif echo "$L" | grep -E 'zero physical devices|NVK did not come up' > /dev/null; then RESULT=nodevice
  elif echo "$L" | grep -F 'not allow-listed' > /dev/null; then RESULT=refused
  else RESULT=none; fi
}

if [ "$MODE" = --undo ]; then
  if grep -Fx "$LINE" "$AL" > /dev/null 2>&1; then
    echo "removing '$LINE' from $AL (sudo)"
    sudo /bin/bash -c "grep -Fxv -- '$LINE' '$AL' > '$AL.tmp' && chmod 644 '$AL.tmp' && mv -f '$AL.tmp' '$AL'" || die "could not edit $AL"
  else echo "'$LINE' is not on the allow-list"; fi
  if [ -d "$BK/$SAFE/$(basename "$A")" ]; then
    quit_app; rm -rf "$A"; ditto "$BK/$SAFE/$(basename "$A")" "$A" && codesign -v "$A" && echo "original app restored from $BK/$SAFE"
  fi
  exit 0
fi

sysctl -n debug.nvaccel_surface_gpu_on > /dev/null 2>&1 || die "the Intel GPU desktop is not running in this boot (CLEAN-07Y with autostart)"
SANDBOX=0; codesign -d --entitlements :- "$A" 2>/dev/null | grep -F 'com.apple.security.app-sandbox' > /dev/null && SANDBOX=1
APPSTORE=0; [ -d "$A/Contents/_MASReceipt" ] && APPSTORE=1
ADHOC=0; codesign -dv "$A" 2>&1 | grep -E 'flags=0x[0-9a-f]*\(.*adhoc' > /dev/null && ADHOC=1
echo "app:      $A ($BID)"
echo "process:  $EXE   -> allow-list line '$LINE'"
echo "signing:  sandboxed $SANDBOX, App Store $APPSTORE, ad-hoc $ADHOC"
grep -Fx "$LINE" "$AL" > /dev/null 2>&1 && echo "already on the allow-list"

# 3. one launch with the GPU, nothing changed yet
echo "test launch with the Intel GPU (10 s)..."
probe NVMTL_ENABLE=1
echo "  result: $RESULT${RUNNING:+, running as pid $RUNNING}"

if [ "$RESULT" = nodevice ] || { [ "$RESULT" != up ] && [ $SANDBOX = 1 ]; }; then
  [ $SANDBOX = 1 ] || die "it got no GPU device although it is not sandboxed: send me its log (log show --last 2m --predicate 'process == \"$EXE\"')"
  [ $APPSTORE = 0 ] || die "it is sandboxed and from the App Store: re-signing it would break its App Store receipt check. Not changed."
  [ $ADHOC = 1 ] || die "it is sandboxed and signed by a developer (not ad-hoc): re-signing it may break it (iCloud, keychain, updates). Not changed."
  echo
  echo "It is sandboxed: the sandbox hides /dev/dri, so it cannot see the Intel GPU even when allowed."
  echo "The fix is to re-sign it without the App Sandbox (its other entitlements stay; a backup is kept)."
  echo "Without the sandbox the app can read your files like any non-App Store app, and an update brings the sandbox back."
  read -r -p "Re-sign $(basename "$A") without the sandbox? [y/N] " ok
  [ "$ok" = y ] || [ "$ok" = Y ] || die "not changed"
  quit_app
  if [ ! -d "$BK/$SAFE/$(basename "$A")" ]; then
    mkdir -p "$BK/$SAFE" && ditto "$A" "$BK/$SAFE/$(basename "$A")" && codesign -v "$BK/$SAFE/$(basename "$A")" || die "backup failed; nothing changed"
    echo "backup: $BK/$SAFE/$(basename "$A")"
  fi
  E=$(mktemp -t gpuapp-ent).plist
  codesign -d --entitlements :- "$A" > "$E" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$E" 2>/dev/null
  if ! codesign --force --deep --sign - --entitlements "$E" "$A" || ! codesign -v --deep "$A"; then
    rm -f "$E"; rm -rf "$A"; ditto "$BK/$SAFE/$(basename "$A")" "$A"; die "re-signing failed; the original app is back"
  fi
  rm -f "$E"
  echo "re-signed without the sandbox"
elif [ "$RESULT" = none ]; then
  echo "  the Metal plugin logged nothing for it: it may not use Metal at all (then the allow-list does not matter)."
fi

# 5. allow-list, once
if ! grep -Fx "$LINE" "$AL" > /dev/null 2>&1; then
  echo "adding '$LINE' to $AL (sudo)"
  printf '%s\n' "$LINE" | sudo tee -a "$AL" > /dev/null || die "could not add the line"
fi

echo "normal launch (10 s)..."
probe ""
if [ "$RESULT" = up ]; then
  echo "DONE: $EXE gets the Intel GPU${RUNNING:+ (running, pid $RUNNING)} -- its window should be open."
else
  echo "NOT DONE: after the changes the result is '$RESULT'${RUNNING:+ (running, pid $RUNNING)}."
  echo "Its log: log show --last 2m --style compact --predicate 'process == \"$EXE\"'"
  exit 1
fi
