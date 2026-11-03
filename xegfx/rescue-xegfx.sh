#!/bin/bash
# rescue-xegfx.sh [DATA_ROOT] -- macOS stopped booting after install-xegfx.sh. Put back the auxiliary kernel collection
# saved by install-xegfx.sh (the one from before XeGfx) and move XeGfx.kext out of /Library/Extensions. Deletes nothing:
# the XeGfx collection and the kext are kept under /Library/XeGfx for diagnosis.
#   macOS Recovery -> Utilities -> Terminal:   bash /Volumes/PKG/xegfx/rescue-xegfx.sh "/Volumes/MAC - Data"
#   Safe Mode (OpenCore CLEAN-07S):            sudo bash /Volumes/PKG/xegfx/rescue-xegfx.sh
# Also copies the crashed boot's panic reports to /Volumes/PKG/xegfx/reports/rescue-<time>.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D="${1:-/}"; LIVE=0; [ "$D" = / ] && LIVE=1; D="${D%/}"
die() { echo "xegfx-rescue: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo in macOS; Recovery Terminal already is root)"
[ -d "$D/Library/XeGfx" ] || die "$D/Library/XeGfx not found. In Recovery the data volume is usually \"/Volumes/MAC - Data\": ls /Volumes"
KC="$D/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
BK="$(cat "$D/Library/XeGfx/last-backup.txt" 2>/dev/null)"
[ -n "$BK" ] || BK="$(ls -d "$D"/Library/XeGfx/backup-* 2>/dev/null | sort | head -1 | sed "s|^$D||")"
[ -n "$BK" ] || die "no backup folder in $D/Library/XeGfx"
OLDKC="$D$BK/AuxiliaryKernelExtensions.kc"
OUT="$HERE/reports/rescue-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
exec > >(tee "$OUT/rescue.log") 2>&1
echo "data root: $D   backup: $D$BK"
ls -la "$D$BK" "$D/Library/KernelCollections" "$D/Library/Extensions"
ls -t "$D"/Library/Logs/DiagnosticReports/*.panic "$D"/Library/Logs/DiagnosticReports/Retired/*.panic 2>/dev/null | head -3 \
  | while IFS= read -r f; do cp "$f" "$OUT/"; done
nvram -p 2>/dev/null | grep -a -i -E 'panic|xegfx|boot-args|csr' | cut -c1-400 > "$OUT/nvram.txt"
if [ $LIVE = 1 ]; then
  log show --last 6h --style compact --predicate 'process == "kernel"' 2>/dev/null | grep -a -i -E 'xegfx|panic|kernelcollection|auxkc|kmutil|kext' | tail -3000 > "$OUT/kernel-log.txt"
fi
SAVE="$D/Library/XeGfx/broken-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$SAVE"
if [ -f "$OLDKC" ]; then
  if command -v kmutil > /dev/null && kmutil inspect -a x86_64 -A "$OLDKC" > "$OUT/restored-collection.txt" 2>&1; then
    grep -q '^org.watchthelight.XeGfx' "$OUT/restored-collection.txt" && die "the backup collection contains XeGfx -- stopping"
    cat "$OUT/restored-collection.txt"
  fi
  [ -f "$KC" ] && cp -p "$KC" "$SAVE/AuxiliaryKernelExtensions.kc.with-xegfx"
  cp -p "$OLDKC" "$KC.rescue" && mv -f "$KC.rescue" "$KC" || die "copy of the backup collection failed"
  if command -v cmp > /dev/null; then cmp -s "$OLDKC" "$KC" || die "restored collection differs from the backup"; fi
  echo "restored $KC from $BK"
else
  # there was no auxiliary collection before XeGfx: remove the one install-xegfx.sh made
  [ -f "$KC" ] && mv -f "$KC" "$SAVE/AuxiliaryKernelExtensions.kc.with-xegfx"
  echo "no collection existed before XeGfx; moved $KC away"
fi
[ -e "$D/Library/Extensions/XeGfx.kext" ] && mv -f "$D/Library/Extensions/XeGfx.kext" "$SAVE/XeGfx.kext"
[ ! -e "$D/Library/Extensions/XeGfx.kext" ] || die "XeGfx.kext still in /Library/Extensions"
[ $LIVE = 1 ] && { kcditto > "$OUT/kcditto.log" 2>&1 || true; }
sync
echo
echo "Done. XeGfx is out; the broken collection and the kext are kept in $SAVE."
echo "Reports: $OUT. Restart and pick MAC in OpenCore (normal mode)."
