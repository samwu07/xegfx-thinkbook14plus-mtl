Touchpad on the ThinkBook 14+ 2024 (Core Ultra 7 155H, macOS 15.8.1, OpenCore) -- WORKING since 2026-11-04.
It is a Goodix GXTP5100 (I2C-HID, address 0x2C) on Intel LPSS I2C0, PCI 8086:7E78, interrupt GpioInt pin 0x23 of GPI0
(INTC1083). Not PS/2: VoodooPS2 stays keyboard-only (ps2kbdonly=1). Found by decompiling the DSDT (TPAD in I2C0).

What it takes (all three):
  1. VoodooI2C 2.9.1 (GPL-3.0, https://github.com/VoodooI2C/VoodooI2C/releases/tag/v2.9.1) and VoodooI2CHID, in
     EFI/OC/Kexts, with this change to VoodooI2C.kext/Contents/Info.plist: a copy of the VoodooI2CPCILakeController
     personality under a new name (e.g. VoodooI2CPCIMeteorLakeController) with
         IOPCIMatch = 0x7e788086&0xFFFCFFFF        (Meteor Lake-P I2C0..I2C3, 7E78-7E7B)
     2.9.1 has no Meteor Lake ID. Kernel/Add order, after Lilu: VoodooI2C.kext/Contents/PlugIns/VoodooGPIO.kext,
     .../VoodooInput.kext, .../VoodooI2CServices.kext, VoodooI2C.kext, VoodooI2CHID.kext.
     add-touchpad.sh check|apply|undo does this on the live EFI (kexts from touchpad/kexts, not in this repository).
  2. Boot-arg -vi2c-force-polling (force-polling.sh on|off). VoodooI2CDeviceNub::probe exits with "Could not find
     GPIO controller" when a device declares a GpioInt and VoodooGPIO has no driver for the controller (it knows
     INT3450 INT34BB INT3455 INT345D INT344B INTC1055 and AMD only, not INTC1083), and the touchpad never registers.
  3. A restart.
A Windows deploy replaces the EFI: run add-touchpad.sh apply and force-polling.sh on again.

Two defects of the stock driver on this machine, both fixed in patches/VoodooI2CHID-glitch-guard.patch (1 and 2 below
are what make it usable):

1. THE CURSOR FLEW TO THE EDGE AND BACK while swiping (a few times per second, ~100+ jumps of >120 pt in 40 s).
   Cause: now and then the I2C read returns a report in which one byte of a finger coordinate is 0, for ONE report
   (X 4051 = 0x0FD3 read as 211 = 0x00D3; Y 1252 = 0x04E4 as 228). VoodooInput passes it on and macOS moves the cursor
   there and back. Where the zero byte comes from is not known (the DesignWare read code is standard; maybe the pad firmware
   updating its buffer). Report 4 layout (decoded from the descriptor, 40 bytes): ID, 5 x {flags (bit0 confidence,
   bit1 tip, bits4-7 contact id), X u16, Y u16, pressure u16}, scan time u16 (100 us), contact count, button.
   Guard in VoodooI2CHIDDevice::getInputReport: a frame in which a finger moved more than 160 units (pad 4149 x 2147)
   from the last good frame is read again (up to 2x); a re-read that agrees with the first read within 40 units is a real
   fast move; otherwise the frame is dropped (3 bad frames in a row are taken as a new baseline). Vote: while a finger is
   down each new frame is read twice, a differing pair (same scan time) gets a third read, nothing confirmed is dropped.
   Result: jumps > 120 pt in 40 s of swiping 185-311 -> 7, > 300 pt 27-56 -> 0; "fixed and smooth" (user).
   Boot-args: vi2c-glitch-step=N, -vi2c-no-glitch-guard, -vi2c-no-vote.
   Careful with per-finger bookkeeping: unused slots read as contact id 0 / no tip, the same id as the real finger 0, so
   "last position per id" must ignore inactive slots (checks that did not were blind for one finger).
2. THE POLL NEVER WENT IDLE: the pad answers a poll with its last report when untouched, every poll counted as activity,
   so the driver read ~180 times/s forever (~7,600 I2C0 interrupts/s on CPU 0, no deep C-states). Only a report with a
   new scan time counts now: ~19 reads/s, 803 interrupts/s. Boot-arg vi2c-idle-ms=N sets the idle period (default 50).
Also in the patch, harmless and not needed for the fix: drop of 0-contact frames with a finger down (-vi2c-keep-bogus),
drop of exact repeats (-vi2c-keep-dups), device-clock timestamps (-vi2c-raw-ts), element-vs-report coordinate check
(-vi2c-no-elem-fix), a lock around the report handler, and ioreg counters (VoodooI2CHIDDevice Glitch*/Vote*,
VoodooI2CPrecisionTouchpadHIDEventDriver RawJumps/ElemFixed/Overlaps ...). cursor-watch.c measures the real cursor
(clang -O2 -o cursor-watch cursor-watch.c -framework CoreGraphics -framework CoreFoundation; ./cursor-watch 40 120,
then swipe): the number of steps > 120 pt in one poll.
Not done: real GPIO interrupts (VoodooGPIO needs a Meteor Lake INTC1083 pin table; Linux pinctrl-meteorlake.c has it),
Touch ID, audio.
