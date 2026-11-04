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
Not done: GPIO interrupts (polling costs a little CPU), Touch ID, audio.
