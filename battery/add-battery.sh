#!/bin/bash
# add-battery.sh check|apply|undo -- battery status in macOS on the live OpenCore EFI (disk0s1, EFI/OC):
# SMCBatteryManager 1.3.8 (acidanthera VirtualSMC-1.3.8-RELEASE.zip, SHA-256 2e29a8aa...4de8b, the same release as the
# VirtualSMC.kext already in the EFI) in Kernel/Add after VirtualSMC. Why: macOS showed no battery (pmset had only "AC
# Power", no AppleSmartBattery). The DSDT's BAT1 (PNP0C0A) and ACAD (ACPI0003) are fine for it: every field _BIX/_BST
# and _PSR read sits in EC0's SystemMemory region ECMM (0xFE0B0400), not in EmbeddedControl space, so no ECEnabler and
# no ACPI patch are needed.
# The next Windows deploy (work\deploy-sn750-clean07*.bat) replaces this EFI: apply again after it.
#   sudo bash /Volumes/PKG/battery/add-battery.sh check      read-only: what the active config has
#   sudo bash /Volumes/PKG/battery/add-battery.sh apply      backup, copy, add, validate
#   sudo bash /Volumes/PKG/battery/add-battery.sh undo       put the config.plist from before the first apply back
set -uo pipefail
MODE=${1:-check}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy; K1=SMCBatteryManager
die() { echo "add-battery: $*" >&2; [ -n "${MNT:-}" ] && [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in check|apply|undo) ;; *) echo "usage: $0 check|apply|undo" >&2; exit 2 ;; esac
[ -f "$HERE/kexts/$K1.kext/Contents/MacOS/$K1" ] || die "missing $HERE/kexts/$K1.kext"

MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = check ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; K="$MNT/EFI/OC/Kexts"
[ -f "$C" ] || die "no $C (is $DEV the OpenCore EFI?)"
n=$($PB -c 'Print :Kernel:Add' "$C" 2>/dev/null | grep -c 'BundlePath')
have() { $PB -c 'Print :Kernel:Add' "$C" | grep -F "BundlePath = $1.kext" > /dev/null; }
echo "EFI $DEV at $MNT; config.plist $(stat -f %z "$C") B, Kernel/Add $n entries"
case "$MODE" in
  check)
    have VirtualSMC && echo "  VirtualSMC: in Kernel/Add ($($PB -c 'Print :CFBundleVersion' "$K/VirtualSMC.kext/Contents/Info.plist" 2>/dev/null))" || echo "  VirtualSMC: MISSING ($K1 needs it)"
    have $K1 && echo "  $K1: already in Kernel/Add" || echo "  $K1: not yet"
    ;;
  apply)
    have Lilu || die "no Lilu.kext in Kernel/Add"
    have VirtualSMC || die "no VirtualSMC.kext in Kernel/Add: $K1 needs it"
    v=$($PB -c 'Print :CFBundleVersion' "$K/VirtualSMC.kext/Contents/Info.plist" 2>/dev/null)
    [ "$v" = 1.3.8 ] || die "VirtualSMC in the EFI is $v, $K1 here is 1.3.8: use the matching release"
    BK="$HERE/backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; ls "$K" > "$BK/kexts-before.txt"
    echo "backup: $BK"
    fail() { cp -p "$BK/config.plist" "$C"; die "$1: config.plist put back"; }
    rm -rf "${K:?}/$K1.kext"; ditto --norsrc --noextattr "$HERE/kexts/$K1.kext" "$K/$K1.kext"
    if have $K1; then echo "  $K1: entry exists, kext copied"; else
      # plistlib, not chained PlistBuddy "Add :Kernel:Add:N ..." (in one call that inserted the entry in the wrong place)
      i=$(/usr/bin/python3 -I - "$C" "$K1" <<'PY'
import plistlib, sys
p, k = sys.argv[1], sys.argv[2]
c = plistlib.load(open(p, 'rb')); a = c['Kernel']['Add']
a.append({'Arch': 'Any', 'BundlePath': k + '.kext', 'Comment': 'Battery status (add-battery.sh)', 'Enabled': True,
          'ExecutablePath': 'Contents/MacOS/' + k, 'MaxKernel': '', 'MinKernel': '', 'PlistPath': 'Contents/Info.plist'})
plistlib.dump(c, open(p, 'wb'), sort_keys=False)
print(len(a) - 1)
PY
) || fail "editing config.plist failed"
      echo "  $K1: added as Kernel/Add $i"
    fi
    plutil -lint "$C" > /dev/null || fail "config.plist did not validate"
    have $K1 || fail "entry not found after adding"
    sync; echo "done. Restart, then: pmset -g batt"
    ;;
  undo)
    BK=$(ls -d "$HERE"/backup-* 2>/dev/null | sort | head -1); [ -n "$BK" ] || die "no backup in $HERE"   # the oldest: from before any apply
    cp -p "$BK/config.plist" "$C"; grep -qx "$K1.kext" "$BK/kexts-before.txt" || rm -rf "${K:?}/$K1.kext"
    sync; echo "config.plist from $BK put back; $K1.kext removed if it was not there before. Restart."
    ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
