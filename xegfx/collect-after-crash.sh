#!/bin/bash
# collect-after-crash.sh -- run after a restart that followed an XeGfx stage panic or freeze:
#   sudo bash /Volumes/PKG/xegfx/collect-after-crash.sh
# The unified log survives the restart, so the crashed boot's XeGfx messages are still readable. Read-only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo:  sudo bash $0" >&2; exit 2; }
OUT="$HERE/reports/crash-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
log show --last 3h --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "xegfx" OR eventMessage CONTAINS[c] "drm" OR eventMessage CONTAINS[c] "i915" OR eventMessage CONTAINS[c] "panic")' > "$OUT/kernel-xegfx-3h.txt" 2>&1
log show --last 3h --style compact --predicate 'process == "kernel"' | tail -6000 > "$OUT/kernel-3h-tail.txt" 2>&1
ls -la /Library/Logs/DiagnosticReports/ > "$OUT/diagnostic-reports.txt" 2>&1
for f in $(ls -t /Library/Logs/DiagnosticReports/*.panic /Library/Logs/DiagnosticReports/Retired/*.panic 2>/dev/null | head -3); do cp "$f" "$OUT/"; done
for v in xegfx-step xegfx-step-prev; do nvram "$v"; done > "$OUT/nvram-breadcrumbs.txt" 2>&1
sync
echo "done: $(ls "$OUT" | wc -l | tr -d ' ') files in $OUT"
