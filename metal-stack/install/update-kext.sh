#!/bin/bash
# update-kext.sh <XgFbMove|XeGfxAccel> -- replaces only that kext (from /Volumes/PKG/metal-stack/out/kexts) in
# /Library/Extensions and the auxiliary kernel collection; everything else install-metal.sh / install-desktop.sh /
# install-xeintelfb.sh / add-bitcode-reader.sh put there stays. (install-metal.sh would also reinstall the private
# plugin and drop the bitcode reader added after it.)
#   XgFbMove    built by 6-xgfbmove.sh
#   XeGfxAccel  built by 7-xeflip.sh (0.9.1: the Intel zero-copy flip; out/orig/XeGfxAccel.kext is the stock 0.9)
#   sudo bash /Volumes/PKG/metal-stack/install/update-kext.sh XeGfxAccel        then restart into CLEAN-07Y
# Undo: the previous collection and kext are saved in /Library/XeGfx/backup-<kext>-<time>/ (this prints the command).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(cd "$HERE/.." && pwd)/out"
NAME=${1:-}
case "$NAME" in
  XgFbMove)   ID=org.local.XgFbMove;          BUILD=6-xgfbmove.sh ;;
  XeGfxAccel) ID=org.watchthelight.XeGfxAccel; BUILD=7-xeflip.sh ;;
  *) echo "usage: sudo bash $0 XgFbMove|XeGfxAccel" >&2; exit 2 ;;
esac
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
TAG=$(echo "$NAME" | tr 'A-Z' 'a-z')
# after the kext swap and until the new collection is in place, any failure puts the old kext back, so
# /Library/Extensions keeps matching the collection that boots
SWAPPED=0
restore() {
  [ $SWAPPED = 1 ] || return 0
  rm -rf "$EXT/$NAME.kext"; ditto --norsrc --noextattr "$BK/$NAME.kext" "$EXT/$NAME.kext"; SWAPPED=0
  echo "update-kext: the old $NAME.kext is back in $EXT; the collection was not replaced" >&2
}
die() { echo "update-kext: $*" >&2; restore; exit 1; }
trap 'echo "update-kext: FAILED at line $LINENO: $BASH_COMMAND" >&2; restore' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "built for macOS 15"
REPORT="$HERE/reports/$TAG-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/update.log") 2>&1

(cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $OUT changed (SHA256SUMS)"
NEWK="$OUT/kexts/$NAME.kext"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEWK/Contents/Info.plist" 2>/dev/null) || die "no $NEWK: bash /Volumes/PKG/metal-stack/$BUILD"
[ -d "$EXT/$NAME.kext" ] || die "$NAME is not installed at all (install-metal.sh)"
CUR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/$NAME.kext/Contents/Info.plist" 2>/dev/null || echo '?')
echo "$NAME $CUR -> $VER"

BK=/Library/XeGfx/backup-$TAG-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
cp -p "$KC" "$BK/"; ditto --norsrc --noextattr "$EXT/$NAME.kext" "$BK/$NAME.kext"
# every kext in the current collection must be in the new one (ours included: XeGfxAccel, XeGfxAGDC, XgFbMove, ...)
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ {print $1}' || true)
[ -n "$OLD" ] || die "cannot read the current collection"
echo "backup: $BK   kexts now: $(echo $OLD)"

rm -rf "$EXT/$NAME.kext.new"
ditto --norsrc --noextattr "$NEWK" "$EXT/$NAME.kext.new"
find "$EXT/$NAME.kext.new" -name '._*' -delete
chown -R root:wheel "$EXT/$NAME.kext.new"; chmod -R 755 "$EXT/$NAME.kext.new"
rm -rf "$EXT/$NAME.kext"; mv "$EXT/$NAME.kext.new" "$EXT/$NAME.kext"; SWAPPED=1
NEW="$KC.$TAG-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$REPORT/kmutil.log" 2>&1; then
  grep -i -E 'error|unresolved|symbol' "$REPORT/kmutil.log" | head -20 || true   # no match must not end the script before die
  die "the collection did not link (log in $REPORT/kmutil.log)"
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
for b in $OLD; do printf '%s\n' "$INS" | grep "^$b[[:space:]]" > /dev/null || die "$b missing from the new collection"; done
printf '%s\n' "$INS" | awk -F'\t' -v id="$ID" -v v="$VER" '$1 == id && $2 == v {f=1} END {exit !f}' \
  || die "the new collection does not hold $NAME $VER"
mv -f "$NEW" "$KC"; SWAPPED=0
kcditto > "$REPORT/kcditto.log" 2>&1 || true
sync
echo
echo "$NAME $VER is in the auxiliary collection. Restart into CLEAN-07Y, then:"
echo "  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7"
[ "$NAME" = XeGfxAccel ] && echo "  sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh        then, logged in again:  sudo bash /Volumes/PKG/metal-stack/desktop/xeflip.sh try"
echo "Undo:  sudo cp -p $BK/AuxiliaryKernelExtensions.kc $KC && sudo rm -rf $EXT/$NAME.kext && sudo ditto $BK/$NAME.kext $EXT/$NAME.kext && sudo kcditto"
echo "       then restart"
