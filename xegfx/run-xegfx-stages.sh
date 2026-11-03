#!/bin/bash
# run-xegfx-stages.sh [TARGET] -- load XeGfx (idle) and run its stages one at a time up to TARGET (default 2),
# saving the driver log, results and probe dictionaries to disk after EVERY stage, and stopping at the first failure.
#   sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 2     read-only probe (registers, panel's GGTT entry, pipe A)
#   sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 4     + i915 init with ALL display code skipped, then checks the
#                                                           panel still scans out the same memory ("display lost")
#   sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 6     + first GPU work on every engine, GPU->CPU memory check
#   sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7     + hand the GPU to the Metal accelerator (XeGfxAccel from
#                                                           metal-stack/install/install-metal.sh must be installed)
# Stages that already ran this boot are skipped by the kext. A stage that stalls longer than the watchdog (60 s)
# panics on purpose; the Mac then restarts without XeGfx. Run collect-after-crash.sh after such a restart.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET=${1:-2}
[ "$(id -u)" = 0 ] || { echo "run with sudo:  sudo bash $0 $TARGET" >&2; exit 2; }
[ ! -e /Library/Extensions/XeGfx.kext ] || { echo "XeGfx.kext is in /Library/Extensions (the auxiliary-collection route that froze the Mac): run rescue-xegfx.sh first" >&2; exit 2; }
case "$TARGET" in [1-7]) ;; *) echo "TARGET must be 1..7" >&2; exit 2 ;; esac
if [ "$TARGET" = 7 ] && [ ! -d /Library/Extensions/XeGfxAccel.kext ]; then
  echo "stage 7 hands the GPU to XeGfxAccel, which is not installed: sudo bash /Volumes/PKG/metal-stack/install/install-metal.sh" >&2; exit 2
fi
OUT="$HERE/reports/stages-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
# debug.xegfx_results is opaque (8 x int32, per stage: 0 not run, 1 pass, negative errno); plain `sysctl` prints nothing.
# A failed stage leaves debug.xegfx_stage below it, and writing a higher value runs that stage AGAIN: for stage 4 that
# re-initialises i915 on top of the first instance (2026-11-01: four i915 instances, band on the panel). So the script
# checks the stage counter after every write and never re-runs a stage that failed this boot.
results() { sysctl -b debug.xegfx_results 2>/dev/null | od -An -v -t d4 | tr -s ' \n' ' ' | sed 's/^ //'; }
snap() {   # $1 = label; everything is written and synced before the next stage can hang the machine
  echo "per-stage result s0..s7: $(results)" > "$OUT/$1-results.txt"
  sysctl -b debug.xegfx_log > "$OUT/$1-xegfx-log.txt" 2>&1
  ioreg -l -w0 -r -c XeGfxResident > "$OUT/$1-ioreg-XeGfxResident.txt" 2>&1
  pgrep -x WindowServer > "$OUT/$1-windowserver-pid.txt" 2>&1
  sync
}
{ sw_vers; sysctl -n machdep.cpu.brand_string kern.bootargs; csrutil status
  # FbRelocate.efi's load-time verdict, if an old CLEAN-07F/07G is booted (UTF-16, volatile UEFI variable)
  nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:fbreloc-load | sed 's/%00//g'; } > "$OUT/system.txt" 2>&1
# exact id: XeGfx is not XeGfxAccel. No grep -q: it stops reading early, kmutil dies of SIGPIPE, pipefail says "not loaded"
loaded() { kmutil showloaded --list-only 2>/dev/null | grep -E "$1 \(" > /dev/null; }
# The boot framebuffer must be out of i915's GuC area before stage 4 (WTLIntelGfx issue #13). XgFbMove.kext
# (metal-stack/install) moves it from macOS, once, before XeGfx is loaded; it replaced FbRelocate.efi.
if [ -d /Library/Extensions/XgFbMove.kext ]; then
  if loaded 'org\.watchthelight\.XeGfx'; then
    echo "XeGfx is already loaded in this boot, so XgFbMove is not run (it only moves before XeGfx)"
  elif ! loaded 'org\.local\.XgFbMove'; then
    echo "moving the boot framebuffer out of the GuC area (XgFbMove)..."
    kmutil load -b org.local.XgFbMove > "$OUT/xgfbmove-load.txt" 2>&1 || { cat "$OUT/xgfbmove-load.txt"; echo "XgFbMove load failed" >&2; exit 1; }
  fi
  ioreg -l -w0 -r -c IOPCIDevice | grep -o '"xgfbmove-result" = "[^"]*"' | head -1 | tee "$OUT/xgfbmove.txt"
fi
if ! loaded 'org\.watchthelight\.XeGfx'; then
  echo "loading XeGfx (idle)..."
  kmutil load -b org.watchthelight.XeGfx > "$OUT/kmutil-load.txt" 2>&1 || { cat "$OUT/kmutil-load.txt"; echo "load failed -- is OpenCore CLEAN-07Y (XeGfx via Kernel/Add) deployed and the Mac restarted?" >&2; exit 1; }
fi
sysctl -w debug.xegfx_wdog=60 > /dev/null 2>&1 || true
snap stage0
read -r -a R <<< "$(results)"
[ "${#R[@]}" = 8 ] || { echo "cannot read debug.xegfx_results: $(cat "$OUT/stage0-results.txt")" >&2; exit 1; }
for i in 1 2 3 4 5 6 7; do
  if [ "${R[$i]}" -lt 0 ]; then
    echo "stage $i already FAILED this boot (result ${R[$i]}). Restart before running stages again." >&2; exit 1
  fi
done
# Where the firmware's framebuffer sits in the GGTT (upstream issue #13): i915 maps the GuC image at GUC_GGTT_TOP
# 0xFEE00000 (2 MiB slot), and stage 4 refuses (-28) a framebuffer that starts below 0xFEE00000 and ends above it.
# Read from the newest stage report that has stage 2's probe (by stage number: exFAT times can tie; stage 0/1 have it
# when stage 2 ran in an earlier run this boot).
fbplace() {
  local f="" n; for n in 7 6 5 4 3 2 1 0; do f="$OUT/stage$n-ioreg-XeGfxResident.txt"; grep '"plane-surf-1-a"=' "$f" > /dev/null 2>&1 && break; f=""; done
  [ -n "$f" ] || return
  local surf size psz; surf=$(sed -nE 's/.*"plane-surf-1-a"=([0-9]+).*/\1/p' "$f" | head -1)
  size=$(sed -nE 's/.*"boot-fb-size"=([0-9]+).*/\1/p' "$f" | head -1); psz=$(sed -nE 's/.*"plane-size-1-a"=([0-9]+).*/\1/p' "$f" | head -1)
  [ -n "$surf" ] && [ -n "$size" ] || return
  surf=$(echo "$surf % 4294967296" | bc); local end=$((surf + size)) top=$((0xFEE00000)) slot=$((0xFF000000))
  printf 'boot framebuffer: %dx%d, GGTT 0x%08X - 0x%08X (%d KiB)\n' $(( (psz & 0xFFFF) + 1 )) $(( ((psz >> 16) & 0xFFFF) + 1 )) "$surf" "$end" $((size / 1024))
  if [ "$surf" -lt "$top" ] && [ "$end" -gt "$top" ]; then echo "  -> crosses 0xFEE00000: stage 4 would refuse it (-28) and the GuC image would show as a band"
  elif [ "$surf" -lt "$slot" ] && [ "$end" -gt "$top" ]; then echo "  -> inside the GuC slot 0xFEE00000-0xFF000000: stage 4 would pass but the band would still appear"
  else echo "  -> clear of the GuC slot: stage 4 should pass without a band"; fi
}
DONE=$(sysctl -n debug.xegfx_stage)
for s in $(seq 1 "$TARGET"); do
  if [ "$s" -le "$DONE" ]; then echo "=== stage $s: passed earlier this boot ==="; continue; fi
  # 2026-11-02 15:09/15:15: XgFbMove refused (-5), the stages went on, and stage 4 loaded the GuC into the panel's
  # memory (the band). A framebuffer still in the GuC area now stops the run here, before i915 touches anything.
  if [ "$s" = 4 ]; then
    fbplace > "$OUT/fb-placement-before-stage4.txt"
    if grep -E '^  -> (crosses|inside)' "$OUT/fb-placement-before-stage4.txt" > /dev/null; then
      cat "$OUT/fb-placement-before-stage4.txt"
      echo "STOPPED before stage 4: the framebuffer was not moved out of the GuC area ($(sed -E 's/.*status (-?[0-9]+).*/XgFbMove status \1/' "$OUT/xgfbmove.txt" 2>/dev/null))." >&2
      echo "Stage 4 would draw the band. Nothing has been changed yet; send me $OUT, then restart." >&2
      break
    fi
  fi
  echo "=== stage $s ==="
  sync
  sysctl -w debug.xegfx_stage=$s > "$OUT/stage$s-sysctl.txt" 2>&1
  rc=$?
  snap "stage$s"
  DONE=$(sysctl -n debug.xegfx_stage)
  read -r -a R <<< "$(results)"
  if [ $rc -ne 0 ] || [ "$DONE" -lt "$s" ]; then
    echo "stage $s FAILED: result ${R[$s]:-?} (see $OUT/stage$s-*.txt). Stopping; restart before trying again." >&2
    tail -30 "$OUT/stage$s-xegfx-log.txt"
    break
  fi
  echo "stage $s passed"
done
fbplace | tee "$OUT/fb-placement.txt"
if [ "$TARGET" = 7 ]; then
  ioreg -l -w0 -r -c NMXAccel > "$OUT/ioreg-NMXAccel.txt" 2>&1
  if grep -q NMXAccel "$OUT/ioreg-NMXAccel.txt"; then echo "XeGfxAccel attached (NMXAccel service). Next: bash /Volumes/PKG/metal-stack/install/test-metal.sh"
  else echo "no NMXAccel service after stage 7 (see $OUT)"; fi
fi
log show --last 10m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "xegfx" OR eventMessage CONTAINS[c] "drm" OR eventMessage CONTAINS[c] "i915")' > "$OUT/kernel-log.txt" 2>&1
sync
echo
echo "Reports: $OUT"
echo "Look at the screen: if the panel went black or shows a band, say so -- that is what stage 4 checks for."
