#!/bin/bash
# uninstall-xegfx.sh -- remove XeGfx.kext and rebuild the auxiliary kernel collection without it (upstream
# tools/install.sh XEGFX_MODE=uninstall), keeping every other third-party kext.
#   sudo bash /Volumes/PKG/xegfx/uninstall-xegfx.sh      then restart
set -euo pipefail
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
die() { echo "xegfx-uninstall: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
BK=/Library/XeGfx/backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"; [ -f "$KC" ] && cp -p "$KC" "$BK/"
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ && $1 != "org.watchthelight.XeGfx" {print $1}' || true)
rm -rf "$EXT/XeGfx.kext"
NEW="$KC.xegfx-new"; rm -f "$NEW"
kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$BK/kmutil.log" 2>&1 \
  || die "collection build failed (log $BK/kmutil.log; old collection kept)"
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" | grep -q '^org.watchthelight.XeGfx[[:space:]]' && die "XeGfx still in the new collection"
for b in $OLD; do printf '%s\n' "$INS" | grep -q "^$b[[:space:]]" || die "$b was in the old collection but is missing from the new one"; done
mv -f "$NEW" "$KC"
kcditto > "$BK/kcditto.log" 2>&1 || true
echo "XeGfx removed (backup $BK). Restart to apply."
