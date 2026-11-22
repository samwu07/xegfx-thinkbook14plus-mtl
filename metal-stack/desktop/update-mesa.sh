#!/bin/bash
# update-mesa.sh -- puts the rebuilt libvulkan_intel.dylib (out/GPUBundles/nvmtl) in /Library/GPUBundles/nvmtl with that
# folder's install names. The old one stays next to it as libvulkan_intel.dylib.prev. Nothing is restarted: WindowServer
# keeps the file it mapped until it next starts (log out and in).
#   sudo bash /Volumes/PKG/metal-stack/desktop/update-mesa.sh
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
NEW=/Volumes/PKG/metal-stack/out/GPUBundles/nvmtl/libvulkan_intel.dylib; D=/Library/GPUBundles/nvmtl; L=$D/libvulkan_intel.dylib
[ -f "$NEW" ] || { echo "no $NEW"; exit 1; }
[ -f "$L" ] || { echo "no $L: the desktop is not installed"; exit 1; }
cp -p "$L" "$L.prev"
cp "$NEW" "$L.new"; xattr -c "$L.new"
OLD=$(otool -L "$L.new" | awk '/libdrm\.2\.dylib/{print $1; exit}')
install_name_tool -id "$L" "$L.new" 2>/dev/null
[ "$OLD" = "$D/libdrm.2.dylib" ] || install_name_tool -change "$OLD" "$D/libdrm.2.dylib" "$L.new" 2>/dev/null
codesign -s - -f "$L.new" > /dev/null 2>&1 || { echo "codesign FAILED, nothing changed"; rm -f "$L.new"; exit 1; }
otool -L "$L.new" | grep -q "$D/libdrm.2.dylib" || { echo "libdrm path wrong, nothing changed"; rm -f "$L.new"; exit 1; }
chown root:wheel "$L.new"; chmod 755 "$L.new"; mv -f "$L.new" "$L"
echo "updated $L ($(shasum -a 256 "$L" | cut -c1-12)); to undo: sudo mv $L.prev $L"
