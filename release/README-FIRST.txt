EFI-CLEAN-07Y-public: read this before you boot it
==================================================

This is the OpenCore EFI of one Lenovo ThinkBook 14+ 2024 (21LD, Core Ultra 7 155H) running macOS 15.8.1, with three
things taken out. It will NOT boot as it is: add them back first.

1. SMBIOS (PlatformInfo > Generic). SystemSerialNumber, MLB, SystemUUID and ROM are placeholders. Generate your own
   (GenSMBIOS, model as in SystemProductName) and use your Wi-Fi MAC as ROM.

2. AMFIPass.kext (Kernel > Add, entry 1, disabled). It is distributed as a binary only, with no licence that allows
   passing it on. Download AMFIPass 1.4.1 from the OpenCore Legacy Patcher project, put it in OC/Kexts and set the
   entry to Enabled.

3. The two ACPI tables made from Lenovo's firmware (ACPI > Add entries 0 and 3, ACPI > Delete entry 0, all disabled).
   They are Lenovo's code with patches, so they are not published here. Dump your machine's tables (OpenCore:
   Misc > Debug > SysReport = true, boot once, take SysReport/ACPI/ from the EFI partition; or acpidump -b on
   Windows/Linux), decompile with iasl, patch, compile, and name them as below. On Windows,
   acpi/make-acpi-tables.cmd in the repository does all of this from your machine's firmware, and with
   -EfiPath <this EFI folder> also sets the ACPI > Add and ACPI > Delete entries (acpi/README.txt). What each changes:

   DSDT-TB21LD-SCOPE.aml  (your DSDT.aml, patched)
   (in the words of the config.plist comment: "deferred forward Scopes, static _CRS v2, PCHS guards", then)
     - module-level Scope() blocks whose target is only defined inside a module-level If: wrapped in If (One)
     - PC00._CRS static: no PCI config reads (GPCL, ^MC.PMxx); bus 0..0x3E
     - every If ((PCHS != 0x04)) unwrapped
     - Name (_DEP, ...) removed (forward references that abort the table load)
     - PC00.XHCI / RHUB _PSx: skip the PCI_Config device-ID check, so the PCH xHCI can reach D0 (USB works)
     - PU2C / PU3C = 10 / 2 as root Names, so PC00.XHCI.RHUB gets its ports
     - IM00 = One and the OSYS default 0x07E5, for the I2C touchpad; PS2K _STA renamed XSTA for SSDT-TB21LD-PS2VIS
   APIC-TB21LD-BSP0.aml  (your APIC/MADT, rewritten)
     - VedCloud's MADT format: 48 Type 0 (Local APIC) entries, ProcessorId 0 = APIC ID 32 = the real boot CPU
     - ACPI > Delete entry 0 drops the original MADT by its OEM Table ID ("CB-01   ") and length (on another
       machine: yours): turn it on only together with Add entry 3, or the machine has no MADT at all
   VedCloud's project (https://github.com/VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics) has the MADT layout this
   follows.

Then: copy EFI/ to your EFI partition (keep another boot entry), boot, and install the drivers from
xegfx-drivers-*.zip as metal-stack/README and metal-stack/desktop/README.txt in the repository describe.
Licences of everything in here: THIRD-PARTY.txt and LICENSES/.
