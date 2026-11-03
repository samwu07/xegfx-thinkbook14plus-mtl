#!/bin/bash
# 5-collect.sh -- copies every build output to /Volumes/PKG/metal-stack/out with sha256 sums and a manifest
# (linked libraries, minimum macOS, kext dependencies), so the install package can be checked before anything is
# installed. Read-only for the system.
#   bash /Volumes/PKG/metal-stack/5-collect.sh
. "$(dirname "$0")/common.sh"
O="$HERE/out"

collect() {
  rm -rf "$O"; mkdir -p "$O/kexts" "$O/GPUBundles/nvmtl"
  local k
  for k in XeGfxAccel/15/XeGfxAccel XeGfxAGDC/XeGfxAGDC NMIntelFB/NMIntelFB XeGfxIntelFB/XeGfxIntelFB; do
    ditto --norsrc --noextattr "$OUTROOT/kexts/$k.kext" "$O/kexts/$(basename "$k").kext"
  done
  ditto --norsrc --noextattr "$OUTROOT/plugin/NVMTLDriver.bundle" "$O/GPUBundles/NVMTLDriver.bundle"
  cp "$OUTROOT/xlate/libnvmtl_translate.dylib" "$X/prefix/lib/libvulkan_intel.dylib" "$X/prefix/lib/libdrm.2.dylib" \
     "$O/GPUBundles/nvmtl/"
  (cd "$O" && find . -type f ! -name SHA256SUMS ! -name '._*' | sort | xargs shasum -a 256 > SHA256SUMS)
  wc -l < "$O/SHA256SUMS" | xargs echo "files:"
}
manifest() {
  local f
  echo "## built $(date '+%Y-%m-%d %H:%M') on $(sw_vers -productVersion) ($(sw_vers -buildVersion)), SDK $SDKROOT"
  for r in "$WTL" "$X/drm" "$X/mesa"; do echo "## $(basename "$r") $(git -C "$r" log -1 --format='%h %s')"; done
  for f in "$O"/GPUBundles/nvmtl/*.dylib "$O"/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver; do
    echo "## $(basename "$f")"
    otool -L "$f" | tail -n +2
    otool -l "$f" | { grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' || true; } | { grep -E 'minos|sdk| version' || true; } | tr -s ' '
  done
  for f in "$O"/kexts/*.kext; do
    echo "## $(basename "$f")"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleVersion' -c 'Print :OSBundleLibraries' "$f/Contents/Info.plist"
  done
}
step collect collect
step manifest manifest
cp "$LOGS/manifest.log" "$O/MANIFEST.txt"
echo
echo "Collected into $O ($(du -sh "$O" | cut -f1)). Tell me it's done: I check it from Windows and prepare the install step."
