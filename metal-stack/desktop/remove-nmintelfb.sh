#!/bin/bash
# remove-nmintelfb.sh -- takes NMIntelFB.kext out of /Library/Extensions and the auxiliary kernel collection; every
# other kext in the collection stays. The kext and the old collection are kept in /Library/XeGfx/backup-nmintelfb-<time>.
# 2026-11-02 18:57: with NMIntelFB in the collection the boot stopped after "NMIntelFB: step 5 frame counter" (each of
# its steps writes and syncs an NVRAM variable first). Its boot guard counts only starts that reach step 7, so it never
# turns itself off after such a stop: every boot loads it again.
# Works in a normal boot and in Safe Mode (CLEAN-07S does not load the auxiliary collection, so NMIntelFB cannot stop it).
#   sudo bash /Volumes/PKG/metal-stack/desktop/remove-nmintelfb.sh        then restart
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ID=com.nullmoth.NMIntelFB
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
BK=/Library/XeGfx/backup-nmintelfb-$(date +%Y%m%d-%H%M%S)
# until the new collection is in place, any failure puts the kext back, so /Library/Extensions keeps matching the
# collection that boots
MOVED=0
restore() {
  [ $MOVED = 1 ] || return 0
  [ -e "$EXT/NMIntelFB.kext" ] || mv "$BK/NMIntelFB.kext" "$EXT/NMIntelFB.kext"; MOVED=0
  echo "remove-nmintelfb: NMIntelFB.kext is back in $EXT; the collection was not replaced" >&2
}
die() { echo "remove-nmintelfb: $*" >&2; restore; exit 1; }
trap 'echo "remove-nmintelfb: FAILED at line $LINENO: $BASH_COMMAND" >&2; restore' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
REPORT="$HERE/reports/rmfb-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/remove.log") 2>&1

# where NMIntelFB got to in the boot that stopped (the boot after a stop moves the marker to -prev)
for v in nmintelfb-step nmintelfb-step-prev nmintelfb-starts; do printf '%s: %s\n' "$v" "$(nvram "$v" 2>/dev/null | cut -f2-)"; done
CUR=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null) || die "cannot read $KC"
printf '%s\n' "$CUR" > "$REPORT/old-collection.txt"
INKC=0; printf '%s\n' "$CUR" | awk -F'\t' -v id=$ID '$1 == id {f=1} END {exit !f}' && INKC=1
INEXT=0; [ -e "$EXT/NMIntelFB.kext" ] && INEXT=1
echo "NMIntelFB: in $EXT $INEXT, in the auxiliary collection $INKC"
if [ $INKC = 0 ] && [ $INEXT = 0 ]; then
  if kmutil showloaded --list-only 2>/dev/null | grep -F "$ID (" > /dev/null; then
    echo "NMIntelFB is loaded but not from the auxiliary collection (OpenCore Kernel/Add?): tell me where you added it"
  else echo "NMIntelFB is not installed: nothing to do"; fi
  exit 0
fi
# every other kext in the current collection must be in the new one
OLD=$(printf '%s\n' "$CUR" | awk -F'\t' -v id=$ID '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 != id {print $1}')

mkdir -p "$BK"; cp -p "$KC" "$BK/"
echo "backup: $BK"
if [ $INEXT = 1 ]; then mv "$EXT/NMIntelFB.kext" "$BK/NMIntelFB.kext"; MOVED=1; fi
NEW="$KC.rmfb-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$REPORT/kmutil.log" 2>&1; then
  grep -i -E 'error|unresolved|symbol' "$REPORT/kmutil.log" | head -20 || true   # no match must not end the script before die
  die "the collection did not link (log in $REPORT/kmutil.log)"
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
printf '%s\n' "$INS" | awk -F'\t' -v id=$ID '$1 == id {f=1} END {exit f}' || die "NMIntelFB is still in the new collection"
for b in $OLD; do printf '%s\n' "$INS" | grep "^$b[[:space:]]" > /dev/null || die "$b missing from the new collection"; done
mv -f "$NEW" "$KC"; MOVED=0
kcditto > "$REPORT/kcditto.log" 2>&1 || true
sync
echo
echo "NMIntelFB is out of the auxiliary collection (kext and old collection in $BK). Restart."
echo "Undo:  sudo cp -p $BK/AuxiliaryKernelExtensions.kc $KC && sudo kcditto   (and move $BK/NMIntelFB.kext back)"
