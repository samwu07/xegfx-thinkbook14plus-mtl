#!/bin/bash
# 4-kexts.sh -- the kernel side of the desktop path, with upstream's build scripts:
#   XeGfxAccel.kext  the Metal accelerator (IOAccelerator) over XeGfx. Upstream builds only the macOS 26 variant
#                    (-DNM_TAHOE, Tahoe vtable forwarders); the source keeps everything Tahoe-only behind #ifdef NM_TAHOE,
#                    so the same command line without it is the macOS 15 variant -> kexts/XeGfxAccel/15/
#   XeGfxAGDC.kext   AppleGraphicsDeviceControl, which IOPresentment needs before WindowServer gets a display pipe
#   NMIntelFB.kext   the built-in panel's framebuffer (what upstream's tools/install.sh installs)
#   XeGfxIntelFB.kext the alternative framebuffer kext (Intel class name); built for comparison
# Nothing is installed here.
#   bash /Volumes/PKG/metal-stack/4-kexts.sh
. "$(dirname "$0")/common.sh"
no_xegfx
[ -f "$WTL/build/kext_flags.sh" ] || { echo "run 1-fetch.sh first"; exit 1; }
[ -d "$OGKM/src/nvidia/generated" ] || { echo "run 1-fetch.sh first (NVIDIA headers)"; exit 1; }
export OUTROOT=$OUTROOT/kexts OGKM SDKROOT

accel15() {
  local s="$WTL/build/build_xegfxaccel_15.sh"
  sed -e 's/ -DNM_TAHOE//' -e 's#out="$OUTROOT/$name/26"#out="$OUTROOT/$name/15"#' -e "s/printf '26  '/printf '15  '/" \
    "$WTL/build/build_xegfxaccel.sh" > "$s"
  if grep -q -- '-DNM_TAHOE' "$s"; then echo "sed left -DNM_TAHOE in $s"; return 1; fi
  grep -q 'name/15"' "$s" || { echo "sed did not move the output to .../15"; return 1; }
  diff "$WTL/build/build_xegfxaccel.sh" "$s" || true
  bash "$s"
  local k="$OUTROOT/XeGfxAccel/15/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel"
  [ -f "$k" ]
  nm -m "$k" | grep -c 'undefined' | xargs echo "undefined symbols (resolved at kernel-collection link):"
}
report() {
  local k
  for k in XeGfxAccel/15/XeGfxAccel XeGfxAGDC/XeGfxAGDC NMIntelFB/NMIntelFB XeGfxIntelFB/XeGfxIntelFB; do
    local b="$OUTROOT/$k.kext/Contents/MacOS/$(basename "$k")"
    printf '%-40s ' "$k.kext"; [ -f "$b" ] && echo "$(stat -f %z "$b") B $(shasum -a 256 "$b" | cut -c1-16)" || echo MISSING
  done
}
step build-accel-15 accel15
step build-agdc bash "$WTL/build/build_xegfxagdc.sh"
step build-nmintelfb bash "$WTL/build/build_nmintelfb.sh"
step build-xegfxintelfb bash "$WTL/build/build_xegfxintelfb.sh"
step kext-report report
cat "$LOGS/kext-report.log"
echo
echo "Kexts done. Next:  bash /Volumes/PKG/metal-stack/5-collect.sh"
