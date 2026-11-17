#!/usr/bin/python3 -I
# backlight-peek.py -- read the panel backlight and panel power registers through XeGfxAccel's read-only register window
# (the same window as ggtt-peek.py; nothing is written to the GPU), to see whether this panel's brightness is the display
# engine's PWM (south display BLC_PWM_PCH_CTL1/2, both controllers) or something else (eDP AUX/DPCD, EC).
#   sudo /usr/bin/python3 -I /Volumes/PKG/metal-stack/desktop/backlight-peek.py
import subprocess, sys, struct, os

def sysctl(*a):
    return subprocess.run(["/usr/sbin/sysctl"] + list(a), capture_output=True, check=True).stdout
def rd(off):
    base = off & ~0xff
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % base)
    return struct.unpack("<64I", sysctl("-b", "debug.nvaccel_mmio_win"))[(off - base) // 4]
if os.geteuid() != 0:
    sys.exit("run with sudo")
orig = int(sysctl("-n", "debug.nvaccel_mmio_addr").strip())
try:
    # display 9+ (Broxton style, used from Cannon Point on): CTL, FREQ and DUTY are three registers per controller
    for ctl in (0, 1):
        b = 0xc8250 + 0x100 * ctl
        c, f, d = rd(b), rd(b + 4), rd(b + 8)
        print("controller %d  BXT_BLC_PWM_CTL %05x: %08x  enable=%d polarity=%d" % (ctl, b, c, c >> 31 & 1, c >> 29 & 1))
        print("              FREQ %05x: %d   DUTY %05x: %d   -> %s" % (b + 4, f, b + 8, d, "%.1f%%" % (100.0 * d / f) if f else "no period"))
    for name, off in (("PP_STATUS", 0xc7200), ("PP_CONTROL", 0xc7204), ("PP_STATUS (2)", 0xc7300), ("PP_CONTROL (2)", 0xc7304),
                      ("UTIL_PIN_CTL", 0x48400)):
        print("%-34s %05x: %08x" % (name, off, rd(off)))
finally:
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % orig)
