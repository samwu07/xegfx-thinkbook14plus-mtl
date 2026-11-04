#!/bin/bash
# wsmark-test.sh [SECONDS] -- WindowServer's completion marks (XeGfxAccel 0.9.5 + the plugin from 9-wsmark-plugin.sh) on
# for SECONDS (default 60) in a running Intel desktop, then off again; keep an animation (UFO test) on screen meanwhile.
# Records every 5 s: frames to the panel, pending / ready / late-ready marks, timeouts and the surfaces they hit; then the
# kernel's and WindowServer's diagnostic lines. Restarts the Dock at the end (it vanished with the marks on 2026-11-03).
# Late ready marks close to the timeouts = composites finish after 100 ms (a queue that grows); timeouts piling up on one
# surface with few late marks and a growing hold count = a hold the plugin never releases.
#   sudo bash /Volumes/PKG/metal-stack/desktop/wsmark-test.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
SECS=${1:-60}
sysctl -n debug.nvaccel_surface_gpu_ready_late > /dev/null 2>&1 || { echo "no debug.nvaccel_surface_gpu_ready_late: XeGfxAccel 0.9.5 is not running" >&2; exit 1; }
O="$(cd "$(dirname "$0")" && pwd)/reports/wsmark-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$O"
was=$(sysctl -n debug.nvaccel_surface_gpu_on); t0=$(date '+%Y-%m-%d %H:%M:%S')
c() { sysctl -n debug.nvaccel_iop_ok_h4 debug.nvaccel_surface_gpu_pend debug.nvaccel_surface_gpu_ready debug.nvaccel_surface_gpu_ready_late \
      debug.nvaccel_surface_gpu_timeouts debug.nvaccel_surface_gpu_wait_max_us 2>/dev/null | tr '\n' ' '; }
echo "time frames/s pend ready late timeouts wait_max_us | timeout ids" > "$O/counters.txt"
sysctl -w debug.nvaccel_surface_gpu_on=1 > /dev/null
echo "marks ON for $SECS s -- keep UFO test on screen..."
read -r f0 _ <<< "$(c)"
for i in $(seq 5 5 "$SECS"); do
  sleep 5; read -r f p r l t w <<< "$(c)"
  echo "$(date +%T) $(( (f - f0) / 5 )) $p $r $l $t $w | $(sysctl -n debug.nvaccel_surface_gpu_timeout_ids)" | tee -a "$O/counters.txt"
  f0=$f
done
sysctl -w debug.nvaccel_surface_gpu_on=$was > /dev/null
echo "marks back to $was"
sleep 2
log show --start "$t0" --style compact --predicate '(process == "kernel" AND eventMessage CONTAINS "surface marks:") OR (process == "WindowServer" AND (eventMessage CONTAINS "WindowServer marks" OR eventMessage CONTAINS "frame completion"))' \
  2>/dev/null > "$O/log.txt"
grep -c 'no ready mark' "$O/log.txt" | xargs echo "kernel timeout lines:"
grep -E 'WindowServer marks: [0-9]+ composites' "$O/log.txt" | tail -2 | sed -E 's/.*NVMTL: //'
killall Dock 2>/dev/null; echo "Dock restarted (it redraws everything)"
sync
echo "Report: $O"
