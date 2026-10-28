#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""backgrounds.py -- the launcher's background, modelled the way the RTL makes it.

test_pattern(): Tango's only background (a test pattern, no frame buffer). Pure per-pixel logic -- x/y counters, compares, a per-line
   adder for the gradient, a midpoint (add/compare, no multiply) circle per line, a frame counter for the
   sweep. No framebuffer, no multiplier, no ROM.  The accent colour follows the launcher's Menu colour.
The loud parts (bars, ramps) sit in the margins the launcher panel does not cover, so menu text stays legible.
No wallpapers, no MiSTer wave: both would need a frame buffer.
"""
import math
from PIL import Image

W, H = 1280, 720
BG0, BG1 = (9, 12, 20), (16, 21, 34)          # vertical gradient, top -> bottom (per-line adder)
MINOR, MAJOR, RING = (22, 29, 45), (36, 46, 70), (58, 72, 104)
BARS = [(232, 236, 244), (242, 224, 74), (63, 208, 224), (79, 208, 138),
        (217, 91, 217), (229, 72, 77), (74, 123, 255), (18, 20, 28)]   # classic bar order, our tones

def _circle_spans(r, cy):
    """Per-line half-width of a circle -- the RTL steps this with the midpoint algorithm (adds only)."""
    spans = {}
    for y in range(cy - r, cy + r + 1):
        dy = y - cy
        spans[y] = int(math.isqrt(max(0, r * r - dy * dy)))
    return spans

def test_pattern(accent=(242, 163, 58), frame=0, sweep_on=True):
    im = Image.new('RGB', (W, H)); px = im.load()
    cx, cy = W // 2, H // 2
    rings = [(_circle_spans(r, cy), r) for r in (300, 150)]
    sweep = (frame * 3) % H                                   # scan line moving down 3 lines/frame
    for y in range(H):
        base = tuple(BG0[k] + (BG1[k] - BG0[k]) * y // H for k in range(3))
        for x in range(W):
            c = base
            # grids: minor every 40 px, major every 160 px (counters)
            if x % 40 == 0 or y % 40 == 0: c = MINOR
            if x % 160 == 0 or y % 160 == 0: c = MAJOR
            # centre crosshair
            if x in (cx - 1, cx) or y in (cy - 1, cy): c = RING
            # rings: pixel is on the outline if |x-cx| is within 2 px of the line's half-width
            for spans, r in rings:
                if y in spans:
                    # fill between this line's half-width and the previous line's (as the RTL midpoint step does)
                    hw = spans[y]; hp = spans.get(y - 1 if y > cy else y + 1, 0)
                    lo, hi = min(hw, hp), max(hw, hp)
                    if lo - 1 <= abs(x - cx) <= hi + 1: c = RING
            # the loud parts live in the margins the launcher panel (y 80..640) doesn't cover:
            # colour bars along the bottom (y 652..692), grey + accent ramps along the top (y 22..38, 42..48)
            if 240 <= x < 1040:
                if 652 <= y < 692: c = BARS[(x - 240) // 100]
                elif 22 <= y < 38:
                    v = ((x - 240) * 16 // 800) * 17; c = (v, v, v)
                elif 42 <= y < 48:                            # accent ramp: dark -> Menu colour
                    t = (x - 240) * 8 // 800
                    c = tuple(accent[k] * (t + 1) >> 3 for k in range(3))
            # corner brackets in the Menu colour (40 px arms, 48 px inset, 3 px thick)
            for bx, by, sx, sy in ((48, 48, 1, 1), (W - 49, 48, -1, 1), (48, H - 49, 1, -1), (W - 49, H - 49, -1, -1)):
                dx, dy2 = (x - bx) * sx, (y - by) * sy
                if (0 <= dx < 40 and 0 <= dy2 < 3) or (0 <= dy2 < 40 and 0 <= dx < 3): c = accent
            # small safe-area ticks at 5% of the width (64 px) -- the classic title-safe marks
            if x in (64, W - 65) and 330 <= y < 390: c = MAJOR
            # sweep: a soft bright scan line with a 6-line fading tail (compares on the frame counter)
            d = (sweep - y) % H
            if sweep_on and d < 6:
                a = (6 - d)
                c = tuple(min(255, c[k] + (accent[k] >> 3) * a // 2) for k in range(3))
            px[x, y] = c
    return im

def test_pattern_native(accent=(242, 163, 58), frame=0, sweep_on=True):
    """The scaler launcher's native 640 x 360 frame (fpga/rtl/tango_core_menu.v): test_pattern at the even x and even
    y -- the RTL computes the pattern on a 720p beam of its own and sends those pixels to ascal."""
    full = test_pattern(accent, frame, sweep_on).load()
    im = Image.new('RGB', (W // 2, H // 2)); px = im.load()
    for y in range(H // 2):
        for x in range(W // 2):
            px[x, y] = full[2 * x, 2 * y]
    return im

def test_pattern_scaled(accent=(242, 163, 58), frame=0):
    """The launcher's picture with nearest (no filter loaded): ascal scales the native frame x2 (its nearest source
    column floor(((2*ox+1)*640 - 1) / 2560) is ox // 2, the same for rows)."""
    return test_pattern_native(accent, frame).resize((W, H), Image.NEAREST)

_NOSWEEP = {}
def sweep_frame(img, x=100):
    """The pattern frame (0..239; the sweep, (3 * frame) % 720, repeats every 240 frames) whose sweep the launcher's
    scaled picture img (1280 x 720, nearest) shows: the even rows of column x (left of the launcher panel; at x = 100
    the pattern has only the gradient, the row grids, the crosshair rows and the sweep) that differ from the pattern
    without its sweep are its tail rows -- y with (sweep - y) % 720 < 6 -- which give the sweep.  None if no sweep
    fits (the picture is not the pattern)."""
    if x not in _NOSWEEP:
        _NOSWEEP[x] = test_pattern_native(frame=0, sweep_on=False).load()
    base = _NOSWEEP[x]; px = img.load()
    rows = {y for y in range(0, H, 2) if px[x, y] != base[x // 2, y // 2]}
    for s in range(0, H, 3):
        if rows == {y for y in range(0, H, 2) if (s - y) % H < 6}:
            return s // 3
    return None

if __name__ == '__main__':
    import os, sys
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'backgrounds'); os.makedirs(out, exist_ok=True)
    test_pattern(frame=int(sys.argv[1]) if len(sys.argv) > 1 else 40).save(os.path.join(out, 'test_pattern.png'))
    print('ok')
