#!/bin/bash
# test-metal.sh -- first Metal test on the Intel GPU, after install-metal.sh, a restart, and
#   sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7      (stage 7 hands the GPU to XeGfxAccel)
# Builds upstream's userland/tools/mtlprobe.m (v0.0.47) once, then runs it with NM_TEST_PLUGIN: the plugin is loaded
# into mtlprobe only, on the NMXAccel service. mtlprobe compiles an MSL compute kernel, fills a buffer on the GPU and
# checks it on the CPU, then draws; exit 0 only when the values are right.
#   bash /Volumes/PKG/metal-stack/install/test-metal.sh        (your normal user, no sudo)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" != 0 ] || { echo "run without sudo" >&2; exit 2; }
R="$HERE/reports/metal-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
PL=/Library/XeGfx/metal/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
SRC=$HOME/src/WTLIntelGfx/userland/tools/mtlprobe.m
B=$HOME/src/XeGfx-build/mtlprobe/mtlprobe          # the name matters: the plugin admits a process called mtlprobe

# tested as you: mtlprobe loads the plugin with your permissions, so "exists for root" is not enough
if [ ! -r "$PL" ]; then
  ls -ld /Library/XeGfx /Library/XeGfx/metal /Library/XeGfx/metal/NVMTLDriver.bundle \
         /Library/XeGfx/metal/NVMTLDriver.bundle/Contents /Library/XeGfx/metal/NVMTLDriver.bundle/Contents/MacOS "$PL" 2>&1 \
    | tee "$R/plugin-permissions.txt"
  if sudo -n true 2>/dev/null || [ -e /Library/XeGfx/metal/NVMTLDriver.bundle ]; then
    echo "The plugin is installed but your user cannot read it. Fix:  sudo chmod -R a+rX /Library/XeGfx/metal" >&2
  else
    echo "plugin not installed: sudo bash $HERE/install-metal.sh" >&2
  fi
  exit 2
fi
if ! ioreg -r -c NMXAccel -d 1 | grep NMXAccel > /dev/null; then   # no -q: SIGPIPE + pipefail
  echo "no NMXAccel service yet: run  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7  first" >&2; exit 2
fi
if [ ! -x "$B" ]; then
  [ -f "$SRC" ] || { echo "missing $SRC (metal-stack 1-fetch.sh)" >&2; exit 2; }
  mkdir -p "$(dirname "$B")"
  xcrun clang -fobjc-arc -O1 -mmacosx-version-min=15.0 -framework Foundation -framework Metal -framework IOKit \
    "$SRC" -o "$B" > "$R/mtlprobe-build.txt" 2>&1 || { cat "$R/mtlprobe-build.txt"; exit 3; }
fi
rm -f /tmp/nvmtl.log 2>/dev/null
echo "== mtlprobe (plugin $PL)"
NM_TEST_PLUGIN="$PL" "$B" 2>&1 | tee "$R/mtlprobe.txt"
rc=${PIPESTATUS[0]}
cp /tmp/nvmtl.log "$R/" 2>/dev/null
ioreg -l -w0 -r -c NMXAccel > "$R/ioreg-NMXAccel.txt" 2>&1
sysctl -b debug.xegfx_log > "$R/xegfx-log.txt" 2>&1
log show --last 5m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "nmx" OR eventMessage CONTAINS[c] "xegfx" OR eventMessage CONTAINS[c] "drm")' > "$R/kernel-log.txt" 2>&1
sync
echo
echo "mtlprobe exit $rc  (0 = Metal compute and draw verified on the Intel GPU)"
echo "Reports: $R"
