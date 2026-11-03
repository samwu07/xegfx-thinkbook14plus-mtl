#!/bin/bash
# install-xeintelfb.sh [uninstall] -- XeGfxIntelFB.kext, upstream's framebuffer for XeGfx (Apple's IONDRVFramebuffer
# under an Intel class name), into /Library/Extensions and the auxiliary kernel collection; every other kext stays.
#
# Why: CoreDisplay picks the GPU vendor from the framebuffer's class name. Plain IONDRVFramebuffer reads as no vendor,
# which turns IOPresentment off for WindowServer (upstream I-108). That was the 2026-11-02 16:43 desktop: WindowServer
# composited with Metal on the Intel GPU, but 0 swaps reached the accelerator and every frame went through Apple's CPU
# blit. With IOPresentment on, frames go to the accelerator's display pipe instead.
# Also: the panel's EDID name and size, its measured refresh, and HiDPI modes. Its hardware cursor stays off on this
# Mac (it only arms over the GOP layout of upstream's laptop, PLANE_SURF 0xff000000; this GOP uses 0xfe800000).
# The 0.9 build matches only upstream's 7D67, so the installed copy's Info.plist also lists 0x7d558086 (re-signed).
# Boot guard (its own): two boots in a row that do not stay up 120 s after it starts make it decline, and Apple's
# framebuffer drives the panel again. CLEAN-07S (Safe Mode) does not load the auxiliary collection at all.
#   sudo bash /Volumes/PKG/metal-stack/desktop/install-xeintelfb.sh              then restart into CLEAN-07Y
#   sudo bash /Volumes/PKG/metal-stack/desktop/install-xeintelfb.sh uninstall    then restart
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(cd "$HERE/.." && pwd)/out"
ID=org.watchthelight.XeGfxIntelFB; MATCH="0x7d558086 0x7d678086"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
PB=/usr/libexec/PlistBuddy; KP=IOKitPersonalities.XeGfxIntelFramebuffer.IOPCIMatch
MODE=${1:-install}
case "$MODE" in install|uninstall) ;; *) echo "usage: $0 [uninstall]" >&2; exit 2 ;; esac
BK=/Library/XeGfx/backup-xeintelfb-$(date +%Y%m%d-%H%M%S)
# from the kext swap until the new collection is in place, any failure puts /Library/Extensions back as it was
SWAPPED=0
restore() {
  [ $SWAPPED = 1 ] || return 0
  rm -rf "$EXT/XeGfxIntelFB.kext"; [ -d "$BK/XeGfxIntelFB.kext" ] && ditto --norsrc --noextattr "$BK/XeGfxIntelFB.kext" "$EXT/XeGfxIntelFB.kext"
  SWAPPED=0; echo "install-xeintelfb: $EXT is back as it was; the collection was not replaced" >&2
}
die() { echo "install-xeintelfb: $*" >&2; restore; exit 1; }
trap 'echo "install-xeintelfb: FAILED at line $LINENO: $BASH_COMMAND" >&2; restore' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "built for macOS 15"
REPORT="$HERE/reports/xeintelfb-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/$MODE.log") 2>&1

CUR=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null) || die "cannot read $KC"
printf '%s\n' "$CUR" > "$REPORT/old-collection.txt"
# every other kext in the current collection must be in the new one
OLD=$(printf '%s\n' "$CUR" | awk -F'\t' -v id=$ID '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 != id {print $1}')
[ -n "$OLD" ] || die "cannot read the current collection"
if [ "$MODE" = install ]; then
  [ ! -e "$EXT/NMIntelFB.kext" ] || die "NMIntelFB.kext is installed: sudo bash $HERE/remove-nmintelfb.sh first"
  (cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $OUT changed (SHA256SUMS)"
  NEWK="$OUT/kexts/XeGfxIntelFB.kext"
  VER=$("$PB" -c 'Print :CFBundleVersion' "$NEWK/Contents/Info.plist" 2>/dev/null) || die "no $NEWK (metal-stack 4-kexts.sh)"
  echo "XeGfxIntelFB $VER, matching $MATCH"
else
  [ -e "$EXT/XeGfxIntelFB.kext" ] || printf '%s\n' "$CUR" | grep -F "$ID" > /dev/null || { echo "XeGfxIntelFB is not installed: nothing to do"; exit 0; }
fi

mkdir -p "$BK"; cp -p "$KC" "$BK/"
[ -d "$EXT/XeGfxIntelFB.kext" ] && ditto --norsrc --noextattr "$EXT/XeGfxIntelFB.kext" "$BK/XeGfxIntelFB.kext"
echo "backup: $BK"
if [ "$MODE" = install ]; then
  rm -rf "$EXT/XeGfxIntelFB.kext.new"
  ditto --norsrc --noextattr "$NEWK" "$EXT/XeGfxIntelFB.kext.new"
  find "$EXT/XeGfxIntelFB.kext.new" -name '._*' -delete
  # plutil takes the value as its own argument (PlistBuddy's Set would have to parse the space inside it)
  plutil -replace "$KP" -string "$MATCH" "$EXT/XeGfxIntelFB.kext.new/Contents/Info.plist"
  [ "$(plutil -extract "$KP" raw -o - "$EXT/XeGfxIntelFB.kext.new/Contents/Info.plist")" = "$MATCH" ] || die "IOPCIMatch did not take"
  codesign -s - -f "$EXT/XeGfxIntelFB.kext.new" > "$REPORT/codesign.txt" 2>&1 \
    || echo "note: ad-hoc signing failed ($(tail -1 "$REPORT/codesign.txt")); the boot-args relax AMFI, continuing"
  chown -R root:wheel "$EXT/XeGfxIntelFB.kext.new"; chmod -R 755 "$EXT/XeGfxIntelFB.kext.new"
  SWAPPED=1; rm -rf "$EXT/XeGfxIntelFB.kext"; mv "$EXT/XeGfxIntelFB.kext.new" "$EXT/XeGfxIntelFB.kext"
else
  SWAPPED=1; rm -rf "$EXT/XeGfxIntelFB.kext"
fi
NEW="$KC.xeintelfb-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$REPORT/kmutil.log" 2>&1; then
  grep -i -E 'error|unresolved|symbol' "$REPORT/kmutil.log" | head -20 || true   # no match must not end the script before die
  die "the collection did not link (log in $REPORT/kmutil.log)"
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
for b in $OLD; do printf '%s\n' "$INS" | grep "^$b[[:space:]]" > /dev/null || die "$b missing from the new collection"; done
if [ "$MODE" = install ]; then
  printf '%s\n' "$INS" | awk -F'\t' -v id=$ID -v v="$VER" '$1 == id && $2 == v {f=1} END {exit !f}' || die "the new collection does not hold XeGfxIntelFB $VER"
else
  printf '%s\n' "$INS" | awk -F'\t' -v id=$ID '$1 == id {f=1} END {exit f}' || die "XeGfxIntelFB is still in the new collection"
fi
mv -f "$NEW" "$KC"; SWAPPED=0
kcditto > "$REPORT/kcditto.log" 2>&1 || true
# a fresh start for its boot guard (two counted starts without 120 s of uptime turn it off)
nvram -d xeintelfb-starts 2>/dev/null || true
sync
echo
if [ "$MODE" = install ]; then
  echo "XeGfxIntelFB $VER is in the auxiliary collection (backup $BK). Restart into CLEAN-07Y, then as before:"
  echo "  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7"
  echo "  sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh"
  echo "  sudo bash /Volumes/PKG/metal-stack/desktop/fb-check.sh     (the swaps should now count up)"
  echo "Undo:  sudo bash $HERE/install-xeintelfb.sh uninstall"
else
  echo "XeGfxIntelFB is out of the auxiliary collection (backup $BK). Restart."
fi
