Metal stack, phase 1: does Metal run on the Intel GPU? (ThinkBook 14+ 155H, macOS 15.8.1)

What gets installed (from /Volumes/PKG/metal-stack/out):
  XeGfxAccel.kext       /Library/Extensions + auxiliary kernel collection (the old collection is backed up first)
  XgFbMove.kext         same place: moves the boot framebuffer out of i915's GuC area from macOS, only when
                        run-xegfx-stages.sh loads it -- replaces FbRelocate.efi (CLEAN-07F/07G are retired)
  ANV, libdrm, translator  /Library/GPUBundles/nvmtl
  NVMTLDriver.bundle    /Library/XeGfx/metal (private: only the test loads it; other apps and WindowServer do not)
Nothing starts at boot: XgFbMove has no personality, the accelerator attaches only after XeGfx stage 7. The desktop
(panel kexts, system-wide plugin, WindowServer) is phase 2.

Order:
  1. CLEAN-07A, as your user:   bash /Volumes/PKG/metal-stack/6-xgfbmove.sh         (builds XgFbMove, seconds)
  2. CLEAN-07A:                 sudo bash /Volumes/PKG/metal-stack/install/install-metal.sh    then restart
  3. boot CLEAN-07Y (Windows: work\deploy-sn750-clean07y.bat): XeGfx in OpenCore, no FbRelocate
  4. sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 7
       first line: "xgfbmove-result" ... status 1 ... surf 0xfe800000 -> 0x80000000; then stages 1-7
  5. bash /Volumes/PKG/metal-stack/install/test-metal.sh     mtlprobe: compute kernel + draw, checked on the CPU

Outcomes:
  - install says "the collection did not link": nothing was replaced; send me install/reports/install-*/kmutil.log
  - XgFbMove status <0: the move did not happen; run-xegfx-stages.sh now stops before stage 4 (no band), send the report
  - a newer XgFbMove (1.2: also takes a target full of an earlier session's GGTT entries, which made 1.1 refuse -5 on
    2026-11-02): bash /Volumes/PKG/metal-stack/6-xgfbmove.sh, then
    sudo bash /Volumes/PKG/metal-stack/install/update-xgfbmove.sh   then restart. It replaces only XgFbMove; the
    plugin, its bitcode reader and the desktop parts stay.
  - one kext only, from out/kexts:  sudo bash /Volumes/PKG/metal-stack/install/update-kext.sh XgFbMove|XeGfxAccel
    (XeGfxAccel 0.9.1 = the zero-copy flip from 7-xeflip.sh; update-xgfbmove.sh is the same for XgFbMove)
  - a panic: restart (nothing of this loads at boot), then sudo bash /Volumes/PKG/xegfx/collect-after-crash.sh
  - test-metal.sh exit 0: Metal works on the Intel GPU -> phase 2 (desktop)
  Reports land in install/reports and xegfx/reports on PKG.

Undo:  sudo bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh            then restart
       from Recovery: bash /Volumes/PKG/metal-stack/install/uninstall-metal.sh "/Volumes/MAC - Data"
