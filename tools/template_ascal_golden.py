#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_ascal_golden.py -- pattern check for the Template-ASCAL sim (sim/run_tb_template_ascal.sh, ascal_wrap_sim:
nearest-neighbour).

usage: template_ascal_golden.py <run.json> <menu_f<k>.ppm> [<menu_f<k>.ppm> ...]
Exit 0 only if all frames pass.

The pattern and the source size a frame must show come from template_patterns.shown() / sizes_shown() over the
run's frame-end records (run.json): the OSD's Pattern (status[44:41]) and the pad's A / B presses; the OSD's
Source size (status[47:45]).  The core applies a change at its native frame end, and ascal shows that frame a
frame or two later, so frame k is checked against the pattern and size after record k-3, and neither may change
in records k-3 .. k-1 (else the session's timing is wrong: FAIL).

Window geometry (observed from sim, confirmed by tango_video_geo + ascal):
  Before the options (frame 6): ascal_wrap_sim's default window 0..640 x 0..359 -- non-black check only.
  From frame 9: the session's options select Full Screen (the framework's Aspect ratio, status[127:126] = 1:
  tb_template.inc; sys/tango_video.v applies it), so the iw x ih frame (the source size) fills 1280x720.
    sx = floor(((2*ox+1)*iw - 1) / (2*ow))  ox = screen_x (X0=0)
    sy = floor(((2*oy+1)*ih - 1) / (2*oh))  oy = screen_y (Y0=0)
    Expected: template_patterns.pattern(p, sx, sy, iw, ih)  (+-5 tolerance)
"""
import json, os, re, sys
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import template_patterns as TP

IW, IH = 320, 240            # source frame (template active), unless the run selected another size
OW, OH = 1280, 720           # output window (full screen)
X0, Y0 = 0, 0

SCREEN_W, SCREEN_H = 1280, 720

# OSD panel bounds — avoid checking pixels inside the overlay
OSD_X0, OSD_X1 = 200, 1079
OSD_Y0, OSD_Y1 = 80, 639

# Default geometry (ascal_wrap_sim before geo fires): active 0..640 x 0..359
DEF_HMAX = 640
DEF_VMAX = 359
SETTLED_FROM = 9             # the first frame drawn with the session's options

TOL = 5  # pixel tolerance for pipeline rounding


def nn_src(ox, oy, ow=OW, oh=OH, iw=IW, ih=IH):
    sx = ((2 * ox + 1) * iw - 1) // (2 * ow)
    sy = ((2 * oy + 1) * ih - 1) // (2 * oh)
    return sx, sy


def in_osd(x, y):
    return OSD_X0 <= x <= OSD_X1 and OSD_Y0 <= y <= OSD_Y1


def check_frame(path, settled=True, pat=0, sz=0):
    """settled=True: full-screen geometry (f9+), checked against pattern pat at source size sz.  False: default
    geometry (f6)."""
    img = Image.open(path).convert('RGB')
    if img.size != (SCREEN_W, SCREEN_H):
        print(f'FAIL {path}: size {img.size}, expected ({SCREEN_W},{SCREEN_H})')
        return 1
    px = img.load()

    # 1. Check that the active window contains non-black pixels.
    nonblack = 0
    x_limit = SCREEN_W if settled else DEF_HMAX + 1
    y_limit = SCREEN_H if settled else DEF_VMAX + 1
    for y in range(0, y_limit, 30):
        for x in range(0, x_limit, 30):
            if not in_osd(x, y) and px[x, y] != (0, 0, 0):
                nonblack += 1
    if nonblack == 0:
        print(f'FAIL {path}: active window is entirely black (ascal not producing output)')
        return 1
    print(f'  {path}: {nonblack} non-black samples (PASS non-black check)')

    if not settled:
        # Frame 6: default geometry, just verify non-black
        return 0

    # 2. Pattern pixel check at safe positions (outside OSD panel).
    #    All in the full-screen window with settled geometry.
    #
    # Safe zones confirmed across the captured frames:
    #   y=30 (top strip, outside OSD y0=80): the picture in ALL frames
    #   x=10 (far-left, outside OSD x0=200): the picture in ALL frames
    #   Avoid bottom strip (y≥640) at x=60-1200: the download strip overlay
    #   (frame f13) and pad-cursor (f26) pollute that area.
    safe_spots = [
        # top strip: y=30 — outside OSD (y0=80), clean in all frames
        (10,  30), (50,  30), (100, 30), (400, 30), (640, 30), (1000, 30), (1270, 30),
        # far-left column: x=10 — outside OSD (x0=200), clean in all frames
        (10, 200), (10, 400), (10, 600), (10, 680),
        # bottom-left corner: safe from download strip which starts near x=60
        (20, 680), (40, 680),
    ]

    bad = 0
    for sx_scr, sy_scr in safe_spots:
        if not (0 <= sx_scr < SCREEN_W and 0 <= sy_scr < SCREEN_H):
            continue
        if in_osd(sx_scr, sy_scr):
            continue
        ox, oy = sx_scr - X0, sy_scr - Y0
        iw, ih = TP.size(sz)[1:3]
        src_x, src_y = nn_src(ox, oy, iw=iw, ih=ih)
        exp_r, exp_g, exp_b = TP.pattern(pat, src_x, src_y, iw, ih)
        r, g, b = px[sx_scr, sy_scr]
        if (abs(r - exp_r) > TOL or abs(g - exp_g) > TOL or abs(b - exp_b) > TOL):
            print(f'  MISMATCH ({sx_scr},{sy_scr}): got ({r},{g},{b}) expected ({exp_r},{exp_g},{exp_b})')
            bad += 1

    name = TP.PATTERNS[pat].__name__ if pat < len(TP.PATTERNS) else 'gradient'
    if bad:
        print(f'FAIL {path}: pattern {pat} ({name}) at {TP.size(sz)[0]}: {bad} pixel mismatches')
        return 1
    print(f'  {path}: pattern {pat} ({name}) at {TP.size(sz)[0]} check PASS')
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    J = json.load(open(sys.argv[1]))
    rec = [(int(f['status'], 16), f['joy']) for f in J['frames']]
    shown, sizes = TP.shown(rec), TP.sizes_shown(rec)
    fails = 0
    for p in sys.argv[2:]:
        k = int(re.search(r'_f(\d+)\.ppm$', p).group(1))
        if k < SETTLED_FROM:
            fails += check_frame(p, settled=False)
            continue
        want, wsz = shown[k - 3], sizes[k - 3]
        if any(s != want for s in shown[k - 3:k]) or any(s != wsz for s in sizes[k - 3:k]):
            print(f'FAIL {p}: the pattern or the size changes in records {k - 3}..{k - 1} ({shown[k - 3:k]}, '
                  f'{sizes[k - 3:k]}): capture this frame later')
            fails += 1
            continue
        fails += check_frame(p, settled=True, pat=want, sz=wsz)
    print('  patterns shown after each frame-end record:', ''.join(str(s) for s in shown))
    print('  source sizes after each frame-end record:  ', ''.join(str(s) for s in sizes))
    if fails:
        print(f'ASCAL GOLDEN: FAIL ({fails} frames)')
        sys.exit(1)
    print('ASCAL GOLDEN: PASS')


if __name__ == '__main__':
    main()
