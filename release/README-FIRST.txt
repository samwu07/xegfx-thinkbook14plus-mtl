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
   Windows/Linux), decompile with iasl, patch, compile, and name them as below. What each one changes:

   DSDT-TB21LD-SCOPE.aml  (your DSDT.aml, patched)
   (in the words of the config.plist comment: "deferred forward Scopes, static _CRS v2, PCHS guards", then)
     - forward Scope() blocks moved after the objects they extend
     - static _CRS resource templates in place of computed ones (second version)
     - guards on the PCHS (PCH series) checks
     - PC00.XHCI / RHUB _PSx: skip the PCI_Config device-ID check, so the PCH xHCI can reach D0 (USB works)
     - PU2C / PU3C = 10 / 2, so PC00.XHCI.RHUB gets its ports
   APIC-TB21LD-BSP0.aml  (your APIC/MADT, rewritten)
     - VedCloud's MADT format: 48 Type 0 (Local APIC) entries, ProcessorId 0 = APIC ID 32 = the real boot CPU
     - ACPI > Delete entry 0 drops the original MADT by its OEM Table ID ("CB-01   ") and length: turn it on only
       together with Add entry 3, or the machine has no MADT at all
   VedCloud's project (https://github.com/VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics) has the MADT layout this
   follows. A script that makes both tables from a dump is planned for this repository.

Then: copy EFI/ to your EFI partition (keep another boot entry), boot, and install the drivers from
xegfx-drivers-*.zip as metal-stack/README and metal-stack/desktop/README.txt in the repository describe.
Licences of everything in here: THIRD-PARTY.txt and LICENSES/.
