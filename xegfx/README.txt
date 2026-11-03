WTLIntelGfx (XeGfx) 0.0.47 kernel-only stage test for the ThinkBook 14+ (Core Ultra 7 155H, 8086:7D55).
Kext: unmodified official release zip (sha256 222ca676325d86bc5e7a06dc67478360651a8afb234f35e3dcef82b886ca60c0).

Route 2 (current): OpenCore injects XeGfx. Nothing is installed into macOS.
  0. In Windows: work\deploy-sn750-clean07x.bat, then boot rEFInd -> OpenCore -> MAC.
     Use the Mac normally for 15-30 min first. If it freezes like before: Windows -> deploy-sn750-clean07a.bat (= undo).
  1. sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 2     read-only probe
  2. sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 4     i915 up, display code skipped, panel checked
  3. sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 6     first GPU work
  after a crash/freeze + restart:  sudo bash /Volumes/PKG/xegfx/collect-after-crash.sh
  remove:  Windows -> deploy-sn750-clean07a.bat
Reports land in reports/ here.

Resolution test (upstream issue #13): work\deploy-sn750-clean07r.bat = 07Y + boot resolution 2560x1600.
  Run ONLY:  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 2
  It prints where the boot framebuffer sits and whether stage 4 can pass. Go back with deploy-sn750-clean07y.bat.

Framebuffer move (upstream issue #13): work\deploy-sn750-clean07f.bat = 07Y + FbRelocate.efi (OpenCore driver that
moves the panel's GGTT mapping from 0xFE800000 to 0x80000000 just before macOS starts).
  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 2     must print "clear of the GuC slot"; only then:
  sudo bash /Volumes/PKG/xegfx/run-xegfx-stages.sh 4     no band expected; then 6
  black screen at boot -> rEFInd -> Windows -> deploy-sn750-clean07y.bat

Route 1 (retired): install-xegfx.sh put XeGfx into the auxiliary kernel collection; the desktop hard-froze ~1 min
after login although XeGfx never started. If that state is ever back:
  OpenCore picker -> Recovery -> Utilities -> Terminal:
  bash /Volumes/PKG/xegfx/rescue-xegfx.sh "/Volumes/MAC - Data"
  (on a Chinese-language system the volume is "/Volumes/MAC - 数据"; ls /Volumes shows it)
