Metal stack for XeGfx on the ThinkBook 14+ 155H (8086:7D55), macOS 15.8.1 -- BUILD ONLY, nothing is installed.

Before building: boot OpenCore CLEAN-07A (Windows: work\deploy-sn750-clean07a.bat) -- no XeGfx, no FbRelocate.
The 2026-11-01 22:27 build panic (vm_page_validate_no_references: page 0x140005000 is referenced) came in a CLEAN-07F
boot; that page is where the firmware loads FbRelocate.efi (0x140000000 + 0x5000). Every step refuses to start in a
boot where FbRelocate ran or XeGfx is loaded.

Open Terminal, stay your normal user (no sudo), keep the Mac on power and Wi-Fi, run the steps one by one. Each stops
at the first error, prints the end of the log, and keeps every log in /Volumes/PKG/metal-stack/logs.

  bash /Volumes/PKG/metal-stack/0-prereqs.sh    MacPorts + prebuilt LLVM 20, meson, glslang..., SPIR-V translator,
                                                Rust (20-40 min). Asks for your password once (MacPorts).
  bash /Volumes/PKG/metal-stack/1-fetch.sh      sources into ~/src at pinned revisions (5-10 min, ~2 GB)
  bash /Volumes/PKG/metal-stack/2-userland.sh   libdrm + Mesa ANV (20-40 min)
  bash /Volumes/PKG/metal-stack/3-plugin.sh     Metal plugin + shader translator (5-15 min)
  bash /Volumes/PKG/metal-stack/4-kexts.sh      XeGfxAccel (macOS 15 variant), XeGfxAGDC, NMIntelFB, XeGfxIntelFB (2-5 min)
  bash /Volumes/PKG/metal-stack/5-collect.sh    copies the results to /Volumes/PKG/metal-stack/out + manifest
  bash /Volumes/PKG/metal-stack/6-xgfbmove.sh   XgFbMove.kext into out (seconds)
  bash /Volumes/PKG/metal-stack/7-xeflip.sh     XeGfxAccel 0.9.1: v0.0.47 + the Intel zero-copy flip (metal-stack/xeflip),
                                                into out/kexts (the stock 0.9 stays in out/orig); about a minute.
                                                Install: sudo bash .../install/update-kext.sh XeGfxAccel
  (a rerun of 5-collect.sh rebuilds out from the stock builds: run 6- and 7- again after it)

At most 8 compilers run at once. More or fewer:  JOBS=12 bash /Volumes/PKG/metal-stack/2-userland.sh
Homebrew is no longer used (since September 2026 it compiles everything from source on Intel Macs, LLVM included);
what it already installed under /usr/local stays and is kept out of these builds.

If a step fails: tell me which one; the log is on PKG and I read it from Windows. Rerunning a step is safe.

What gets built (from WTLIntelGfx v0.0.47 = the XeGfx you run):
  XeGfxAccel.kext      Metal accelerator that WindowServer and Metal apps talk to
  XeGfxAGDC.kext       display-pipe service WindowServer needs
  NMIntelFB.kext       framebuffer for the built-in panel
  NVMTLDriver.bundle   the Metal plugin (Metal on Vulkan)
  libnvmtl_translate   Metal shaders -> SPIR-V
  libvulkan_intel      Mesa ANV, the Vulkan driver, + libdrm with the XeGfx patches

Not part of this: installing. After 5-collect.sh I check the outputs and prepare an install with a rollback.
Upstream has only run this stack on macOS 26; the accelerator is built here without its Tahoe-only parts.
