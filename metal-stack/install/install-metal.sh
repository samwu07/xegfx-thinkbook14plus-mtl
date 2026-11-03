#!/bin/bash
# install-metal.sh -- phase 1 of the Metal stack, from /Volumes/PKG/metal-stack/out (5-collect.sh):
#   XeGfxAccel.kext    -> /Library/Extensions + the auxiliary kernel collection (old collection backed up first)
#   ANV, libdrm, translator -> /Library/GPUBundles/nvmtl, the paths the plugin loads them from
#   NVMTLDriver.bundle -> /Library/XeGfx/metal, a private folder: test-metal.sh loads it into mtlprobe only, so no
#                         other app (and not WindowServer) runs the plugin yet
#   XgFbMove.kext      -> /Library/Extensions + the same collection (6-xgfbmove.sh): moves the boot framebuffer out of
#                         the GuC area when run-xegfx-stages.sh loads it, instead of FbRelocate.efi at boot
# Nothing attaches at boot: XeGfxAccel matches only an Intel GPU that XeGfx stage 7 has marked nmxgpu-claimed, and
# XgFbMove has no personality at all (kmutil load only).
# Not in phase 1: the plugin in /Library/GPUBundles (every Metal app would load it), NMIntelFB and XeGfxAGDC (they take
# the panel at boot) -- that is the desktop phase.
#   sudo bash /Volumes/PKG/metal-stack/install/install-metal.sh        then restart
# Undo: sudo bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh
#       from Recovery: bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh "/Volumes/MAC - Data"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$(cd "$HERE/.." && pwd)/out"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
GB=/Library/GPUBundles/nvmtl; PRIV=/Library/XeGfx/metal
die() { echo "install-metal: $*" >&2; exit 1; }
# no silent deaths: set -e used to end the script without a word (install-desktop.sh, 2026-11-02)
trap 'echo "install-metal: FAILED at line $LINENO: $BASH_COMMAND -- the steps after it did not run" >&2' ERR
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "built for macOS 15"
REPORT="$HERE/reports/install-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/install.log") 2>&1

echo "== checks"
(cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $OUT changed (SHA256SUMS)"
[ -d "$OUT/kexts/XgFbMove.kext" ] || die "XgFbMove.kext not built: bash /Volumes/PKG/metal-stack/6-xgfbmove.sh"
[ ! -e "$EXT/XeGfx.kext" ] || die "XeGfx.kext is in /Library/Extensions (the retired route): run rescue-xegfx.sh first"
for k in NMIntelFB XeGfxIntelFB NMXGPU NMXAccel; do      # XeGfxAGDC is ours (phase 2): kept if present
  [ ! -e "$EXT/$k.kext" ] || die "$k.kext is installed; phase 1 expects it absent"
done
if [ -e /Library/GPUBundles/NVMTLDriver.bundle ] && [ ! -d /Library/XeGfx/desktop ]; then
  die "/Library/GPUBundles/NVMTLDriver.bundle exists and is not ours (old VedCloud runtime?): remove it first"
fi
csrutil status | grep -qE 'status: disabled|Kext Signing: disabled' || die "kext signing is enforced: boot OpenCore CLEAN-07A or CLEAN-07Y"

BK=/Library/XeGfx/backup-metal-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
[ -f "$KC" ] && cp -p "$KC" "$BK/"
# every OTHER vendor's kext must survive the rebuild; ours (org.watchthelight.*, org.local.*) come and go with
# /Library/Extensions (2026-11-02: a removed XeGfxAGDC blocked a correct collection)
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ && $1 !~ /^org\.watchthelight\./ && $1 !~ /^org\.local\./ {print $1}' || true)
echo "backup: $BK   third-party kexts in the current collection: ${OLD:-none}"

echo "== userland -> $GB"
mkdir -p "$GB"
for f in libdrm.2.dylib libvulkan_intel.dylib libnvmtl_translate.dylib; do cp "$OUT/GPUBundles/nvmtl/$f" "$GB/$f.new"; done
OLDDRM=$(otool -L "$GB/libvulkan_intel.dylib.new" | awk '/libdrm\.2\.dylib/ {print $1; exit}')
install_name_tool -id "$GB/libdrm.2.dylib" "$GB/libdrm.2.dylib.new"
install_name_tool -id "$GB/libvulkan_intel.dylib" -change "$OLDDRM" "$GB/libdrm.2.dylib" "$GB/libvulkan_intel.dylib.new"
install_name_tool -id "$GB/libnvmtl_translate.dylib" "$GB/libnvmtl_translate.dylib.new"
for f in libdrm.2.dylib libvulkan_intel.dylib libnvmtl_translate.dylib; do
  codesign -s - -f "$GB/$f.new" > /dev/null 2>&1
  mv -f "$GB/$f.new" "$GB/$f"       # renamed into place: a cp over a mapped dylib kills the next loader
done
otool -L "$GB/libvulkan_intel.dylib" | grep -q "$GB/libdrm.2.dylib" || die "libvulkan_intel still points at $OLDDRM"
printf '{\n    "file_format_version": "1.0.1",\n    "ICD": {\n        "library_path": "%s",\n        "api_version": "1.4.363",\n        "library_arch": "64"\n    }\n}\n' \
  "$GB/libvulkan_intel.dylib" > "$GB/intel_icd.json"
chown -R root:wheel "$GB"; chmod 755 "$GB"; chmod 644 "$GB"/*.json; chmod 755 "$GB"/*.dylib
otool -L "$GB/libvulkan_intel.dylib" | tail -n +2

echo "== plugin -> $PRIV (private)"
mkdir -p "$PRIV"; rm -rf "$PRIV/NVMTLDriver.bundle"
ditto --norsrc --noextattr "$OUT/GPUBundles/NVMTLDriver.bundle" "$PRIV/NVMTLDriver.bundle"
find "$PRIV" -name '._*' -delete
codesign -s - -f "$PRIV/NVMTLDriver.bundle" > /dev/null 2>&1
# explicit modes: ditto keeps the exFAT source's bits, and mtlprobe loads the plugin as your user, not root
chown -R root:wheel "$PRIV"; chmod -R u=rwX,go=rX "$PRIV"; chmod 755 /Library/XeGfx
sudo -u "${SUDO_USER:-nobody}" test -r "$PRIV/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" \
  || die "the plugin is not readable by ${SUDO_USER:-other users}: $(ls -ld /Library/XeGfx "$PRIV" "$PRIV/NVMTLDriver.bundle")"

echo "== XeGfxAccel + XgFbMove -> $EXT and the auxiliary kernel collection"
for k in XeGfxAccel XgFbMove; do
  rm -rf "$EXT/$k.kext.new"
  ditto --norsrc --noextattr "$OUT/kexts/$k.kext" "$EXT/$k.kext.new"
  find "$EXT/$k.kext.new" -name '._*' -delete
  chown -R root:wheel "$EXT/$k.kext.new"; chmod -R 755 "$EXT/$k.kext.new"
  rm -rf "$EXT/$k.kext"; mv "$EXT/$k.kext.new" "$EXT/$k.kext"
done
NEW="$KC.metal-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$BK/kmutil.log" 2>&1; then
  cp "$BK/kmutil.log" "$REPORT/"
  rm -rf "$EXT/XeGfxAccel.kext" "$EXT/XgFbMove.kext"
  grep -i -E 'error|unresolved|symbol' "$BK/kmutil.log" | head -20 || true   # no match must not end the script before die
  die "the collection did not link (log in $REPORT/kmutil.log). Nothing replaced; both kexts removed again."
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
printf '%s\n' "$INS" | grep -q 'org.watchthelight.XeGfxAccel' || die "XeGfxAccel missing from the new collection"
printf '%s\n' "$INS" | grep -q 'org.local.XgFbMove' || die "XgFbMove missing from the new collection"
for b in $OLD; do printf '%s\n' "$INS" | grep -q "^$b[[:space:]]" || die "$b was in the old collection but is missing from the new one"; done
mv -f "$NEW" "$KC"
kcditto > "$BK/kcditto.log" 2>&1 || true
cp "$BK/kmutil.log" "$REPORT/" 2>/dev/null || true
echo "$BK" > /Library/XeGfx/last-backup.txt
echo "$BK" > /Library/XeGfx/metal/backup.txt
echo
echo "Installed (backup $BK). Restart into OpenCore CLEAN-07Y (XeGfx, no FbRelocate), then:"
echo "  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7      (loads XgFbMove first, then stages 1-7)"
echo "  bash /Volumes/PKG/metal-stack/install/test-metal.sh"
