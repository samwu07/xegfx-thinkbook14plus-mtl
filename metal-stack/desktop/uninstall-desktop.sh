#!/bin/bash
# uninstall-desktop.sh [DATA_ROOT] -- undo install-desktop.sh: the auxiliary kernel collection from before it comes back,
# and XeGfxAGDC.kext, the system-wide plugin and the allow-list move aside to /Library/XeGfx/removed-desktop-<time>.
# Phase 1 (accelerator, XgFbMove, private plugin) stays.
#   running macOS:  sudo bash /Volumes/PKG/metal-stack/desktop/uninstall-desktop.sh        then restart
#   Recovery:       bash /Volumes/PKG/metal-stack/desktop/uninstall-desktop.sh "/Volumes/MAC - Data"
#                   (on a Chinese-language system the volume is "/Volumes/MAC - 数据"; ls /Volumes shows it)
set -uo pipefail
D="${1:-/}"; LIVE=0; [ "$D" = / ] && LIVE=1; D="${D%/}"
die() { echo "uninstall-desktop: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo in macOS; Recovery Terminal already is root)"
if [ -f "$D/Library/XeGfx/desktop/backup.txt" ]; then
  BK="$D$(cat "$D/Library/XeGfx/desktop/backup.txt")"
else
  # install-desktop.sh before 2026-11-02 wrote backup.txt only at its very end, so a failed run left none: take the
  # OLDEST desktop backup, the collection from before the first phase-2 attempt
  BK=$(ls -d "$D"/Library/XeGfx/backup-desktop-* 2>/dev/null | sort | head -1)
  [ -n "$BK" ] || die "no backup.txt and no $D/Library/XeGfx/backup-desktop-* (wrong volume?)"
  echo "no backup.txt; using the oldest desktop backup: $BK"
fi
KC="$D/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
SAVE="$D/Library/XeGfx/removed-desktop-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$SAVE"
if [ -f "$BK/AuxiliaryKernelExtensions.kc" ]; then
  [ -f "$KC" ] && cp -p "$KC" "$SAVE/AuxiliaryKernelExtensions.kc.with-agdc"
  cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC.restore" && mv -f "$KC.restore" "$KC" || die "restoring the collection failed"
  echo "restored $KC from $BK"
fi
[ -e "$D/Library/Extensions/XeGfxAGDC.kext" ] && mv -f "$D/Library/Extensions/XeGfxAGDC.kext" "$SAVE/"
[ ! -e "$D/Library/Extensions/XeGfxAGDC.kext" ] || die "XeGfxAGDC.kext still in /Library/Extensions"
[ -d "$D/Library/GPUBundles/NVMTLDriver.bundle" ] && mv -f "$D/Library/GPUBundles/NVMTLDriver.bundle" "$SAVE/"
[ -f "$D/Library/GPUBundles/nvmtl-allow.txt" ] && mv -f "$D/Library/GPUBundles/nvmtl-allow.txt" "$SAVE/"
[ -d "$D/Library/GPUBundles/NVMTLDriver.bundle.new" ] && mv -f "$D/Library/GPUBundles/NVMTLDriver.bundle.new" "$SAVE/"
[ -d "$D/Library/XeGfx/desktop" ] && mv -f "$D/Library/XeGfx/desktop" "$SAVE/desktop"
[ $LIVE = 1 ] && { kcditto > "$SAVE/kcditto.log" 2>&1 || true; }
sync
echo "Phase 2 removed; everything moved to $SAVE. Phase 1 is still installed. Restart."
