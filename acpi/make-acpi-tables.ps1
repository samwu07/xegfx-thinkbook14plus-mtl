#Requires -Version 5.1
<#
.SYNOPSIS
    Makes the two firmware-derived ACPI tables that EFI-CLEAN-07Y needs (DSDT-TB21LD-SCOPE.aml and
    APIC-TB21LD-BSP0.aml) from THIS laptop's own tables, on Windows.

.DESCRIPTION
    The public EFI leaves out the patched DSDT and MADT because they are the laptop vendor's firmware code. This
    script rebuilds them from the machine it runs on:

      1. reads DSDT, APIC (MADT) and MCFG from the running firmware (or from -InputDir: an OpenCore SysReport\ACPI
         folder or acpidump -b output)
      2. finds the boot CPU's APIC ID (CPUID on logical CPU 0, through PowerShell 7) and the P/E core types
      3. counts the USB2/USB3 ports of the PCH xHCI (\_SB.PC00.XHCI) through the Windows USB stack
      4. decompiles the DSDT with iasl, applies the changes listed in release/README-FIRST.txt (each one is found by
         structure, not by line number, and reported as applied or not found), recompiles it and checks the result
      5. writes the VedCloud-format MADT: 48 Type 0 entries, ProcessorId 0 = the boot CPU
      6. optionally (-EfiPath) copies both tables into an EFI-CLEAN-07Y folder and points its ACPI > Delete entry at
         this machine's MADT (OEM Table ID and length), with a backup of config.plist
      7. writes report.txt: what was found and changed, without serial numbers or table contents (safe to post)

    Boot Windows straight from the firmware boot menu (F12), not through OpenCore: through OpenCore, Windows sees
    the injected tables instead of the firmware's.

    Nothing is written outside -OutDir (and -EfiPath when given). iasl.exe is downloaded from the ACPICA GitHub
    release 20260408 (the build these tables were made with) and checked against its SHA256, unless -Iasl points to
    one or -NoDownload is set.

.PARAMETER InputDir
    Use table files from this folder instead of the running firmware (any of *.aml, *.dat, *.bin; picked by their
    signature). The CPU and USB probes still read the PC this runs on.
.PARAMETER OutDir
    Output folder. Default: .\out next to this script.
.PARAMETER EfiPath
    An EFI-CLEAN-07Y folder (the one holding OC\config.plist, or its parent). The two tables are copied to OC\ACPI and
    config.plist gets ACPI > Add for both enabled and ACPI > Delete (APIC) set to this machine's MADT.
.PARAMETER BspApicId
    APIC ID of the boot CPU, if it cannot be read here. It is CPUID(1).EBX bits 31:24, which OpenCore logs as
    "OCCPU: RAW CPUID(1) ... EBX xxxxxxxx" (the first two hex digits).
.PARAMETER OpenCoreLog
    An opencore-*.txt log; the boot CPU's APIC ID is taken from its OCCPU line.
.PARAMETER PU2C
    Number of USB2 (HSxx) ports on PC00.XHCI.RHUB, if the USB probe cannot find them.
.PARAMETER PU3C
    Number of USB3 (SSxx) ports on PC00.XHCI.RHUB, if the USB probe cannot find them.
.PARAMETER MaxBus
    Highest PCI bus number for the static PC00._CRS (default 0x3E, as in the shipped table).
.PARAMETER Iasl
    Path to iasl.exe.
.PARAMETER NoDownload
    Do not download iasl.exe.
.PARAMETER Force
    Go on when the tables look already patched, or when iasl reports errors (compiles with -f). Not for booting.

.EXAMPLE
    .\make-acpi-tables.ps1
.EXAMPLE
    .\make-acpi-tables.ps1 -EfiPath E:\EFI-CLEAN-07Y\EFI
.EXAMPLE
    .\make-acpi-tables.ps1 -InputDir D:\SysReport\ACPI -OpenCoreLog D:\opencore-2026-11-09-120000.txt

.NOTES
    BSD-2-Clause, part of https://github.com/samwu07/xegfx-thinkbook14plus-mtl
#>
[CmdletBinding()]
param(
    [string]$InputDir,
    [string]$OutDir,
    [string]$EfiPath,
    [int]$BspApicId = -1,
    [string]$OpenCoreLog,
    [int]$PU2C = -1,
    [int]$PU3C = -1,
    [int]$MaxBus = -1,
    [string]$Iasl,
    [switch]$NoDownload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptVersion = '1.0 (2026-11-11)'
$IaslUrl = 'https://github.com/acpica/acpica/releases/download/20260408/iasl.exe'
$IaslSha256 = '739c597bcee4563f18d13e73b2051bb661707713e6154cf5712a1b7eef4a5df9'
$DsdtOut = 'DSDT-TB21LD-SCOPE.aml'          # names the EFI-CLEAN-07Y config.plist expects
$ApicOut = 'APIC-TB21LD-BSP0.aml'
$MadtSlots = 48                               # SSDT-PLUG-ALT declares Processor C000..C02F, IDs 0..47
$ShippedMaxBus = 0x3E                         # what the shipped static PC00._CRS declares (bus 0..0x3E)

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$WorkDir = Join-Path $OutDir 'work'
$DumpDir = Join-Path $OutDir 'dump'

$Warnings = New-Object 'System.Collections.Generic.List[string]'
$Changes = New-Object 'System.Collections.Generic.List[object]'
$Facts = New-Object 'System.Collections.Generic.List[string]'

function Step([string]$m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Say([string]$m) { Write-Host "   $m" }
function Warn([string]$m) { Write-Host "   WARNING: $m" -ForegroundColor Yellow; $Warnings.Add($m) }
function Fail([string]$m) {
    Write-Host ''
    Write-Host "ERROR: $m" -ForegroundColor Red
    exit 1
}
function Fact([string]$m) { $Facts.Add($m) }
function Change([string]$id, [string]$what, [string]$status, [string]$detail) {
    $Changes.Add([pscustomobject]@{ Id = $id; What = $what; Status = $status; Detail = $detail })
    $color = 'Green'
    if ($status -ne 'applied') { $color = 'Yellow' }
    Write-Host ('   [{0}] {1,-9} {2}: {3}' -f $id, $status, $what, $detail) -ForegroundColor $color
}
function Hex([long]$v, [int]$w = 2) { '0x' + $v.ToString('X' + $w) }

# ------------------------------------------------------------------------------------------------ native helpers
if (-not ('XegAcpi.AslDoc' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace XegAcpi {
    public static class Fw {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint EnumSystemFirmwareTables(uint provider, byte[] buf, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buf, uint size);
        const uint ACPI = 0x41435049;

        public static string[] List() {
            uint n = EnumSystemFirmwareTables(ACPI, null, 0);
            if (n == 0) return new string[0];
            byte[] b = new byte[n];
            EnumSystemFirmwareTables(ACPI, b, n);
            string[] r = new string[n / 4];
            for (int i = 0; i < r.Length; i++) r[i] = Encoding.ASCII.GetString(b, i * 4, 4);
            return r;
        }

        public static byte[] Get(string sig) {
            uint id = BitConverter.ToUInt32(Encoding.ASCII.GetBytes(sig), 0);
            uint n = GetSystemFirmwareTable(ACPI, id, null, 0);
            if (n == 0) return null;
            byte[] b = new byte[n];
            if (GetSystemFirmwareTable(ACPI, id, b, n) != n) return null;
            return b;
        }

        public static int Sum(byte[] b) {
            int s = 0;
            foreach (byte x in b) s = (s + x) & 0xFF;
            return s;
        }

        public static int IndexOf(byte[] hay, byte[] needle) {
            for (int i = 0; i + needle.Length <= hay.Length; i++) {
                int k = 0;
                while (k < needle.Length && hay[i + k] == needle[k]) k++;
                if (k == needle.Length) return i;
            }
            return -1;
        }
    }

    public static class UsbHub {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inLen, byte[] outBuf, int outLen, out int ret, IntPtr ov);
        const uint IOCTL_USB_GET_NODE_INFORMATION = 0x220408;
        const uint IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2 = 0x22045C;

        // returns { ports, usb2, usb3, unknown } or { -1, win32 error, 0, 0 }
        public static int[] Probe(string path) {
            using (SafeFileHandle h = CreateFile(path, 0x40000000, 2, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (h.IsInvalid) return new int[] { -1, Marshal.GetLastWin32Error(), 0, 0 };
                byte[] ni = new byte[80];
                int r;
                if (!DeviceIoControl(h, IOCTL_USB_GET_NODE_INFORMATION, ni, ni.Length, ni, ni.Length, out r, IntPtr.Zero))
                    return new int[] { -1, Marshal.GetLastWin32Error(), 0, 0 };
                int ports = ni[6];     // USB_NODE_INFORMATION: NodeType(4) + USB_HUB_DESCRIPTOR(len, type, bNumberOfPorts ...)
                int u2 = 0, u3 = 0, other = 0;
                for (int p = 1; p <= ports; p++) {
                    byte[] b = new byte[16];
                    BitConverter.GetBytes(p).CopyTo(b, 0);
                    BitConverter.GetBytes(16).CopyTo(b, 4);
                    BitConverter.GetBytes(7).CopyTo(b, 8);
                    if (!DeviceIoControl(h, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2, b, 16, b, 16, out r, IntPtr.Zero)) { other++; continue; }
                    uint proto = BitConverter.ToUInt32(b, 8);
                    if ((proto & 4) != 0) u3++; else if ((proto & 2) != 0) u2++; else other++;
                }
                return new int[] { ports, u2, u3, other };
            }
        }
    }

    public class AslBlock {
        public int Header = -1, Open, Close = -1, Parent = -1;
        public string Kind = "", Name = "", Path = "\\", Code = "";
        public bool InMethod, InCond;
    }

    // A disassembled ASL file as lines plus its { } blocks, each with the namespace path it opens.
    public class AslDoc {
        public string[] Lines, Code;
        public List<AslBlock> Blocks = new List<AslBlock>();
        public List<int>[] Kids;
        Dictionary<string, List<int>> byKey = new Dictionary<string, List<int>>();
        static readonly Regex Head = new Regex(@"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\((.*))?$");
        static readonly HashSet<string> NsKinds = new HashSet<string> { "Scope", "Device", "Method", "Processor", "ThermalZone", "PowerResource" };
        static readonly HashSet<string> CondKinds = new HashSet<string> { "If", "Else", "ElseIf", "While", "Switch", "Case", "Default" };

        public AslDoc(string[] lines) {
            Lines = lines;
            Code = StripCode(lines);
            Stack<int> st = new Stack<int>();
            int lastSig = -1;
            for (int i = 0; i < Code.Length; i++) {
                string c = Code[i];
                for (int j = 0; j < c.Length; j++) {
                    if (c[j] == '{') {
                        AslBlock b = new AslBlock();
                        b.Open = i;
                        b.Header = c.Substring(0, j).Trim().Length > 0 ? i : lastSig;
                        b.Parent = st.Count > 0 ? st.Peek() : -1;
                        b.Code = b.Header >= 0 ? Code[b.Header].Trim() : "";
                        Blocks.Add(b);
                        st.Push(Blocks.Count - 1);
                    } else if (c[j] == '}') {
                        if (st.Count > 0) Blocks[st.Pop()].Close = i;
                    }
                }
                string t = c.Trim();
                if (t.Length > 0 && t != "{" && !t.StartsWith("}")) lastSig = i;
            }
            Kids = new List<int>[Blocks.Count];
            for (int i = 0; i < Blocks.Count; i++) Kids[i] = new List<int>();
            for (int i = 0; i < Blocks.Count; i++) {
                AslBlock b = Blocks[i];
                Match m = Head.Match(b.Code);
                if (m.Success) b.Kind = m.Groups[1].Value;
                AslBlock p = b.Parent >= 0 ? Blocks[b.Parent] : null;
                string scope = p != null ? p.Path : "\\";
                if (p != null) {
                    Kids[b.Parent].Add(i);
                    b.InMethod = p.InMethod || p.Kind == "Method";
                    b.InCond = p.InCond || CondKinds.Contains(p.Kind);
                }
                if (NsKinds.Contains(b.Kind) && m.Success && m.Groups[2].Success) {
                    string a = m.Groups[2].Value;
                    int k = a.IndexOfAny(new char[] { ',', ')' });
                    b.Name = (k >= 0 ? a.Substring(0, k) : a).Trim();
                    b.Path = Resolve(scope, b.Name);
                } else {
                    b.Path = scope;
                }
                string key = b.Kind + "|" + b.Path;
                if (!byKey.ContainsKey(key)) byKey[key] = new List<int>();
                byKey[key].Add(i);
            }
        }

        // code part of each line: comments removed, string contents blanked
        public static string[] StripCode(string[] lines) {
            string[] res = new string[lines.Length];
            bool inBlock = false;
            for (int i = 0; i < lines.Length; i++) {
                string s = lines[i];
                StringBuilder sb = new StringBuilder(s.Length);
                bool inStr = false;
                for (int j = 0; j < s.Length; j++) {
                    char c = s[j];
                    if (inBlock) { if (c == '*' && j + 1 < s.Length && s[j + 1] == '/') { inBlock = false; j++; } continue; }
                    if (inStr) {
                        if (c == '\\' && j + 1 < s.Length) { j++; sb.Append('_'); continue; }
                        if (c == '"') { inStr = false; sb.Append('"'); } else sb.Append('_');
                        continue;
                    }
                    if (c == '"') { inStr = true; sb.Append('"'); continue; }
                    if (c == '/' && j + 1 < s.Length && s[j + 1] == '/') break;
                    if (c == '/' && j + 1 < s.Length && s[j + 1] == '*') { inBlock = true; j++; continue; }
                    sb.Append(c);
                }
                res[i] = sb.ToString();
            }
            return res;
        }

        public static string Seg(string s) {
            s = s.Trim().ToUpperInvariant();
            while (s.Length < 4) s += "_";
            return s;
        }

        public static string Resolve(string scope, string name) {
            name = name.Trim();
            List<string> segs = new List<string>();
            if (name.StartsWith("\\")) {
                name = name.Substring(1);
            } else {
                if (scope.Length > 1) segs.AddRange(scope.Substring(1).Split('.'));
                while (name.StartsWith("^")) { if (segs.Count > 0) segs.RemoveAt(segs.Count - 1); name = name.Substring(1); }
            }
            foreach (string x in name.Split('.')) if (x.Trim().Length > 0) segs.Add(Seg(x));
            return "\\" + string.Join(".", segs.ToArray());
        }

        public int[] Find(string kind, string path) {
            List<int> l;
            return byKey.TryGetValue(kind + "|" + path, out l) ? l.ToArray() : new int[0];
        }

        public int NextCodeLine(int from) {
            for (int i = from; i < Code.Length; i++) if (Code[i].Trim().Length > 0) return i;
            return -1;
        }

        // module-level Scope() blocks whose target exists only inside a module-level If/Else: under the legacy
        // module-level code of macOS's ACPICA those conditional blocks run after the table load, so the Scope
        // must be deferred the same way (wrapped in If (One))
        public int[] ForwardScopes() {
            HashSet<string> cond = new HashSet<string>(), uncond = new HashSet<string>();
            foreach (AslBlock b in Blocks) {
                if (b.InMethod) continue;
                if (b.Kind == "Device" || b.Kind == "Processor" || b.Kind == "ThermalZone" || b.Kind == "PowerResource")
                    (b.InCond ? cond : uncond).Add(b.Path);
            }
            List<int> wrap = new List<int>();
            HashSet<int> wrapped = new HashSet<int>();
            for (int i = 0; i < Blocks.Count; i++) {
                AslBlock b = Blocks[i];
                if (b.Kind != "Scope" || b.InMethod || b.InCond || b.Path == "\\") continue;
                bool inside = false;
                for (int p = b.Parent; p >= 0; p = Blocks[p].Parent) if (wrapped.Contains(p)) { inside = true; break; }
                if (inside) continue;
                string[] segs = b.Path.Substring(1).Split('.');
                string pre = "\\";
                for (int k = 0; k < segs.Length; k++) {
                    pre = k == 0 ? "\\" + segs[0] : pre + "." + segs[k];
                    if (cond.Contains(pre) && !uncond.Contains(pre)) { wrap.Add(i); wrapped.Add(i); break; }
                }
            }
            return wrap.ToArray();
        }

        // External() lines naming an object inside a method (a method-local temporary): iasl rejects them (6163)
        public int[] MethodLocalExternals() {
            HashSet<string> methods = new HashSet<string>();
            foreach (AslBlock b in Blocks) if (b.Kind == "Method") methods.Add(b.Path);
            Regex ext = new Regex(@"^\s*External\s*\(\s*([\\^A-Za-z0-9_.]+)");
            List<int> r = new List<int>();
            for (int i = 0; i < Code.Length; i++) {
                Match m = ext.Match(Code[i]);
                if (!m.Success) continue;
                string p = Resolve("\\", m.Groups[1].Value);
                int dot = p.LastIndexOf('.');
                while (dot > 0) {
                    p = p.Substring(0, dot);
                    if (methods.Contains(p)) { r.Add(i); break; }
                    dot = p.LastIndexOf('.');
                }
            }
            return r.ToArray();
        }
    }
}
'@
}

function Invoke-Native([string]$exe, [string[]]$argv, [string]$cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result + $e.Result; StdOut = $o.Result }
}

function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose(); $sha.Dispose() }
}
function Ascii([byte[]]$b, [int]$o, [int]$n) { [Text.Encoding]::ASCII.GetString($b, $o, $n) }

function Test-AcpiTable([byte[]]$b, [string]$sig) {
    if ($null -eq $b -or $b.Length -lt 36) { return $false }
    if ((Ascii $b 0 4) -ne $sig) { return $false }
    if ([BitConverter]::ToUInt32($b, 4) -ne $b.Length) { return $false }
    return ([XegAcpi.Fw]::Sum($b) -eq 0)
}

function Describe-Table([byte[]]$b) {
    '{0} {1} bytes, OEM "{2}", table ID "{3}", rev {4}, creator "{5}" {6}' -f (Ascii $b 0 4), $b.Length, (Ascii $b 10 6),
        (Ascii $b 16 8), $b[8], (Ascii $b 28 4), (Hex ([BitConverter]::ToUInt32($b, 32)) 8)
}

function Set-Checksum([byte[]]$b) {
    $b[9] = 0
    $b[9] = [byte]((256 - [XegAcpi.Fw]::Sum($b)) % 256)
}

# ================================================================================================ 0. start
Write-Host "make-acpi-tables $ScriptVersion  (xegfx-thinkbook14plus-mtl)" -ForegroundColor White
Write-Host "Output: $OutDir"
New-Item -ItemType Directory -Force -Path $OutDir, $WorkDir, $DumpDir | Out-Null

$cs = $null; $bios = $null; $cpuName = ''
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpuName = (@(Get-CimInstance Win32_Processor)[0].Name).Trim()
} catch { }
if ($cs) { Fact ('Machine: {0} {1} | BIOS {2} ({3:yyyy-MM-dd}) | {4}' -f $cs.Manufacturer, $cs.Model, $bios.SMBIOSBIOSVersion, $bios.ReleaseDate, $cpuName) }

# ================================================================================================ 1. iasl
Step 'iasl (ACPICA compiler)'
$iaslExe = $null
$cands = @()
if ($Iasl) { $cands += $Iasl }
$cands += (Join-Path $PSScriptRoot 'iasl.exe'), (Join-Path $OutDir 'tools\iasl.exe')
$onPath = Get-Command iasl.exe -ErrorAction SilentlyContinue
if ($onPath) { $cands += $onPath.Source }
foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { $iaslExe = (Resolve-Path -LiteralPath $c).Path; break } }
if (-not $iaslExe) {
    if ($NoDownload) { Fail "iasl.exe not found. Get it from $IaslUrl and pass -Iasl <path>." }
    $iaslExe = Join-Path $OutDir 'tools\iasl.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $iaslExe) | Out-Null
    Say "downloading $IaslUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $IaslUrl -OutFile $iaslExe -UseBasicParsing
        $ProgressPreference = $pp
    } catch { Fail "download failed ($($_.Exception.Message)). Get iasl.exe from $IaslUrl and pass -Iasl <path>." }
    if ((Get-Sha256 $iaslExe) -ne $IaslSha256) {
        Remove-Item -LiteralPath $iaslExe -Force
        Fail "the downloaded iasl.exe does not have the expected SHA256 $IaslSha256; deleted it."
    }
}
$iaslHash = Get-Sha256 $iaslExe
$iv = Invoke-Native $iaslExe @('-v') $WorkDir
$iaslVer = ([regex]::Match($iv.Out, 'version \d+')).Value
Say "$iaslExe  ($iaslVer, sha256 $($iaslHash.Substring(0,16))...)"
if ($iaslHash -ne $IaslSha256) { Warn "iasl is not the 20260408 build the shipped tables were made with; results may differ slightly." }
Fact "iasl: $iaslVer, sha256 $iaslHash"

# ================================================================================================ 2. tables
Step 'ACPI tables'
$dsdt = $null; $apic = $null; $mcfg = $null
if ($InputDir) {
    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) { Fail "-InputDir $InputDir is not a folder." }
    foreach ($f in Get-ChildItem -LiteralPath $InputDir -File | Where-Object { $_.Extension -in '.aml', '.dat', '.bin' } | Sort-Object Name) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -lt 36) { continue }
        $s = Ascii $b 0 4
        if ($s -eq 'DSDT' -and -not $dsdt) { $dsdt = $b; Say "DSDT <- $($f.Name)" }
        elseif ($s -eq 'APIC' -and -not $apic) { $apic = $b; Say "APIC <- $($f.Name)" }
        elseif ($s -eq 'MCFG' -and -not $mcfg) { $mcfg = $b; Say "MCFG <- $($f.Name)" }
    }
    Fact "Tables: from files in -InputDir"
} else {
    $dsdt = [XegAcpi.Fw]::Get('DSDT')
    $apic = [XegAcpi.Fw]::Get('APIC')
    $mcfg = [XegAcpi.Fw]::Get('MCFG')
    Fact "Tables: read from the running firmware (GetSystemFirmwareTable)"
}
foreach ($t in @(@('DSDT', $dsdt), @('APIC', $apic))) {
    if (-not (Test-AcpiTable $t[1] $t[0])) { Fail "no valid $($t[0]) table (missing, wrong length or bad checksum)." }
}
if ($mcfg -and -not (Test-AcpiTable $mcfg 'MCFG')) { $mcfg = $null }
[IO.File]::WriteAllBytes((Join-Path $DumpDir 'DSDT.aml'), $dsdt)
[IO.File]::WriteAllBytes((Join-Path $DumpDir 'APIC.aml'), $apic)
if ($mcfg) { [IO.File]::WriteAllBytes((Join-Path $DumpDir 'MCFG.aml'), $mcfg) }
Say (Describe-Table $dsdt)
Say (Describe-Table $apic)
Fact ('DSDT: ' + (Describe-Table $dsdt))
Fact ('MADT: ' + (Describe-Table $apic))
Say "copies in $DumpDir (firmware code: keep them to yourself)"

# ---------------------------------------------------------------------------------------------- parse the MADT
$madtEnabled = New-Object 'System.Collections.Generic.List[int]'
$madtCopy = New-Object 'System.Collections.Generic.List[byte[]]'
$madtTypes = @{}
$nmi = $null
$o = 44
while ($o + 2 -le $apic.Length) {
    $t = $apic[$o]; $l = $apic[$o + 1]
    if ($l -lt 2 -or $o + $l -gt $apic.Length) { Fail "MADT entry at offset $o is malformed." }
    $e = New-Object byte[] $l
    [Array]::Copy($apic, $o, $e, 0, $l)
    if ($madtTypes.ContainsKey([int]$t)) { $madtTypes[[int]$t]++ } else { $madtTypes[[int]$t] = 1 }
    switch ($t) {
        0  { if ($e[4] -band 1) { $madtEnabled.Add([int]$e[3]) } }
        9  { if ([BitConverter]::ToUInt32($e, 8) -band 1) { $madtEnabled.Add([int][BitConverter]::ToUInt32($e, 4)) } }
        1  { $madtCopy.Add($e) }
        2  { $madtCopy.Add($e) }
        3  { $madtCopy.Add($e) }
        5  { $madtCopy.Add($e) }
        4  { if (-not $nmi) { $nmi = @{ Flags = [BitConverter]::ToUInt16($e, 3); Lint = $e[5]; All = ($e[2] -eq 0xFF) } } }
        10 { if (-not $nmi) { $nmi = @{ Flags = [BitConverter]::ToUInt16($e, 2); Lint = $e[8]; All = ([BitConverter]::ToUInt32($e, 4) -eq [uint32]::MaxValue) } } }
        default { Warn "MADT entry type $t (length $l) is not carried over." }
    }
    $o += $l
}
$typeList = ($madtTypes.Keys | Sort-Object | ForEach-Object { "type $_ x$($madtTypes[$_])" }) -join ', '
Say "MADT entries: $typeList; enabled CPUs: $($madtEnabled.Count)"
Fact "MADT entries: $typeList; enabled CPUs: $($madtEnabled.Count) (APIC IDs $((@($madtEnabled) | Sort-Object) -join ','))"

# ---------------------------------------------------------------------------------------------- already patched?
$looksPatched = @()
$t0 = 0; if ($madtTypes.ContainsKey(0)) { $t0 = $madtTypes[0] }
if (-not $madtTypes.ContainsKey(9) -and $t0 -eq $MadtSlots) { $looksPatched += "the MADT has $MadtSlots Type 0 entries and no x2APIC entries (the format this script writes)" }
foreach ($mark in 'XU2C', 'XU3C') {       # names only this patch introduces (XSTA occurs in some firmware)
    if ([XegAcpi.Fw]::IndexOf($dsdt, [Text.Encoding]::ASCII.GetBytes($mark)) -ge 0) { $looksPatched += "the DSDT already contains the name $mark" }
}
if ($looksPatched.Count -gt 0) {
    $msg = 'These tables look already patched (' + ($looksPatched -join '; ') + '). Was Windows started through OpenCore? ' +
           'Start it from the firmware boot menu (F12) instead, or pass an untouched dump with -InputDir.'
    if (-not $Force) { Fail $msg }
    Warn $msg
}

# ================================================================================================ 3. CPU topology
Step 'Boot CPU'
$topo = $null
$probe = @'
$ErrorActionPreference = 'Stop'
if (-not ('XegCpu.K' -as [type])) {
    Add-Type -Namespace XegCpu -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr m); [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentThread(); [DllImport("kernel32.dll")] public static extern uint GetCurrentProcessorNumber();'
}
$X = [System.Runtime.Intrinsics.X86.X86Base]
$max = $X::CpuId(0, 0).Item1
$r = @()
for ($i = 0; $i -lt [Math]::Min([Environment]::ProcessorCount, 64); $i++) {
    [void][XegCpu.K]::SetThreadAffinityMask([XegCpu.K]::GetCurrentThread(), [UIntPtr]([uint64]1 -shl $i))
    [Threading.Thread]::Sleep(2)
    $on = [XegCpu.K]::GetCurrentProcessorNumber()
    $l1 = $X::CpuId(1, 0)
    $x2 = -1; if ($max -ge 0xB) { $x2 = $X::CpuId(0xB, 0).Item4 }
    $ty = 0; if ($max -ge 0x1A) { $ty = ($X::CpuId(0x1A, 0).Item1 -shr 24) -band 0xFF }
    $r += [pscustomobject]@{ Cpu = $i; On = [int]$on; Apic = [int](($l1.Item2 -shr 24) -band 0xFF); X2 = [int64]$x2; Type = [int]$ty; Hv = [int](($l1.Item3 -shr 31) -band 1) }
}
ConvertTo-Json -Compress -InputObject $r
'@
try {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $json = & ([scriptblock]::Create($probe))
    } else {
        $pwsh = $null
        $pc = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pc) { $pwsh = $pc.Source }
        elseif (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $pwsh -and $winget -and $BspApicId -lt 0 -and -not $OpenCoreLog -and [Environment]::UserInteractive) {
            Say 'The boot CPU is read with CPUID, which needs PowerShell 7 (pwsh.exe, from Microsoft).'
            $ans = Read-Host '   Install it now with "winget install --id Microsoft.PowerShell"? [y/N]'
            if ($ans -match '^(y|yes)$') {
                & $winget.Source install --id Microsoft.PowerShell --exact --source winget
                if (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
            }
        }
        if ($pwsh) {
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
            $r = Invoke-Native $pwsh @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) $WorkDir
            if ($r.Code -ne 0) { throw "pwsh exited $($r.Code): $($r.Out)" }
            $json = @(($r.StdOut -split "`r?`n") | Where-Object { $_.TrimStart().StartsWith('[') }) | Select-Object -Last 1
        } else {
            $json = $null
            Say 'PowerShell 7 (pwsh.exe) is not installed, so CPUID cannot be read from here.'
        }
    }
    if ($json) {
        $parsed = ConvertFrom-Json -InputObject ([string]$json)     # Windows PowerShell returns the array as one object
        $topo = @($parsed | ForEach-Object { $_ })
    }
} catch {
    Warn "CPUID probe failed: $($_.Exception.Message)"
    $topo = $null
}

$bspSource = ''
$bsp = -1
if ($topo) {
    $moved = @($topo | Where-Object { $_.On -ne $_.Cpu })
    $ids = @($topo | ForEach-Object { if ($_.X2 -ge 0) { [int]$_.X2 } else { $_.Apic } })
    $same = (@($ids | Sort-Object) -join ',') -eq (@($madtEnabled | Sort-Object) -join ',')
    if ($moved.Count -gt 0) { Warn 'could not pin the probe to every CPU; ignoring the CPUID results.'; $topo = $null }
    elseif (-not $same) {
        Warn ("CPUID APIC IDs ($(@($ids | Sort-Object) -join ',')) do not match the MADT's enabled CPUs; " +
              'ignoring the CPUID results (are these tables from another machine?)')
        $topo = $null
    } else {
        $bsp = $ids[0]
        $bspSource = 'CPUID on Windows logical CPU 0'
        if ($topo[0].Hv) { $bspSource += ' (hypervisor present; APIC IDs matched the MADT)' }
    }
}
if ($OpenCoreLog) {
    if (-not (Test-Path -LiteralPath $OpenCoreLog)) { Fail "-OpenCoreLog $OpenCoreLog not found." }
    $m = Select-String -LiteralPath $OpenCoreLog -Pattern 'OCCPU: RAW CPUID\(1\) EAX [0-9A-Fa-f]{8} EBX ([0-9A-Fa-f]{8})' | Select-Object -First 1
    if (-not $m) { Fail "no 'OCCPU: RAW CPUID(1)' line in $OpenCoreLog." }
    $fromLog = [Convert]::ToInt32($m.Matches[0].Groups[1].Value.Substring(0, 2), 16)
    Say "OpenCore log: CPUID(1).EBX $($m.Matches[0].Groups[1].Value) -> boot CPU APIC ID $fromLog"
    if ($bsp -ge 0 -and $bsp -ne $fromLog) { Warn "the OpenCore log says APIC $fromLog, CPUID here says $bsp; using the log." }
    $bsp = $fromLog; $bspSource = 'OpenCore log (OCCPU: RAW CPUID(1) EBX)'
}
if ($BspApicId -ge 0) {
    if ($bsp -ge 0 -and $bsp -ne $BspApicId) { Warn "-BspApicId $BspApicId differs from what was read ($bsp, $bspSource); using -BspApicId." }
    $bsp = $BspApicId; $bspSource = '-BspApicId'
}
if ($bsp -lt 0) {
    Fail ("cannot tell which CPU is the boot CPU. Either install PowerShell 7 (winget install --id Microsoft.PowerShell) and " +
          'run this again, or pass -OpenCoreLog <an opencore-*.txt log> or -BspApicId <n>.')
}
if (-not $madtEnabled.Contains($bsp)) { Fail "APIC ID $bsp is not an enabled CPU in this MADT." }
if ($madtEnabled.Count -gt $MadtSlots) { Fail "$($madtEnabled.Count) enabled CPUs do not fit the $MadtSlots-entry layout." }
foreach ($a in $madtEnabled) { if ($a -gt 254) { Fail "APIC ID $a does not fit a Type 0 MADT entry." } }

# P-core threads first (boot CPU and its sibling, then the rest), then E-cores and LP E-cores, each ascending
$typeOf = @{}
$typeSource = ''
if ($topo) {
    foreach ($c in $topo) { $id = if ($c.X2 -ge 0) { [int]$c.X2 } else { $c.Apic }; $typeOf[$id] = $c.Type }
    $typeSource = 'CPUID leaf 0x1A'
} else {
    foreach ($a in $madtEnabled) { if ($madtEnabled.Contains($a -bxor 1)) { $typeOf[$a] = 0x40 } else { $typeOf[$a] = 0x20 } }
    $typeSource = 'SMT pairs in the MADT (no CPUID)'
}
$sorted = @($madtEnabled | Sort-Object)
$order = @($bsp)
$order += @($sorted | Where-Object { $_ -ne $bsp -and ($_ -shr 1) -eq ($bsp -shr 1) })
$order += @($sorted | Where-Object { $order -notcontains $_ -and $typeOf[$_] -eq $typeOf[$bsp] })
$order += @($sorted | Where-Object { $order -notcontains $_ })
$pCount = @($madtEnabled | Where-Object { $typeOf[$_] -eq 0x40 }).Count
Say "boot CPU APIC ID $bsp ($bspSource)"
Say "MADT order (ProcessorId 0..$($order.Count - 1)): $($order -join ',')"
Fact "Boot CPU: APIC ID $bsp, from $bspSource"
Fact ("Core types from ${typeSource}: $pCount P-core threads, $($madtEnabled.Count - $pCount) E/LP-E cores")

# ================================================================================================ 4. MADT
Step "MADT -> $ApicOut"
if (-not $nmi) { $nmi = @{ Flags = 0x000D; Lint = 1; All = $true }; Warn 'no NMI entry in the MADT; using flags 0x000D, LINT1.' }
elseif (-not $nmi.All) { Warn 'the firmware NMI entry is per-CPU; writing it for all processors.' }
$body = New-Object 'System.Collections.Generic.List[byte]'
for ($slot = 0; $slot -lt $MadtSlots; $slot++) {
    if ($slot -lt $order.Count) { $body.AddRange([byte[]](0, 8, $slot, $order[$slot], 1, 0, 0, 0)) }
    else { $body.AddRange([byte[]](0, 8, $slot, 0xFF, 0, 0, 0, 0)) }
}
foreach ($e in $madtCopy) { $body.AddRange($e) }
$nf = [BitConverter]::GetBytes([uint16]$nmi.Flags)
$body.AddRange([byte[]](4, 6, 0xFF, $nf[0], $nf[1], $nmi.Lint))
$newApic = New-Object byte[] (44 + $body.Count)
[Array]::Copy($apic, 0, $newApic, 0, 44)
$body.CopyTo($newApic, 44)
[BitConverter]::GetBytes([uint32]$newApic.Length).CopyTo($newApic, 4)
Set-Checksum $newApic
$apicPath = Join-Path $OutDir $ApicOut
[IO.File]::WriteAllBytes($apicPath, $newApic)
Say "$($newApic.Length) bytes: $MadtSlots Type 0 ($($order.Count) enabled), $($madtCopy.Count) IOAPIC/override entries, 1 LAPIC NMI (flags $(Hex $nmi.Flags 4), LINT$($nmi.Lint))"

# ================================================================================================ 5. DSDT
Step 'DSDT: decompile'
$amlIn = Join-Path $WorkDir 'DSDT.aml'
$dslIn = Join-Path $WorkDir 'DSDT.dsl'
[IO.File]::WriteAllBytes($amlIn, $dsdt)
if (Test-Path -LiteralPath $dslIn) { Remove-Item -LiteralPath $dslIn -Force }
$r = Invoke-Native $iaslExe @('-d', 'DSDT.aml') $WorkDir
[IO.File]::WriteAllText((Join-Path $WorkDir 'iasl-decompile.log'), $r.Out)
if (-not (Test-Path -LiteralPath $dslIn)) { Fail "iasl -d produced no DSDT.dsl (see $WorkDir\iasl-decompile.log)." }
$lines = [IO.File]::ReadAllLines($dslIn)
$doc = [XegAcpi.AslDoc]::new($lines)
$Blk = $doc.Blocks
Say "$($lines.Count) lines, $($Blk.Count) blocks"

$del = New-Object bool[] $lines.Count
$before = @{}
$after = @{}
function Add-Before([int]$i, [string[]]$text) { if (-not $before.ContainsKey($i)) { $before[$i] = New-Object 'System.Collections.Generic.List[string]' }; $before[$i].AddRange($text) }
function Add-After([int]$i, [string[]]$text) { if (-not $after.ContainsKey($i)) { $after[$i] = New-Object 'System.Collections.Generic.List[string]' }; $after[$i].AddRange($text) }
function Remove-Block([int]$bi) { $b = $Blk[$bi]; for ($i = $b.Header; $i -le $b.Close; $i++) { $del[$i] = $true } }
function Set-Line([int]$i, [string]$text) { $lines[$i] = $text; $doc.Code[$i] = ([XegAcpi.AslDoc]::StripCode([string[]]@($text)))[0] }
function Indent([int]$i) { ([regex]::Match($lines[$i], '^\s*')).Value }
function Get-One([string]$kind, [string]$path) {
    $f = @($doc.Find($kind, $path))
    if ($f.Count -eq 1) { return $f[0] }
    return -1
}
function Child-Of([int]$parent, [string]$kind, [string]$name) {
    @($doc.Kids[$parent] | Where-Object { $Blk[$_].Kind -eq $kind -and [XegAcpi.AslDoc]::Seg($Blk[$_].Name) -eq $name })
}
function Lines-Matching([int]$bi, [string]$pattern) {
    $b = $Blk[$bi]
    @($b.Open..$b.Close | Where-Object { -not $del[$_] -and $doc.Code[$_] -match $pattern })
}

Step 'DSDT: changes'

# --- C1: External() lines that name method-local objects (iasl error 6163) ------------------------------------
# Each is replaced by a root External of the same name, as in the shipped table: the methods only call it after
# CondRefOf (NAME), which finds nothing at run time either way.
$bad = @($doc.MethodLocalExternals())
$rootExt = [ordered]@{}
foreach ($i in $bad) {
    $del[$i] = $true
    $m = [regex]::Match($doc.Code[$i], 'External\s*\(\s*([\\^A-Za-z0-9_.]+)\s*(,\s*(\w+))?')
    $leaf = ($m.Groups[1].Value -split '\.')[-1]
    $type = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { 'UnknownObj' }
    if (@($doc.Find('Method', "\$([XegAcpi.AslDoc]::Seg($leaf))")).Count -eq 0) { $rootExt[$leaf] = $type }
}
if ($rootExt.Count) { Add-After $bad[-1] @($rootExt.Keys | ForEach-Object { "    External (\$_, $($rootExt[$_])) // replaces the method-local External()s above" }) }
$badNames = (@($bad | ForEach-Object { ($lines[$_].Trim() -split '[ ,(]+')[1] }) -join ', ')
if ($bad.Count) { Change 'C1' 'compile fix' 'applied' ("replaced $($bad.Count) External() naming method-local objects (" + $badNames + ") by root External() for " + (@($rootExt.Keys) -join ', ')) }
else { Change 'C1' 'compile fix' 'none' 'no External() naming a method-local object' }

# --- C2: deferred forward Scopes ------------------------------------------------------------------------------
$fwd = @($doc.ForwardScopes())
foreach ($bi in $fwd) {
    $b = $Blk[$bi]; $ind = Indent $b.Header
    Add-Before $b.Header @("${ind}If (One) // deferred: target defined in a module-level If", "${ind}{")
    Add-After $b.Close @("${ind}}")
}
if ($fwd.Count) { Change 'C2' 'deferred forward Scopes' 'applied' "wrapped $($fwd.Count) in If (One): $((@($fwd | ForEach-Object { $Blk[$_].Path }) -join ', '))" }
else { Change 'C2' 'deferred forward Scopes' 'none' 'no module-level Scope() whose target is only defined inside a module-level If' }

# --- C3: PCHS guards ------------------------------------------------------------------------------------------
$pchs = @(); $elses = 0
for ($bi = 0; $bi -lt $Blk.Count; $bi++) {
    if ($Blk[$bi].Kind -ne 'If' -or $Blk[$bi].Code -notmatch '^If \(\(PCHS != (0x04|PCHX)\)\)$') { continue }
    $pchs += $bi
    $b = $Blk[$bi]
    $del[$b.Header] = $true; $del[$b.Open] = $true; $del[$b.Close] = $true
    $n = $doc.NextCodeLine($b.Close + 1)
    while ($n -ge 0 -and $doc.Code[$n].Trim() -match '^Else(If)?\b') {
        $eb = @($doc.Kids[$b.Parent] | Where-Object { $Blk[$_].Header -eq $n })
        if ($eb.Count -ne 1) { break }
        Remove-Block $eb[0]; $elses++
        $n = $doc.NextCodeLine($Blk[$eb[0]].Close + 1)
    }
}
if ($pchs.Count) {
    $ml = @($pchs | Where-Object { -not $Blk[$_].InMethod }).Count
    Change 'C3' 'PCHS guards' 'applied' "unwrapped $($pchs.Count) If ((PCHS != 0x04)) ($ml module-level, $($pchs.Count - $ml) in methods)$(if ($elses) { ", dropped $elses Else branches" })"
} else { Change 'C3' 'PCHS guards' 'not found' 'no If ((PCHS != 0x04)) in this DSDT' }

# --- C4: Name (_DEP, ...) -------------------------------------------------------------------------------------
$deps = @()
for ($bi = 0; $bi -lt $Blk.Count; $bi++) { if ($Blk[$bi].Code -match '^Name \(_DEP,') { $deps += $bi; Remove-Block $bi } }
for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $del[$i] -and $doc.Code[$i] -match '^\s*Name \(_DEP,.*\)\s*$') { $del[$i] = $true; $deps += -1 } }
if ($deps.Count) { Change 'C4' '_DEP removed' 'applied' "removed $($deps.Count) Name (_DEP, ...) (forward references that abort the table load; macOS does not use _DEP)" }
else { Change 'C4' '_DEP removed' 'none' 'no Name (_DEP, ...)' }

# --- C5: static PC00._CRS -------------------------------------------------------------------------------------
$pc00 = Get-One 'Device' '\_SB_.PC00'
$crs = @(); if ($pc00 -ge 0) { $crs = @(Child-Of $pc00 'Method' '_CRS') }
$busMax = $ShippedMaxBus; $busWhy = 'as in the shipped table'
if ($MaxBus -ge 0) { $busMax = $MaxBus; $busWhy = '-MaxBus' }
if ($crs.Count -eq 1) {
    $ecam = [long]($busMax + 2) * 0x100000          # the firmware formula is PBMX = (GPCL () >> 20) - 2
    $g = @(Lines-Matching $crs[0] 'GPCL \(\)')
    foreach ($i in $g) { Set-Line $i ($lines[$i] -replace 'GPCL \(\)', ((Hex $ecam 8) + ' /* static (was GPCL ()): bus 0..' + (Hex $busMax 2) + ' */')) }
    $mcIfs = @($doc.Kids[$crs[0]] | Where-Object { $Blk[$_].Kind -eq 'If' -and $Blk[$_].Code -match '\^MC\.' })
    foreach ($bi in $mcIfs) { Remove-Block $bi }
    $left = @(Lines-Matching $crs[0] '\^MC\.|GPCL|DVID|PCI_Config')
    $detail = "GPCL () -> $(Hex $ecam 8) (bus 0..$(Hex $busMax 2), $busWhy) in $($g.Count) place(s); removed $($mcIfs.Count) If (^MC.xxx) blocks"
    if ($left.Count) { Change 'C5' 'static PC00._CRS' 'partial' "$detail; still reads PCI config at DSL line(s) $((@($left | ForEach-Object { $_ + 1 })) -join ',')" }
    elseif ($g.Count -eq 0 -and $mcIfs.Count -eq 0) { Change 'C5' 'static PC00._CRS' 'none' 'PC00._CRS reads no PCI config space here' }
    else { Change 'C5' 'static PC00._CRS' 'applied' $detail }
    Fact "PC00._CRS: SystemMemory-backed windows (M32/M64, GNVS) and the OEM's own PCHA branch kept as they are"
} else { Change 'C5' 'static PC00._CRS' 'not found' "\_SB.PC00 / its _CRS method not found exactly once (PC00: $(if ($pc00 -ge 0) {'yes'} else {'no'}), _CRS: $($crs.Count))" }

# --- C6: PC00.XHCI / RHUB _PSx skip the PCI_Config DVID check -------------------------------------------------
$xhci = Get-One 'Device' '\_SB_.PC00.XHCI'
$xhciAdr = -1
if ($xhci -ge 0) {
    $ad = @(Lines-Matching $xhci '^\s*Name \(_ADR, (0x[0-9A-Fa-f]+|Zero)\)')
    if ($ad.Count -ge 1) { $v = [regex]::Match($doc.Code[$ad[0]], 'Name \(_ADR, (0x[0-9A-Fa-f]+|Zero)\)').Groups[1].Value; $xhciAdr = if ($v -eq 'Zero') { 0 } else { [Convert]::ToInt64($v, 16) } }
    $targets = @()
    foreach ($nm in '_PS0', '_PS3') { $targets += @(Child-Of $xhci 'Method' $nm | ForEach-Object { @{ L = "XHCI.$nm"; B = $_ } }) }
    $rhub = @(Child-Of $xhci 'Device' 'RHUB')
    if ($rhub.Count -eq 1) { foreach ($nm in '_PS0', '_PS2', '_PS3') { $targets += @(Child-Of $rhub[0] 'Method' $nm | ForEach-Object { @{ L = "XHCI.RHUB.$nm"; B = $_ } }) } }
    $done = @(); $odd = @()
    foreach ($t in $targets) {
        $hits = @(Lines-Matching $t.B '^\s*If \(\(DVID == 0xFFFF\)\)\s*$')
        if ($hits.Count -eq 1) {
            Set-Line $hits[0] ($lines[$hits[0]] -replace 'If \(\(DVID == 0xFFFF\)\)', 'If (Zero) // was: If ((DVID == 0xFFFF)), a PCI_Config read that fails on macOS')
            $done += $t.L
        } else { $odd += "$($t.L) ($($hits.Count) DVID checks)" }
    }
    if ($done.Count) { Change 'C6' 'XHCI _PSx DVID check' 'applied' ("skipped in " + ($done -join ', ') + $(if ($odd.Count) { '; not changed: ' + ($odd -join ', ') } else { '' })) }
    else { Change 'C6' 'XHCI _PSx DVID check' 'not found' "no If ((DVID == 0xFFFF)) in PC00.XHCI / RHUB _PS0/_PS2/_PS3 $(if ($odd.Count) { '(' + ($odd -join ', ') + ')' })" }
} else { Change 'C6' 'XHCI _PSx DVID check' 'not found' '\_SB.PC00.XHCI not found exactly once' }

# --- root-level Field entries that become fixed Names (C7 PU2C/PU3C, C8 IMxx) ---------------------------------
$rootFields = @()
for ($bi = 0; $bi -lt $Blk.Count; $bi++) {
    $b = $Blk[$bi]
    if ($b.Kind -eq 'Field' -and $b.Path -eq '\' -and -not $b.InMethod -and -not $b.InCond) { $rootFields += $bi }
}
function Find-FieldEntry([string]$name) {
    foreach ($fb in $rootFields) {
        $hit = @(Lines-Matching $fb "^\s*$name\s*,")
        if ($hit.Count -eq 1) { return @{ F = $fb; L = $hit[0] } }
    }
    return $null
}
function Set-FieldName($entry, [string]$name, [string]$value, [string]$why) {
    Set-Line $entry.L (($lines[$entry.L] -replace "^(\s*)$name(\s*,)", '$1$2') + " // was $name, now a Name below")
    Add-After $Blk[$entry.F].Close @("    Name ($name, $value) // $why")
}

# --- C7: PU2C / PU3C ------------------------------------------------------------------------------------------
$usb = $null
$usrCount = 0; $ladder2 = 0; $ladder3 = 0
if ($xhci -ge 0) {
    $usrCount = @($doc.Blocks | Where-Object { $_.Kind -eq 'Device' -and $_.Path -like '\_SB_.PC00.XHCI.*' -and $_.Path -match '\.USR\d$' }).Count
    foreach ($i in $Blk[$xhci].Open..$Blk[$xhci].Close) {
        $m = [regex]::Match($doc.Code[$i], 'If \(\((One|0x[0-9A-F]+) <= PU([23])C\)\)')
        if ($m.Success) {
            $v = if ($m.Groups[1].Value -eq 'One') { 1 } else { [Convert]::ToInt32($m.Groups[1].Value, 16) }
            if ($m.Groups[2].Value -eq '2') { $ladder2 = [Math]::Max($ladder2, $v) } else { $ladder3 = [Math]::Max($ladder3, $v) }
        }
    }
}
$hubPorts = $null
$pciDevs = @()
try { $pciDevs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' }) } catch { $pciDevs = @() }
if ($xhciAdr -ge 0 -and $pciDevs.Count) {
    foreach ($c in @($pciDevs | Where-Object { $_.Class -eq 'USB' })) {
        try {
            $busN = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName DEVPKEY_Device_BusNumber -ErrorAction Stop).Data
            $addr = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName DEVPKEY_Device_Address -ErrorAction Stop).Data
            if ($busN -ne 0 -or $addr -ne $xhciAdr) { continue }
            $kids = @((Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName DEVPKEY_Device_Children -ErrorAction Stop).Data)
            foreach ($k in $kids) {
                if ($k -notlike 'USB\ROOT_HUB*') { continue }
                $path = '\\?\' + ($k -replace '\\', '#') + '#{f18a0e88-c30c-11d0-8815-00a0c906bed8}'
                $res = [XegAcpi.UsbHub]::Probe($path)
                $hw = ($c.InstanceId -split '\\')[1] -replace '&SUBSYS.*$', ''
                if ($res[0] -ge 0) { $hubPorts = @{ Ctrl = $hw; Ports = $res[0]; U2 = $res[1]; U3 = $res[2]; Other = $res[3] } }
                else { Warn "USB root hub of $hw could not be opened (Win32 error $($res[1]))." }
            }
        } catch { }
    }
}
$pu2 = -1; $pu3 = -1; $puSource = ''
if ($hubPorts) {
    Say ("xHCI {0} at 00:{1:X2}.{2}: {3} root hub ports = {4} USB2 + {5} USB3{6}; {7} USRx device(s) in the DSDT" -f $hubPorts.Ctrl,
         ($xhciAdr -shr 16), ($xhciAdr -band 0xFFFF), $hubPorts.Ports, $hubPorts.U2, $hubPorts.U3,
         $(if ($hubPorts.Other) { " + $($hubPorts.Other) unknown" } else { '' }), $usrCount)
    $pu2 = $hubPorts.U2 - $usrCount; $pu3 = $hubPorts.U3
    $puSource = "Windows USB stack ($($hubPorts.Ctrl): $($hubPorts.U2) USB2 ports - $usrCount USR, $($hubPorts.U3) USB3 ports)"
}
if ($PU2C -ge 0) { $pu2 = $PU2C; $puSource = '-PU2C/-PU3C' }
if ($PU3C -ge 0) { $pu3 = $PU3C; $puSource = '-PU2C/-PU3C' }
if ($pu2 -lt 0 -or $pu3 -lt 0) {
    if ($pu2 -lt 0) { $pu2 = 10 }
    if ($pu3 -lt 0) { $pu3 = 2 }
    $puSource = 'NOT MEASURED: ThinkBook 14+ values used'
    Warn 'could not count the xHCI ports here; used the ThinkBook values PU2C/PU3C = 10/2. Check them (Linux: lsusb -t; or pass -PU2C/-PU3C).'
}
if ($ladder2 -gt 0 -and $pu2 -gt $ladder2) { Warn "PU2C $pu2 is more than the DSDT can create ($ladder2); using $ladder2."; $pu2 = $ladder2 }
if ($ladder3 -gt 0 -and $pu3 -gt $ladder3) { Warn "PU3C $pu3 is more than the DSDT can create ($ladder3); using $ladder3."; $pu3 = $ladder3 }
if ($xhci -ge 0) {
    $locals = @()
    foreach ($nm in 'PU2C', 'PU3C') {
        $h = @(Lines-Matching $xhci "^\s*Name \($nm, Zero\)\s*$")
        if ($h.Count -eq 1) { $locals += @{ N = $nm; L = $h[0] } }
    }
    $e2 = Find-FieldEntry 'PU2C'
    $e3 = Find-FieldEntry 'PU3C'
    if ($e2 -and $e3 -and $locals.Count -eq 2) {
        Set-FieldName $e2 'PU2C' (Hex $pu2 2) 'USB2 ports of PC00.XHCI.RHUB (macOS never runs the copy from the PCH NVS)'
        Set-FieldName $e3 'PU3C' (Hex $pu3 2) 'USB3 ports of PC00.XHCI.RHUB'
        foreach ($x in $locals) { Set-Line $x.L ($lines[$x.L] -replace "Name \($($x.N), Zero\)", ("Name (X" + $x.N.Substring(1) + ", Zero) // was $($x.N): XHCI now uses the root value")) }
        Change 'C7' 'PU2C / PU3C' 'applied' "root Names PU2C = $pu2, PU3C = $pu3 ($puSource); XHCI-local PU2C/PU3C renamed XU2C/XU3C"
    } else {
        Change 'C7' 'PU2C / PU3C' 'not found' "root Field PU2C: $([bool]$e2), PU3C: $([bool]$e3); XHCI-local Name (PU2C/PU3C, Zero): $($locals.Count) of 2"
    }
} else { Change 'C7' 'PU2C / PU3C' 'not found' '\_SB.PC00.XHCI not found exactly once' }

# --- C8: IMxx for the I2C controller(s) with a HID-over-I2C (PNP0C50) device ----------------------------------
$tpCtl = @{}
foreach ($b in $Blk) {
    if ($b.Kind -notin 'Device', 'Scope') { continue }
    $m = [regex]::Match($b.Path, '\.I2C(\d)(\.|$)')
    if (-not $m.Success) { continue }
    $hasHid = $false
    for ($i = $b.Open; $i -le $b.Close; $i++) { if ($lines[$i].Contains('"PNP0C50"') -or $lines[$i].Contains('EisaId ("PNP0C50")')) { $hasHid = $true; break } }
    if ($hasHid) { $tpCtl[$m.Groups[1].Value] = $true }
}
if ($tpCtl.Count) {
    $ok = @(); $miss = @()
    foreach ($n in ($tpCtl.Keys | Sort-Object)) {
        $fe = Find-FieldEntry "IM0$n"
        if ($fe) { Set-FieldName $fe "IM0$n" 'One' "I2C$n in PCI mode, so its _PS0/_PS3/_DSM exist (HID-over-I2C touchpad)"; $ok += "IM0$n" } else { $miss += "IM0$n" }
    }
    if ($ok.Count) { Change 'C8' 'I2C touchpad mode' 'applied' "$($ok -join ', ') = One (root Field -> Name), for $((@($tpCtl.Keys | Sort-Object | ForEach-Object { "I2C$_" })) -join ', ')$(if ($miss.Count) { "; no root Field for $($miss -join ', ')" })" }
    else { Change 'C8' 'I2C touchpad mode' 'not found' "no root Field entry for $($miss -join ', ')" }
} else { Change 'C8' 'I2C touchpad mode' 'not found' 'no PNP0C50 device under an I2Cn controller' }

# --- C9: OSYS default -----------------------------------------------------------------------------------------
$osDone = ''
for ($bi = 0; $bi -lt $Blk.Count -and -not $osDone; $bi++) {
    if ($Blk[$bi].Kind -ne 'Method' -or $Blk[$bi].Path -notmatch '\._INI$') { continue }
    $h = @(Lines-Matching $bi '^\s*OSYS = 0x03E8\s*$')
    if ($h.Count -ge 1) { Set-Line $h[0] ($lines[$h[0]] -replace 'OSYS = 0x03E8', 'OSYS = 0x07E5 // was 0x03E8: macOS answers no to _OSI ("Windows ..."), so OSYS stayed at 2000'); $osDone = $Blk[$bi].Path }
}
if ($osDone) { Change 'C9' 'OSYS default' 'applied' "${osDone}: OSYS = 0x03E8 -> 0x07E5 (Windows 2021), so the touchpad _CRS returns its interrupt" }
else { Change 'C9' 'OSYS default' 'not found' 'no OSYS = 0x03E8 in an _INI method' }

# --- C10: PS2K _STA -> XSTA (SSDT-TB21LD-PS2VIS supplies _STA = 0x0F on Darwin) ----------------------------------
$ps2k = @($Blk | Where-Object { $_.Kind -eq 'Device' -and $_.Path -match '\.PS2K$' -and -not $_.InMethod })
$ps2Done = @()
foreach ($d in $ps2k) {
    $di = $Blk.IndexOf($d)
    $sta = @(Child-Of $di 'Method' '_STA')
    if ($sta.Count -eq 1) { $hl = $Blk[$sta[0]].Header; Set-Line $hl ($lines[$hl] -replace 'Method \(_STA,', 'Method (XSTA,'); $ps2Done += $d.Path }
}
if ($ps2Done.Count) { Change 'C10' 'PS2K _STA -> XSTA' 'applied' ("$($ps2Done -join ', ') (for SSDT-TB21LD-PS2VIS)" + $(if ($ps2Done -notcontains '\_SB_.PC00.LPCB.PS2K') { ' -- NOT at \_SB.PC00.LPCB.PS2K, where SSDT-TB21LD-PS2VIS expects it' } else { '' })) }
else { Change 'C10' 'PS2K _STA -> XSTA' 'not found' 'no Device (PS2K) with a Method (_STA): disable SSDT-TB21LD-PS2VIS.aml' }

Change '--' 'USB port types' 'skipped' 'ThinkBook only (HS01/HS03/HS07 _UPC type 3 -> 0); not applied to other machines'

# --- checks for the release's own SSDTs ------------------------------------------------------------------------
$checks = @()
$lpcb = @($doc.Find('Device', '\_SB_.PC00.LPCB')).Count
$checks += "\_SB.PC00.LPCB exists (SSDT-TB21LD-EC, -PS2VIS): $(if ($lpcb) { 'yes' } else { 'NO -- disable both' })"
$ecHere = @($doc.Find('Device', '\_SB_.PC00.LPCB.EC__')).Count
$checks += "\_SB.PC00.LPCB.EC already defined (SSDT-TB21LD-EC adds one): $(if ($ecHere) { 'YES -- disable SSDT-TB21LD-EC.aml, or it fails to load' } else { 'no (fine)' })"
$usbx = @($doc.Find('Device', '\_SB_.USBX')).Count
$checks += "\_SB.USBX already defined (SSDT-USBX adds one): $(if ($usbx) { 'YES -- disable SSDT-USBX.aml' } else { 'no (fine)' })"
$cpuClash = @($Blk | Where-Object { ($_.Kind -eq 'Processor' -or $_.Kind -eq 'Device') -and $_.Path -match '^\\_SB_\.C0[0-2][0-9A-F]$' }).Count
$checks += "\_SB.C000..C02F already defined (SSDT-PLUG-ALT adds them): $(if ($cpuClash) { "YES ($cpuClash) -- SSDT-PLUG-ALT will fail" } else { 'no (fine)' })"
foreach ($c in $checks) { Say $c }

# --- PCI bus range check (live) -------------------------------------------------------------------------------
if ($pciDevs.Count -and -not $InputDir) {
    try {
        $buses = @(Get-PnpDeviceProperty -InstanceId @($pciDevs | ForEach-Object { $_.InstanceId }) -KeyName DEVPKEY_Device_BusNumber -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Data })
        $maxSeen = ($buses | Measure-Object -Maximum).Maximum
        Fact "PCI: highest bus number in use under Windows: $(Hex $maxSeen 2)"
        if ($null -ne $maxSeen -and $maxSeen -gt $busMax) {
            Warn "Windows uses PCI bus $(Hex $maxSeen 2), above the static range 0..$(Hex $busMax 2). Run again with -MaxBus $(Hex $maxSeen 2) or higher (MCFG allows up to $(if ($mcfg) { Hex $mcfg[55] 2 } else { '?' }))."
        }
    } catch { }
}

# ================================================================================================ 6. compile
Step "DSDT: compile -> $DsdtOut"
$outLines = New-Object 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($before.ContainsKey($i)) { $outLines.AddRange($before[$i]) }
    if (-not $del[$i]) { $outLines.Add($lines[$i]) }
    if ($after.ContainsKey($i)) { $outLines.AddRange($after[$i]) }
}
$hdrNote = @(
    '/*',
    " * Patched by acpi/make-acpi-tables.ps1 $ScriptVersion (xegfx-thinkbook14plus-mtl) for macOS with EFI-CLEAN-07Y.",
    " * Changes: $((@($Changes | Where-Object { $_.Status -eq 'applied' -or $_.Status -eq 'partial' } | ForEach-Object { $_.Id })) -join ', '); see report.txt.",
    ' */')
$dslOut = Join-Path $WorkDir 'DSDT-patched.dsl'
[IO.File]::WriteAllLines($dslOut, [string[]]($hdrNote + $outLines.ToArray()))
$prefix = Join-Path $WorkDir 'DSDT-patched'
$amlTmp = "$prefix.aml"
if (Test-Path -LiteralPath $amlTmp) { Remove-Item -LiteralPath $amlTmp -Force }
$argv = @('-vr', '-p', $prefix)
if ($Force) { $argv += '-f' }
$r = Invoke-Native $iaslExe ($argv + @($dslOut)) $WorkDir
[IO.File]::WriteAllText((Join-Path $WorkDir 'iasl-compile.log'), $r.Out)
$sum = [regex]::Match($r.Out, 'Compilation (complete|successful|failed)\.\s+(\d+) Errors?, (\d+) Warnings?, (\d+) Remarks?')
$errs = 0; $warns = 0
if ($sum.Success) { $errs = [int]$sum.Groups[2].Value; $warns = [int]$sum.Groups[3].Value }
$errLines = @(($r.Out -split "`r?`n") | Where-Object { $_ -match '^Error\s+\d+' })
Say "iasl: $errs errors, $warns warnings (log: $WorkDir\iasl-compile.log)"
foreach ($e in ($errLines | Select-Object -First 8)) { Say "  $e" }
Fact "iasl compile: $errs errors, $warns warnings$(if ($Force) { ' (-f)' })"
if (-not (Test-Path -LiteralPath $amlTmp) -or ($errs -gt 0 -and -not $Force)) {
    Fail "the patched DSDT did not compile cleanly. Send report.txt and the Error lines of $WorkDir\iasl-compile.log (not the .dsl)."
}
$newDsdt = [IO.File]::ReadAllBytes($amlTmp)
if (-not (Test-AcpiTable $newDsdt 'DSDT')) { Fail 'the compiled DSDT has a bad header or checksum.' }
$dsdtPath = Join-Path $OutDir $DsdtOut
[IO.File]::WriteAllBytes($dsdtPath, $newDsdt)
Say (Describe-Table $newDsdt)

# --- read it back: the changes must be in the compiled table ----------------------------------------------------
$rt = Join-Path $WorkDir 'roundtrip'
New-Item -ItemType Directory -Force -Path $rt | Out-Null
Copy-Item -LiteralPath $dsdtPath -Destination (Join-Path $rt 'DSDT.aml') -Force
$rtDsl = Join-Path $rt 'DSDT.dsl'
if (Test-Path -LiteralPath $rtDsl) { Remove-Item -LiteralPath $rtDsl -Force }
$null = Invoke-Native $iaslExe @('-d', 'DSDT.aml') $rt
if (Test-Path -LiteralPath $rtDsl) {
    $t = [IO.File]::ReadAllText($rtDsl)
    $nPchs = [regex]::Matches($t, 'If \(\(PCHS != 0x04\)\)').Count
    $nOne = [regex]::Matches($t, 'If \(One\)').Count
    $nDep = [regex]::Matches($t, 'Name \(_DEP,').Count
    $nXu = [regex]::Matches($t, 'Name \(XU[23]C').Count
    $nXsta = [regex]::Matches($t, 'Method \(XSTA').Count
    $v = @(
        ('If ((PCHS != 0x04)) left: {0}' -f $nPchs),
        ('If (One) wrappers: {0} (C2 added {1})' -f $nOne, $fwd.Count),
        ('Name (_DEP left: {0}' -f $nDep),
        ('XU2C/XU3C: {0}' -f $nXu),
        ('XSTA: {0}' -f $nXsta)
    )
    Say ('read back: ' + ($v -join ' | '))
    Fact ('Read back from the compiled DSDT: ' + ($v -join ' | '))
}

# ================================================================================================ 7. EFI
$apicTid = [BitConverter]::ToString($apic, 16, 8).Replace('-', '')
$apicTidText = Ascii $apic 16 8
if ($EfiPath) {
    Step "EFI: $EfiPath"
    $cfg = $null
    foreach ($c in @((Join-Path $EfiPath 'OC\config.plist'), (Join-Path $EfiPath 'EFI\OC\config.plist'))) { if (Test-Path -LiteralPath $c) { $cfg = (Resolve-Path -LiteralPath $c).Path; break } }
    if (-not $cfg) { Fail "no OC\config.plist under $EfiPath." }
    $acpiDir = Join-Path (Split-Path $cfg) 'ACPI'
    $bak = Join-Path $OutDir ('efi-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.XmlResolver = $null
    $xml.Load($cfg)
    function Get-Val($dict, [string]$key) {
        $el = @($dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        for ($i = 0; $i -lt $el.Count - 1; $i++) { if ($el[$i].Name -eq 'key' -and $el[$i].InnerText -eq $key) { return $el[$i + 1] } }
        return $null
    }
    function Set-Val($dict, [string]$key, [string]$tag, [string]$text) {
        $old = Get-Val $dict $key
        $new = $xml.CreateElement($tag)
        if ($null -ne $text -and $tag -ne 'true' -and $tag -ne 'false') { $new.InnerText = $text }
        if ($old) { [void]$dict.ReplaceChild($new, $old) }
    }
    $root = @($xml.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })[0]
    $acpi = Get-Val $root 'ACPI'
    $nAdd = 0; $nDel = 0
    foreach ($d in @((Get-Val $acpi 'Add').ChildNodes | Where-Object { $_.Name -eq 'dict' })) {
        $p = Get-Val $d 'Path'
        if ($p -and ($p.InnerText -eq $DsdtOut -or $p.InnerText -eq $ApicOut)) { Set-Val $d 'Enabled' 'true' $null; $nAdd++ }
    }
    foreach ($d in @((Get-Val $acpi 'Delete').ChildNodes | Where-Object { $_.Name -eq 'dict' })) {
        $s = Get-Val $d 'TableSignature'
        if ($s -and $s.InnerText.Trim() -eq [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('APIC'))) {
            Set-Val $d 'OemTableId' 'data' ([Convert]::ToBase64String($apic, 16, 8))
            Set-Val $d 'TableLength' 'integer' ([string]$apic.Length)
            Set-Val $d 'All' 'false' $null
            Set-Val $d 'Enabled' 'true' $null
            Set-Val $d 'Comment' 'string' "Replace the native MADT (OEM Table ID ""$apicTidText"", $($apic.Length) bytes), set by acpi/make-acpi-tables.ps1"
            $nDel++
        }
    }
    if ($nAdd -ne 2 -or $nDel -ne 1) { Fail "config.plist: expected ACPI > Add entries $DsdtOut and $ApicOut and one ACPI > Delete entry for APIC; found $nAdd and $nDel. The EFI folder was not changed." }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.Encoding = $utf8
    $ws.NewLineHandling = [System.Xml.NewLineHandling]::None
    $ms = New-Object System.IO.MemoryStream
    $w = [System.Xml.XmlWriter]::Create($ms, $ws)
    $xml.Save($w); $w.Close()
    # back to Apple's plist spelling, so the file only differs where the values changed
    $txt = $utf8.GetString($ms.ToArray())
    $txt = $txt -replace '^<\?xml version="1.0" encoding="utf-8"\?>', '<?xml version="1.0" encoding="UTF-8"?>'
    $txt = $txt -replace '(PropertyList-1\.0\.dtd")\[\]>', '$1>'
    $txt = $txt -replace '<(true|false|array|dict|string|data) />', '<$1/>'
    New-Item -ItemType Directory -Force -Path $bak, $acpiDir | Out-Null
    Copy-Item -LiteralPath $cfg -Destination (Join-Path $bak 'config.plist') -Force
    foreach ($f in @($DsdtOut, $ApicOut)) {
        $dst = Join-Path $acpiDir $f
        if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination (Join-Path $bak $f) -Force }
        Copy-Item -LiteralPath (Join-Path $OutDir $f) -Destination $dst -Force
    }
    [IO.File]::WriteAllText($cfg, $txt, $utf8)
    Say "copied $DsdtOut and $ApicOut to $acpiDir"
    Say "config.plist: ACPI > Add for both enabled; ACPI > Delete (APIC) = OEM Table ID ""$apicTidText"", length $($apic.Length), enabled"
    Say "previous config.plist (and tables, if any) saved in $bak"
}

# ================================================================================================ 8. report
$rep = New-Object 'System.Collections.Generic.List[string]'
$rep.Add("make-acpi-tables $ScriptVersion report, $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$rep.Add('(no serial numbers, UUIDs or table contents; fine to paste into an issue)')
$rep.Add('')
foreach ($f in $Facts) { $rep.Add($f) }
$rep.Add("USB: PC00.XHCI _ADR $(if ($xhciAdr -ge 0) { Hex $xhciAdr 8 } else { '?' }); PU2C = $pu2, PU3C = $pu3 from $puSource; DSDT can create up to $ladder2 HS / $ladder3 SS ports")
$rep.Add("MADT order (ProcessorId 0..$($order.Count - 1) -> APIC ID): $($order -join ',')")
$rep.Add('')
$rep.Add('DSDT changes:')
foreach ($c in $Changes) { $rep.Add(('  {0,-3} {1,-9} {2}: {3}' -f $c.Id, $c.Status, $c.What, $c.Detail)) }
$rep.Add('')
$rep.Add('Checks for the SSDTs in EFI-CLEAN-07Y:')
foreach ($c in $checks) { $rep.Add("  $c") }
if ($errLines.Count) { $rep.Add(''); $rep.Add('iasl errors:'); foreach ($e in $errLines) { $rep.Add("  $e") } }
if ($Warnings.Count) { $rep.Add(''); $rep.Add('Warnings:'); foreach ($w2 in $Warnings) { $rep.Add("  - $w2") } }
$rep.Add('')
$rep.Add('Output:')
$rep.Add("  $DsdtOut  $($newDsdt.Length) bytes  sha256 $(Get-Sha256 $dsdtPath)")
$rep.Add("  $ApicOut  $($newApic.Length) bytes  sha256 $(Get-Sha256 $apicPath)")
$rep.Add("  config.plist ACPI > Delete (APIC): OemTableId <$apicTid> (""$apicTidText""), TableLength $($apic.Length)$(if ($EfiPath) { ' -- set by -EfiPath' } else { ' -- set these by hand, or run again with -EfiPath' })")
$repPath = Join-Path $OutDir 'report.txt'
[IO.File]::WriteAllLines($repPath, $rep.ToArray())

Step 'Done'
Say "$dsdtPath"
Say "$apicPath"
Say "$repPath  <- post this one if something does not work"
if (-not $EfiPath) {
    Write-Host ''
    Write-Host '   Next: copy both .aml files to EFI\OC\ACPI of EFI-CLEAN-07Y and in config.plist' -ForegroundColor White
    Write-Host "     - ACPI > Add: enable $DsdtOut and $ApicOut"
    Write-Host "     - ACPI > Delete (TableSignature APIC): OemTableId = $apicTid (""$apicTidText""), TableLength = $($apic.Length), Enabled"
    Write-Host '     (or run this again with -EfiPath <that EFI folder> to do it automatically)'
}
Write-Host '   Keep another boot entry while testing. The dump\ and work\ folders hold firmware code: do not post them.'
if ($Warnings.Count) { Write-Host "   $($Warnings.Count) warning(s), listed in report.txt." -ForegroundColor Yellow }
