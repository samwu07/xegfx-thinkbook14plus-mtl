#!/bin/bash
# 7-xeflip.sh -- XeGfxAccel with the Intel zero-copy flip (metal-stack/xeflip, see xeflip_glue.inc): the v0.0.47
# accelerator source plus xeflip.patch, built with upstream's command line for macOS 15 (as 4-kexts.sh does), as
# version 0.9.1, into /Volumes/PKG/metal-stack/out/kexts/XeGfxAccel.kext. The stock build is kept in out/orig/ (once).
# The flip is off until `sysctl debug.nvaccel_xeflip=1` (desktop/xeflip.sh), so 0.9.1 otherwise behaves as 0.9.
# About a minute; in a boot where the stages have not run (4-kexts.sh's rule).
#   bash /Volumes/PKG/metal-stack/7-xeflip.sh
#   sudo bash /Volumes/PKG/metal-stack/install/update-kext.sh XeGfxAccel      then restart into CLEAN-07Y
. "$(dirname "$0")/common.sh"
no_xegfx
S="$HERE/xeflip"; P="$SRC/XeGfxAccel-xeflip"; O="$HERE/out"
[ -f "$S/xeflip.patch" ] && [ -f "$S/gpufb.patch" ] && [ -f "$S/wsmark.patch" ] && [ -f "$S/xeflip_core.h" ] && [ -f "$S/xeflip_glue.inc" ] || { echo "missing sources in $S"; exit 1; }
[ -f "$WTL/build/build_xegfxaccel.sh" ] || { echo "run 1-fetch.sh first"; exit 1; }
[ "$(git -C "$WTL" rev-parse HEAD)" = "$WTL_REV" ] || { echo "$WTL is not at v0.0.47 ($WTL_REV): xeflip.patch is made for that source"; exit 1; }
[ -d "$O/kexts" ] || { echo "run 5-collect.sh first"; exit 1; }
[ -d "$OGKM/src/nvidia/generated" ] || { echo "run 1-fetch.sh first (NVIDIA headers)"; exit 1; }
export OUTROOT=$OUTROOT/kexts OGKM SDKROOT
B="$OUTROOT/XeGfxAccel/xeflip"

prepare() {
  rm -rf "$P"; mkdir -p "$P"
  ditto --norsrc --noextattr "$WTL/kexts/XeGfxAccel" "$P/XeGfxAccel"
  (cd "$P" && patch -p1 -N < "$S/xeflip.patch")
  # 0.9.2: head 4 goes to the framebuffer the panel is attached to (GFX0's, with XeGfxIntelFB 0.9.1)
  (cd "$P" && patch -p1 -N < "$S/gpufb.patch")
  # 0.9.4: WindowServer's completion marks on the 'XGDR' connection (the plugin's ANV build has no NVK escape)
  (cd "$P" && patch -p1 -N < "$S/wsmark.patch")
  cp "$S/xeflip_core.h" "$S/xeflip_glue.inc" "$P/XeGfxAccel/accel/"
  local f="$P/XeGfxAccel/accel/nvrm-accel.cpp"
  echo "xeflip hooks in nvrm-accel.cpp: $(grep -c '<xeflip>' "$f") marked (want 5), XEFLIP_TRY $(grep -c 'XEFLIP_TRY' "$f") (want 3), gpufb $(grep -c 'nvXeHasPanel' "$f") (want 3), wsmark $(grep -c 'nvXeWsMark' "$f") (want 3)"
  [ "$(grep -c '<xeflip>' "$f")" = 5 ] && [ "$(grep -c 'XEFLIP_TRY' "$f")" = 3 ] && [ "$(grep -c 'nvXeHasPanel' "$f")" = 3 ] && [ "$(grep -c 'nvXeWsMark' "$f")" = 3 ]
}
build() {
  local s="$WTL/build/build_xegfxaccel_xeflip.sh" k="$B/XeGfxAccel.kext"
  sed -e 's/ -DNM_TAHOE//' -e "s#^SRC=\"\$REPO/kexts/XeGfxAccel\"#SRC=\"$P/XeGfxAccel\"#" \
      -e 's#out="$OUTROOT/$name/26"#out="$OUTROOT/$name/xeflip"#' -e "s/printf '26  '/printf 'xeflip  '/" \
      "$WTL/build/build_xegfxaccel.sh" > "$s"
  if grep -q -- '-DNM_TAHOE' "$s"; then echo "sed left -DNM_TAHOE in $s"; return 1; fi
  grep -q "SRC=\"$P/XeGfxAccel\"" "$s" || { echo "sed did not point SRC at the patched copy"; return 1; }
  grep -q 'name/xeflip"' "$s" || { echo "sed did not move the output to .../xeflip"; return 1; }
  bash "$s" || { cat "$B/accel.err" 2>/dev/null | grep -E 'error' | head -20; return 1; }
  [ -f "$k/Contents/MacOS/XeGfxAccel" ]
  grep -c -E 'warning' "$B/accel.err" 2>/dev/null | xargs echo "compiler warnings:" || true
  grep -E 'xeflip' "$B/accel.err" 2>/dev/null | head -10 || true
  plutil -replace CFBundleVersion -string 0.9.5 "$k/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string 0.9.5 "$k/Contents/Info.plist" || true
  echo "xeflip strings in the binary: $(strings "$k/Contents/MacOS/XeGfxAccel" | grep -c 'nvaccel_xeflip') (11 sysctls, at least)"
  # no grep -q after a pipe: pipefail and SIGPIPE turn an early match into a failure
  strings "$k/Contents/MacOS/XeGfxAccel" | grep 'xeflip: frame #' > /dev/null || { echo "the binary has no xeflip code"; return 1; }
  nm -m "$k/Contents/MacOS/XeGfxAccel" | grep -c 'undefined' | xargs echo "undefined symbols (resolved at kernel-collection link):"
  codesign -s - -f "$k"
}
collect() {
  if [ ! -d "$O/orig/XeGfxAccel.kext" ]; then mkdir -p "$O/orig"; ditto --norsrc --noextattr "$O/kexts/XeGfxAccel.kext" "$O/orig/XeGfxAccel.kext"; fi
  rm -rf "$O/kexts/XeGfxAccel.kext"
  ditto --norsrc --noextattr "$B/XeGfxAccel.kext" "$O/kexts/XeGfxAccel.kext"
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.txt ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
  wc -l < "$O/SHA256SUMS" | xargs echo "files in out:"
}
step xeflip-prepare prepare
step xeflip-build build
step xeflip-collect collect
cat "$LOGS/xeflip-prepare.log" "$LOGS/xeflip-build.log" | grep -E 'hooks|warnings|strings|undefined|xeflip' | head -12
echo
echo "XeGfxAccel 0.9.5 (xeflip with found slots + gpufb + wsmark + mark diagnostics) is in out/kexts (0.9 kept in out/orig). Next:"
echo "  sudo bash /Volumes/PKG/metal-stack/install/update-kext.sh XeGfxAccel      then restart into CLEAN-07Y"
