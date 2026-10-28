#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""idle_check.py -- the "black until the core's first frame" checks (sys README, tango_video.v show_ok) on sim/tb_vproc.v
runs (sim/run_idle_gates.sh):
  idle_check.py novideo <run dir> [<osd stream>]   the core sends no picture (sim/tango_core_novideo.v): tango_video's
                                                   picture (de_out)
                                                   is 0 in every frame; the last frame is black outside the OSD panel
                                                   (x 200..1079, y 80..639), and with the stream (an OSD page played
                                                   over the link) it is that page over black, pixel for pixel, from
                                                   the OSD model (tools/osd-model/)
  idle_check.py video <run dir>                    the core's frames: every frame before the first picture is black
                                                   (every pixel 0, de_out 0 but for tango_video's beam lead: its first
                                                   few clocks of the next frame, at most LEAD); from the first picture on,
                                                   every frame has the whole 1280x720 picture (921600 de_out clocks: the
                                                   gate opened at a frame boundary, no torn first frame)
Exit 0 only if every check passes.
"""
import os, re, struct, sys
import numpy as np
from PIL import Image

FULL = 1280 * 720
LEAD = 32                                    # tango_video's beam leads the bench's frame boundary (LAT + VLAT - 2 = 14)

def frames(d):
    out = []; cur = None
    for l in open(os.path.join(d, 'run.log'), errors='replace'):
        m = re.match(r'frame (\d+): nonblack=(\d+)', l)
        if m: cur = [int(m.group(1)), int(m.group(2)), None]; out.append(cur); continue
        m = re.match(r'\s+picture=(\d+)', l)
        if m and cur is not None: cur[2] = int(m.group(1))
    return [tuple(x) for x in out]

def ppm(d, k):
    p = os.path.join(d, 'out_f%d.ppm' % k)
    return np.asarray(Image.open(p).convert('RGB')) if os.path.exists(p) else None

def osd_page(stream):
    """the page the stream leaves shown, rendered over black (the link-stream decoder of menu-tango's benches)"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'osd-model'))   # tools/osd-model/
    import export_hw as E, zosd as Z, pages as P
    d = open(stream, 'rb').read(); i = 0; recs = []
    while i < len(d):
        n = struct.unpack_from('<H', d, i)[0]
        if n != 0xFFFF: recs.append(d[i + 2:i + 2 + n]); i += 2 + n
        else: i += 6                                   # a wait record (tb_vproc.v header)
    atlas, pal, geom = {}, [None] * 17, None
    glyphs = [[0] * 512 for _ in range(2)]; rows = [[0] * 32 for _ in range(2)]; shown = 0; en = 0
    for r in recs:
        if len(r) < 2 or r[0] != 2: continue
        c, b = r[1], r[2:]
        if c == 0x01: en = b[0] & 1
        elif c == 0x11: geom = struct.unpack('>HHHHBBBB', bytes(b[:12]))
        elif c == 0x12:
            for k in range(b[1]): pal[b[0] + k] = tuple(b[2 + 3 * k:5 + 3 * k])
        elif c == 0x13:
            bpc = (geom[7] + 3) // 4 if geom else 6; col = b[0] << 8 | b[1]; body = b[2:]
            for k in range(len(body) // bpc): atlas[col + k] = int.from_bytes(body[k * bpc:(k + 1) * bpc], 'big')
        elif c == 0x14:
            bk, e = b[0] & 1, (b[1] << 8 | b[2]) & 511; body = b[3:]
            for k in range(len(body) // 4): glyphs[bk][(e + k) & 511] = int.from_bytes(body[4 * k:4 * k + 4], 'big')
        elif c == 0x15:
            bk, row = b[0] & 1, b[1] & 31; body = b[2:]
            for k in range(len(body) // 8): rows[bk][(row + k) & 31] = int.from_bytes(body[8 * k:8 * k + 8], 'big')
        elif c == 0x16: shown = b[0] & 1
    assert en == 1 and geom == (E.X0, E.Y0, P.W, P.H, P.SW, P.RH, P.TOP, 24), (en, geom)
    font = Z.Font(*P.FONTS['saira'])
    _, _, got = E.model_render(font)
    T = dict(E.build_tables(font, got['menu'], got['panel'], got['acc']))
    T['atlas'] = [atlas.get(i, 0) for i in range(1024)]; T['glyphs'] = glyphs[shown]
    T['rows'] = [w for v in rows[shown] for w in (v & 0xFFFFFFFF, v >> 32)]
    T['pal'] = pal[:16]; T['K'] = pal[16]
    return np.asarray(E.table_render(Image.new('RGB', (1280, 720), (0, 0, 0)), T, E.X0, E.Y0).convert('RGB'))

def main():
    mode, d = sys.argv[1], sys.argv[2]
    fails = 0
    def check(ok, msg):
        nonlocal fails
        print('  %s  %s' % ('PASS' if ok else 'FAIL', msg)); fails += 0 if ok else 1
    fr = frames(d)
    print('  frames (frame, non-black pixels, de_out clocks): %s' % fr)
    if not fr:
        print('  FAIL  no frames in %s/run.log' % d); return 1
    if mode == 'novideo':
        check(all(pic == 0 for _, _, pic in fr), 'no picture from the core: tango_video draws nothing in %d frames' % len(fr))
        last = fr[-1][0]; got = ppm(d, last)
        check(got is not None, 'frame %d dumped' % last)
        if got is None: return 1
        outside = np.ones((720, 1280), bool); outside[80:640, 200:1080] = False
        check(not got[outside].any(), 'frame %d: black outside the OSD panel' % last)
        if len(sys.argv) > 3:
            want = osd_page(sys.argv[3]); diff = int(np.any(got != want, axis=2).sum())
            check(diff == 0, 'frame %d = the OSD page over black (OSD model): %d pixels differ, %d non-black'
                  % (last, diff, int((got.max(axis=2) > 0).sum())))
        else:
            check(got.any(), 'frame %d: the OSD shows' % last)
    else:
        first = next((f for f, _, pic in fr if pic > LEAD), None)
        check(first is not None, 'the core\'s picture appears (frame %s)' % first)
        if first is None: return 1
        pre = [f for f, _, _ in fr if f < first]
        check(all(nb == 0 and (pic == 0 or (f == first - 1 and pic <= LEAD)) for f, nb, pic in fr if f < first),
              'frames %s: black (no pixel; de_out 0 but for the next frame\'s first clocks in frame %d)' % (pre, first - 1))
        check(all(pic == FULL for f, _, pic in fr if f >= first),
              'frames %d..: the whole picture in each (%d de_out clocks): the first one is not torn' % (first, FULL))
        dumped = [f for f in pre if ppm(d, f) is not None]
        check(all(not ppm(d, f).any() for f in dumped), 'dumped frames %s before it: every pixel 0' % dumped)
    print('idle_check %s: %s' % (mode, 'PASS' if not fails else 'FAIL (%d)' % fails))
    return 1 if fails else 0

if __name__ == '__main__':
    sys.exit(main())
