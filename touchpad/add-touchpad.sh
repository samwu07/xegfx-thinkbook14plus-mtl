#!/bin/bash
# add-touchpad.sh check|apply|undo -- the ThinkBook 14+ 2024 touchpad (Goodix GXTP5100, I2C-HID at 0x2C on LPSS I2C0,
# PCI 8086:7E78, GpioInt pin 0x23 of INTC1083) on the live OpenCore EFI (disk0s1, EFI/OC).
# Kexts from /Volumes/PKG/touchpad/kexts: VoodooI2C 2.9.1 (Info.plist patched with a Meteor Lake personality for
# 0x7e78..0x7e7b, class VoodooI2CPCILakeController) and VoodooI2CHID; its plugins VoodooGPIO, VoodooInput and
# VoodooI2CServices are added first. VoodooGPIO has no INTC1083 table, so the touchpad runs in polling mode.
#   sudo bash /Volumes/PKG/touchpad/add-touchpad.sh check      read-only: what the active config has
#   sudo bash /Volumes/PKG/touchpad/add-touchpad.sh apply      backup, copy, add after Lilu, validate
#   sudo bash /Volumes/PKG/touchpad/add-touchpad.sh undo       put the backed-up config.plist back, remove the kexts
# A Windows deploy (work\deploy-sn750-clean07*.bat) replaces the EFI: apply again after it.
set -uo pipefail
MODE=${1:-check}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy
P=VoodooI2C.kext/Contents/PlugIns
# bundle path | executable
ENT=("$P/VoodooGPIO.kext|VoodooGPIO" "$P/VoodooInput.kext|VoodooInput" "$P/VoodooI2CServices.kext|VoodooI2CServices"
     "VoodooI2C.kext|VoodooI2C" "VoodooI2CHID.kext|VoodooI2CHID")
TOP=(VoodooI2C VoodooI2CHID)
die() { echo "add-touchpad: $*" >&2; [ -n "${MNT:-}" ] && [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in check|apply|undo) ;; *) echo "usage: $0 check|apply|undo" >&2; exit 2 ;; esac
for k in "${TOP[@]}"; do [ -f "$HERE/kexts/$k.kext/Contents/Info.plist" ] || die "missing $HERE/kexts/$k.kext"; done
grep -q 0x7e788086 "$HERE/kexts/VoodooI2C.kext/Contents/Info.plist" || die "VoodooI2C.kext is not the patched one (no 0x7e788086)"

MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = check ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; K="$MNT/EFI/OC/Kexts"
[ -f "$C" ] || die "no $C (is $DEV the OpenCore EFI?)"
n=$($PB -c 'Print :Kernel:Add' "$C" 2>/dev/null | grep -c 'BundlePath')
echo "EFI $DEV at $MNT; config.plist $(stat -f %z "$C") B, Kernel/Add $n entries; OpenCore $(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | cut -f2)"
have() { $PB -c 'Print :Kernel:Add' "$C" | grep -Fx "        BundlePath = $1" > /dev/null; }
case "$MODE" in
  check)
    for i in $(seq 0 $((n - 1))); do printf '  %2d %-60s %s\n' $i "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" "$($PB -c "Print :Kernel:Add:$i:Enabled" "$C")"; done
    for e in "${ENT[@]}"; do have "${e%%|*}" && echo "  ${e%%|*}: already in Kernel/Add" || echo "  ${e%%|*}: not yet"; done
    ;;
  apply)
    have Lilu.kext || die "no Lilu.kext in Kernel/Add"
    BK="$HERE/backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; ls "$K" > "$BK/kexts-before.txt"
    echo "backup: $BK"
    for k in "${TOP[@]}"; do rm -rf "$K/$k.kext"; ditto --norsrc --noextattr "$HERE/kexts/$k.kext" "$K/$k.kext"; done
    for e in "${ENT[@]}"; do
      b=${e%%|*}; x=${e##*|}
      [ -f "$K/$b/Contents/MacOS/$x" ] || { cp -p "$BK/config.plist" "$C"; die "$K/$b/Contents/MacOS/$x missing: config.plist put back"; }
      if have "$b"; then echo "  $b: entry exists"; continue; fi
      i=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath')
      $PB -c "Add :Kernel:Add:$i dict" -c "Add :Kernel:Add:$i:Arch string Any" -c "Add :Kernel:Add:$i:BundlePath string $b" \
          -c "Add :Kernel:Add:$i:Comment string Touchpad (add-touchpad.sh)" -c "Add :Kernel:Add:$i:Enabled bool true" \
          -c "Add :Kernel:Add:$i:ExecutablePath string Contents/MacOS/$x" -c "Add :Kernel:Add:$i:MaxKernel string" \
          -c "Add :Kernel:Add:$i:MinKernel string" -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" "$C" \
        || { cp -p "$BK/config.plist" "$C"; die "PlistBuddy failed on $b: config.plist put back"; }
      echo "  $b: added as Kernel/Add $i"
    done
    plutil -lint "$C" > /dev/null || { cp -p "$BK/config.plist" "$C"; die "config.plist did not validate: put back"; }
    sync; echo "done. Restart (rEFInd -> OpenCore -> CLEAN-07Y as before), then: ioreg -l -w0 | grep -i VoodooI2C"
    ;;
  undo)
    BK=$(ls -d "$HERE"/backup-* 2>/dev/null | sort | tail -1); [ -n "$BK" ] || die "no backup in $HERE"
    grep -q VoodooI2C "$BK/config.plist" && die "newest backup $BK already has VoodooI2C: pick the older one by hand"
    cp -p "$BK/config.plist" "$C"; for k in "${TOP[@]}"; do grep -qx "$k.kext" "$BK/kexts-before.txt" || rm -rf "$K/$k.kext"; done
    sync; echo "config.plist from $BK put back; the kexts removed. Restart."
    ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
