#!/bin/bash
# collect-windowserver.sh [START] [END] -- after WindowServer crashed on the Intel GPU: copies its crash reports
# (.ips: crashed thread + the library it died in) and watchdog spins, and the unified log for the window START..END
# (default: the 2026-11-02 13:24-13:33 crash loop): everything WindowServer said, every NVMTL (plugin) line, and the
# kernel's accelerator / AGDC / IOPresentment / IOAccel lines. Read-only.
#   sudo bash /Volumes/PKG/metal-stack/desktop/collect-windowserver.sh
#   sudo bash /Volumes/PKG/metal-stack/desktop/collect-windowserver.sh "2026-11-02 15:00:00" "2026-11-02 15:10:00"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo (crash reports are root-only); it only reads" >&2; exit 2; }
START=${1:-2026-11-02 13:24:00}; END=${2:-2026-11-02 13:33:00}
R="$HERE/reports/wscrash-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
day=$(echo "$START" | cut -c1-10)
for f in /Library/Logs/DiagnosticReports/WindowServer*"$day"* /Library/Logs/DiagnosticReports/Retired/WindowServer*"$day"*; do
  [ -f "$f" ] && cp "$f" "$R/"
done
ls -la "$R" > "$R/files.txt"
log show --start "$START" --end "$END" --style compact --predicate 'process == "WindowServer"' > "$R/windowserver.txt" 2>&1
log show --start "$START" --end "$END" --style compact --predicate 'eventMessage CONTAINS "NVMTL"' > "$R/nvmtl.txt" 2>&1
log show --start "$START" --end "$END" --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "nmx" OR eventMessage CONTAINS[c] "agdc" OR eventMessage CONTAINS[c] "IOPresent" OR eventMessage CONTAINS[c] "IOAccel" OR eventMessage CONTAINS[c] "xegfx" OR eventMessage CONTAINS[c] "watchdog")' > "$R/kernel.txt" 2>&1
log show --start "$START" --end "$END" --style compact --predicate 'process == "launchd" AND eventMessage CONTAINS "WindowServer"' > "$R/launchd.txt" 2>&1
sync
printf '%s\n' "crash reports: $(ls "$R" | grep -c -E '\.ips$')  spins: $(ls "$R" | grep -c -E '\.spin$')" \
  "log lines: WindowServer $(wc -l < "$R/windowserver.txt"), NVMTL $(wc -l < "$R/nvmtl.txt"), kernel $(wc -l < "$R/kernel.txt")"
echo "Saved to $R -- tell me when it is there."
