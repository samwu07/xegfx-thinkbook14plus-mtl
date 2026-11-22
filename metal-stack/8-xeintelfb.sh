#!/bin/bash
# 8-xeintelfb.sh -- XeGfxIntelFB 0.9.7: the v0.0.48 source plus metal-stack/xeintelfb/bootvram.patch, built with
# upstream's build_xegfxintelfb.sh, into /Volumes/PKG/metal-stack/out/kexts/XeGfxIntelFB.kext (0.9 kept in out/orig).
# Why: 0.9 renames GFX0's IONDRVFramebuffer, but that one never comes online on this Mac -- the GOP framebuffer
# (phys 0x7a800000, stolen memory) is in neither GFX0 BAR, so WindowServer's Intel FB fails to open and it keeps using
# UEFIGraphicsFB's .Display_boot (no GPU above it: no IOPresentment, 0 swaps). 0.9.4 adds the console range to GFX0's
# device memory before IONDRVFramebuffer starts, and gives that framebuffer IOFBDependentID/Index (XeGfxAGDC needs
# them), and the panel timing from its EDID as NVRMTiming (AGDC answers the link query with it). Boot-arg
# -xeintelfbnovram turns all three off. 0.9.4 also gives IOFramebuffer a VBL interrupt from pipe A's frame counter (the boot
# NDRV has none: IOFramebuffer ran its 30 Hz stand-in and WindowServer composited at 30 frames/s); -xeintelfbnovbl.
# 0.9.5: native brightness (0.9.7: the slider is brightness-probe; the linear keys CoreBrightness keeps at 65536 are ignored). The panel reports as built-in (AppleBacklightDisplay) and XeGfxBacklight, matched on SSDT-PNLF's
# APP0002, gives its IODisplay the brightness parameter and writes the backlight PWM (needs /Volumes/PKG/brightness/
# add-pnlf.sh in the EFI); -xeintelfbnobl.
# Seconds; in a boot where the stages have not run (4-kexts.sh's rule).
#   bash /Volumes/PKG/metal-stack/8-xeintelfb.sh
#   sudo bash /Volumes/PKG/metal-stack/desktop/install-xeintelfb.sh      then restart into CLEAN-07Y
. "$(dirname "$0")/common.sh"
no_xegfx
S="$HERE/xeintelfb"; P="$SRC/XeGfxIntelFB-bootvram"; O="$HERE/out"
[ -f "$S/bootvram.patch" ] || { echo "missing $S/bootvram.patch"; exit 1; }
[ -f "$WTL/build/build_xegfxintelfb.sh" ] || { echo "run 1-fetch.sh first"; exit 1; }
[ "$(git -C "$WTL" rev-parse HEAD)" = "$WTL_REV" ] || { echo "$WTL is not at $WTL_TAG ($WTL_REV): bootvram.patch is made for that source"; exit 1; }
[ -d "$O/kexts" ] || { echo "run 5-collect.sh first"; exit 1; }
B="$OUTROOT/kexts/XeGfxIntelFB-bootvram"

prepare() {
  rm -rf "$P"; mkdir -p "$P/kexts" "$P/build"
  ditto --norsrc --noextattr "$WTL/kexts/XeGfxIntelFB" "$P/kexts/XeGfxIntelFB"
  cp "$WTL/build/build_xegfxintelfb.sh" "$P/build/"
  (cd "$P" && patch -p1 -N < "$S/bootvram.patch")
  echo "bootvram hooks in intelfb.cpp: $(grep -c 'xifbAddConsoleRange' "$P/kexts/XeGfxIntelFB/intelfb.cpp") (want 2)"
  [ "$(grep -c 'xifbAddConsoleRange' "$P/kexts/XeGfxIntelFB/intelfb.cpp")" = 2 ]
}
build() {
  local k="$B/XeGfxIntelFB/XeGfxIntelFB.kext"
  OUTROOT="$B" bash "$P/build/build_xegfxintelfb.sh"
  [ -f "$k/Contents/MacOS/XeGfxIntelFB" ]
  plutil -replace CFBundleVersion -string 0.9.7 "$k/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string 0.9.7 "$k/Contents/Info.plist"
  # no grep -q after a pipe: pipefail and SIGPIPE turn an early match into a failure
  strings "$k/Contents/MacOS/XeGfxIntelFB" | grep 'boot vram: console' > /dev/null || { echo "the binary has no bootvram code"; return 1; }
  strings "$k/Contents/MacOS/XeGfxIntelFB" | grep 'backlight: handler on' > /dev/null || { echo "the binary has no backlight code"; return 1; }
  # the brightness handler's personality: on PNLF (APP0002), the "backlight" service IODisplay searches
  local KP=IOKitPersonalities.XeGfxBacklight
  plutil -insert "$KP" -dictionary "$k/Contents/Info.plist"
  plutil -insert "$KP.CFBundleIdentifier" -string org.watchthelight.XeGfxIntelFB "$k/Contents/Info.plist"
  plutil -insert "$KP.IOClass" -string XeGfxBacklight "$k/Contents/Info.plist"
  plutil -insert "$KP.IOProviderClass" -string IOACPIPlatformDevice "$k/Contents/Info.plist"
  plutil -insert "$KP.IONameMatch" -string APP0002 "$k/Contents/Info.plist"
  plutil -insert "$KP.IOProbeScore" -integer 1000 "$k/Contents/Info.plist"
  codesign -s - -f "$k"
}
collect() {
  if [ ! -d "$O/orig/XeGfxIntelFB.kext" ]; then mkdir -p "$O/orig"; ditto --norsrc --noextattr "$O/kexts/XeGfxIntelFB.kext" "$O/orig/XeGfxIntelFB.kext"; fi
  rm -rf "$O/kexts/XeGfxIntelFB.kext"
  ditto --norsrc --noextattr "$B/XeGfxIntelFB/XeGfxIntelFB.kext" "$O/kexts/XeGfxIntelFB.kext"
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.txt ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
  wc -l < "$O/SHA256SUMS" | xargs echo "files in out:"
}
step xeintelfb-prepare prepare
step xeintelfb-build build
step xeintelfb-collect collect
cat "$LOGS/xeintelfb-prepare.log" "$LOGS/xeintelfb-build.log" | grep -E 'hooks|XeGfxIntelFB ' | head -6
echo
echo "XeGfxIntelFB 0.9.7 (bootvram + backlight) is in out/kexts (0.9 kept in out/orig). Next:"
echo "  sudo bash /Volumes/PKG/metal-stack/desktop/install-xeintelfb.sh      then restart into CLEAN-07Y"
