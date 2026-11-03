#!/bin/bash
# update-nmintelfb.sh -- adds (or replaces) NMIntelFB.kext from out/kexts in /Library/Extensions and the auxiliary kernel
# collection; everything else install-metal.sh / install-desktop.sh / add-bitcode-reader.sh put there stays.
# NMIntelFB is a framebuffer ON the Intel GPU (GFX0) for the panel the firmware lit: macOS then files the panel under the
# Intel GPU, not under the GPU-less firmware display (.Display_boot), which is what keeps WindowServer on CompositorSW.
# It loads at boot. Its boot guard turns it off after two starts without WindowServer; boot-arg -nmintelfboff turns it
# off outright. Undo: the command this prints, or remove /Library/Extensions/NMIntelFB.kext and rebuild the collection.
# (install-metal.sh would also reinstall the private plugin and drop the bitcode reader added after it.)
#   sudo bash /Volumes/PKG/metal-stack/install/update-nmintelfb.sh        then restart into CLEAN-07Y
# Undo: the previous collection is saved in /Library/XeGfx/backup-nmintelfb-<time>/ (this prints the command).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(cd "$HERE/.." && pwd)/out"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
# after the kext swap and until the new collection is in place, any failure puts the old NMIntelFB.kext back, so
# /Library/Extensions keeps matching the collection that boots
SWAPPED=0
restore() {
  [ $SWAPPED = 1 ] || return 0
  rm -rf "$EXT/NMIntelFB.kext"; [ -d "$BK/NMIntelFB.kext" ] && ditto --norsrc --noextattr "$BK/NMIntelFB.kext" "$EXT/NMIntelFB.kext"; SWAPPED=0
  echo "update-nmintelfb: the old NMIntelFB.kext is back in $EXT; the collection was not replaced" >&2
}
die() { echo "update-nmintelfb: $*" >&2; restore; exit 1; }
trap 'echo "update-nmintelfb: FAILED at line $LINENO: $BASH_COMMAND" >&2; restore' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "built for macOS 15"
REPORT="$HERE/reports/nmintelfb-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/update.log") 2>&1

(cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $OUT changed (SHA256SUMS)"
NEWK="$OUT/kexts/NMIntelFB.kext"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEWK/Contents/Info.plist" 2>/dev/null) || die "no $NEWK"
CUR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/NMIntelFB.kext/Contents/Info.plist" 2>/dev/null || echo none)
BUNDLEID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEWK/Contents/Info.plist")
echo "NMIntelFB $CUR -> $VER (binary $(shasum -a 256 "$EXT/NMIntelFB.kext/Contents/MacOS/NMIntelFB" | cut -c1-12) -> $(shasum -a 256 "$NEWK/Contents/MacOS/NMIntelFB" | cut -c1-12))"

BK=/Library/XeGfx/backup-nmintelfb-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
cp -p "$KC" "$BK/"; [ -d "$EXT/NMIntelFB.kext" ] && ditto --norsrc --noextattr "$EXT/NMIntelFB.kext" "$BK/NMIntelFB.kext"
# every kext in the current collection must be in the new one (ours included: NMIntelFB, XeGfxAGDC, NMIntelFB)
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ {print $1}' || true)
[ -n "$OLD" ] || die "cannot read the current collection"
echo "backup: $BK   kexts now: $(echo $OLD)"

rm -rf "$EXT/NMIntelFB.kext.new"
ditto --norsrc --noextattr "$NEWK" "$EXT/NMIntelFB.kext.new"
find "$EXT/NMIntelFB.kext.new" -name '._*' -delete
chown -R root:wheel "$EXT/NMIntelFB.kext.new"; chmod -R 755 "$EXT/NMIntelFB.kext.new"
rm -rf "$EXT/NMIntelFB.kext"; mv "$EXT/NMIntelFB.kext.new" "$EXT/NMIntelFB.kext"; SWAPPED=1
NEW="$KC.nmintelfb-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$REPORT/kmutil.log" 2>&1; then
  grep -i -E 'error|unresolved|symbol' "$REPORT/kmutil.log" | head -20
  die "the collection did not link (log in $REPORT/kmutil.log)"
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
for b in $OLD; do printf '%s\n' "$INS" | grep "^$b[[:space:]]" > /dev/null || die "$b missing from the new collection"; done
printf '%s\n' "$INS" | awk -F'\t' -v v="$VER" -v b="$BUNDLEID" '$1 == b && $2 == v {f=1} END {exit !f}' \
  || die "the new collection does not hold NMIntelFB $VER"
cmp -s "$NEWK/Contents/MacOS/NMIntelFB" "$EXT/NMIntelFB.kext/Contents/MacOS/NMIntelFB" || die "the kext in $EXT is not the one in $NEWK"
mv -f "$NEW" "$KC"; SWAPPED=0
kcditto > "$REPORT/kcditto.log" 2>&1 || true
sync
echo
echo "NMIntelFB $VER is in the auxiliary collection. Restart into CLEAN-07Y, then:"
echo "  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7"
echo "  sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh"
echo "Undo:  sudo cp -p $BK/AuxiliaryKernelExtensions.kc $KC && sudo rm -rf $EXT/NMIntelFB.kext && sudo kcditto"
echo "       then restart"
