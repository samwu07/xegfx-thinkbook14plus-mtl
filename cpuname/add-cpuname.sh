#!/bin/bash
# add-cpuname.sh check|apply|undo -- the real CPU name in About This Mac / System Information ("Processor Name: Unknown"
# before) on the live OpenCore EFI (disk0s1, EFI/OC), with RestrictEvents 1.1.6 (acidanthera, from
# /Volumes/PKG/cpuname/kexts; release zip SHA-256 98170dfa...14ee6) after Lilu in Kernel/Add, and in config.plist NVRAM:
#   4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revcpuname = "Intel Core Ultra 7 155H"  (added to NVRAM/Add and NVRAM/Delete)
#   7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args  gets " revcpu=1" appended
# and PlatformInfo/Generic/ProcessorType = 0x0F01 (3841): RestrictEvents only renames the CPU through Apple's table entry
# for that type when a CPU has 8 cores or more (its README); OpenCore's automatic choice here was 0x0605, so About This
# Mac kept "Unknown" (2026-11-13). The type is only what macOS displays.
# OpenCore writes both at every boot. The next Windows deploy (work\deploy-sn750-clean07*.bat) replaces this EFI: apply
# again after it, or copy the kext and entries into the work folder.
#   sudo bash /Volumes/PKG/cpuname/add-cpuname.sh check      read-only: what the active config has
#   sudo bash /Volumes/PKG/cpuname/add-cpuname.sh apply      backup, copy, add, validate
#   sudo bash /Volumes/PKG/cpuname/add-cpuname.sh undo       put the config.plist from before the first apply back, remove the kext
set -uo pipefail
MODE=${1:-check}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy
K1=RestrictEvents; NAME="Intel Core Ultra 7 155H"; PTYPE=3841
OCG=4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102; AG=7C436110-AB2A-4BBB-A880-FE41995C9F82
die() { echo "add-cpuname: $*" >&2; [ -n "${MNT:-}" ] && [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in check|apply|undo) ;; *) echo "usage: $0 check|apply|undo" >&2; exit 2 ;; esac
[ -f "$HERE/kexts/$K1.kext/Contents/Info.plist" ] || die "missing $HERE/kexts/$K1.kext"

MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = check ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; K="$MNT/EFI/OC/Kexts"
[ -f "$C" ] || die "no $C (is $DEV the OpenCore EFI?)"
n=$($PB -c 'Print :Kernel:Add' "$C" 2>/dev/null | grep -c 'BundlePath')
have() { $PB -c 'Print :Kernel:Add' "$C" | grep -F "BundlePath = $1.kext" > /dev/null; }
args() { $PB -c "Print :NVRAM:Add:$AG:boot-args" "$C" 2>/dev/null; }
echo "EFI $DEV at $MNT; config.plist $(stat -f %z "$C") B, Kernel/Add $n entries"
case "$MODE" in
  check)
    have Lilu && echo "  Lilu: in Kernel/Add" || echo "  Lilu: MISSING (RestrictEvents needs it)"
    have $K1 && echo "  $K1: already in Kernel/Add" || echo "  $K1: not yet"
    echo "  config boot-args: $(args || echo '(none in NVRAM/Add)')"
    echo "  config revcpuname: $($PB -c "Print :NVRAM:Add:$OCG:revcpuname" "$C" 2>/dev/null || echo '(not set)')"
    echo "  NVRAM/Delete $OCG: $($PB -c "Print :NVRAM:Delete:$OCG" "$C" 2>/dev/null | tr -s ' \n' ' ' || echo '(none)')"
    echo "  NVRAM/Delete $AG: $($PB -c "Print :NVRAM:Delete:$AG" "$C" 2>/dev/null | tr -s ' \n' ' ' || echo '(none)')"
    echo "  WriteFlash: $($PB -c 'Print :NVRAM:WriteFlash' "$C" 2>/dev/null)"
    echo "  PlatformInfo/Generic/ProcessorType: $($PB -c 'Print :PlatformInfo:Generic:ProcessorType' "$C" 2>/dev/null || echo '(missing)') (0 = automatic; wanted $PTYPE = 0x0F01)"
    echo "  PlatformInfo/UpdateSMBIOS: $($PB -c 'Print :PlatformInfo:UpdateSMBIOS' "$C" 2>/dev/null)"
    ;;
  apply)
    have Lilu || die "no Lilu.kext in Kernel/Add: RestrictEvents needs it"
    args > /dev/null || die "config.plist has no NVRAM/Add boot-args: not the layout this script knows, nothing changed"
    BK="$HERE/backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; ls "$K" > "$BK/kexts-before.txt"
    echo "backup: $BK"
    fail() { cp -p "$BK/config.plist" "$C"; die "$1: config.plist put back"; }
    rm -rf "$K/$K1.kext"; ditto --norsrc --noextattr "$HERE/kexts/$K1.kext" "$K/$K1.kext"
    if have $K1; then echo "  $K1: entry exists, kext copied"; else
      i=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath')
      $PB -c "Add :Kernel:Add:$i dict" -c "Add :Kernel:Add:$i:Arch string Any" -c "Add :Kernel:Add:$i:BundlePath string $K1.kext" \
          -c "Add :Kernel:Add:$i:Comment string CPU name (add-cpuname.sh)" -c "Add :Kernel:Add:$i:Enabled bool true" \
          -c "Add :Kernel:Add:$i:ExecutablePath string Contents/MacOS/$K1" -c "Add :Kernel:Add:$i:MaxKernel string" \
          -c "Add :Kernel:Add:$i:MinKernel string" -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" "$C" \
        || fail "PlistBuddy failed on $K1"
      echo "  $K1: added as Kernel/Add $i"
    fi
    $PB -c "Print :NVRAM:Add:$OCG" "$C" > /dev/null 2>&1 || $PB -c "Add :NVRAM:Add:$OCG dict" "$C" || fail "no NVRAM/Add $OCG"
    $PB -c "Delete :NVRAM:Add:$OCG:revcpuname" "$C" > /dev/null 2>&1
    $PB -c "Add :NVRAM:Add:$OCG:revcpuname string $NAME" "$C" || fail "cannot set revcpuname"
    $PB -c "Print :NVRAM:Delete:$OCG" "$C" > /dev/null 2>&1 || $PB -c "Add :NVRAM:Delete:$OCG array" "$C" || fail "no NVRAM/Delete $OCG"
    if ! $PB -c "Print :NVRAM:Delete:$OCG" "$C" | grep -qx ' *revcpuname'; then
      j=$($PB -c "Print :NVRAM:Delete:$OCG" "$C" | sed '1d;$d' | grep -c .)
      $PB -c "Add :NVRAM:Delete:$OCG:$j string revcpuname" "$C" || fail "cannot add revcpuname to NVRAM/Delete"
    fi
    a=$(args); case " $a " in *" revcpu=1 "*) echo "  boot-args: revcpu=1 already there" ;;
      *) $PB -c "Set :NVRAM:Add:$AG:boot-args $a revcpu=1" "$C" || fail "cannot set boot-args"; echo "  boot-args: revcpu=1 appended" ;; esac
    $PB -c "Print :NVRAM:Delete:$AG" "$C" 2>/dev/null | grep -qx ' *boot-args' \
      || echo "  note: boot-args is not in NVRAM/Delete for $AG, so OpenCore may keep the old value; check after the restart"
    pt=$($PB -c 'Print :PlatformInfo:Generic:ProcessorType' "$C" 2>/dev/null) || fail "no PlatformInfo/Generic/ProcessorType: not the layout this script knows"
    if [ "$pt" = "$PTYPE" ]; then echo "  ProcessorType: already 0x0F01"; else
      $PB -c "Set :PlatformInfo:Generic:ProcessorType $PTYPE" "$C" || fail "cannot set ProcessorType"; echo "  ProcessorType: $pt -> $PTYPE (0x0F01)"; fi
    plutil -lint "$C" > /dev/null || fail "config.plist did not validate"
    sync; echo "done. Restart (as before), then: system_profiler SPHardwareDataType | grep Processor"
    ;;
  undo)
    BK=$(ls -d "$HERE"/backup-* 2>/dev/null | sort | head -1); [ -n "$BK" ] || die "no backup in $HERE"   # the oldest: from before any apply
    cp -p "$BK/config.plist" "$C"; grep -qx "$K1.kext" "$BK/kexts-before.txt" || rm -rf "$K/$K1.kext"
    sync; echo "config.plist from $BK put back; $K1.kext removed if it was not there before. Restart."
    ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
