#!/usr/bin/python3 -I
# ggtt-map.py -- read-only map of the Intel GPU's GGTT through XeGfxAccel's register window (debug.nvaccel_mmio_addr /
# debug.nvaccel_mmio_win: 64 dwords = 32 GGTT entries from any BAR0 offset; entries start at BAR0 + 8 MiB). Writes
# nothing to the GPU: it only moves the window and reads, then puts the window back.
# For the zero-copy flip's slots (2026-11-03: all four fixed slots at 0x50000000 read as in use, nothing flipped):
#   sudo /usr/bin/python3 -I /Volumes/PKG/metal-stack/desktop/ggtt-map.py
# Per 16 MiB of GGTT: 8 windows of 32 entries spread over it. '.' all one value (the most common such value = scratch),
# 'o' all one other value, '#' mixed. Then the 24 MiB slot candidates 0x40000000-0xF0000000 the patched flip would take.
import subprocess, sys, struct, collections, os

GSM = 0x800000
def sysctl(*a):
    return subprocess.run(["/usr/sbin/sysctl"] + list(a), capture_output=True, check=True).stdout
def window(entry):
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % (GSM + entry * 8))
    b = sysctl("-b", "debug.nvaccel_mmio_win")
    if len(b) != 256:
        sys.exit("debug.nvaccel_mmio_win gave %d bytes (stage 7 run? XeGfxAccel loaded?)" % len(b))
    return struct.unpack("<32Q", b)

if os.geteuid() != 0:
    sys.exit("run with sudo")
orig = int(sysctl("-n", "debug.nvaccel_mmio_addr").strip())
try:
    chunks = []          # (first entry, [values])
    for c in range(256):                       # 256 x 16 MiB = 4 GiB
        vals = []
        for s in range(8):
            vals += window(c * 4096 + s * 512)
        chunks.append(vals)
    # slot candidates, 24 MiB = 6144 entries: sample 24 windows (768 entries) spread over each
    cands = []
    lo, hi, stride = 0x40000000, 0xF0000000, 0x01800000
    a = lo
    while a + stride <= hi:
        e0 = a >> 12; vals = []
        for s in range(24):
            vals += window(e0 + s * 256)
        cands.append((a, vals))
        a += stride
finally:
    sysctl("-w", "debug.nvaccel_mmio_addr=%d" % orig)

uni = collections.Counter(v[0] for v in chunks if len(set(v)) == 1)
uni.update(v[0] for _, v in cands if len(set(v)) == 1)
scratch = uni.most_common(1)[0][0] if uni else None
def ch(vals):
    if len(set(vals)) != 1: return "#"
    return "." if vals[0] == scratch else "o"
print("scratch (most common uniform value): %s" % ("%016x" % scratch if scratch is not None else "none"))
print("other uniform values: %s" % ", ".join("%016x x%d" % (v, n) for v, n in uni.most_common()[1:6]))
print("GGTT, 16 MiB per character, 64 per line:")
for row in range(4):
    print("  %08x  %s" % (row << 30, "".join(ch(chunks[row * 64 + i]) for i in range(64))))
free = [a for a, v in cands if len(set(v)) == 1 and v[0] == scratch]
print("slot candidates 0x%08x-0x%08x (24 MiB): %d of %d all scratch (sampled)" % (lo, hi, len(free), len(cands)))
print("  first free: %s" % " ".join("%08x" % a for a in free[:8]))
busy = [(a, v) for a, v in cands if not (len(set(v)) == 1 and v[0] == scratch)]
for a, v in busy[:6]:
    d = collections.Counter(v)
    print("  busy %08x: %d distinct in %d sampled, e.g. %s" % (a, len(d), len(v), " ".join("%016x" % x for x, _ in d.most_common(3))))
print("fixed slots of 0.9.2 (0x50000000 + n*24 MiB):", " ".join(
    "%08x=%s" % (a, "free" if a in free else "BUSY") for a in (0x50000000 + i * stride for i in range(4))))
