#!/bin/bash
# fps-now.sh [SECONDS] -- frames per second that reach the Intel panel, printed live once a second (default 20 s).
# No sudo needed. Start it, then do the thing to measure (drag a window in circles, run UFO test, scroll).
#   bash /Volumes/PKG/metal-stack/desktop/fps-now.sh
N=${1:-20}
a=$(sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null) || { echo "no debug.nvaccel_iop_ok_h4: the Intel desktop is not running"; exit 1; }
echo "measuring for $N s -- start now"; sum=0; max=0
for i in $(seq 1 "$N"); do
  sleep 1; b=$(sysctl -n debug.nvaccel_iop_ok_h4); d=$((b - a)); a=$b
  sum=$((sum + d)); [ $d -gt $max ] && max=$d
  printf '%2d s: %3d frames/s\n' "$i" "$d"
done
echo "mean $((sum / N)) frames/s, max $max"
