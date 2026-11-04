#!/bin/bash
# fps-vbl.sh -- what paces the Intel desktop at ~30 frames/s: frames to the panel, 15 s per phase, UFO test on screen.
# 2026-11-03 16:19: with the marks fixed (3 timeouts, not 116) the panel still got exactly 29/s, so WindowServer's own
# waits are not it. Both present paths wait for the panel inside the frame transaction: the copy for the next vblank
# (debug.nvaccel_iop_vblsync), the flip for its latch. Phases:
#   A  as now (flip on)        B  flip off, copy at vblank        C  flip off, copy at once (may tear)
#   D  C + WindowServer's completion marks (no wait in WindowServer either)
# Everything goes back as it was; the Dock is restarted at the end (the marks phase).
#   sudo bash /Volumes/PKG/metal-stack/desktop/fps-vbl.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
O="$(cd "$(dirname "$0")" && pwd)/reports/fps-vbl-$(date +%Y%m%d-%H%M%S).txt"
fl=$(sysctl -n debug.nvaccel_xeflip); vb=$(sysctl -n debug.nvaccel_iop_vblsync); mk=$(sysctl -n debug.nvaccel_surface_gpu_on)
restore() { sysctl -w debug.nvaccel_xeflip=$fl debug.nvaccel_iop_vblsync=$vb debug.nvaccel_surface_gpu_on=$mk > /dev/null; }
trap restore EXIT
phase() {   # $1 label, $2 flip, $3 vblsync, $4 marks
  sysctl -w debug.nvaccel_xeflip=$2 debug.nvaccel_iop_vblsync=$3 debug.nvaccel_surface_gpu_on=$4 > /dev/null; sleep 3
  local a b t0=$(sysctl -n debug.nvaccel_surface_gpu_timeouts); a=$(sysctl -n debug.nvaccel_iop_ok_h4); sleep 15; b=$(sysctl -n debug.nvaccel_iop_ok_h4)
  echo "$1  flip $2 vblsync $3 marks $4: $(( (b - a) / 15 )) frames/s, mark timeouts +$(( $(sysctl -n debug.nvaccel_surface_gpu_timeouts) - t0 ))" | tee -a "$O"
}
echo "keep UFO test on screen for the next ~75 s..."
phase A "$fl" 1 0
phase B 0 1 0
phase C 0 0 0
phase D 0 0 1
restore; trap - EXIT
killall Dock 2>/dev/null
echo "restored: flip $fl, vblsync $vb, marks $mk; Dock restarted. Details: $O"
