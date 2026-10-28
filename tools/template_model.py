#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_model.py -- bit-exact model of the Template core's picture (rtl/tango_core_template.v),
for the sim gate's goldens.  See the RTL header for the behaviour and its MiSTer sources.

The model runs the core frame by frame from reset, driven by what the testbench recorded at the END of every
frame k (the core's beam at (1649, 749)): the option word and joystick_0 the core saw there.  Options change
only in the vertical blank, so the word recorded at the end of frame k is the one frame k+1 is drawn with.
usage: template_model.py <run.json> <outdir>    (run.json from fpga/sim/tb_menu.cpp mode=template)
writes <outdir>/template_f<k>.png for every k in run.json "capture"
"""
import json, math, os, sys
from PIL import Image
FW, FH, W, H = 1650, 750, 1280, 720
Q = [max(0, min(127, round(127 * math.cos((i + 0.5) * math.pi / 512)))) for i in range(256)]

def cosv(x):
    x &= 1023
    i = ((~x) & 255) if (x >> 8) & 1 else (x & 255)
    return (127 - Q[i]) if ((x >> 9) ^ (x >> 8)) & 1 else (128 + Q[i])

MASK63 = (1 << 63) - 1
def lfsr_step(r):
    fb = 1 ^ (((r >> 62) ^ (r >> 60) ^ (r >> 59) ^ (r >> 57) ^ (r >> 53)) & 1)
    return ((r << 1) | fb) & MASK63

def rnd_c(r):
    b0, b1, b2 = r & 1, (r >> 1) & 1, (r >> 2) & 1
    return (b0 << 5) | (b1 << 4) | (b2 * 15)

def aspect_lo():
    """The low bit of the Aspect ratio entry, found by name in the core's CONF_STR as the firmware sets it
    (template_page.conf_str: sys/build_tools/confstr_expand.py; the framework's O[127:126], sys/tango_video_opts.vh).
    The RTL's bare build reads those bits itself, so a core reading other bits differs from this model."""
    import template_page as TP
    b = TP.entry_bits(TP.conf_str(), 'Aspect ratio')
    if b is None or b[0] - b[1] != 1:
        sys.exit(f'template_model.py: no two-bit "Aspect ratio" entry in the CONF_STR ({b})')
    return b[1]

def geom(status, ar_lo):
    """x0, core pixel width: Aspect ratio Full Screen (1) / 16:9 (3) 1280 wide; Original (0) / 4:3 (2) 960, centred"""
    return (0, 4) if ((status >> ar_lo) & 3) in (1, 3) else (160, 3)

def run(rec, capture, strip_bytes, dl_frame):
    """rec[k] = (status, joy) at the end of frame k.  Returns {k: Image} for k in capture."""
    out = {}
    r, rsave, vvc, sq = 0, 0, 0, [628, 348]
    status = 0
    last = max(capture)
    ar_lo = aspect_lo()
    for k in range(last + 1):
        x0, sc = geom(status, ar_lo)
        want = k in capture
        rows = []
        for y in range(H):
            startx = 7 if k == 0 and y == 0 else 0            # the beam starts at x 7 after reset
            row = []
            for b in range(320):
                row.append(rnd_c(r))
                if x0 + sc * b + sc - 1 >= startx: r = lfsr_step(r)
            rows.append(row)
            # line end: the next line starts a new core line (save) or repeats this one (restore)
            ny = y + 1
            if ny < H:
                if ny % 3 == 0: rsave = r
                else: r = rsave
        # line 749's end: ny = 0 -> save (vblank lines do not step)
        rsave = r
        if want:
            img = Image.new('RGB', (W, H)); px = img.load()
            col = (status >> 3) & 3
            loaded = dl_frame is not None and k > dl_frame
            for y in range(H):
                cl = y // 3
                cg = (cosv(vvc + (cl << 2)) >> 3) + 32
                row = rows[y]
                for x in range(W):
                    if sq[0] <= x < sq[0] + 24 and sq[1] <= y < sq[1] + 24: px[x, y] = (255, 255, 255); continue
                    if loaded and 688 <= y < 704 and 16 <= x < 656 and (x - 16) % 20 < 16:
                        v = strip_bytes[(x - 16) // 20]; px[x, y] = (v, v, v); continue
                    if not (x0 <= x < x0 + 320 * sc): px[x, y] = (0, 0, 0); continue
                    rc = row[(x - x0) // sc]
                    v = ((cg - rc) << 2) if cg >= rc else 0
                    px[x, y] = (v if col in (0, 1) else 0, v if col in (0, 2) else 0, v if col in (0, 3) else 0)
            out[k] = img
        # frame end: the option word / joystick seen there
        st, joy = rec[k]
        if st & 1: vvc = 0
        else: vvc = (vvc + (5 if (st >> 2) & 1 else 6)) & 1023
        R, L, D, U = joy & 1, (joy >> 1) & 1, (joy >> 2) & 1, (joy >> 3) & 1
        if R and not L: sq[0] = 1256 if sq[0] >= 1252 else sq[0] + 4
        if L and not R: sq[0] = 0 if sq[0] <= 4 else sq[0] - 4
        if D and not U: sq[1] = 696 if sq[1] >= 692 else sq[1] + 4
        if U and not D: sq[1] = 0 if sq[1] <= 4 else sq[1] - 4
        status = st
    return out

if __name__ == '__main__':
    run_json, outdir = sys.argv[1], sys.argv[2]
    J = json.load(open(run_json))
    rec = [(int(f['status'], 16), f['joy']) for f in J['frames']]
    data = open(J['file'], 'rb').read()[:32] if J.get('file') else bytes(32)
    imgs = run(rec, J['capture'], list(data) + [0] * (32 - len(data)), J.get('dl_frame'))
    os.makedirs(outdir, exist_ok=True)
    for k, im in imgs.items():
        im.save(os.path.join(outdir, f'template_f{k}.png')); print('wrote', os.path.join(outdir, f'template_f{k}.png'))
