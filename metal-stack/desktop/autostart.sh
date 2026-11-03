#!/bin/bash
# autostart.sh on|off|status -- start the Intel GPU desktop by itself in every CLEAN-07Y boot (stages + desktop-on.sh),
# with the guards of autostart-boot.sh: CLEAN-07Y only, one unconfirmed run turns it off, never logs anyone out.
#   sudo bash /Volumes/PKG/metal-stack/desktop/autostart.sh on        takes effect at the next boot (not now)
#   sudo bash /Volumes/PKG/metal-stack/desktop/autostart.sh off       removes the LaunchDaemon
#   bash /Volumes/PKG/metal-stack/desktop/autostart.sh status
# One boot without it, any boot entry: add -xegfxnoauto to the boot-args in OpenCore's boot picker, or boot Safe Mode.
# The zero-copy flip follows once the desktop is confirmed; -xegfxnoflip skips only that, /Library/XeGfx/desktop/xeflip-off for good.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D=/Library/XeGfx/desktop; LBL=org.local.xegfx-desktop; PL=/Library/LaunchDaemons/$LBL.plist
case "${1:-status}" in
  status)
    if [ -f "$PL" ]; then echo "autostart: installed ($PL)"; else echo "autostart: not installed"; fi
    [ -e "$D/autostart-off" ] && echo "  switched OFF by its guard or by you ($D/autostart-off): sudo bash $0 on"
    echo "  nvram xegfx-auto-pending: $(nvram xegfx-auto-pending 2>/dev/null | cut -f2) (1 = a run is unconfirmed)"
    if [ -e "$D/xeflip-off" ]; then echo "  zero-copy flip at boot: OFF ($D/xeflip-off; sudo rm it to allow it again)"
    else echo "  zero-copy flip at boot: on, after the desktop is confirmed (boot-arg -xegfxnoflip skips it once)"; fi
    echo "  flip now: $(sysctl -n debug.nvaccel_xeflip 2>/dev/null || echo -), flipped $(sysctl -n debug.nvaccel_xeflip_flips 2>/dev/null || echo -) of $(sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null || echo -) frames to the panel"
    echo "  last log lines:"; tail -6 "$D/autostart.log" 2>/dev/null | sed 's/^/    /' || true
    ;;
  on)
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
    [ -f "$HERE/autostart-boot.sh" ] && [ -f "$HERE/desktop-on.sh" ] || { echo "missing $HERE/autostart-boot.sh or desktop-on.sh" >&2; exit 1; }
    bash -n "$HERE/autostart-boot.sh" || { echo "autostart-boot.sh has a syntax error" >&2; exit 1; }
    mkdir -p "$D"
    install -o root -g wheel -m 755 "$HERE/autostart-boot.sh" "$D/autostart-boot.sh"
    cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LBL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$D/autostart-boot.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LaunchOnlyOnce</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$D/autostart-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$D/autostart-launchd.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PL"; chmod 644 "$PL"
    plutil -lint "$PL" > /dev/null || { rm -f "$PL"; echo "the plist did not validate; nothing installed" >&2; exit 1; }
    rm -f "$D/autostart-off"; nvram xegfx-auto-pending=0
    echo "autostart is ON from the next boot. In a CLEAN-07Y boot it runs the stages and desktop-on.sh by itself;"
    echo "at the login window the screen goes dark once (WindowServer restart) -- log in after that."
    echo "Not started now (that would restart WindowServer under you). Log: $D/autostart.log"
    echo "Off for one boot: boot-arg -xegfxnoauto or Safe Mode. Off for good: sudo bash $0 off"
    ;;
  off)
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
    launchctl bootout system/$LBL 2>/dev/null || true
    rm -f "$PL" "$D/autostart-boot.sh"; nvram -d xegfx-auto-pending 2>/dev/null || true
    echo "autostart is OFF (LaunchDaemon removed). The manual way still works: stages, then desktop-on.sh."
    ;;
  *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
