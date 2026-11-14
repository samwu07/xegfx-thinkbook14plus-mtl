Patches to VoodooI2C 2.9.1 and VoodooInput 1.1.6 for the ThinkBook 14+ 2024 touchpad (Goodix GXTP5100).
Licences: these are changes to GPL code and stay under the licence of what they change -- VoodooI2C (and its VoodooI2CHID
satellite, which has no licence file of its own and is part of the VoodooI2C project) GPL-3.0; VoodooInput GPL-2.0
(acidanthera). Texts: release/LICENSES/spdx-GPL-3.0-only.txt and spdx-GPL-2.0-only.txt. Nothing built from them is in this
repository; apply them to the upstream sources yourself.

  VoodooI2CHID-glitch-guard.patch    against VoodooI2C v2.9.1, folder "VoodooI2C Satellites/VoodooI2CHID" (git apply -p1 there)
      the fix: glitch guard (re-read), vote (read twice, third read decides), idle-poll fix, plus the diagnostics below
  VoodooInput-trace.patch            against VoodooInput 1.1.6: ioreg counters on the finished Magic Trackpad report (diagnostic)
  VoodooI2C-nativeengine-trace.patch against VoodooI2C v2.9.1 "Multitouch Support" (diagnostic: jumps in the message)

Build (what worked here, Xcode 26.3, macOS 15.8.1 target):
  git clone --branch v2.9.1 https://github.com/VoodooI2C/VoodooI2C && git submodule update --init --recursive
  MacKernelSDK must be commit a2ba595 (2024-08-20), put at VoodooI2C/MacKernelSDK: a newer one gives an IOHIDEventService
  vtable mismatch. Copy VoodooInput's VoodooInputMultitouch/*.h to
  Dependencies/VoodooInput/Debug/VoodooInput.kext/Contents/Resources/VoodooInputMultitouch/.
  xcodebuild -workspace VoodooI2C.xcworkspace -scheme VoodooI2CHID -configuration Release CODE_SIGNING_ALLOWED=NO
  Check: nm -u of your build against the official VoodooI2CHID.kext must differ only by _PE_parse_boot_argn, _memcmp,
  _snprintf (all exported by the kernel).
