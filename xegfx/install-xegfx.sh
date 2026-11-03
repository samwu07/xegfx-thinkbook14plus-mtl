#!/bin/bash
# install-xegfx.sh -- put WTLIntelGfx's XeGfx.kext 0.0.47 (official release zip, sha256 222ca676...) into the
# auxiliary kernel collection, the way upstream tools/install.sh does (kernel kext only, no accelerator/plugin).
#   sudo bash /Volumes/PKG/xegfx/install-xegfx.sh
# The kext loads IDLE: nothing touches the GPU until run-xegfx-stages.sh asks for a stage, and nothing loads it at
# boot, so any crash is followed by a clean boot. Undo: sudo bash /Volumes/PKG/xegfx/uninstall-xegfx.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
die() { echo "xegfx-install: $*" >&2; exit 1; }
[ "${XEGFX_AUXKC_ANYWAY:-0}" = 1 ] || die "retired 2026-11-01: with XeGfx in the auxiliary collection the desktop hard-froze ~1 min after login. Deploy OpenCore CLEAN-07X instead (see README.txt)"
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(uname -m)" = x86_64 ] || die "Intel Mac only"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "prepared for macOS Sequoia 15"
REPORT="$HERE/reports/install-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$REPORT"
exec > >(tee "$REPORT/install.log") 2>&1
ioreg -r -n GFX0 -l -w0 > "$REPORT/GFX0-ioreg.txt"
grep -q '"device-id" = <557d0000>' "$REPORT/GFX0-ioreg.txt" || die "8086:7D55 GFX0 not visible"
csrutil status > "$REPORT/sip.txt"; cat "$REPORT/sip.txt"
grep -qE 'status: disabled|Kext Signing: disabled' "$REPORT/sip.txt" \
  || die "kext signing is enforced: boot OpenCore CLEAN-05A (SIP 0x0A43) first"
# the VedCloud runtime must be gone: two i915 ports in one collection is not a test anyone has run
for k in NMXGPU NMXAccel; do
  [ ! -e "$EXT/$k.kext" ] || die "$k.kext is still installed -- run: sudo bash /Volumes/PKG/gpu-7d55/rollback-runtime.sh"
done
cd "$HERE"; shasum -a 256 -c SHA256SUMS.txt > "$REPORT/package-check.txt" || { cat "$REPORT/package-check.txt"; die "package files changed"; }
BK=/Library/XeGfx/backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"; [ -f "$KC" ] && cp -p "$KC" "$BK/"
OLD=$(kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | awk -F'\t' '$1 ~ /^[a-z]+\.[A-Za-z0-9.-]+$/ && $1 !~ /^com\.apple\./ && $1 != "org.watchthelight.XeGfx" {print $1}' || true)
echo "third-party kexts in the current collection: ${OLD:-none}"
rm -rf "$EXT/XeGfx.kext.new"; ditto "$HERE/XeGfx.kext" "$EXT/XeGfx.kext.new"
find "$EXT/XeGfx.kext.new" -name '._*' -delete
chown -R root:wheel "$EXT/XeGfx.kext.new"; chmod -R 755 "$EXT/XeGfx.kext.new"
rm -rf "$EXT/XeGfx.kext"; mv "$EXT/XeGfx.kext.new" "$EXT/XeGfx.kext"
NEW="$KC.xegfx-new"; rm -f "$NEW"
if ! kmutil create -n aux --volume-root / "${KARG[@]}" -B "$KB" -S "$KS" --repository "$EXT" -A "$NEW" -z > "$BK/kmutil.log" 2>&1; then
  cp "$BK/kmutil.log" "$REPORT/"; rm -rf "$EXT/XeGfx.kext"
  die "collection build failed (old collection kept, kext removed again); log in $REPORT"
fi
INS=$(kmutil inspect -a x86_64 -A "$NEW" 2>/dev/null) || die "cannot inspect the new collection"
printf '%s\n' "$INS" > "$REPORT/new-collection.txt"
printf '%s\n' "$INS" | grep -q '^org.watchthelight.XeGfx[[:space:]]' || die "XeGfx missing from the new collection"
for b in $OLD; do printf '%s\n' "$INS" | grep -q "^$b[[:space:]]" || die "$b was in the old collection but is missing from the new one"; done
mv -f "$NEW" "$KC"
kcditto > "$BK/kcditto.log" 2>&1 || true
cp "$BK/kmutil.log" "$BK/kcditto.log" "$REPORT/" 2>/dev/null || true
echo "$BK" > /Library/XeGfx/last-backup.txt
echo
echo "XeGfx 0.0.47 is in the auxiliary collection (backup $BK)."
echo "Restart once (rEFInd -> OpenCore -> macOS). Then:  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 2"
