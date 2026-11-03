#!/bin/bash
# update-plugin.sh -- puts the rebuilt NVMTLDriver (out/GPUBundles) into both installed bundles, keeping everything else
# in them (air-runtime, Info.plist). The old binary stays next to it as NVMTLDriver.prev. Nothing is restarted.
#   sudo bash /Volumes/PKG/metal-stack/desktop/update-plugin.sh
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
NEW=/Volumes/PKG/metal-stack/out/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
[ -f "$NEW" ] || { echo "no $NEW"; exit 1; }
for B in /Library/XeGfx/metal/NVMTLDriver.bundle /Library/GPUBundles/NVMTLDriver.bundle; do
  [ -d "$B" ] || { echo "skip $B (not installed)"; continue; }
  M=$B/Contents/MacOS
  cp -p "$M/NVMTLDriver" "$M/NVMTLDriver.prev"
  cp "$NEW" "$M/NVMTLDriver.new" && xattr -c "$M/NVMTLDriver.new"
  chown root:wheel "$M/NVMTLDriver.new"; chmod 755 "$M/NVMTLDriver.new"; mv -f "$M/NVMTLDriver.new" "$M/NVMTLDriver"
  codesign -s - -f "$B" > /dev/null 2>&1 || { echo "codesign FAILED on $B -- restoring"; mv -f "$M/NVMTLDriver.prev" "$M/NVMTLDriver"; exit 1; }
  echo "updated $B ($(shasum -a 256 "$M/NVMTLDriver" | cut -c1-12))"
done
echo "Next: sudo bash /Volumes/PKG/metal-stack/desktop/add-bitcode-reader.sh"
