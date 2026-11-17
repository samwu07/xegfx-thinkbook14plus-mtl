#!/bin/bash
# add-pnlf.sh check|apply|undo -- SSDT-PNLF on the live OpenCore EFI (disk0s1, EFI/OC/ACPI + config.plist ACPI/Add), for
# native brightness with XeGfxIntelFB 0.9.5: the "backlight" service IOFramebuffer looks for when the first framebuffer
# opens, and the APP0002 device XeGfxBacklight attaches to. Source: /Volumes/PKG/brightness/acpi/SSDT-PNLF.dsl.
# The next Windows deploy (work\deploy-sn750-clean07*.bat) replaces this EFI: apply again after it.
#   sudo bash /Volumes/PKG/brightness/add-pnlf.sh check      read-only: what the active config has
#   sudo bash /Volumes/PKG/brightness/add-pnlf.sh apply      backup, copy, add, validate
#   sudo bash /Volumes/PKG/brightness/add-pnlf.sh undo       put the config.plist from before the first apply back
set -uo pipefail
MODE=${1:-check}; HERE="$(cd "$(dirname "$0")" && pwd)"; DEV=/dev/disk0s1; PB=/usr/libexec/PlistBuddy; T=SSDT-PNLF.aml
die() { echo "add-pnlf: $*" >&2; [ -n "${MNT:-}" ] && [ -n "${OWN:-}" ] && diskutil unmount "$MNT" > /dev/null 2>&1; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
case "$MODE" in check|apply|undo) ;; *) echo "usage: $0 check|apply|undo" >&2; exit 2 ;; esac
[ -f "$HERE/acpi/$T" ] || die "missing $HERE/acpi/$T (iasl $HERE/acpi/SSDT-PNLF.dsl)"

MNT=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'); OWN=""
if [ -z "$MNT" ]; then
  if [ "$MODE" = check ]; then diskutil mount readOnly "$DEV" > /dev/null || die "cannot mount $DEV"; else diskutil mount "$DEV" > /dev/null || die "cannot mount $DEV"; fi
  MNT=$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p'); OWN=1
fi
C="$MNT/EFI/OC/config.plist"; A="$MNT/EFI/OC/ACPI"
[ -f "$C" ] || die "no $C (is $DEV the OpenCore EFI?)"
have() { $PB -c 'Print :ACPI:Add' "$C" 2>/dev/null | grep -F "Path = $T" > /dev/null; }
n=$($PB -c 'Print :ACPI:Add' "$C" 2>/dev/null | grep -c 'Path = ')
echo "EFI $DEV at $MNT; config.plist $(stat -f %z "$C") B, ACPI/Add $n entries"
case "$MODE" in
  check)
    $PB -c 'Print :ACPI:Add' "$C" | grep -E 'Path = |Enabled = ' | paste - - | sed 's/^ */  /'
    have && echo "  $T: already in ACPI/Add" || echo "  $T: not yet"
    ;;
  apply)
    [ -d "$A" ] || die "no $A"
    BK="$HERE/backup-pnlf-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"; cp -p "$C" "$BK/config.plist"; ls "$A" > "$BK/acpi-before.txt"
    echo "backup: $BK"
    fail() { cp -p "$BK/config.plist" "$C"; die "$1: config.plist put back"; }
    cp "$HERE/acpi/$T" "$A/$T"
    if have; then echo "  $T: entry exists, table copied"; else
      i=$n
      $PB -c "Add :ACPI:Add:$i dict" -c "Add :ACPI:Add:$i:Comment string backlight for native brightness (add-pnlf.sh)" \
          -c "Add :ACPI:Add:$i:Enabled bool true" -c "Add :ACPI:Add:$i:Path string $T" "$C" || fail "PlistBuddy failed"
      echo "  $T: added as ACPI/Add $i"
    fi
    plutil -lint "$C" > /dev/null || fail "config.plist did not validate"
    sync; echo "done. Install XeGfxIntelFB 0.9.5 too, then restart."
    ;;
  undo)
    BK=$(ls -d "$HERE"/backup-pnlf-* 2>/dev/null | sort | head -1); [ -n "$BK" ] || die "no backup in $HERE"   # the oldest: from before any apply
    cp -p "$BK/config.plist" "$C"; grep -qx "$T" "$BK/acpi-before.txt" || rm -f "$A/$T"
    sync; echo "config.plist from $BK put back; $T removed if it was not there before. Restart."
    ;;
esac
[ -n "$OWN" ] && diskutil unmount "$MNT" > /dev/null 2>&1
exit 0
