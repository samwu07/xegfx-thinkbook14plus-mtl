#!/bin/bash
# fps-ab.sh -- frames per second that reach the panel, 20 s with the zero-copy flip ON, 20 s OFF (copy path), 20 s ON
# again. Keep an animation on screen (UFO test) the whole minute. The flip is left as it was found.
# 2026-11-03 14:14: ~26 frames/s at the panel, all flipped, transactions = frames: WindowServer itself sends ~30/s.
# Same rate in both modes = WindowServer's drawing is the limit; different = the present path is.
#   sudo bash /Volumes/PKG/metal-stack/desktop/fps-ab.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
O="$(cd "$(dirname "$0")" && pwd)/reports/fps-ab-$(date +%Y%m%d-%H%M%S).txt"
was=$(sysctl -n debug.nvaccel_xeflip)
s() { sysctl -n debug.nvaccel_iop_ok_h4 debug.nvaccel_xeflip_flips debug.nvaccel_iop_copy_us debug.nvaccel_xeflip_flip_us debug.nvaccel_iop_vbl_wait_us 2>/dev/null | tr '\n' ' '; }
phase() {   # $1 = flip 0/1, $2 = label
  sysctl -w debug.nvaccel_xeflip=$1 > /dev/null; sleep 2
  read -r p0 f0 _ <<< "$(s)"; local sum=0
  for i in $(seq 1 20); do
    sleep 1; read -r p f cu fu vw <<< "$(s)"
    echo "$(date +%T) $2 frames/s $((p - p0)) flipped/s $((f - f0)) copy_us $cu flip_us $fu vbl_wait_us $vw" >> "$O"
    sum=$((sum + p - p0)); p0=$p; f0=$f
  done
  echo "$2: mean $((sum / 20)) frames/s" | tee -a "$O"
}
echo "keep UFO test on screen for the next minute..."
phase 1 "flip ON "; phase 0 "flip OFF"; phase 1 "flip ON "
sysctl -w debug.nvaccel_xeflip=$was > /dev/null
echo "flip back to $was. Details: $O"
