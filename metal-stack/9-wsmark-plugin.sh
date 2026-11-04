#!/bin/bash
# 9-wsmark-plugin.sh -- the Metal plugin (NVMTLDriver) with WindowServer's completion marks on the accelerator's 'XGDR'
# connection (metal-stack/xeflip/wsmark-plugin.patch), built from a copy of the plugin source as it is in ~/src/WTLIntelGfx
# (local changes included), into /Volumes/PKG/metal-stack/out/GPUBundles/NVMTLDriver.bundle. The binary before is kept
# as out/orig/NVMTLDriver (once). Pairs with XeGfxAccel 0.9.4 (7-xeflip.sh); with an older accelerator the marks are
# refused and WindowServer waits for its composites as before.
# Why (2026-11-03 14:22): WindowServer spent 41 % of its main thread in -[NVMTLCommandBuffer waitUntilCompleted] and the
# desktop ran at ~30 frames/s: the plugin skips that wait only when the kernel takes the marks, and they went through
# nvmtl_nvk_surface_dirty, which only NVIDIA's NVK exports.
# Seconds; in a boot where the stages have not run (4-kexts.sh's rule).
#   bash /Volumes/PKG/metal-stack/9-wsmark-plugin.sh
#   sudo bash /Volumes/PKG/metal-stack/desktop/update-plugin.sh      then restart (WindowServer loads it at start)
. "$(dirname "$0")/common.sh"
no_xegfx
S="$HERE/xeflip/wsmark-plugin.patch"; P="$SRC/NVMTL-wsmark"; O="$HERE/out"; B="$OUTROOT/wsmark"
[ -f "$S" ] || { echo "missing $S"; exit 1; }
[ -f "$WTL/build/build_plugin.sh" ] || { echo "run 1-fetch.sh first"; exit 1; }
[ -f "$O/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" ] || { echo "run 3-plugin.sh and 5-collect.sh first"; exit 1; }

prepare() {
  rm -rf "$P"; mkdir -p "$P/build"
  ditto --norsrc --noextattr "$WTL/plugin" "$P/plugin"
  cp "$WTL/build/build_plugin.sh" "$P/build/"
  (cd "$P" && patch -p1 -N < "$S")
  echo "wsmark hooks in nvmtl_vk.c: $(grep -c 'nvmtl_xgdr_gpu_mark' "$P/plugin/nvmtl_vk.c") (want 2)"
  [ "$(grep -c 'nvmtl_xgdr_gpu_mark' "$P/plugin/nvmtl_vk.c")" = 2 ]
}
build() {
  XEGFX_DEPS="$DEPS" XEGFX_OUT="$B" bash "$P/build/build_plugin.sh"
  [ -f "$B/plugin/NVMTLDriver" ]
  # no grep -q after a pipe: pipefail and SIGPIPE turn an early match into a failure
  strings "$B/plugin/NVMTLDriver" | grep "WindowServer marks: on the accelerator" > /dev/null || { echo "the binary has no wsmark code"; return 1; }
}
collect() {
  local M="$O/GPUBundles/NVMTLDriver.bundle/Contents/MacOS"
  if [ ! -f "$O/orig/NVMTLDriver" ]; then mkdir -p "$O/orig"; cp -p "$M/NVMTLDriver" "$O/orig/NVMTLDriver"; fi
  cp "$B/plugin/NVMTLDriver" "$M/NVMTLDriver"
  codesign -s - -f "$O/GPUBundles/NVMTLDriver.bundle" > /dev/null 2>&1 || true
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.txt ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
  wc -l < "$O/SHA256SUMS" | xargs echo "files in out:"
}
step wsmark-prepare prepare
step wsmark-build build
step wsmark-collect collect
cat "$LOGS/wsmark-prepare.log" "$LOGS/wsmark-build.log" | grep -E 'hooks|NVMTLDriver ' | head -4
echo
echo "NVMTLDriver with WindowServer marks is in out/GPUBundles (the one before in out/orig). Next:"
echo "  sudo bash /Volumes/PKG/metal-stack/desktop/update-plugin.sh      (and XeGfxAccel 0.9.4: 7-xeflip.sh, update-kext.sh)"
