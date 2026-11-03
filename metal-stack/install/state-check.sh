#!/bin/bash
# state-check.sh -- READ-ONLY snapshot of everything the kernel collections depend on, before a restart:
# the auxiliary collection and any leftover .new files (with their kexts), /Library/Extensions, our backups,
# Apple's boot/system collections on the sealed volume and in Preboot (timestamps), what is loaded, the GPUBundles
# folder, and what kmutil / kernelmanagerd logged in the last 6 hours (the --update-all crash on 2026-11-02).
# Changes nothing.
#   sudo bash /Volumes/PKG/metal-stack/install/state-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo (Preboot is root-only); it only reads" >&2; exit 2; }
R="$HERE/reports/state-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
ids() { kmutil inspect -a x86_64 -A "$1" 2>&1 | awk -F'\t' 'NR <= 2 && !/^[a-z]+\./ {print "   " $0} /^[a-z]+\./ {print "   " $1 "\t" $2}'; }
{
  date; sw_vers; csrutil status | head -1; csrutil authenticated-root status 2>&1
  echo; echo "## /Library/KernelCollections"; ls -laT /Library/KernelCollections
  for f in /Library/KernelCollections/AuxiliaryKernelExtensions.kc*; do echo "## $f"; ids "$f"; done
  echo; echo "## /Library/Extensions"; ls -laT /Library/Extensions
  for k in /Library/Extensions/*.kext; do
    printf '   %-28s %s\n' "$(basename "$k")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$k/Contents/Info.plist" 2>&1)"
  done
  echo; echo "## /Library/XeGfx"; ls -laT /Library/XeGfx
  for t in last-backup.txt metal/backup.txt desktop/backup.txt; do printf '   %-20s %s\n' "$t" "$(cat "/Library/XeGfx/$t" 2>&1)"; done
  for b in /Library/XeGfx/backup-*; do
    [ -f "$b/AuxiliaryKernelExtensions.kc" ] || { echo "## $b: (no collection)"; continue; }
    echo "## $b  $(stat -f '%Sm %z B' "$b/AuxiliaryKernelExtensions.kc")"; ids "$b/AuxiliaryKernelExtensions.kc"
  done
  echo; echo "## /Library/GPUBundles"; ls -laT /Library/GPUBundles /Library/GPUBundles/nvmtl 2>&1
  echo; echo "## Apple's collections on the sealed system volume (read-only; must be untouched)"
  ls -laT /System/Library/KernelCollections
  echo "## Apple's boot collections in Preboot (what boot.efi loads)"
  ls -laT /System/Volumes/Preboot/*/boot/System/Library/KernelCollections 2>&1
  echo; echo "## loaded third-party kexts"; kmutil showloaded --list-only 2>&1 | grep -v -E 'com\.apple\.' | tail -n +1
  echo; echo "## kmutil / kernelmanagerd, last 6 h"
  log show --last 6h --style compact --predicate 'process == "kmutil" OR process == "kernelmanagerd"' 2>/dev/null \
    | grep -i -E 'error|fail|crash|segment|unable|writ|install|creat|collection|rebuild' | tail -120
  echo; echo "## kmutil crash reports"
  ls -laT /Library/Logs/DiagnosticReports 2>/dev/null | grep -i kmutil
  ls -laT /Users/*/Library/Logs/DiagnosticReports 2>/dev/null | grep -i kmutil
} > "$R/state.txt" 2>&1
for f in /Library/Logs/DiagnosticReports/kmutil* /Users/*/Library/Logs/DiagnosticReports/kmutil*; do [ -f "$f" ] && cp "$f" "$R/"; done
sync
grep -E '^## /Library/KernelCollections/|^   (org|com)\.' "$R/state.txt" | head -30
echo
echo "Read-only snapshot saved: $R/state.txt -- tell me when it is there."
