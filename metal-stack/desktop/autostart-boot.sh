#!/bin/bash
# autostart-boot.sh -- run by launchd at boot (org.local.xegfx-desktop, installed by autostart.sh as
# /Library/XeGfx/desktop/autostart-boot.sh): the Intel GPU desktop without typing the stages and desktop-on.sh by hand.
# It does nothing unless every condition holds, and a run that is not confirmed working blocks the next one:
#   - not Safe Mode, no boot-arg -xegfxnoauto, no /Library/XeGfx/desktop/autostart-off
#   - XeGfx is in this boot's kernel collection (OpenCore CLEAN-07Y); any other boot entry is left alone, before the
#     stages script could move the boot framebuffer (XgFbMove)
#   - the previous run was confirmed (nvram xegfx-auto-pending is not 1). A boot that hung, panicked or was ended with
#     the power button leaves it at 1: the next boot skips and turns autostart off (autostart.sh on to re-enable)
#   - nobody is logged in yet when desktop-on.sh would restart WindowServer (it would log them out)
# Confirmed = 3 minutes after the WindowServer restart, frames reach the panel (debug.nvaccel_iop_ok_h4 > 0) and the
# crash guard counted at most 1 WindowServer start. Log: /Library/XeGfx/desktop/autostart.log
PATH=/usr/bin:/bin:/usr/sbin:/sbin
D=/Library/XeGfx/desktop; L=$D/autostart.log; PKG=/Volumes/PKG/metal-stack/desktop
log() { echo "$(date '+%F %T') $*" >> "$L"; }
off() { touch "$D/autostart-off"; log "autostart switched OFF: $*  (re-enable: sudo bash $PKG/autostart.sh on)"; sync; exit 0; }
mkdir -p "$D"
# keep the log short: the last 400 lines
[ -f "$L" ] && tail -400 "$L" > "$L.tmp" 2>/dev/null && mv -f "$L.tmp" "$L"
log "boot $(sysctl -n kern.boottime | sed -E 's/.*\} //')"

[ -e "$D/autostart-off" ] && { log "off ($D/autostart-off exists): nothing done"; exit 0; }
[ "$(sysctl -n kern.safeboot 2>/dev/null)" = 1 ] && { log "Safe Mode: nothing done"; exit 0; }
case " $(sysctl -n kern.bootargs) " in *" -xegfxnoauto "*) log "boot-arg -xegfxnoauto: nothing done"; exit 0 ;; esac
# no grep -q after a pipe: pipefail/SIGPIPE (see run-xegfx-stages.sh)
if ! kmutil showloaded --show all --collection boot --list-only 2>/dev/null | grep -F 'org.watchthelight.XeGfx (' > /dev/null; then
  log "XeGfx is not in this boot's kernel collection (not CLEAN-07Y): nothing done"; exit 0
fi
if [ "$(nvram xegfx-auto-pending 2>/dev/null | cut -f2)" = 1 ]; then
  nvram xegfx-auto-pending=0
  off "the previous automatic start was never confirmed (a hang, a panic or a restart with the power button)"
fi

# the scripts live on PKG, which mounts some seconds into the boot
for i in $(seq 1 90); do [ -f "$PKG/desktop-on.sh" ] && break; sleep 2; done
[ -f "$PKG/desktop-on.sh" ] || { log "$PKG not mounted after 3 minutes: nothing done"; exit 0; }
# WindowServer must be up (desktop-on.sh restarts it) and nobody logged in yet
for i in $(seq 1 60); do pgrep -x WindowServer > /dev/null && break; sleep 2; done
# XeGfxIntelFB's framebuffer gets the panel (display0) only when WindowServer first opens it: 2026-11-03 13:12 the
# kext started at :40, display0 came at 13:13:02, desktop-on.sh checked at :45 and stopped. Wait for it (2 minutes).
for i in $(seq 1 60); do ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F 'display0' > /dev/null && break; sleep 2; done
ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F 'display0' > /dev/null || log "the panel did not reach XeGfxIntelFB's framebuffer in 2 minutes; desktop-on.sh will say why"
cu=$(stat -f %Su /dev/console 2>/dev/null)
# at the login window the console belongs to root or to WindowServer's own account (2026-11-03 08:19: "_windowserver was
# logged in" skipped a CLEAN-07Y boot); only a person's account counts
case "$cu" in ""|root|_windowserver|_*) ;; *) log "$cu was logged in before the start: skipped this boot (run desktop-on.sh by hand)"; exit 0 ;; esac

nvram xegfx-auto-pending=1
log "starting desktop-on.sh (stages included)"
before=$(ls -t "$PKG/reports" 2>/dev/null | grep '^on-' | head -1)
bash "$PKG/desktop-on.sh" > /dev/null 2>&1
rc=$?
R=$(ls -td "$PKG/reports"/on-* 2>/dev/null | head -1)
if [ $rc -ne 0 ] || [ "$(basename "$R")" = "$before" ]; then
  # desktop-on stops BEFORE the restart on any failed check: nothing changed, so the next boot may try again
  nvram xegfx-auto-pending=0
  log "desktop-on.sh stopped (exit $rc) before changing anything: $(grep '^desktop-on:' "$R/desktop-on.log" 2>/dev/null | tail -1)"
  exit 0
fi
log "switches set, WindowServer restarted; report $R"
sleep 180
frames=$(sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null); frames=${frames:-0}
# grep -c prints 0 itself when nothing matches (and exits 1): no "|| echo 0", which would make it "0 0"
starts=$(grep -c 'WindowServer start #' "$R/guard.log" 2>/dev/null); starts=${starts:-0}
if [ "${frames:-0}" -gt 0 ] && [ "${starts:-0}" -le 1 ]; then
  nvram xegfx-auto-pending=0
  log "confirmed: $frames frames on the panel, $starts WindowServer start(s)"
  # Zero-copy flip (XeGfxAccel 0.9.3, 2026-11-03 08:33: 602 flips, 0 copied), only on a confirmed desktop. Off for good
  # with /Library/XeGfx/desktop/xeflip-off, for one boot with boot-arg -xegfxnoflip. If WindowServer restarts or a frame
  # fails within a minute it goes off again and xeflip-off is written; frames are then copied as before.
  case " $(sysctl -n kern.bootargs) " in *" -xegfxnoflip "*) log "flip: boot-arg -xegfxnoflip, left off"; sync; exit 0 ;; esac
  [ -e "$D/xeflip-off" ] && { log "flip: $D/xeflip-off exists, left off"; sync; exit 0; }
  sysctl -n debug.nvaccel_xeflip_ggtt > /dev/null 2>&1 || { log "flip: XeGfxAccel older than 0.9.3 (no slot scan), left off"; sync; exit 0; }
  ws=$(pgrep -x WindowServer | head -1); f0=$(sysctl -n debug.nvaccel_iop_fail 2>/dev/null)
  sysctl -w debug.nvaccel_xeflip=1 > /dev/null 2>&1
  g=$(sysctl -n debug.nvaccel_xeflip_ggtt 2>/dev/null)
  case "$g" in
    [1-4]" slot(s)"*) log "flip ON: $g" ;;
    *) sysctl -w debug.nvaccel_xeflip=0 > /dev/null 2>&1; log "flip: no slot placed ($g), left off for this boot"; sync; exit 0 ;;
  esac
  sleep 60
  ws2=$(pgrep -x WindowServer | head -1); f1=$(sysctl -n debug.nvaccel_iop_fail 2>/dev/null)
  fl=$(sysctl -n debug.nvaccel_xeflip_flips 2>/dev/null); cp=$(sysctl -n debug.nvaccel_xeflip_copied 2>/dev/null)
  if [ "$ws2" != "$ws" ] || [ "${f1:-0}" != "${f0:-0}" ]; then
    sysctl -w debug.nvaccel_xeflip=0 > /dev/null 2>&1; touch "$D/xeflip-off"
    log "flip switched OFF for later boots: WindowServer $ws -> ${ws2:-none}, frame failures ${f0:-?} -> ${f1:-?} (rm $D/xeflip-off to allow it again)"
  else
    log "flip confirmed: ${fl:-0} flipped, ${cp:-0} copied in the first minute"
  fi
else
  nvram xegfx-auto-pending=0
  off "not confirmed after 3 minutes: $frames frames on the panel, $starts WindowServer start(s) (report $R)"
fi
sync
