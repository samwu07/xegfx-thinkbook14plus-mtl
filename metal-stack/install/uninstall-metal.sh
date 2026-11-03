#!/bin/bash
# uninstall-metal.sh [DATA_ROOT] -- undo install-metal.sh: put back the auxiliary kernel collection saved before the
# install, and move XeGfxAccel.kext, XgFbMove.kext, /Library/GPUBundles/nvmtl and /Library/XeGfx/metal aside (nothing is deleted:
# they land in /Library/XeGfx/removed-metal-<time>).
#   running macOS:  sudo bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh        then restart
#   Recovery:       bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh "/Volumes/MAC - Data"
#                   (on a Chinese-language system the volume is "/Volumes/MAC - 数据"; ls /Volumes shows it)
set -uo pipefail
D="${1:-/}"; LIVE=0; [ "$D" = / ] && LIVE=1; D="${D%/}"
die() { echo "uninstall-metal: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo in macOS; Recovery Terminal already is root)"
[ -f "$D/Library/XeGfx/metal/backup.txt" ] || die "$D/Library/XeGfx/metal/backup.txt not found (wrong volume, or install-metal.sh never finished)"
BK="$D$(cat "$D/Library/XeGfx/metal/backup.txt")"
KC="$D/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
SAVE="$D/Library/XeGfx/removed-metal-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$SAVE"
if [ -f "$BK/AuxiliaryKernelExtensions.kc" ]; then
  [ -f "$KC" ] && cp -p "$KC" "$SAVE/AuxiliaryKernelExtensions.kc.with-accel"
  cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC.restore" && mv -f "$KC.restore" "$KC" || die "restoring the collection failed"
  echo "restored $KC from $BK"
else
  [ -f "$KC" ] && mv -f "$KC" "$SAVE/AuxiliaryKernelExtensions.kc.with-accel"
  echo "there was no collection before the install; removed the one it made"
fi
for k in XeGfxAccel XgFbMove; do
  [ -e "$D/Library/Extensions/$k.kext" ] && mv -f "$D/Library/Extensions/$k.kext" "$SAVE/"
  [ ! -e "$D/Library/Extensions/$k.kext" ] || die "$k.kext still in /Library/Extensions"
done
[ -d "$D/Library/GPUBundles/nvmtl" ] && mv -f "$D/Library/GPUBundles/nvmtl" "$SAVE/"
cp -p "$D/Library/XeGfx/metal/backup.txt" "$SAVE/" 2>/dev/null
mv -f "$D/Library/XeGfx/metal" "$SAVE/metal"
[ $LIVE = 1 ] && { kcditto > "$SAVE/kcditto.log" 2>&1 || true; }
sync
echo "Metal phase 1 removed; everything moved to $SAVE. Restart."
