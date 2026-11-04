Metal stack, phase 2: the desktop on the Intel GPU (ThinkBook 14+ 155H, macOS 15.8.1, OpenCore CLEAN-07Y)

Needs phase 1 installed (install-metal.sh) and mtlprobe passing (it did, 2026-11-02).

Persistent part (inert in any boot where you do not run the stages):
  XeGfxAGDC.kext       auxiliary kernel collection; loads at boot but idle until desktop-on.sh switches it on
  NVMTLDriver.bundle   /Library/GPUBundles, system-wide
  nvmtl-allow.txt      /Library/GPUBundles: "!WindowServer" -- only WindowServer, and only once armed
Not installed: NMIntelFB. Over XeGfx the accelerator drives Apple's own boot framebuffer (IONDRVFramebuffer, which this
Mac uses) by copying finished frames into it. NMIntelFB would not change that: it scans out the same console memory, the
accelerator's zero-copy flip is NVIDIA-only, and XeGfxAGDC only reports IONDRVFramebuffer-class framebuffers. Installed
by hand on 2026-11-02 18:57 it stopped the boot at its "step 5 frame counter" (its "BAR2 window" line is informational).
  Take it out again:  sudo bash /Volumes/PKG/metal-stack/desktop/remove-nmintelfb.sh   (normal boot or CLEAN-07S)
Desktop slow although WindowServer is on the Intel GPU (16:43: Metal compositing worked, but 0 swaps reached the
accelerator and AGDC reported no framebuffer):  sudo bash /Volumes/PKG/metal-stack/desktop/fb-check.sh
  Cause (upstream I-108): CoreDisplay reads the GPU vendor from the framebuffer's class name; plain IONDRVFramebuffer
  is "no vendor", so IOPresentment is off and WindowServer blits every frame with the CPU. Upstream's fix is
  XeGfxIntelFB (IONDRVFramebuffer under an Intel class name, plus EDID, refresh, HiDPI):
  sudo bash /Volumes/PKG/metal-stack/desktop/install-xeintelfb.sh      (uninstall: ... install-xeintelfb.sh uninstall)
  2026-11-02 21:54, XeGfxIntelFB 0.9 installed: still 0 swaps. GPUWrangler took GFX0/XeGfxIntelFramebuffer as the Intel
  GPU's framebuffer but "Failed to open connection to framebuffer": it is the same dead IONDRVFramebuffer GFX0 always
  had (power state 0, no modes), because the GOP framebuffer (phys 0x7a800000, stolen memory) is in neither GFX0 BAR.
  WindowServer fell back to UEFIGraphicsFB's .Display_boot again. XeGfxIntelFB 0.9.1 (8-xeintelfb.sh, patch in
  metal-stack/xeintelfb) adds the console range to GFX0's device memory first; its log line "IONDRVFramebuffer start
  ok, name .Display_boot" means GFX0 came online. Boot-arg -xeintelfbnovram turns that part off.
  23:02, with 0.9.1: GFX0's framebuffer came online (it is .Display_boot now, with display0; the firmware one is left
  without a display), but the panel showed a white wallpaper, no terminal text and lag while screenshots were right,
  and still 0 swaps. XeGfxAccel kept head 4 on the firmware framebuffer ("... is on the GPU, but head 4 is already the
  firmware framebuffer ... not taken"), which is now dead ("getPixelInformation for framebuffer 0 failed"), and AGDC
  left GFX0's out ("no IOFBDependentIndex"). Fixes: XeGfxAccel 0.9.2 (7-xeflip.sh + xeflip/gpufb.patch) gives head 4
  to the framebuffer that has display0; XeGfxIntelFB 0.9.2 (8-xeintelfb.sh) sets IOFBDependentID/Index on GFX0's.
  2026-11-03 00:28: GPUWrangler bound the Intel GPU to GFX0's framebuffer and WindowServer's Metal compositor came up on
  it, but CoreDisplay's link query to AGDC (0x921) was refused 4 times ("capabilities when none exist", "No plane
  indices") and 0 frames were sent. AGDC answers 0x921 only with K5 on (debug.xegfx_agdc_k5=1, now desktop-on step 2b),
  and XeGfxIntelFB 0.9.3 gives it the panel's EDID timing (NVRMTiming: 3072x1920, 387.84 MHz, 60.000 Hz) instead of
  upstream's 2560x1600 165 Hz default. Also: holding the power button can leave xeintelfb-starts at 2 (its 120 s clear
  is lost), and the next boot declines XeGfxIntelFB; desktop-on now checks for that and resets the count.
  2026-11-03 00:48: WORKING -- 1972 frames through the Intel display pipe to the panel, 0 fails, no crash.
  Apps without a Metal device draw nothing in places once the accelerator is up: Terminal showed no text ("not
  allow-listed: no device for Terminal", Core Image "No Metal renderer available"); started with NVMTL_ENABLE=1 it did.
  Fix: one armed-only line per app in /Library/GPUBundles/nvmtl-allow.txt, e.g.
    echo '!Terminal' | sudo tee -a /Library/GPUBundles/nvmtl-allow.txt        then quit and reopen the app
  desktop-on keeps such "!App" lines (it resets "*", plain names and the guard's "-WindowServer"). To try an app first:
    open -n -a <App> --env NVMTL_ENABLE=1

Zero-copy flip, 2026-11-03 01:09 (xeflip.sh try): 0 flips, 351 copied, reason -5 then -4 -- all four fixed slots at GGTT
  0x50000000 read as in use. ggtt-map.py / ggtt-peek.py (read-only, through debug.nvaccel_mmio_win) showed why: this
  i915 never clears the GGTT, so everything outside i915's objects (bottom, top near 0xFEE00000) and the screen
  (0x80000000, entries 0x800003...) is stale random memory, and "all one scratch value" never holds. XeGfxAccel 0.9.3
  (7-xeflip.sh): switching the flip on scans for ranges with no real entry (or all scratch), slots nearest 0xB8000000;
  debug.nvaccel_xeflip_ggtt shows the slots and a map. Build in a boot without the stages (autostart: -xegfxnoauto).
  2026-11-03 08:33, 0.9.3: WORKS -- 602 frames flipped, 0 copied, 0 fails in the 30 s trial; slots b6800000 b8000000
  b5000000 b9800000; mapping a new surface ~13 ms (once per surface, 3 surfaces), latch 4-10 ms. In that boot the holes
  WERE cleared (scratch 20000872390001, map mostly '.'); the 01:09 boot had stale data. 0.9.3 takes either.

Autostart (2026-11-03): every CLEAN-07Y boot runs the stages and desktop-on.sh by itself.
  sudo bash /Volumes/PKG/metal-stack/desktop/autostart.sh on      from the next boot     (off / status likewise)
  LaunchDaemon org.local.xegfx-desktop -> /Library/XeGfx/desktop/autostart-boot.sh, log /Library/XeGfx/desktop/autostart.log
  It does nothing in Safe Mode, with boot-arg -xegfxnoauto, with /Library/XeGfx/desktop/autostart-off, or in a boot
  whose kernel collection has no XeGfx (any entry but CLEAN-07Y). A run counts as good after 3 minutes with frames on
  the panel and at most one WindowServer start; a boot that starts with the previous run unconfirmed (hang, panic, power
  button) skips and switches autostart off (autostart.sh on to re-enable). If you are logged in before it is ready it
  skips that boot rather than restart WindowServer under you: at the login window wait for the one dark flash.
  First automatic boot 2026-11-03 08:30: confirmed at 08:34 with 2395 frames. Since then, after the confirmation, it
  also switches the zero-copy flip on (needs XeGfxAccel 0.9.3), and turns it off for later boots (xeflip-off) if
  WindowServer restarts or a frame fails in the first minute. Skip the flip once: boot-arg -xegfxnoflip.

Known issue (2026-11-03 08:45): window sidebars (behind-window blur, "vibrancy") show see-through on the Intel GPU; not the
  flip (it was off). System Settings > Accessibility > Display > Reduce transparency makes them solid (confirmed), so the
  blur passes (CoreAnimation's downsample_blur_* / narrow_blur_* through NVMTL) are the suspects. Workaround: keep it on.

Known issues (2026-11-03 15:2x, screenshots): desktop widgets in the full-colour desktop mode (no app in front) get
  octagonal corners -- straight 45-degree cuts where the rounded corner should be; with an app in front the same widgets
  are rounded. In the Weather app: opaque black boxes behind sidebar text, bright cyan where a translucent material
  should be. An off-screen CARenderer test on the Intel device (cornerRadius, continuous corners, masksToBounds, shape
  and layer masks, 7 variants) renders correct arcs, so these are WindowServer-only shader variants mistranslated by
  NVMTL (a straight cut = |x|+|y| where sqrt(x*x+y*y) belongs). Not fixed.
30 frames/s, found (2026-11-03 16:3x): WindowServer composites on a 30 Hz beat. fps-vbl.sh: 27/28/28/28 frames/s with
  flip on, copy at vblank, copy at once, + marks -- the present path is not it; fps-now.sh while dragging a window (no
  browser): max 30; fps-gaps: 324 of 398 frame gaps 30-34 ms, 7 at 15-19 ms. The boot NDRV under XeGfxIntelFB has no VBL
  interrupt, so IOFramebuffer runs its 30 Hz stand-in (IOFBWaitCursorPeriod 33333333). XeGfxIntelFB 0.9.4 (8-xeintelfb.sh)
  registers a VBL source driven by pipe A's frame counter (58.5 Hz); boot-arg -xeintelfbnovbl turns it off.
  Result 2026-11-03 16:5x, fps-gaps while dragging: 0.9.3 7 gaps at 15-19 ms / 324 at 30-34; 0.9.4 (VBL 58.17 Hz from the
  frame counter) 154 / 175; 0.9.4 + the marks (debug.nvaccel_surface_gpu_on=1) 497 / 51 of 616, 2 timeouts, 0 fails:
  ~58-60 frames/s. Since then the marks are ON by default in desktop-on.sh (and so in autostart); WSMARK=0 turns them off,
  at run time: sudo sysctl -w debug.nvaccel_surface_gpu_on=0.
Known limit (2026-11-03 14:2x): the desktop runs at ~30 frames/s (UFO test 30 fps in Safari and Edge).
  fps-ab.sh: 29 / 28 / 29 frames/s with the flip on / off / on -- not the present path. Edge with the GPU: 22. WindowServer
  ~72 % CPU. sample (reports/ws-sample.txt): ws_main_thread 41 % in CompositorMetal::composite -> MetalContext::Flush ->
  -[NVMTLCommandBuffer commitAndWaitUntilSubmitted] -> waitUntilCompleted: WindowServer waits for every composite to
  FINISH on the GPU, so CPU and GPU take turns. The plugin skips that wait only when the kernel takes WindowServer's
  completion marks (nvmtl_ws_kernel_waits); the marks go through nvmtl_nvk_surface_dirty, which only NVIDIA's NVK
  exports -- ANV has none, so debug.nvaccel_surface_gpu_marks stays 0 and the log says "waiting for each composite here".
  Fix (written 2026-11-03, not yet booted): the marks go on the accelerator's 'XGDR' connection, which WindowServer
  already uses for ANV's DRM ioctls. XeGfxAccel 0.9.4 (7-xeflip.sh + xeflip/wsmark.patch): selector 1 (surface, pending)
  -> nvSurfGpuEscape. Plugin (9-wsmark-plugin.sh + xeflip/wsmark-plugin.patch): uses it when the Vulkan driver has no NVK
  escape. Either half alone changes nothing (0.9.3 answers selector 1 with bad argument, checked live). Check after
  boot: debug.nvaccel_surface_gpu_marks counting, WindowServer log "the swap waits in NVAccel". Off again without a
  rebuild: sudo sysctl -w debug.nvaccel_surface_gpu_on=0 (the plugin re-asks every second).
  2026-11-03 14:55, booted: the marks work (WindowServer: "the swap waits in NVAccel", 14777 marks) but 305 swaps timed
  out at 100 ms waiting for a ready mark and the Dock vanished; marks off + killall Dock brought it back. Suspect: a
  pending hold that is never released (the plugin counts holds per surface and marks ready only when the count reaches
  0), or a frame shown before the GPU finished and carried forward. desktop-on.sh now keeps them OFF; WSMARK=1 tries
  them. Next: log the surface ID on each timeout (kernel) and the hold count per surface (plugin).
  Diagnostics written: XeGfxAccel 0.9.5 (pend / ready / ready_late counters, debug.nvaccel_surface_gpu_timeout_ids, the
  first 32 timeouts logged with their surface) and the plugin (commit-to-release time per composite, 5 s summaries of
  open holds). Test in a running desktop: sudo bash desktop/wsmark-test.sh (60 s with the marks on, then off again).
  Result 2026-11-03 15:44 (reports/wsmark-20261103-154406): timeouts 116 = late ready marks 116, open holds 3 on 2
  surfaces throughout -- no leak; the composites finish, but late: 251 of 1830 over 50 ms (86-135 ms typical, worst 562
  ms), frames to the panel 20-28/s with the marks (29 without). So the cap is the cost of a composite itself (~34 ms when
  WindowServer waits for each one); the marks only queue more of them. Keep them off. Next question: GPU execution time
  vs the plugin's CPU work per composite (copies, one submit per managed upload, completion latency).
  Frame breakdown written (plugin, 9-wsmark-plugin.sh): per WindowServer composite commit -> GPU start, GPU span (device
  timestamps over all parts), GPU end -> completion, parts per composite; 5 s summaries "WindowServer frames (5 s)" and
  the first 8 over 50 ms. Works with the marks off. Read: log show --last 5m --predicate 'eventMessage CONTAINS
  "WindowServer frame"'.
  Result 2026-11-03 16:00 (marks off, UFO test): ~84 WindowServer command buffers/s, each 3.4-3.8 ms = commit->GPU 1.5 +
  GPU 1.7 + done 0.3; ~3 per frame at 28 frames/s. The main thread is busy 23 % (sample): ~8 ms CPU + ~11-14 ms waiting
  for its command buffers one by one = ~22 ms per frame > 16.7 ms, so every second refresh is missed: 60 -> 30. The GPU
  does ~5 ms per frame. With the marks the waits go, but the swap waits for a mark INSIDE the transaction while the
  plugin releases it only after publishing, which needs the accelerator: that is the 100 ms timeout (116 = 116). The
  plugin's early order (release first) needs NVAccelSurfaceWait, which NMXAccel publishes but the plugin looked up as
  NVAccel only ("marked newest after the GPU finishes"). Fixed in wsmark-plugin.patch (NMXAccel too); only matters with
  the marks on. Test again: WSMARK via wsmark-test.sh.

Zero-copy flip (XeGfxAccel 0.9.1, local addition; metal-stack/xeflip): instead of copying each composited frame (22.5
MiB) into the boot framebuffer, the panel scans WindowServer's surface itself: its pages are mapped into a GGTT slot
once and PLANE_SURF is pointed at the slot, latched at vblank. Off by default; needs frames reaching the accelerator
(debug.nvaccel_iop_ok_h4 counting up, i.e. XeGfxIntelFB in place).
  build:    bash /Volumes/PKG/metal-stack/7-xeflip.sh          (a boot where the stages have not run)
  install:  sudo bash /Volumes/PKG/metal-stack/install/update-kext.sh XeGfxAccel     then restart, stages 7, desktop-on
  test:     sudo bash /Volumes/PKG/metal-stack/desktop/xeflip.sh try     (30 s, then off by itself)
  keep on:  sudo bash /Volumes/PKG/metal-stack/desktop/xeflip.sh on      (until restart; `off` to stop)
  If a frame cannot be flipped it is copied as before (debug.nvaccel_xeflip_last_why says why). After 1 s without
  frames the last frame is copied into the boot framebuffer and that is shown again, so a WindowServer exit never
  leaves a frozen picture. Caveat: while a frame is flipped, a kernel panic's text goes to the boot framebuffer,
  which is not on screen until the restart (the report is saved as always).

Steps:
  1. CLEAN-07Y:   sudo bash /Volumes/PKG/metal-stack/desktop/install-desktop.sh     then restart (done 2026-11-02)
  2. sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7
  3. sudo bash /Volumes/PKG/metal-stack/desktop/add-bitcode-reader.sh
       installs the AIR bitcode reader the plugin needs for CoreDisplay's precompiled shaders (missing on 2026-11-02:
       14 WindowServer crashes, then a watchdog panic) and proves it in mtlprobe on those exact shaders, once per
       reader: run A = libLLVM in the plugin only, run B = /Library/GPUBundles/nvmtl/air-opt only.
       A PASS of either unlocks step 4 (the file gpupass-ok names which). To test air-opt alone:
       sudo bash /Volumes/PKG/metal-stack/desktop/add-bitcode-reader.sh --air-opt-only
  4. log in, save your work and close apps, then:  sudo bash /Volumes/PKG/metal-stack/desktop/desktop-on.sh
       AGDC up (debug.xegfx_agdc) -> register the framebuffer -> scanout pipe -> checks -> crash-loop guard ->
       WindowServer restart. If a check fails it stops BEFORE the restart and nothing changes.
  5. log in again:  bash /Volumes/PKG/metal-stack/desktop/desktop-check.sh
  After any WindowServer trouble:  sudo bash /Volumes/PKG/metal-stack/desktop/collect-windowserver.sh "START" "END"

Every switch in step 4 lasts only until the next restart. If WindowServer keeps crashing, the crash-loop guard switches
the Intel GPU off for it within seconds. Black or frozen screen for over 2 minutes: hold the power button; the next
boot is your normal desktop (nothing of this starts by itself).

Refresh rate: the panel runs at the rate the firmware set at boot. XeGfx keeps i915's display code off (it never
mode-sets), and the stage 4 check measured 6 frames per 100 ms = 60 Hz. 120 Hz would need mode-setting, which no
XeGfx release does. This phase is about compositing on the GPU, not the refresh rate.

Undo:  sudo bash /Volumes/PKG/metal-stack/desktop/uninstall-desktop.sh                then restart
       from Recovery: bash /Volumes/PKG/metal-stack/desktop/uninstall-desktop.sh "/Volumes/MAC - Data"
Reports land in /Volumes/PKG/metal-stack/desktop/reports.
