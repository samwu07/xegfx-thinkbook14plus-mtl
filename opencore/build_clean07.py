r"""Build CLEAN-07A and CLEAN-07S from CLEAN-05A.

CLEAN-07A = CLEAN-05A + Misc/Security/AllowSetDefault = true: in the OpenCore picker, Ctrl+Enter on an entry makes it
            the default (so MAC, not Windows, starts after the 5 s timeout). Nothing else changes.
CLEAN-07S = CLEAN-07A + boot-arg -x (macOS Safe Mode). Safe Mode does not load the Auxiliary Kernel Collection, so a
            third-party kext that kills the boot (XeGfx 0.0.47, 2026-11-01) can be uninstalled from a running macOS.
            Rescue only: deploy CLEAN-07A again afterwards.
CLEAN-07X = CLEAN-07A + XeGfx 0.0.47 injected by OpenCore (Kernel/Add) instead of the auxiliary kernel collection,
            which hard-froze the desktop ~1 min after login (2026-11-01) although XeGfx never started. The kext stays
            idle (its only personality waits for IOResource XeGfxArm); run-xegfx-stages.sh loads it by hand. The GuC
            firmware is embedded in the binary, so no on-disk bundle is needed. Undo: deploy CLEAN-07A.
Wi-Fi fix (07A, 07S, 07Y since 2026-11-02 16:00): Kernel/Patch on AirportItlwm 2.4.0. Its iwx_rm_sta_cmd (the
            latitude_mld branch for the 7E40) walks TIDs 0..16 over a 9-entry queue table at softc+0x1e28 and writes
            0xffff into entries 9..15, i.e. over the next field, mac_ctxt_task: entries 11 and 12 turn the top halves of
            its function pointer and argument into 0xffffffff, and the next time the task runs taskq_thread jumps there
            -- the six "Kernel trap at 0xffffffff....1130" panics of 2026-11-01/02, 1-5 min after a Wi-Fi connect.
            The patch makes the loop walk entries 0..8 and treat i == 9 as the management queue (it was 16).
            Usage: python build_clean07.py [PACKAGE ...]   (no arguments: every package, as before)
"""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess, sys

R = Path(__file__).resolve().parents[2]
SRC = R / 'outputs/boot-first/CLEAN-05A'
OCV = R / 'work/boot-package-assets/OpenCorePkg-1.0.8/Utilities/ocvalidate/ocvalidate.exe'
G = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
XEGFX = R / 'work/dl/wtlintelgfx-0.0.47/XeGfx.kext'   # unpacked from XeGfx-0.0.47.zip (sha256 222ca676...)
XEGFX_BIN_SHA = '96bedf301e5a871965f5563fa0a7039789625cc100f3de4e4db3248fdac82e06'


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def die(m):
    print('ABORT: ' + m)
    sys.exit(1)


man = json.loads((SRC / 'UPDATE-MANIFEST.json').read_text(encoding='utf-8'))
for e in man['files']:
    if sha(SRC / e['relative_path']) != e['after_sha256']:
        die('CLEAN-05A hash mismatch: ' + e['relative_path'])


# work/fbreloc/build.sh; logic tested by test_fbreloc.py. 1.0 is kept byte for byte: it is what CLEAN-07F deployed
# (ImageBase 0x140000000; the 2026-11-01 build panic named its last page, 0x140005000). 1.1 has ImageBase 0.
FBRELOC = {'1.0': (R / 'work/fbreloc/out/FbRelocate-1.0.efi', '855fad7bbd19841d'),
           '1.1': (R / 'work/fbreloc/out/FbRelocate.efi', None)}


# AirportItlwm 2.4.0 (VedCloud, laobamac Sequoia d695c97) as shipped in CLEAN-05A; the patch is only valid for it
ITLWM_BIN = 'EFI/OC/Kexts/AirportItlwm.kext/Contents/MacOS/AirportItlwm'
ITLWM_BIN_SHA = '69d7efb58bd7c0883fd5c8cec212f06326576417bc975bea93c0b3a82fc341fd'
# ItlIwx::iwx_rm_sta_cmd +0x89 (0x81559): movl $0,-0x34(%rbp); cmpl $0x10,-0x34(%rbp); jg out; cmpl $0x10,-0x34(%rbp);
# sete %al; andb $1,%al; movb %al,-0x35(%rbp) -- both 0x10 become 0x09
ITLWM_FIND = bytes.fromhex('c745cc00000000 837dcc10 0f8f23010000 837dcc10 0f94c0 2401 8845cb')
ITLWM_REPL = bytes.fromhex('c745cc00000000 837dcc09 0f8f23010000 837dcc09 0f94c0 2401 8845cb')


def build(name, safe=False, xegfx=False, extra_args='', resolution='', fbreloc='', wifi_fix=False):
    if ONLY and name not in ONLY:
        return
    out = R / 'outputs/boot-first' / name
    if out.exists():
        shutil.rmtree(out)
    for e in man['files']:
        d = out / e['relative_path']
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SRC / e['relative_path'], d)
    cfgp = out / 'EFI/OC/config.plist'
    cfg = plistlib.loads(cfgp.read_bytes())
    assert cfg['Misc']['Security']['AllowSetDefault'] is False
    cfg['Misc']['Security']['AllowSetDefault'] = True
    if safe:
        ba = cfg['NVRAM']['Add'][G]['boot-args']
        assert '-x' not in ba.split()
        cfg['NVRAM']['Add'][G]['boot-args'] = ba + ' -x'
    if fbreloc:
        drv, want = FBRELOC[fbreloc]
        if not drv.is_file():
            die(f'{drv} missing: bash work/fbreloc/build.sh')
        if want and not sha(drv).startswith(want):
            die(f'{drv.name} is not the FbRelocate {fbreloc} that was deployed')
        shutil.copyfile(drv, out / 'EFI/OC/Drivers/FbRelocate.efi')
        cfg['UEFI']['Drivers'].append({
            'Arguments': '', 'Enabled': True, 'HideVerbose': False, 'LoadEarly': False, 'Path': 'FbRelocate.efi',
            'Comment': f'{name}: at ExitBootServices move the boot framebuffer GGTT mapping off GUC_GGTT_TOP '
                       f'(WTLIntelGfx #13), {"" if fbreloc == "1.0" else "FbRelocate " + fbreloc + ", "}'
                       f'sha256 {sha(drv)[:16]}'})
    if resolution:
        assert cfg['UEFI']['Output']['Resolution'] == 'Max'
        cfg['UEFI']['Output']['Resolution'] = resolution
    if extra_args:
        cfg['NVRAM']['Add'][G]['boot-args'] += ' ' + extra_args
    if xegfx:
        if sha(XEGFX / 'Contents/MacOS/XeGfx') != XEGFX_BIN_SHA:
            die('XeGfx binary is not the 0.0.47 release')
        fw = (XEGFX / 'Contents/Resources/mtl_guc_70.bin').read_bytes()
        if (XEGFX / 'Contents/MacOS/XeGfx').read_bytes().count(fw) != 1:
            die('GuC firmware is not embedded in the XeGfx binary')
        assert not any(k['BundlePath'] == 'XeGfx.kext' for k in cfg['Kernel']['Add'])
        shutil.copytree(XEGFX, out / 'EFI/OC/Kexts/XeGfx.kext')
        cfg['Kernel']['Add'].append({
            'Arch': 'x86_64', 'BundlePath': 'XeGfx.kext', 'Enabled': True, 'ExecutablePath': 'Contents/MacOS/XeGfx',
            'MaxKernel': '24.99.99', 'MinKernel': '24.0.0', 'PlistPath': 'Contents/Info.plist',
            'Comment': 'CLEAN-07X: WTLIntelGfx XeGfx 0.0.47 official zip, idle until run-xegfx-stages.sh loads it'})
    if wifi_fix:
        itlwm = (out / ITLWM_BIN).read_bytes()
        if sha(out / ITLWM_BIN) != ITLWM_BIN_SHA:
            die('AirportItlwm is not the 2.4.0 binary the Wi-Fi patch was made for')
        if itlwm.count(ITLWM_FIND) != 1:
            die('the Wi-Fi patch bytes do not occur exactly once in AirportItlwm')
        assert len(ITLWM_FIND) == len(ITLWM_REPL)
        assert not any(p.get('Identifier') == 'com.zxystd.AirportItlwm' for p in cfg['Kernel']['Patch'])
        cfg['Kernel']['Patch'].append({
            'Arch': 'x86_64', 'Base': '', 'Count': 1, 'Enabled': True, 'Identifier': 'com.zxystd.AirportItlwm',
            'Find': ITLWM_FIND, 'Replace': ITLWM_REPL, 'Mask': b'', 'ReplaceMask': b'', 'Limit': 0, 'Skip': 0,
            'MaxKernel': '', 'MinKernel': '',
            'Comment': 'AirportItlwm 2.4.0 iwx_rm_sta_cmd: walk the 9-entry TID queue table, not 16 TIDs '
                       '(its overrun corrupted mac_ctxt_task -> panic at 0xffffffff....1130)'})
    for k in [k for k in cfg if k.startswith('#Comment-CLEAN')]:
        cfg.pop(k)
    cfg['#Comment-CLEAN07'] = (f'{name}: CLEAN-05A + AllowSetDefault' + (' + -x (Safe Mode rescue, temporary)' if safe else '')
                               + (' + XeGfx 0.0.47 via Kernel/Add' if xegfx else '') + (f' + {extra_args}' if extra_args else '')
                               + (f' + UEFI/Output/Resolution {resolution}' if resolution else '')
                               + ((' + FbRelocate.efi' if fbreloc == '1.0' else f' + FbRelocate.efi {fbreloc}') if fbreloc else '')
                               + (' + AirportItlwm rm_sta overrun patch' if wifi_fix else '')
                               + ', by work/clean07/build_clean07.py')
    cfgp.write_bytes(plistlib.dumps(cfg, sort_keys=True))
    r = subprocess.run([str(OCV), str(cfgp)], capture_output=True, text=True)
    (out / 'ocvalidate.txt').write_text(r.stdout + r.stderr, encoding='utf-8')
    if r.returncode != 0 or 'No issues found' not in r.stdout:
        die(f'{name} ocvalidate: ' + (r.stdout + r.stderr)[-600:])
    files = sorted(p.relative_to(out).as_posix() for p in (out / 'EFI').rglob('*') if p.is_file())
    (out / 'UPDATE-MANIFEST.json').write_text(json.dumps(
        {'files': [{'relative_path': f, 'after_sha256': sha(out / f)} for f in files],
         'notes': cfg['#Comment-CLEAN07']}, indent=1), encoding='utf-8')
    changed = [f for f in files if not (SRC / f).exists() or sha(out / f) != sha(SRC / f)]
    print(f'{name}: ocvalidate ok | {len(files)} files | changed vs CLEAN-05A: {changed} | boot-args: '
          f'{cfg["NVRAM"]["Add"][G]["boot-args"]}')


ONLY = set(sys.argv[1:])
build('CLEAN-07A', wifi_fix=True)
build('CLEAN-07S', safe=True, wifi_fix=True)
build('CLEAN-07X', xegfx=True)
# CLEAN-07X froze at the login password too. Upstream README: NVRAM writes run in SMM on this class of firmware, and
# its open I-116 whole-CPU stall is much rarer with xegfx.nvram_trace=0, which it recommends and 07X lacked.
build('CLEAN-07Y', xegfx=True, extra_args='xegfx.nvram_trace=0', wifi_fix=True)
# 07Y stage 4: the GOP framebuffer (3072x1920, 22.5 MiB) sits at GGTT 0xFE800000 and crosses GUC_GGTT_TOP 0xFEE00000,
# where i915 maps the GuC image (band, upstream issue #13). If the firmware places it against the top of the GGTT,
# 2560x1600 (15.6 MiB) would start at 0xFF000000, clear of the GuC slot. Test: stage 2 only, read plane-surf-1-a.
build('CLEAN-07R', xegfx=True, extra_args='xegfx.nvram_trace=0', resolution='2560x1600@32')
# 07R: the GOP ignored 2560x1600 (native mode only). So move the scanout's GGTT mapping instead: FbRelocate.efi copies
# the 5760 entries from 0xFE800000 to 0x80000000 and repoints PLANE_SURF_1_A at ExitBootServices.
build('CLEAN-07F', xegfx=True, extra_args='xegfx.nvram_trace=0', fbreloc='1.0')
# 07F's build panic named page 0x140005000 = FbRelocate 1.0's last page at its preferred base. 07G: the same with
# FbRelocate 1.1 (ImageBase 0, the firmware chooses), for an A/B with work/fbreloc/ramfill-test.
build('CLEAN-07G', xegfx=True, extra_args='xegfx.nvram_trace=0', fbreloc='1.1')
