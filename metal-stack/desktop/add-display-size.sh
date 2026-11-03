#!/bin/bash
# add-display-size.sh -- tells macOS the built-in panel's real size. The boot framebuffer (.Display_boot) has no EDID, so
# macOS sees vendor "unkn" (0x756e6b6e), product 0x717, no physical size, assumes 72 dpi and shows 3072x1920 as 50.3".
# This writes a display override with the ThinkBook 14+ panel's size: 14.5" 16:10 = 312 x 195 mm. Nothing else changes.
#   sudo bash /Volumes/PKG/metal-stack/desktop/add-display-size.sh            then log out and in (or restart)
# Undo: sudo rm -rf /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-756e6b6e
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
VID=$(ioreg -l -w0 -r -c AppleDisplay | sed -n 's/.*"DisplayVendorID" = \([0-9]*\).*/\1/p' | head -1)
PID=$(ioreg -l -w0 -r -c AppleDisplay | sed -n 's/.*"DisplayProductID" = \([0-9]*\).*/\1/p' | head -1)
[ "$VID" = 1970170734 ] && [ "$PID" = 1815 ] || { echo "display is vendor ${VID:-?} product ${PID:-?}, not the EDID-less boot panel (1970170734/1815): nothing written"; exit 1; }
D=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-756e6b6e
mkdir -p "$D"
cat > "$D/DisplayProductID-717" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DisplayProductName</key>
	<string>Built-in Display</string>
	<key>DisplayVendorID</key>
	<integer>1970170734</integer>
	<key>DisplayProductID</key>
	<integer>1815</integer>
	<key>DisplayHorizontalImageSize</key>
	<integer>312</integer>
	<key>DisplayVerticalImageSize</key>
	<integer>195</integer>
</dict>
</plist>
EOF
chown -R root:wheel /Library/Displays; chmod 644 "$D/DisplayProductID-717"
plutil -lint "$D/DisplayProductID-717"
echo "written: $D/DisplayProductID-717 (312 x 195 mm = 14.5\"). Log out and back in for System Settings to show it."
