#!/bin/bash
# desktop-on.sh -- this boot only: hand the desktop to the Intel GPU. Every switch below is a runtime write that a
# restart undoes, so a black or frozen screen is fixed by holding the power button.
#   1. XeGfx stages 1-7 (XgFbMove first), unless they already ran   -> XeGfxAccel attached
#   2. sysctl debug.xegfx_agdc=1   our AppleGraphicsDeviceControl on the iGPU (IOPresentment's display pipe)
#   3. sysctl debug.nvaccelfb=1     register the boot framebuffer (IONDRVFramebuffer) with the accelerator; arms it
#   4. sysctl debug.nvaccelfb=3     open the scanout-backed display pipe and deliver the mode change
#  4b. sysctl debug.nvaccel_iop=1   accept WindowServer's frames (display-pipe transactions); IOP=0 skips it
#   5. checks; only if they pass: restart WindowServer (you are logged out; log in again)
# The order and levels are read from the accelerator and AGDC sources (upstream's own test harness is private).
#   sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh            save your work first
# After logging in again:  bash /Volumes/PKG/metal-stack/desktop/desktop-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
R="$HERE/reports/on-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
exec > >(tee "$R/desktop-on.log") 2>&1
die() { echo "desktop-on: $*"; echo "Nothing was restarted; the desktop is as it was. Reports: $R"; sync; exit 1; }
klog() { log show --last "${1:-2m}" --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "nvaccel" OR eventMessage CONTAINS[c] "agdc" OR eventMessage CONTAINS[c] "nmx" OR eventMessage CONTAINS[c] "framebuffer")' 2>/dev/null; }
[ -f /Library/XeGfx/desktop/backup.txt ] && [ -d /Library/GPUBundles/NVMTLDriver.bundle ] || die "phase 2 is not installed (install-desktop.sh)"
# 2026-11-02: without an AIR bitcode reader CoreDisplay's shaders translated to nothing and WindowServer crashed 14 times
# (then the watchdog panicked). add-bitcode-reader.sh installs a reader and records which one passed CoreDisplay's probe.
GP=/Library/XeGfx/desktop/gpupass-ok
[ -f "$GP" ] || die "CoreDisplay's shaders have not passed the probe yet: run the stages to 7, then sudo bash $HERE/add-bitcode-reader.sh"
READER=$(sed -n 's/^reader=//p' "$GP")
case "$READER" in
  in-process) [ -f /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib ] \
                || die "$GP says libLLVM, but the system plugin has none: sudo bash $HERE/add-bitcode-reader.sh" ;;
  air-opt)    [ -x /Library/GPUBundles/nvmtl/air-opt ] || die "$GP says air-opt, but /Library/GPUBundles/nvmtl/air-opt is gone"
              echo "reader: air-opt -- WindowServer will start it for every new shader (not tested inside WindowServer yet)" ;;
  *)          die "$GP is from an older add-bitcode-reader.sh: sudo bash $HERE/add-bitcode-reader.sh" ;;
esac

# WindowServer first, and every entry only once armed: "*" or a plain name would hand the Intel GPU to apps in any boot
# that runs stage 7. Extra "!App" lines are kept (2026-11-03: Terminal drew no text without a Metal device once the
# accelerator was up); anything else -- "*", plain names, the guard's "-WindowServer" -- puts the list back.
AL=/Library/GPUBundles/nvmtl-allow.txt
ENTRIES=$(grep -v '^[[:space:]]*#' "$AL" 2>/dev/null | grep -v '^[[:space:]]*$' | tr -d ' \t')
if [ "$(printf '%s\n' "$ENTRIES" | head -1)" != '!WindowServer' ] || printf '%s\n' "$ENTRIES" | grep -v -E '^![A-Za-z0-9._ -]+$' | grep . > /dev/null; then
  echo "allow-list was: $(printf '%s ' $ENTRIES)-> back to !WindowServer"
  printf '# Intel GPU (XeGfx) Metal plugin: which processes get the Intel Metal device.\n# "!name" = only once the accelerator is armed (debug.nvaccelfb reads 1).\n!WindowServer\n' > "$AL"
  chmod 644 "$AL"
else
  echo "allow-list: $(printf '%s ' $ENTRIES)"
fi

echo "== 1. stages"
if [ "$(sysctl -n debug.xegfx_stage 2>/dev/null)" != 7 ]; then
  bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7 || die "the stages did not reach 7"
fi
[ "$(sysctl -n debug.xegfx_stage 2>/dev/null)" = 7 ] || die "debug.xegfx_stage is not 7"
# grep without -q reads everything: `| grep -q` under pipefail fails whenever the left side is still writing (SIGPIPE)
ioreg -r -c NMXAccel -d 1 | grep NMXAccel > /dev/null || die "no NMXAccel service"
kmutil showloaded --list-only 2>/dev/null | grep -F "org.watchthelight.XeGfxAGDC (" > /dev/null || die "XeGfxAGDC is not loaded (restart after install-desktop.sh?)"
echo "headless: $(sysctl -n debug.nmxaccel_headless 2>/dev/null) (0 = the Intel GPU owns the panel, as it should)"
# 2026-11-03 00:17: XeGfxIntelFB's boot guard had declined (xeintelfb-starts 2: its clear at 120 s uptime was lost to a
# held power button), the panel was back on UEFIGraphicsFB's framebuffer, and this ran for nothing. XEINTELFB=0 skips it.
if [ "${XEINTELFB:-1}" = 1 ] && ! ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F 'display0' > /dev/null; then
  die "the panel is not on XeGfxIntelFB's framebuffer (nvram xeintelfb-starts = $(nvram xeintelfb-starts 2>/dev/null | cut -f2); 2 or more = its boot guard declined). Reset it with  sudo nvram xeintelfb-starts=%00  and restart"
fi
# this boot got this far with it, so the guard's count goes back to 0 now, written where a held power button cannot lose it
[ "${XEINTELFB:-1}" = 1 ] && nvram xeintelfb-starts=%00 2>/dev/null

echo "== 2. AGDC up"
sysctl -w debug.xegfx_agdc=1 || die "sysctl debug.xegfx_agdc=1 failed"
for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(sysctl -n debug.xegfx_agdc)" = 1 ] && break; sleep 0.5; done
[ "$(sysctl -n debug.xegfx_agdc)" = 1 ] || { klog 2m > "$R/kernel-agdc.txt"; grep -i "agdc" "$R/kernel-agdc.txt" | tail -6
  die "AGDC did not come up: debug.xegfx_agdc = $(sysctl -n debug.xegfx_agdc) (<0 = failed step; kernel log in $R/kernel-agdc.txt)"; }

# 2026-11-03 00:28: WindowServer bound the Intel GPU to GFX0's framebuffer and started its Metal compositor, then asked
# AGDC for the display link (0x921) four times, got Unsupported, logged "capabilities when none exist" / "No plane
# indices" and never sent a frame. AGDC answers 0x921 (and the plane-scaler 0x711) only with K5 on. With XeGfxIntelFB
# 0.9.3 the answer carries the panel's EDID timing (NVRMTiming); without it, upstream's 2560x1600 panel. K5=0 skips it.
echo "== 2b. AGDC link answers (K5)"
if [ "${K5:-1}" = 1 ]; then
  ioreg -r -c XeGfxIntelFramebuffer -l -d 1 | grep -F '"NVRMTiming"' > /dev/null \
    || echo "note: GFX0's framebuffer has no NVRMTiming (XeGfxIntelFB older than 0.9.3): AGDC will describe a 2560x1600 panel"
  sysctl -w debug.xegfx_agdc_k5=1 || die "sysctl debug.xegfx_agdc_k5=1 failed"
else
  echo "K5=0: left at $(sysctl -n debug.xegfx_agdc_k5)"
fi

echo "== 3. register the boot framebuffer"
sysctl -w debug.nvaccelfb=1 || die "sysctl debug.nvaccelfb=1 failed"
sleep 1
klog 1m > "$R/kernel-after-fb1.txt"
grep -E "registerFramebuffer|framebuffer count|found_framebuffer|boot framebuffer|armed|-> pipe" "$R/kernel-after-fb1.txt" | tail -8

echo "== 4. scanout pipe"
sysctl -w debug.nvaccelfb=3 || die "sysctl debug.nvaccelfb=3 failed"
sleep 1
klog 1m > "$R/kernel-after-fb3.txt"
grep -E "scanout|display pipe|mode change|level 3|armed|-> pipe" "$R/kernel-after-fb3.txt" | tail -6
# the accelerator reads 1 (armed) only once a framebuffer got a display pipe; without it the allow-list's
# "!WindowServer" refuses WindowServer, so restarting it would just come back on the software path
[ "$(sysctl -n debug.nvaccelfb)" = 1 ] || die "the accelerator is not armed (debug.nvaccelfb = $(sysctl -n debug.nvaccelfb)): no framebuffer got a display pipe; see $R/kernel-after-fb*.txt"

# 2026-11-02 23:50: with GFX0's framebuffer online (XeGfxIntelFB 0.9.2) WindowServer sent its frames as display-pipe
# transactions, and all 45 came back 0xe00002c7: performTransaction refuses while debug.nvaccel_iop is 0, its default,
# and nothing here had set it. WindowServer then crashed twice in a CPU blit and the watchdog panicked. IOP=0 skips it.
# 2026-11-03 14:55: with XeGfxAccel 0.9.4 + the plugin's 'XGDR' marks, WindowServer stopped waiting for its composites
# (the ~30 frames/s cap), but 305 swaps timed out waiting for a ready mark and the Dock vanished until it was restarted.
# The cause was the plugin's release order (it looked NVAccelSurfaceWait up as NVAccel only; fixed 16:1x: 3 timeouts in 60
# s). With XeGfxIntelFB 0.9.4's VBL the marks take the desktop to ~60 frames/s (16:5x: 497 of 616 frame gaps at one
# refresh, 2 timeouts), so they are on by default since then. WSMARK=0 keeps WindowServer's own wait (~30 frames/s).
echo "== 4a. WindowServer completion marks"
if [ "${WSMARK:-1}" = 1 ]; then
  sysctl -w debug.nvaccel_surface_gpu_on=1 2>/dev/null || echo "no debug.nvaccel_surface_gpu_on (XeGfxAccel before 0.9.4)"
else
  sysctl -w debug.nvaccel_surface_gpu_on=0 2>/dev/null || true
  echo "WSMARK=0: off (WindowServer waits for each composite itself, ~30 frames/s)"
fi
echo "== 4b. frame transactions"
if [ "${IOP:-1}" = 1 ]; then
  sysctl -w debug.nvaccel_iop=1 || die "sysctl debug.nvaccel_iop=1 failed"
  [ "$(sysctl -n debug.nvaccel_iop)" = 1 ] || die "debug.nvaccel_iop did not stay 1"
else
  echo "IOP=0: left at $(sysctl -n debug.nvaccel_iop) (frames will be refused)"
fi

{ sysctl debug.nvaccelfb debug.nvaccel_iop debug.xegfx_agdc debug.xegfx_agdc_k5 debug.nmxaccel_headless debug.xegfx_stage 2>&1
  ioreg -l -w0 -r -c NMXAccel; ioreg -l -w0 -r -c IONDRVFramebuffer; } > "$R/state-before-restart.txt" 2>&1
klog 10m > "$R/kernel-10m.txt"
sync
# Crash-loop guard, detached (it outlives this Terminal and the logout): if WindowServer starts more than twice in the
# next 10 minutes it is crashing on the Intel GPU, so the allow-list goes to deny-all and the next WindowServer comes up
# on the software path -- before launchd's crash loop runs into the 120 s userspace watchdog (the 13:41 panic).
# 10, not 3: on 2026-11-02 the crashes came at 2.5 and 3.2 min, after a 3-minute guard had ended (23:56 panic).
G="$R/guard.log"
cat > "$R/guard.sh" <<'EOF'
#!/bin/bash
AL=/Library/GPUBundles/nvmtl-allow.txt; G=$1; last=$(pgrep -x WindowServer | head -1); starts=0
echo "$(date +%T) guard up, WindowServer pid $last" >> "$G"
echo "time validate perform complete iop_ok iop_ok_h4 iop_fail iop_empty flips k5_link k5_caps k5_why" > "$(dirname "$G")/counters.log"
C="$(dirname "$G")/counters.log"
for i in $(seq 1 600); do
  # 2026-11-03 00:08: with nvaccel_iop=1 the panel kept the boot console text and the log showed no transaction at all;
  # these say afterwards whether WindowServer sent frames (pipe_perform) and whether they reached the panel (iop_ok_h4)
  [ $((i % 5)) = 1 ] && { printf '%s ' "$(date +%T)"; sysctl -n debug.nvaccel_pipe_validate debug.nvaccel_pipe_perform debug.nvaccel_pipe_complete \
    debug.nvaccel_iop_ok debug.nvaccel_iop_ok_h4 debug.nvaccel_iop_fail debug.nvaccel_iop_empty debug.nvaccel_iop_flips debug.xegfx_agdc_k5_link debug.xegfx_agdc_k5_caps debug.xegfx_agdc_k5_why 2>/dev/null | tr '\n' ' '; echo; } >> "$C"
  sleep 1; now=$(pgrep -x WindowServer | head -1)
  if [ -n "$now" ] && [ "$now" != "$last" ]; then starts=$((starts + 1)); echo "$(date +%T) WindowServer start #$starts (pid $now)" >> "$G"; last=$now; fi
  if [ $starts -gt 2 ]; then
    printf '# disarmed by the desktop-on crash-loop guard %s: WindowServer restarted %d times\n-WindowServer\n' "$(date)" $starts > "$AL"
    echo "$(date +%T) CRASH LOOP: allow-list set to -WindowServer; the next WindowServer runs on the software path" >> "$G"; sync; exit 0
  fi
done
echo "$(date +%T) guard done: $starts WindowServer start(s) in 10 minutes" >> "$G"; sync
EOF
nohup bash "$R/guard.sh" "$G" > /dev/null 2>&1 < /dev/null &
disown

echo
echo "All switches set. WindowServer restarts in 10 s: the screen goes dark, then the login window. Log in and run"
echo "  bash /Volumes/PKG/metal-stack/desktop/desktop-check.sh"
echo "A crash-loop guard runs for 10 minutes: if WindowServer keeps crashing it switches the Intel GPU off for it."
echo "If the screen still stays black or frozen for over 2 minutes: hold the power button; a restart undoes this."
sleep 10
sync
old=$(pgrep -x WindowServer | head -1)
killall WindowServer
sleep 5
# 13:2x: a plain killall did not replace WindowServer for you; launchd's own restart does
[ "$(pgrep -x WindowServer | head -1)" != "$old" ] || launchctl kickstart -k system/com.apple.WindowServer
