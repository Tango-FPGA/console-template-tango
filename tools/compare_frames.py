#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""compare_frames.py -- pixel-for-pixel gate: RTL frames (PPM from tb_menu) vs goldens (PNG).
usage: compare_frames.py <rtl.ppm> <golden.png> [<rtl.ppm> <golden.png> ...]
Prints the mismatch count per pair (and how many fall inside the 880x560 panel at (200,80)) and
the first differences; exit 0 only if every pair has 0 mismatches."""
import sys
from PIL import Image
args = sys.argv[1:]
assert args and len(args) % 2 == 0, __doc__
total = 0
for rp, gp in zip(args[0::2], args[1::2]):
    rtl = Image.open(rp).convert('RGB'); ref = Image.open(gp).convert('RGB')
    assert rtl.size == ref.size == (1280, 720), (rtl.size, ref.size)
    a, b = rtl.load(), ref.load()
    bad = [(x, y, a[x, y], b[x, y]) for y in range(720) for x in range(1280) if a[x, y] != b[x, y]]
    inp = sum(1 for x, y, _, _ in bad if 200 <= x < 1080 and 80 <= y < 640)
    print(f'{rp} vs {gp}: mismatches {len(bad)} / {1280 * 720}  (inside panel: {inp})')
    for x, y, p, q in bad[:20]:
        print(f'  ({x},{y}) panel=({x - 200},{y - 80}) rtl={p} golden={q}')
    total += len(bad)
print('FRAMES PASS' if total == 0 else f'FRAMES FAIL ({total} mismatching pixels)')
sys.exit(1 if total else 0)
