#!/usr/bin/python3 -I
# ggtt-peek.py [GGTT address ...] -- print 8 GGTT entries at each address through XeGfxAccel's read-only register window
# (same window as ggtt-map.py; nothing is written to the GPU). Default: the panel's framebuffer (PLANE_SURF of pipe A,
# 0x80000000 after XgFbMove) and two ranges around it, to check the reader against entries whose content is known.
#   sudo /usr/bin/python3 -I /Volumes/PKG/metal-stack/desktop/ggtt-peek.py
import subprocess, sys, struct, os

GSM = 0x800000
def sysctl(*a):
    return subprocess.run(["/usr/sbin/sysctl"] + list(a), capture_output=True, check=True).stdout
def win(off):
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % off)
    return sysctl("-b", "debug.nvaccel_mmio_win")
if os.geteuid() != 0:
    sys.exit("run with sudo")
orig = int(sysctl("-n", "debug.nvaccel_mmio_addr").strip())
try:
    surf = struct.unpack("<64I", win(0x70180))[(0x7019c - 0x70180) // 4] & ~0xfff   # PLANE_SURF(pipe A)
    print("PLANE_SURF pipe A: %08x" % surf)
    addrs = [int(a, 16) for a in sys.argv[1:]] or [surf, 0x80000000, 0x80000000 + 5760 * 4096 - 8 * 4096, 0x81680000,
                                                   0x40000000, 0xc0000000, 0x00000000, 0xfee00000]
    for a in addrs:
        e = struct.unpack("<32Q", win(GSM + (a >> 12) * 8))[:8]
        print("%08x: %s" % (a, " ".join("%016x" % v for v in e)))
finally:
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % orig)
