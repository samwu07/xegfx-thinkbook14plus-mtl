The two ACPI tables EFI-CLEAN-07Y needs, made from your own firmware on Windows (issue #1).
The public EFI leaves out DSDT-TB21LD-SCOPE.aml and APIC-TB21LD-BSP0.aml because they are the laptop vendor's code.
make-acpi-tables.ps1 rebuilds both from the machine it runs on, applies the changes release/README-FIRST.txt lists,
and checks the result.

Run it:
  1. Start Windows from the firmware boot menu (F12), not through OpenCore: through OpenCore, Windows sees the
     injected tables. (The script refuses tables that already look patched.)
  2. Double-click make-acpi-tables.cmd, or in PowerShell:
         .\make-acpi-tables.ps1                                  (results in .\out)
         .\make-acpi-tables.ps1 -EfiPath E:\EFI-CLEAN-07Y-public\EFI   (also puts them into that EFI)
  3. It needs PowerShell 7 (pwsh.exe) to read the boot CPU's APIC ID with CPUID; if it is missing the script offers
     "winget install --id Microsoft.PowerShell". Without it, pass -OpenCoreLog <opencore-*.txt> (the
     "OCCPU: RAW CPUID(1) ... EBX xxxxxxxx" line, a DEBUG OpenCore build) or -BspApicId <n>.
  4. iasl.exe is downloaded from https://github.com/acpica/acpica/releases/tag/20260408 (the build the shipped tables
     were made with) and checked against SHA256 739c597b...df9; or pass -Iasl <path>.
No admin rights needed. It writes only to .\out (and the EFI folder with -EfiPath; the old config.plist goes to
out\efi-backup-*). out\dump and out\work hold firmware code: keep them to yourself. out\report.txt has no serial
numbers or table contents: post that one if something goes wrong.

What it does, step by step (each DSDT change is found by structure, not line numbers, and report.txt says whether it
was applied, changed nothing, or was not found):
  Tables   DSDT, APIC (MADT) and MCFG through GetSystemFirmwareTable, or from -InputDir (an OpenCore SysReport\ACPI
           folder or acpidump -b output; picked by signature).
  CPU      CPUID on every logical CPU (pinned): Windows CPU 0 is the boot CPU; leaf 0x1A gives P/E core types. The
           APIC IDs must match the MADT's enabled CPUs, or the results are not used.
  USB      the PCH xHCI at the DSDT's PC00.XHCI _ADR (00:14.0): its root hub's USB2 and USB3 port counts through
           IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2. PU2C = USB2 ports - USRx devices, PU3C = USB3 ports.
           On the ThinkBook: 12 USB2 + 2 USB3 -> 10 / 2, what Linux showed.
  MADT     VedCloud's format: 48 Type 0 (Local APIC) entries, ProcessorId 0..47 to match SSDT-PLUG-ALT's
           C000..C02F. ProcessorId 0 = the boot CPU, then its SMT sibling, the other P-core threads, the E and LP E
           cores (each ascending); the rest disabled (APIC 0xFF). IOAPIC and interrupt overrides copied as they are,
           one Local APIC NMI for all processors with the firmware's flags and LINT. Header (OEM IDs) unchanged.
  DSDT     iasl -d, then:
    C1  External() of method-local objects (_PS0.PS0X ...) replaced by root External() of the same name (iasl 6163)
    C2  deferred forward Scopes: module-level Scope() blocks whose target exists only inside a module-level If are
        wrapped in If (One). macOS's ACPICA runs module-level If blocks after the table load (legacy module-level
        code), so these Scopes would otherwise point at nothing
    C3  every If ((PCHS != 0x04)) unwrapped (an Else would be dropped): PCHS lives in the PCH NVS
    C4  Name (_DEP, ...) removed: forward references (PMIC) that abort the load; macOS does not use _DEP
    C5  PC00._CRS static: GPCL () (reads the host bridge's PCI config, which fails before the root bridge is up)
        becomes 0x04000000, so bus 0..0x3E as shipped (-MaxBus to change; the script warns when Windows uses a
        higher bus); the If (^MC.PMxx) blocks that blank unused root-port windows are removed. The SystemMemory
        backed windows and the OEM's PCHA branch stay as they are
    C6  PC00.XHCI _PS0/_PS3 and RHUB _PS0/_PS2/_PS3: If ((DVID == 0xFFFF)) -> If (Zero), so the PCH xHCI reaches D0
    C7  root Fields PU2C/PU3C -> Name (PU2C, n), Name (PU3C, m) from the USB count; XHCI's own PU2C/PU3C renamed
        XU2C/XU3C, so its port loop sees the root values (macOS never runs "PU2C = \PU2C" in the Device body)
    C8  IMxx = One for each I2C controller with a PNP0C50 (HID over I2C) device, so its _PS0/_PS3/_DSM exist
    C9  OSYS default 0x03E8 -> 0x07E5 in the _INI that sets it, so the touchpad _CRS returns its GpioInt
    C10 PS2K _STA -> XSTA, for SSDT-TB21LD-PS2VIS (which supplies _STA = 0x0F on Darwin)
    Not done: the ThinkBook's own USB port types (HS01/HS03/HS07 _UPC 3 -> 0).
           Then iasl compiles it (0 errors required), and the result is decompiled again to check C2..C10 are in it.
  Checks   whether the EFI's own SSDTs fit: LPCB present, no existing LPCB.EC (SSDT-TB21LD-EC), USBX, C000..C02F.
  EFI      with -EfiPath: copies both tables to OC\ACPI, enables ACPI > Add for them and points ACPI > Delete (APIC)
           at this machine's MADT: its OEM Table ID and length (the release has the ThinkBook's "CB-01   ", 856).
           Without that entry a second MADT would be added next to the native one.

Tested on the ThinkBook 14+ 2024 (21LD), Windows 11, both PowerShell 5.1 and 7: the MADT is byte for
byte the shipped APIC-TB21LD-BSP0.aml, and the DSDT decompiles to the shipped DSDT-TB21LD-SCOPE.aml except the
ThinkBook port types, If (Zero) for If ((PPID == 0xFFFF)) (both always false), deleted rather than Noop-padded _DEP,
and _CRS keeping the OEM's PCHA branch. Also run on a Dell Latitude 5350 (Meteor Lake) DSDT: all changes found,
0 errors. Other machines: not booted yet. Keep another boot entry.


中文说明
本脚本在 Windows 上从你自己机器的固件生成 EFI-CLEAN-07Y 缺少的两张表（DSDT-TB21LD-SCOPE.aml 和
APIC-TB21LD-BSP0.aml），并按 release/README-FIRST.txt 列出的修改打补丁、编译、校验。
  1. 从固件启动菜单（F12）直接进入 Windows，不要经过 OpenCore（否则 Windows 看到的是注入后的表）。
  2. 双击 make-acpi-tables.cmd；或者 .\make-acpi-tables.ps1 -EfiPath <EFI-CLEAN-07Y 的 EFI 文件夹>，
     会把两张表复制进去，并把 config.plist 的 ACPI > Delete（APIC）改成本机 MADT 的 OEM Table ID 和长度。
  3. 读取开机核心的 APIC ID 需要 PowerShell 7；没有的话脚本会询问是否用 winget 安装，
     或者用 -OpenCoreLog / -BspApicId 指定。
  4. iasl.exe 从 ACPICA 官方 GitHub 发布（20260408）下载并校验 SHA256。
out\dump 和 out\work 里是固件代码，请勿公开；出问题时只需贴出 out\report.txt（不含序列号和表内容）。
