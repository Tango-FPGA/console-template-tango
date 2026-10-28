#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""vproc_golden.py -- the Template's picture through MiSTer's video processing (sys-tango README), from
models: the native frame (tools/template_patterns.py + the pad square), gamma, ascal nearest / polyphase
(sys/build_tools/ascal_poly_model.py), the framework's scanline dimming and the shadow mask -- compared pixel for
pixel with a 1280 x 720 frame of the real ascal netlist (sim/tb_vproc.v out_f<k>.ppm, or tb_ascal_sys.v).

usage: vproc_golden.py <frame.ppm> [--tables <vproc json>] [--status <hex>] [--win hmin,hmax,vmin,vmax]
                       [--out <golden.png>] [--diff <diff.png>]
  --tables  what the link / preset loaded (sys/build_tools/vproc_preset.py --json): flt_mode, the coefficient sets
            (2^frac phases; 'frac' 8 in the TANGO_VIDEO_PROC builds, 4 if absent), gamma, mask words.  Without it:
            nearest, no gamma, no mask (the framework before TANGO_VIDEO_PROC).
  --status  the option word (Pattern status[44:41], Source size [47:45], Scanlines [123:122]); default 0
  --win     the ascal window (tb_vproc / tb_ascal_sys print it per frame); default 160,1119,0,719 (320 x 240 4:3)
Exit 0 only if every pixel equals the model.
"""
import argparse, json, os, sys
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
for _p in (os.path.join(HERE, '..', 'sys', 'build_tools'), os.path.join(HERE, '..', '..', 'sys', 'build_tools')):
    sys.path.insert(0, _p)                   # this repository's sys/ (submodule), or one level up
import template_patterns as TP
import ascal_poly_model as AM

def native(status):
    """the Template's native frame (rtl/tango_core_template.v ASCAL mode): pattern + the 24 x 24 white square in the
    middle (no pad input), no ioctl strip"""
    pat = (status >> 41) & 15
    sz = (status >> 45) & 7
    name, nw, nh, fnw, fnh, cdiv = TP.size(sz)
    fn = TP.PATTERNS[pat] if pat < len(TP.PATTERNS) else TP.PATTERNS[0]
    sqx, sqy = (nw - 24) // 2, (nh - 24) // 2
    rows = []
    for y in range(nh):
        r = []
        for x in range(nw):
            if sqx <= x < sqx + 24 and sqy <= y < sqy + 24:
                r.append((255, 255, 255))
            else:
                r.append(tuple(fn(x, y, nw, nh, 0)))
        rows.append(r)
    return rows, nw, nh

def golden(status, tables, win):
    src, iw, ih = native(status)
    poly = False; hset = vset = hA = vA = None
    frac = 8                                     # nearest looks the same at any FRAC (only the fraction's top bit)
    if tables:
        frac = tables.get('frac', 4)             # ascal's FRAC (json from sys/build_tools/vproc_preset.py)
        g = tables.get('gamma') if tables.get('gamma_en') else None
        if g:
            src = [[(g[p[0]][0], g[p[1]][1], g[p[2]][2]) for p in row] for row in src]
        poly = bool(tables['flt_mode'] & 1)
        sets = {int(k): v for k, v in tables['sets'].items()}
        hset, vset = sets.get(0), sets.get(1)
        hA, vA = sets.get(2), sets.get(3)
    canvas = AM.scale(src, iw, ih, win, poly, hset, vset, hA, vA, frac=frac)
    sl = (status >> 122) & 3
    if tables and tables['flt_mode'] == 3:
        sl = 0                                   # the Scan filter draws the scanlines (tango_video.v sl_eff)
    out = []
    for y, row in enumerate(canvas):
        o = []
        for px in row:
            if px is None:
                o.append((0, 0, 0))
            elif sl and (y & 1):
                o.append(tuple(AM.dim(c, sl) for c in px))
            else:
                o.append(px)
        out.append(o)
    if tables and tables.get('mask_words'):
        out = AM.shadow_mask(out, win, tables['mask_words'])
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('frame'); ap.add_argument('--tables'); ap.add_argument('--status', default='0')
    ap.add_argument('--win', default='160,1119,0,719'); ap.add_argument('--out'); ap.add_argument('--diff')
    a = ap.parse_args()
    tables = json.load(open(a.tables)) if a.tables else None
    win = tuple(int(v) for v in a.win.split(','))
    g = golden(int(a.status, 16), tables, win)
    im = Image.open(a.frame).convert('RGB'); px = im.load()
    W, H = im.size
    bad = 0; first = []; maxd = 0
    dimg = Image.new('RGB', (W, H)) if a.diff else None
    for y in range(H):
        for x in range(W):
            e = g[y][x]; v = px[x, y]
            if e != v:
                bad += 1
                d = max(abs(e[c] - v[c]) for c in range(3)); maxd = max(maxd, d)
                if len(first) < 8: first.append(((x, y), v, e))
                if dimg: dimg.putpixel((x, y), (255, 0, 0))
    if a.out:
        gi = Image.new('RGB', (W, H)); gi.putdata([p for row in g for p in row]); gi.save(a.out)
    if dimg: dimg.save(a.diff)
    print('vproc_golden: %s  %s  %d of %d pixels differ (max %d)' % ('PASS' if bad == 0 else 'FAIL', a.frame, bad, W * H, maxd))
    for f in first: print('   at', f[0], 'sim', f[1], 'model', f[2])
    sys.exit(0 if bad == 0 else 1)

if __name__ == '__main__':
    main()
