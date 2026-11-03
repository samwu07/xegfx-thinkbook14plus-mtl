#!/bin/bash
# oc-boot-display.sh -- OpenCore experiment: make the Intel GPU (GFX0, PciRoot(0x0)/Pci(0x2,0x0)) own the boot display.
# Today the panel's framebuffer (.Display_boot) hangs off the firmware's "display" node, so GPUWrangler files it under a
# GPU-less placeholder (gpu 0x8000, vid ffff) and WindowServer composites the desktop with CompositorSW on the CPU.
# IONDRVSupport's boot driver (IOBootNDRV) attaches to the device marked AAPL,boot-display; marking GFX0 should put the
# panel under the Intel GPU, where its accelerator (NMXAccel) is, so WindowServer can choose CompositorMetal.
# Changes in EFI/OC/config.plist (backup first, next to it):
#   DeviceProperties/Add/PciRoot(0x0)/Pci(0x2,0x0): AAPL,boot-display = <01000000>, model = "Intel Arc Graphics"
#   NVRAM boot-args += xegfxaccel_gpufb=1   (the accelerator then keeps the GPU's own framebuffer as the panel)
#   sudo bash /Volumes/PKG/metal-stack/desktop/oc-boot-display.sh          then restart into OpenCore
#   sudo bash /Volumes/PKG/metal-stack/desktop/oc-boot-display.sh undo     puts the backup back
# Black screen at boot: rEFInd -> Windows -> work\deploy-sn750-clean07y.bat (your usual way back), or this "undo".
# A later deploy-sn750-*.bat from Windows overwrites this config.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
EFI=$(diskutil list | awk '/ EFI EFI /{print $NF; exit}')
[ -n "$EFI" ] || { echo "no EFI partition found"; exit 1; }
MNT=$(diskutil info "$EFI" | awk -F: '/Mount Point/{gsub(/^ +/,"",$2); print $2}')
if [ -z "$MNT" ]; then diskutil mount "$EFI" > /dev/null; MNT=$(diskutil info "$EFI" | awk -F: '/Mount Point/{gsub(/^ +/,"",$2); print $2}'); fi
CFG="$MNT/EFI/OC/config.plist"
[ -f "$CFG" ] || { echo "no $CFG"; ls "$MNT/EFI" 2>/dev/null; exit 1; }
BK="$CFG.before-boot-display"
if [ "${1:-}" = undo ]; then
  [ -f "$BK" ] || { echo "no backup $BK"; exit 1; }
  cp -p "$BK" "$CFG"; plutil -lint "$CFG"; echo "restored $CFG from the backup; restart"; exit 0
fi
[ -f "$BK" ] || cp -p "$CFG" "$BK"
/usr/bin/python3 -I - "$CFG" <<'EOF'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: c = plistlib.load(f)
dev = c.setdefault('DeviceProperties', {}).setdefault('Add', {}).setdefault('PciRoot(0x0)/Pci(0x2,0x0)', {})
dev['AAPL,boot-display'] = b'\x01\x00\x00\x00'
dev.setdefault('model', 'Intel Arc Graphics')
nv = c.setdefault('NVRAM', {})
guid = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
add = nv.setdefault('Add', {}).setdefault(guid, {})
args = add.get('boot-args', '')
if 'xegfxaccel_gpufb=' not in args: add['boot-args'] = (args + ' xegfxaccel_gpufb=1').strip()
dl = nv.setdefault('Delete', {}).setdefault(guid, [])
if 'boot-args' not in dl: dl.append('boot-args')   # so the new boot-args replace the ones stored in NVRAM
with open(p, 'wb') as f: plistlib.dump(c, f)
print('GFX0 properties:', {k: (v.hex() if isinstance(v, bytes) else v) for k, v in dev.items()})
print('boot-args:', add['boot-args'])
EOF
plutil -lint "$CFG"
echo "backup: $BK"
echo "Restart into OpenCore (the same entry as 07Y), run the stages to 7, then before desktop-on.sh:"
echo "  ioreg -l -w0 -r -c IONDRVFramebuffer | grep -E '^\\+-o|IOFBMemorySize|IOAccelTypes'"
echo "The framebuffer under GFX0@2 should now show IOFBMemorySize (the panel)."
