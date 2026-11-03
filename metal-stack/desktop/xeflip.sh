#!/bin/bash
# xeflip.sh try|on|off|status -- the Intel zero-copy flip of XeGfxAccel 0.9.1 (metal-stack/7-xeflip.sh): instead of
# copying every frame WindowServer composites into the boot framebuffer, the panel scans the surface itself.
# Needs the desktop on the Intel GPU with frames reaching the accelerator (XeGfxIntelFB + desktop-on.sh, so that
# debug.nvaccel_iop_ok_h4 counts up). Everything here lasts until restart.
#   try     on for 30 s, then off again by itself; move windows meanwhile and watch the screen
#   on      on until restart (or `off`)
#   off     back to copying from the next frame
#   status  the counters
#   sudo bash /Volumes/PKG/metal-stack/desktop/xeflip.sh try
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE=${1:-status}
die() { echo "xeflip: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
case "$MODE" in try|on|off|status) ;; *) die "usage: $0 try|on|off|status" ;; esac
sysctl -n debug.nvaccel_xeflip > /dev/null 2>&1 \
  || die "no debug.nvaccel_xeflip: XeGfxAccel 0.9.1 is not running (7-xeflip.sh, update-kext.sh XeGfxAccel, restart, stages 7)"
R="$HERE/reports/xeflip-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
exec > >(tee "$R/xeflip.log") 2>&1
status() {
  sysctl debug.nvaccel_xeflip debug.nvaccel_xeflip_ggtt debug.nvaccel_xeflip_flips debug.nvaccel_xeflip_copied debug.nvaccel_xeflip_last_why \
         debug.nvaccel_xeflip_maps debug.nvaccel_xeflip_map_us debug.nvaccel_xeflip_flip_us debug.nvaccel_xeflip_homes \
         debug.nvaccel_xeflip_idle_homes debug.nvaccel_xeflip_kept debug.nvaccel_iop_ok_h4 debug.nvaccel_iop_copy_us \
         debug.nvaccel_iop_fail 2>&1
}
frames() { sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null || echo 0; }
case "$MODE" in
  status) status ;;
  off) sysctl -w debug.nvaccel_xeflip=0; echo "copying again from the next frame" ;;
  try|on)
    a=$(frames); sleep 2; b=$(frames)
    if [ "$a" = "$b" ]; then
      echo "note: no frame reached the accelerator in 2 s (was the screen still?). If moving windows does not change"
      echo "      debug.nvaccel_iop_ok_h4 either, WindowServer is not using the accelerator's display pipe:"
      echo "      sudo bash $HERE/fb-check.sh   (XeGfxIntelFB installed? desktop-on.sh run?)"
    fi
    if [ "$MODE" = try ]; then
      # off again by itself, even if this Terminal is gone
      nohup bash -c 'sleep 30; sysctl -w debug.nvaccel_xeflip=0 > /dev/null' > /dev/null 2>&1 < /dev/null &
      disown
      sysctl -w debug.nvaccel_xeflip=1
      echo "zero-copy flip ON for 30 s: move and resize windows, scroll, watch for glitches..."
      sleep 32
      echo "-- after the trial (it is off again):"
    else
      sysctl -w debug.nvaccel_xeflip=1
      echo "zero-copy flip ON until restart (sudo bash $0 off to stop)"
      sleep 5
    fi
    status
    ;;
esac
log show --last 3m --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "xeflip"' 2>/dev/null \
  | sed -E 's/^[0-9-]+ ([0-9:.]+) .*xeflip: /\1 xeflip: /' | tail -20 > "$R/kernel.txt"
cat "$R/kernel.txt"
status > "$R/counters.txt"
sync
echo "Reports: $R"
