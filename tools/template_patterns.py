#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_patterns.py -- the Template's test patterns and source sizes (ASCAL mode), the model of the RTL's
pattern() and size_tab() (rtl/tango_core_template.v): ONE FUNCTION PER PATTERN and ONE ROW PER SIZE, at
the index the RTL's case and CONF_STR's Pattern / Source size entries give them.  A pattern takes the native x,
y, the active size w x h and the native frame number f (0-255) and returns (R, G, B).  Used by
template_ascal_golden.py and sim/measure_scale.py.  Adding a pattern: README "Adding a test pattern".
"""

# ---- the source sizes: index = the Source size value (status[47:45]); the RTL's size_tab() rows
#   (name, active width NW, active height NH, total width FNW, total lines FNH, CE_DIV: one pixel per CE_DIV of
#   CLK_PIX = 74.25 MHz)
SIZES = [
    ('320x240',      320, 240, 400, 262, 12),   # 59.04 Hz, the Template's own
    ('256x240 NES',  256, 240, 341, 262, 14),   # 59.36 Hz
    ('256x224 SNES', 256, 224, 341, 262, 14),   # 59.36 Hz (also Mega Drive H32)
    ('384x224 CPS',  384, 224, 525, 262,  9),   # 59.98 Hz
    ('160x144 GB',   160, 144, 448, 154, 18),   # 59.79 Hz
]


def size(s):
    """The RTL's size_tab(): a value with no size is size 0."""
    return SIZES[s] if 0 <= s < len(SIZES) else SIZES[0]


def gradient(x, y, w, h, f):
    """0 Gradient: R = x, G = y, B = 0x80 -- the colour path and where the picture lands."""
    return (x & 255, y & 255, 0x80)


def pixel_grid(x, y, w, h, f):
    """1 Pixel grid: 1-px stripes, white on even and black on odd -- columns (3y < h: the top third of the lines),
    rows (3y < 2h), a checkerboard (the rest).  At an integer scale every stripe is k output pixels; otherwise
    they are uneven."""
    on = (~x & 1) if 3 * y < h else (~y & 1) if 3 * y < 2 * h else (~(x ^ y) & 1)
    v = 255 if on else 0
    return (v, v, v)


PATTERNS = [gradient, pixel_grid]          # index = the Pattern value (status[44:41]); NPAT in the RTL


def pattern(p, x, y, w=320, h=240, f=0):
    """The RTL's pattern(): a value with no pattern shows Gradient."""
    return (PATTERNS[p] if 0 <= p < len(PATTERNS) else gradient)(x, y, w, h, f)


def shown(rec):
    """The pattern shown after each frame-end record (status, joy) of a sim run (fpga/sim/tb_menu.cpp
    template_run.json): the OSD's Pattern (status[44:41]) when it changed since the previous record; else
    joystick A (bit 4) steps to the next pattern and B (bit 5) to the previous one, on a press (a 0 -> 1 change
    between records), wrapping.  The RTL samples at the native frame end; for presses and releases held over
    two or more records the two agree."""
    out, p, osd_q, a_q, b_q = [], 0, 0, 0, 0
    for st, joy in rec:
        osd, a, b = (st >> 41) & 15, (joy >> 4) & 1, (joy >> 5) & 1
        ah, bh = a and not a_q, b and not b_q
        if osd != osd_q:     p = osd if osd < len(PATTERNS) else 0
        elif ah and not bh:  p = (p + 1) % len(PATTERNS)
        elif bh and not ah:  p = (p - 1) % len(PATTERNS)
        osd_q, a_q, b_q = osd, a, b
        out.append(p)
    return out


def sizes_shown(rec):
    """The source size after each frame-end record: the OSD's Source size (status[47:45]), a value with no size
    being size 0; the RTL takes it at the native frame end."""
    return [s if s < len(SIZES) else 0 for s in (((st >> 45) & 7) for st, _ in rec)]
