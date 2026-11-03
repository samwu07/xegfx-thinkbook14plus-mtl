#!/bin/bash
# fb-check.sh -- which framebuffer WindowServer draws on, and which one the Intel accelerator and XeGfxAGDC drive.
# Read-only. Best run while the desktop is on the Intel GPU (after desktop-on.sh).
#
# Why (2026-11-02 16:43-16:54): WindowServer composited with Metal on the Intel GPU (GPUPass built, 128+ submissions,
# no failures), but the accelerator's display pipe never went active ("pipe 0 active(+0x298) = 0") and got 0 swaps,
# and AGDC reported no framebuffer ("id 0x1000004aa is under another PCI device", "id 0x1000004dc has no
# IOFBDependentIndex"). So every frame went through Apple's old CPU blit (layer_blit_byte_ANY) -- the lag.
# The panel has two IONDRVFramebuffers: one on UEFIGraphicsFB's platform "display" nub (no PCI parent), one on the
# iGPU. This shows which one WindowServer has open, which one the accelerator registered, and what AGDC sees.
#   sudo bash /Volumes/PKG/metal-stack/desktop/fb-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo (the kernel log needs it); it only reads" >&2; exit 2; }
R="$HERE/reports/fb-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
exec > >(tee "$R/fb-check.log") 2>&1

# every framebuffer with its ancestry (-t) and its children (user clients carry IOUserClientCreator)
ioreg -l -w0 -t -r -c IOFramebuffer -d 2 > "$R/framebuffers.txt" 2>&1
sysctl -a 2>/dev/null | grep -E '^debug\.(xegfx_agdc|xegfx_stage|nvaccelfb|nvaccel_heads|nvaccel_iop_(ok|fail|empty|flips|copy_us)|nmxaccel_headless)' > "$R/sysctls.txt"
system_profiler SPDisplaysDataType > "$R/displays.txt" 2>&1
kmutil showloaded --list-only 2>/dev/null | grep -i -E 'UEFIGraphicsFB|NMIntelFB|XeGfx|NDRV|IOGraphics' > "$R/kexts.txt"
log show --last 30m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS "AGDC" OR eventMessage CONTAINS "found_framebuffer" OR eventMessage CONTAINS "registerFramebuffer" OR eventMessage CONTAINS "initFramebufferResource" OR eventMessage CONTAINS "GATES" OR eventMessage CONTAINS "UEFIGraphicsFB" OR eventMessage CONTAINS "NMIntelFB" OR eventMessage CONTAINS "boot framebuffer")' > "$R/kernel.txt" 2>&1
pgrep -x WindowServer > "$R/windowserver-pid.txt"

echo "== framebuffers (ancestry, then who has them open)"
# the tree lines of each framebuffer and its user clients, plus the properties that tell them apart
grep -E '\+-o |"IOUserClientCreator"|"IOFBDependent(ID|Index)"|"AAPL,boot-display"|"IOFBIsMainDisplay"|"IOFramebufferOpenGLIndex"|"IOAccelIndex"|"IOFBCurrentPixelCount"' \
  "$R/framebuffers.txt" | cut -c1-200
echo
echo "== accelerator and AGDC"
cat "$R/sysctls.txt"
grep -h -E "slot table|found_framebuffer|registerFramebuffer\(|GATES after|initFramebufferResource|boot framebuffer" "$R/kernel.txt" \
  | sed -E 's/^[0-9-]+ ([0-9:.]+) .*\) /\1 /' | awk '!seen[$0]++' | tail -14 | cut -c1-200
echo
echo "== NMIntelFB"
if [ -e /Library/Extensions/NMIntelFB.kext ]; then echo "in /Library/Extensions: yes"; else echo "in /Library/Extensions: no"; fi
kmutil inspect -a x86_64 -A /Library/KernelCollections/AuxiliaryKernelExtensions.kc 2>/dev/null | grep -F com.nullmoth.NMIntelFB > /dev/null \
  && echo "in the auxiliary collection: YES (it loads at every boot: sudo bash $HERE/remove-nmintelfb.sh)" || echo "in the auxiliary collection: no"
grep -F NMIntelFB "$R/kexts.txt" > /dev/null && echo "loaded now: yes" || echo "loaded now: no"
for v in nmintelfb-step nmintelfb-step-prev nmintelfb-starts; do printf '%s: %s\n' "$v" "$(nvram "$v" 2>/dev/null | cut -f2- || echo '(none)')"; done
sync
echo
echo "Reports: $R -- tell me when it is there."
