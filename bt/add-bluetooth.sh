#!/bin/bash
# add-bluetooth.sh check|apply|undo -- Intel Bluetooth (CNVi 8087:0033) on the live OpenCore EFI (disk0s1, EFI/OC).
# Kexts from /Volumes/PKG/bt/kexts: IntelBluetoothFirmware 2.4.0 + IntelBTPatcher 2.4.0 (OpenIntelWireless, the AirportItlwm
# project) and BlueToolFixup 2.7.2 (acidanthera BrcmPatchRAM), appended to Kernel/Add after Lilu.
# The next Windows deploy (work\deploy-sn750-clean07*.bat) replaces this EFI: copy the kexts and entries into the work
# folder too, or apply again after a deploy.
#   sudo bash /Volumes/PKG/bt/add-bluetooth.sh check      read-only: what the active config has
#   sudo bash /Volumes/PKG/bt/add-bluetooth.sh apply      backup, copy, add, validate
#   sudo bash /Volumes/PKG/bt/add-bluetooth.sh undo       put the backed-up config.plist back, remove the three kexts
set -uo pipefail
MODE=${1:-check}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy
KEXTS=(IntelBluetoothFirmware IntelBTPatcher BlueToolFixup)
die() { echo "add-bluetooth: $*" >&2; [ -n "${MNT:-}" ] && [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in check|apply|undo) ;; *) echo "usage: $0 check|apply|undo" >&2; exit 2 ;; esac
for k in "${KEXTS[@]}"; do [ -f "$HERE/kexts/$k.kext/Contents/Info.plist" ] || die "missing $HERE/kexts/$k.kext"; done

MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = check ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; K="$MNT/EFI/OC/Kexts"
[ -f "$C" ] || die "no $C (is $DEV the OpenCore EFI?)"
n=$($PB -c 'Print :Kernel:Add' "$C" 2>/dev/null | grep -c 'BundlePath')
echo "EFI $DEV at $MNT; config.plist $(stat -f %z "$C") B, Kernel/Add $n entries; OpenCore $(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | cut -f2)"
have() { $PB -c 'Print :Kernel:Add' "$C" | grep -F "BundlePath = $1.kext" > /dev/null; }
case "$MODE" in
  check)
    for i in $(seq 0 $((n - 1))); do printf '  %2d %-32s %s\n' $i "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" "$($PB -c "Print :Kernel:Add:$i:Enabled" "$C")"; done
    for k in "${KEXTS[@]}"; do have "$k" && echo "  $k already in Kernel/Add" || echo "  $k: not yet"; done
    ;;
  apply)
    have Lilu || die "no Lilu.kext in Kernel/Add: IntelBTPatcher and BlueToolFixup need it"
    BK="$HERE/backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; ls "$K" > "$BK/kexts-before.txt"
    echo "backup: $BK"
    for k in "${KEXTS[@]}"; do
      rm -rf "$K/$k.kext"; ditto --norsrc --noextattr "$HERE/kexts/$k.kext" "$K/$k.kext"
      if have "$k"; then echo "  $k: entry exists, kext copied"; continue; fi
      i=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath')
      $PB -c "Add :Kernel:Add:$i dict" -c "Add :Kernel:Add:$i:Arch string Any" -c "Add :Kernel:Add:$i:BundlePath string $k.kext" \
          -c "Add :Kernel:Add:$i:Comment string Intel Bluetooth (add-bluetooth.sh)" -c "Add :Kernel:Add:$i:Enabled bool true" \
          -c "Add :Kernel:Add:$i:ExecutablePath string Contents/MacOS/$k" -c "Add :Kernel:Add:$i:MaxKernel string" \
          -c "Add :Kernel:Add:$i:MinKernel string" -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" "$C" \
        || { cp -p "$BK/config.plist" "$C"; die "PlistBuddy failed on $k: config.plist put back"; }
      echo "  $k: added as Kernel/Add $i"
    done
    plutil -lint "$C" > /dev/null || { cp -p "$BK/config.plist" "$C"; die "config.plist did not validate: put back"; }
    sync; echo "done. Restart (rEFInd -> OpenCore -> CLEAN-07Y as before), then: system_profiler SPBluetoothDataType"
    ;;
  undo)
    BK=$(ls -d "$HERE"/backup-* 2>/dev/null | sort | tail -1); [ -n "$BK" ] || die "no backup in $HERE"
    cp -p "$BK/config.plist" "$C"; for k in "${KEXTS[@]}"; do grep -qx "$k.kext" "$BK/kexts-before.txt" || rm -rf "$K/$k.kext"; done
    sync; echo "config.plist from $BK put back; kexts that were not there before removed. Restart."
    ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
