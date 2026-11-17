#!/bin/bash
# brightness.sh [PERCENT | +STEP | -STEP] -- the built-in panel's brightness through XeGfxAccel 0.9.6 and later
# (debug.nvaccel_backlight, per mille of the backlight PWM, xeflip/backlight.patch). No sudo needed. Without an argument
# it prints the current level. Never below 1%: the kernel side refuses darker values.
#   bash /Volumes/PKG/metal-stack/desktop/brightness.sh          current level
#   bash /Volumes/PKG/metal-stack/desktop/brightness.sh 40       set 40%
#   bash /Volumes/PKG/metal-stack/desktop/brightness.sh +10      10 points brighter (-10 darker)
OID=debug.nvaccel_backlight
cur=$(/usr/sbin/sysctl -n $OID 2>/dev/null) || { echo "no $OID: XeGfxAccel 0.9.6 is not loaded, or the backlight PWM is off" >&2; exit 1; }
pct=$(( (cur + 5) / 10 ))
case "${1:-}" in
  "") echo "brightness ${pct}%"; exit 0 ;;
  [+-][0-9]*) want=$(( pct + $1 )) ;;
  [0-9]*) want=$1 ;;
  *) echo "usage: $0 [PERCENT | +STEP | -STEP]" >&2; exit 2 ;;
esac
[ "$want" -lt 1 ] && want=1; [ "$want" -gt 100 ] && want=100
/usr/sbin/sysctl -w $OID=$(( want * 10 )) > /dev/null || { echo "could not set $OID" >&2; exit 1; }
echo "brightness ${want}%"
