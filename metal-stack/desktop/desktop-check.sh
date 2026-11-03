#!/bin/bash
# desktop-check.sh -- after desktop-on.sh and logging in again: is WindowServer compositing on the Intel GPU?
# Collects the evidence to /Volumes/PKG/metal-stack/desktop/reports/check-<time> and prints a verdict.
#   bash /Volumes/PKG/metal-stack/desktop/desktop-check.sh      (no sudo needed)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/reports/check-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
WS=$(pgrep -x WindowServer | head -1)
stat_of() { ioreg -l -w0 -r -c NMXAccel | grep -o "\"$1\"=[0-9]*" | head -1 | cut -d= -f2; }
{ echo "WindowServer pid: $WS  started: $(ps -o lstart= -p "$WS" 2>/dev/null)"
  sysctl debug.nvaccelfb debug.xegfx_agdc debug.xegfx_agdc_cmds debug.nmxaccel_headless debug.xegfx_stage 2>&1; } | tee "$R/summary.txt"
s1=$(stat_of bufferSwapCount); f1=$(stat_of bufferFlipCount); c1=$(stat_of contextGLCount)
sleep 5
s2=$(stat_of bufferSwapCount); f2=$(stat_of bufferFlipCount)
echo "accelerator: swaps ${s1:-?} -> ${s2:-?}, flips ${f1:-?} -> ${f2:-?} in 5 s, GL/Metal contexts ${c1:-?}" | tee -a "$R/summary.txt"
ioreg -l -w0 -r -c NMXAccel > "$R/ioreg-NMXAccel.txt" 2>&1
log show --last 15m --style compact --predicate 'eventMessage CONTAINS "NVMTL"' > "$R/nvmtl-15m.txt" 2>&1
log show --last 15m --style compact --predicate 'process == "WindowServer" AND (eventMessage CONTAINS[c] "metal" OR eventMessage CONTAINS[c] "device" OR eventMessage CONTAINS[c] "accelerat")' > "$R/windowserver-15m.txt" 2>&1
log show --last 15m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "nvaccel" OR eventMessage CONTAINS[c] "agdc" OR eventMessage CONTAINS[c] "nmx")' > "$R/kernel-15m.txt" 2>&1
system_profiler SPDisplaysDataType > "$R/displays.txt" 2>&1
grep -E "Chipset|Metal|Resolution|Refresh|UI Looks" "$R/displays.txt" | tee -a "$R/summary.txt"
# only the WindowServer running now: an earlier one (before desktop-on.sh armed the accelerator) was refused, as it should be
WSLOG="$R/nvmtl-windowserver-$WS.txt"; grep -F "WindowServer[$WS:" "$R/nvmtl-15m.txt" > "$WSLOG"
ws_allowed=$(grep -c -E "allow-listed: WindowServer" "$WSLOG")
ws_denied=$(grep -c -E "no device for WindowServer|denied by list: WindowServer" "$WSLOG")
old_denied=$(grep -E "no device for WindowServer|denied by list: WindowServer" "$R/nvmtl-15m.txt" | grep -v -c -F "WindowServer[$WS:")
echo "plugin log, WindowServer $WS: allow-listed $ws_allowed time(s), refused $ws_denied time(s) (earlier WindowServers refused: $old_denied)" | tee -a "$R/summary.txt"
# Metal on Vulkan never moves bufferSwapCount/bufferFlipCount (those count the accelerator's own GL swaps), so the frames
# are judged from the plugin: CoreDisplay's GPUPass pipeline built, the screen surface bound, and GPU work submitted. The
# plugin logs its submit count at powers of two only, so this is "how far it got", not a per-5-s rate.
ws_parts=$(grep -o -E "commit: G-SUB [0-9]+ parts submitted" "$WSLOG" | awk '{print $3}' | sort -n | tail -1); ws_parts=${ws_parts:-0}
ws_pass=$(grep -c -E "newRenderPipelineStateWithDescriptor: -> 0x[0-9a-f]+ \(VkPipeline from [0-9]+\+10928 B" "$WSLOG")
ws_screen=$(grep -o -E "surface [0-9]+ [0-9]+x[0-9]+ pitch [0-9]+ -> an image in the surface's own pages" "$WSLOG" | head -1)
ws_failed=$(grep -E "FAILED|nvk-reason:|device lost|GPU hang|timed out" "$WSLOG" | grep -v -e "0 prologues failed" -e "land here as" -c)
echo "plugin, WindowServer $WS: GPUPass pipeline $([ "$ws_pass" -gt 0 ] && echo built || echo NOT built), screen surface: ${ws_screen:-none seen}, GPU work submitted >= $ws_parts part(s), failures $ws_failed" | tee -a "$R/summary.txt"
[ "$ws_failed" -gt 0 ] && grep -E "FAILED|nvk-reason:|device lost|GPU hang|timed out" "$WSLOG" | grep -v -e "0 prologues failed" -e "land here as" | sed -E 's/^.*NVMTL: //' | awk '!seen[$0]++' | head -5
sync
echo
if [ "$ws_allowed" -gt 0 ] && [ -n "${s2:-}" ] && [ -n "${s1:-}" ] && [ "$s2" -gt "$s1" ]; then
  echo "VERDICT: WindowServer has the Intel Metal device and the accelerator is presenting frames."
elif [ "$ws_allowed" -gt 0 ] && [ "$ws_pass" -gt 0 ] && [ -n "$ws_screen" ] && [ "$ws_parts" -ge 64 ] && [ "$ws_failed" = 0 ]; then
  echo "VERDICT: WindowServer is compositing on the Intel GPU (Metal on Vulkan: pipelines built, screen surface bound, GPU work flowing, no failures)."
elif [ "$ws_allowed" -gt 0 ]; then
  echo "VERDICT: WindowServer got the Intel Metal device, but the plugin log does not show it drawing cleanly yet -- send me the report."
else
  echo "VERDICT: WindowServer did not take the Intel GPU (still the software path) -- send me the report."
fi
echo "Reports: $R"
