#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""measure_scale.py -- where the Template's picture lands at 720p, against MiSTer's rules.

usage: sim/measure_scale.py <frame> <iw> <ih> <arx> <ary> <scale> [<pattern>]
  <frame>    a 1280x720 frame: sim/obj_ascal_sys/out_f<k>.ppm, or a capture (PNG/PPM; thresholds below)
  <iw> <ih>  the core's frame (the Template's Source size, tools/template_patterns.py SIZES: 320 240, 256 240,
             256 224, 384 224, 160 144); <arx> <ary> the ARX/ARY the framework's Aspect ratio gives (sys/tango_video.v:
             4 3 Original = the Template's native shape, 0 0 Full Screen, 4 3 4:3, 16 9 16:9);
  <scale>    the framework's Scale, video_freak's SCALE (0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 Wider
             HV-Integer); <pattern> 1 = Pixel grid
Prints the picture box (bounding box of the non-black pixels) and the box MiSTer's rules give; with the Pixel grid
also the width of every column stripe (an output line in the columns band, native line 40) against nearest
neighbour, and the row heights down native column 9.  Exit 1 if the box differs or the stripe widths differ from
nearest neighbour's (their order may differ by ascal's phase at a non-integer ratio).
Run the real scaler first, e.g. Pixel grid + Wider HV-Integer at Original (the core's Pattern status[44:41] and
Source size status[47:45]; the framework's Aspect ratio status[127:126], Scale status[125:124], Scanlines
status[123:122], sys/tango_video_opts.vh; the word as 32 hex digits):
  TB_ARGS=+status=30000000000000000000020000000000 sim/run_tb_ascal_sys.sh 6
  python3 sim/measure_scale.py sim/obj_ascal_sys/out_f5.ppm 320 240 4 3 3 1

MiSTer's rules, as behaviour (our own code; nothing copied): video_scale_int in sys/video_freak.sv 141-328 of
MiSTer's current sys/ (Template_MiSTer 19e89ce, NES_MiSTer 2668b7e), its settled result, and the window of
sys/sys_top.v 903-993 (no ARC, no LFB): the same rules as sys/tango_video_geo.v.
"""
import sys
from collections import Counter
from PIL import Image

W, H = 1280, 720
M12 = 0xFFF


def scale_int(scale, hsize, vsize, arx, ary):
    """VIDEO_ARX/ARY as video_freak gives them for SCALE (bit 12 = a size)."""
    if scale == 0 or (ary == 0 and arx != 0):                  # 182-185: as given
        return arx, ary
    k = H // vsize                                              # 193-197
    if (k & M12) == 0:                                          # 202-208: taller than the screen
        return arx, ary
    oheight, htarget, fill = (vsize * k) & M12, 0, ary == 0     # 209-222
    if not fill:
        q = (oheight * arx) // ary                              # 225-238: the aspect width
        htarget, div_num = q & M12, q                           # 244-249
        mul = hsize * (((q // hsize) & M12) or 1)               # 255-259
        if mul <= W: hinteger = mul & M12                       # 264-267
        else: fill = True
    if fill:                                                    # 269-296: no aspect, or too wide
        div_num, kk = W, ((W // hsize) & M12) or 1
        hinteger, oheight = (hsize * kk) & M12, (vsize * kk) & M12
    wideres = (hinteger + hsize) & M12                          # 299
    narrow = (((htarget - hinteger) & M12) <= ((wideres - htarget) & M12)) or wideres > W   # 300
    wres = hinteger if hinteger == htarget else wideres        # 301
    ax = {2: hinteger, 3: hinteger if wres > W else wres, 4: hinteger if narrow else wres}.get(scale, div_num & M12)
    return 0x1000 | ax, 0x1000 | oheight                        # 313-320


def window(arx, ary):
    """sys_top's window for VIDEO_ARX/ARY -> (hmin, hmax, vmin, vmax)."""
    if ary == 0: ax = ay = sz = 0                               # ARY 0: ARC1/ARC2 or full; Tango has no ARC
    else: ax, ay, sz = arx & M12, ary & M12, (arx | ary) >> 12 & 1
    if ax == 0 or ay == 0: wc, hc = W, H
    elif sz: wc, hc = ax, ay
    else: wc, hc = (H * ax // ay) & M12, (W * ay // ax) & M12
    vw, vh = min(wc, W), min(hc, H)
    return (W - vw) >> 1, ((W - vw) >> 1) + vw - 1, (H - vh) >> 1, ((H - vh) >> 1) + vh - 1


def runs(seq):
    out = []
    for v in seq:
        if out and out[-1][0] == v: out[-1][1] += 1
        else: out.append([v, 1])
    return out


def main():
    if len(sys.argv) < 7:
        print(__doc__); return 2
    path, (iw, ih, arx, ary, sc) = sys.argv[1], map(int, sys.argv[2:7])
    pat = int(sys.argv[7]) if len(sys.argv) > 7 else 0
    img = Image.open(path).convert('RGB'); px = img.load()
    if img.size != (W, H):
        print(f'{path}: {img.size}, not 1280x720'); return 2
    lit = lambda x, y: max(px[x, y]) > 40                      # non-black, with room for capture noise
    xs = [x for x in range(W) if any(lit(x, y) for y in range(H))]
    ys = [y for y in range(H) if any(lit(x, y) for x in range(W))]
    if not xs:
        print(f'{path}: all black'); return 1
    h0, h1, v0, v1 = window(*scale_int(sc, iw, ih, arx, ary))
    bx0, bx1, by0, by1 = xs[0], xs[-1], ys[0], ys[-1]
    ok = (bx0, bx1, by0, by1) == (h0, h1, v0, v1)
    print(f'{path}: SCALE {sc}, {iw}x{ih} at {arx}:{ary}: box {bx1 - bx0 + 1} x {by1 - by0 + 1} at h {bx0}..{bx1} '
          f'v {by0}..{by1} | MiSTer: {h1 - h0 + 1} x {v1 - v0 + 1} at h {h0}..{h1} v {v0}..{v1}  '
          f'{"MATCH" if ok else "DIFFERENT"}')
    bad = 0 if ok else 1
    if pat == 1:
        mw, mh = bx1 - bx0 + 1, by1 - by0 + 1
        y = by0 + int(40.5 * mh / ih)                           # native line 40: the columns band
        white = [sum(px[x, y]) > 3 * 128 for x in range(bx0, bx1 + 1)]
        got = [n for _, n in runs(white)]
        want = [n for _, n in runs([((2 * ox + 1) * iw - 1) // (2 * mw) for ox in range(mw)])]
        print(f'    columns (line {y}): {len(got)} stripes, widths {dict(sorted(Counter(got).items()))}; '
              f'nearest neighbour {iw} -> {mw}: {dict(sorted(Counter(want).items()))}, sequence '
              f'{"IDENTICAL" if got == want else "differs at " + str([i for i in range(min(len(got), len(want))) if got[i] != want[i]][:12])}')
        if sorted(Counter(got).items()) != sorted(Counter(want).items()): bad += 1
        x = bx0 + int(9.5 * mw / iw)                            # native column 9 (odd): black in the columns band
        rr = [n for _, n in runs([sum(px[x, yy]) > 3 * 128 for yy in range(by0, by1 + 1)])]
        print(f'    rows (column {x}): first run {rr[0]} (the columns band, black there), heights inside '
              f'{dict(sorted(Counter(rr[1:-1]).items()))} (one double: the rows / checkerboard band edge), last {rr[-1]}')
    return bad


if __name__ == '__main__':
    sys.exit(main())
