#!/bin/bash
# force-polling.sh on|off|show -- the boot-arg -vi2c-force-polling, in the live OpenCore config.plist (disk0s1, NVRAM >
# Add > 7C436110-...:boot-args) and in the running NVRAM.
# Why: VoodooI2CDeviceNub::probe gives up ("Could not find GPIO controller, exiting") when a device declares a GpioInt
# and VoodooGPIO has no driver for the controller; this board's GPI0 is INTC1083 and VoodooGPIO knows only
# INT3450/INT34BB/INT3455/INT345D/INT344B/INTC1055/AMD. With the arg the touchpad (Goodix GXTP5100) is polled.
#   sudo bash /Volumes/PKG/touchpad/force-polling.sh on
set -uo pipefail
MODE=${1:-show}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy
ARG=-vi2c-force-polling; G=7C436110-AB2A-4BBB-A880-FE41995C9F82
die() { echo "force-polling: $*" >&2; [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in on|off|show) ;; *) echo "usage: $0 on|off|show" >&2; exit 2 ;; esac
MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = show ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; [ -f "$C" ] || die "no $C"
KEY=":NVRAM:Add:$G:boot-args"
cur=$($PB -c "Print $KEY" "$C") || die "no boot-args in config.plist"
echo "config.plist boot-args: $cur"; echo "running NVRAM:          $(nvram boot-args 2>/dev/null | cut -f2)"
case "$MODE" in
  on)
    case " $cur " in *" $ARG "*) echo "already in config.plist" ;; *)
      BK="$HERE/backup-polling-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; echo "backup: $BK"
      $PB -c "Set $KEY $cur $ARG" "$C" || { cp -p "$BK/config.plist" "$C"; die "Set failed: config.plist put back"; }
      plutil -lint "$C" > /dev/null || { cp -p "$BK/config.plist" "$C"; die "config.plist did not validate: put back"; } ;;
    esac
    run=$(nvram boot-args 2>/dev/null | cut -f2)
    case " $run " in *" $ARG "*) ;; *) nvram boot-args="$run $ARG" && echo "NVRAM boot-args set too" ;; esac
    sync; echo "done. Restart." ;;
  off)
    new=$(echo " $cur " | sed "s/ $ARG / /; s/^ //; s/ \$//")
    $PB -c "Set $KEY $new" "$C" && plutil -lint "$C" > /dev/null || die "could not remove it"
    run=$(nvram boot-args 2>/dev/null | cut -f2); nvram boot-args="$(echo " $run " | sed "s/ $ARG / /; s/^ //; s/ \$//")"
    sync; echo "removed. Restart." ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
