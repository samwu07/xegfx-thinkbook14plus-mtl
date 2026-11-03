#!/bin/bash
# install-desktop.sh -- phase 2 (desktop), the persistent part. Needs phase 1 (install-metal.sh) and its mtlprobe pass.
#   XeGfxAGDC.kext      -> /Library/Extensions + the auxiliary kernel collection (backup first). It loads at every boot
#                          but stays idle until `sysctl debug.xegfx_agdc=1` (desktop-on.sh); IOPresentment needs it to
#                          give the boot framebuffer a display pipe on the Intel GPU (upstream N-249)
#   NVMTLDriver.bundle  -> /Library/GPUBundles (system-wide; the accelerator's MetalPluginName points here)
#   nvmtl-allow.txt     -> /Library/GPUBundles: "!WindowServer" = WindowServer gets the Intel Metal device, and only once
#                          desktop-on.sh has armed the accelerator (debug.nvaccelfb); every other app is refused
# In a boot where the stages do not run nothing of this does anything: no NMXAccel service -> no plugin load.
# NMIntelFB is NOT installed: over XeGfx the accelerator drives Apple's own boot framebuffer (IONDRVFramebuffer, what
# this Mac uses) through a CPU copy, and upstream notes NMIntelFB at boot left the panel on text.
#   sudo bash /Volumes/PKG/metal-stack/desktop/install-desktop.sh        then restart
# Undo: sudo bash /Volumes/PKG/metal-stack/desktop/uninstall-desktop.sh   (or from Recovery with "/Volumes/MAC - Data")
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(cd "$HERE/.." && pwd)/out"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
GPU=/Library/GPUBundles; PRIV=/Library/XeGfx/metal
die() { echo "install-desktop: $*" >&2; exit 1; }
# no silent deaths (2026-11-02: a silenced codesign ended this script after the collection was already replaced)
trap 'echo "install-desktop: FAILED at line $LINENO: $BASH_COMMAND -- the steps after it did not run; undo with uninstall-desktop.sh" >&2' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "built for macOS 15"
REPORT="$HERE/reports/install-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/install.log") 2>&1

echo "== checks"
(cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $OUT changed (SHA256SUMS)"
[ -f "$PRIV/backup.txt" ] && [ -d "$EXT/XeGfxAccel.kext" ] && [ -d "$EXT/XgFbMove.kext" ] || die "phase 1 is not installed (install-metal.sh)"
[ -x "$PRIV/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" ] || die "no plugin in $PRIV"
[ -d "$OUT/kexts/XeGfxAGDC.kext" ] || die "no XeGfxAGDC.kext in $OUT (4-kexts.sh + 5-collect.sh)"
[ ! -e "$EXT/NMIntelFB.kext" ] || die "NMIntelFB.kext is installed; this phase expects Apple's boot framebuffer"
if [ -e "$GPU/NVMTLDriver.bundle" ] && [ ! -f /Library/XeGfx/desktop/backup.txt ]; then
  die "$GPU/NVMTLDriver.bundle exists but was not put there by this script (old VedCloud runtime?)"
fi

BK=/Library/XeGfx/backup-desktop-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK" /Library/XeGfx/desktop
[ -f "$KC" ] && cp -p "$KC" "$BK/"
[ -f "$GPU/nvmtl-allow.txt" ] && cp -p "$GPU/nvmtl-allow.txt" "$BK/"
# recorded before anything changes, so uninstall-desktop.sh finds it even if a later step fails; a re-run keeps the
# first backup (the collection from before phase 2)
[ -f /Library/XeGfx/desktop/backup.txt ] || echo "$BK" > /Library/XeGfx/desktop/backup.txt
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ && $1 !~ /^org\.watchthelight\./ && $1 !~ /^org\.local\./ {print $1}' || true)
echo "backup: $BK   third-party kexts in the current collection: $(echo $OLD)"

echo "== XeGfxAGDC -> $EXT and the auxiliary kernel collection"
rm -rf "$EXT/XeGfxAGDC.kext.new"
ditto --norsrc --noextattr "$OUT/kexts/XeGfxAGDC.kext" "$EXT/XeGfxAGDC.kext.new"
find "$EXT/XeGfxAGDC.kext.new" -name '._*' -delete
chown -R root:wheel "$EXT/XeGfxAGDC.kext.new"; chmod -R 755 "$EXT/XeGfxAGDC.kext.new"
rm -rf "$EXT/XeGfxAGDC.kext"; mv "$EXT/XeGfxAGDC.kext.new" "$EXT/XeGfxAGDC.kext"
NEW="$KC.desktop-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$BK/kmutil.log" 2>&1; then
  cp "$BK/kmutil.log" "$REPORT/"; rm -rf "$EXT/XeGfxAGDC.kext"
  grep -i -E 'error|unresolved|symbol' "$BK/kmutil.log" | head -20 || true   # no match must not end the script before die
  die "the collection did not link (log in $REPORT/kmutil.log). Nothing replaced; XeGfxAGDC.kext removed again."
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
for b in org.watchthelight.XeGfxAGDC org.watchthelight.XeGfxAccel org.local.XgFbMove $OLD; do
  printf '%s\n' "$INS" | grep -q "^$b[[:space:]]" || die "$b missing from the new collection"
done
mv -f "$NEW" "$KC"
kcditto > "$BK/kcditto.log" 2>&1 || true

echo "== plugin -> $GPU (system-wide) and the allow-list"
rm -rf "$GPU/NVMTLDriver.bundle.new"
# no extended attributes: codesign refuses a bundle carrying them ("detritus"), which killed the first runs
ditto --norsrc --noextattr "$PRIV/NVMTLDriver.bundle" "$GPU/NVMTLDriver.bundle.new"
xattr -cr "$GPU/NVMTLDriver.bundle.new"
chown -R root:wheel "$GPU/NVMTLDriver.bundle.new"; chmod -R u=rwX,go=rX "$GPU/NVMTLDriver.bundle.new"
codesign -s - -f "$GPU/NVMTLDriver.bundle.new" > "$REPORT/codesign.txt" 2>&1 \
  || echo "note: ad-hoc signing failed ($(tail -1 "$REPORT/codesign.txt")); the boot-args relax AMFI, continuing unsigned"
rm -rf "$GPU/NVMTLDriver.bundle"; mv "$GPU/NVMTLDriver.bundle.new" "$GPU/NVMTLDriver.bundle"
cat > "$GPU/nvmtl-allow.txt" <<'EOF'
# Intel GPU (XeGfx) Metal plugin: which processes get the Intel Metal device.
# "!name" = only once the accelerator is armed (sysctl debug.nvaccelfb >= 1, done by desktop-on.sh).
# mtlprobe is always allowed by the plugin itself. Apps are added later, one by one.
!WindowServer
EOF
chown root:wheel "$GPU/nvmtl-allow.txt"; chmod 644 "$GPU/nvmtl-allow.txt"
cp "$BK/kmutil.log" "$REPORT/" 2>/dev/null || true
echo "$BK" > /Library/XeGfx/desktop/backup.txt
echo
echo "Installed (backup $BK). Restart into CLEAN-07Y, log in, save your work, then:"
echo "  sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh"
