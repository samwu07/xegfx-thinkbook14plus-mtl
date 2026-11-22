#!/bin/bash
# 10-mesa-hostptr.sh -- rebuilds Mesa ANV with xemesa/hostptr-mesa.patch into out/GPUBundles/nvmtl (incremental; the tree
# stays as 2-userland.sh left it). Why (WindowServer crashes 2026-11-04 10:46 and 11-05 13:11): an imported host pointer
# whose pages were unmapped before its first use made every execbuf fail with EFAULT, because anv lists every memory
# object in every execbuf: device lost, then nil command buffers and a stack overflow in SkyLight. The patch wires pages
# at import and gives an object that still loses them a blank stand-in. XEGFX_ANV_NO_IMPORT_WIRE=1 skips the wiring (test).
#   ALLOW_XEGFX=1 bash /Volumes/PKG/metal-stack/10-mesa-hostptr.sh
#   bash /Volumes/PKG/metal-stack/desktop/hostptr-test.sh
#   sudo bash /Volumes/PKG/metal-stack/desktop/update-mesa.sh      then log out and in
. "$(dirname "$0")/common.sh"
no_xegfx
S="$HERE/xemesa/hostptr-mesa.patch"; O="$HERE/out"; MS="$X/mesa"
[ -f "$S" ] || { echo "missing $S"; exit 1; }
[ -f "$MS/build/build.ninja" ] || { echo "run 2-userland.sh first"; exit 1; }
prepare() {
  if grep -q host_ptr_stub "$MS/src/intel/vulkan/anv_private.h"; then echo "patch already in the tree"
  else (cd "$MS" && patch -p1 -N < "$S"); fi
  [ "$(grep -c anv_execbuf_use_host_ptr_stubs "$MS/src/intel/vulkan/i915/anv_batch_chain.c")" = 3 ]
}
build() {
  export MACOSX_DEPLOYMENT_TARGET=14.4 PATH=$X/host/bin:$PATH PKG_CONFIG_LIBDIR=$X/prefix/lib/pkgconfig:$X/sdk-pc
  unset PKG_CONFIG_PATH
  ninja -C "$MS/build" -j "$JOBS" src/intel/vulkan/libvulkan_intel.dylib
  strings "$MS/build/src/intel/vulkan/libvulkan_intel.dylib" | grep "a blank object takes its place" > /dev/null || { echo "the binary has no hostptr code"; return 1; }
}
collect() {
  [ -f "$O/orig/libvulkan_intel.dylib" ] || { mkdir -p "$O/orig"; cp -p "$O/GPUBundles/nvmtl/libvulkan_intel.dylib" "$O/orig/"; }
  cp "$MS/build/src/intel/vulkan/libvulkan_intel.dylib" "$X/prefix/lib/libvulkan_intel.dylib"
  cp "$MS/build/src/intel/vulkan/libvulkan_intel.dylib" "$O/GPUBundles/nvmtl/libvulkan_intel.dylib"
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.txt ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
}
step hostptr-prepare prepare
step hostptr-build build
step hostptr-collect collect
echo "Mesa with the host-pointer fix is in out/GPUBundles/nvmtl (the one before in out/orig)."
