#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_audio.py -- the model of the Template's audio test (rtl/tango_core_template.v audio_test(),
status[50:48]): the AUDIO_L/R sample (signed) at CLK_PIX clock n after RESET, for each Audio test value.
1 1 kHz square, 2 440 Hz square, 3 Sweep, 4 Noise, 5 the 440 Hz square on AUDIO_L only (AUDIO_R 0: level_r);
anything else 0.  The RTL registers the sample once (at_out): the
value AUDIO shows during clock n is audio_test(state after n-1 clocks).  This module gives the generator state
after k clocks and the sample the RTL outputs at clock k + 1."""

CLK = 74_250_000
AMP = 8192

def square(k, half):
    """the level of a square whose half-period counter wraps at `half` clocks, after k clocks (starts low)"""
    return AMP if (k // half) % 2 else -AMP

def sweep_levels(n):
    """the sweep's level for clocks 1..n after RESET (list): phase += inc every clock, inc steps every 65536"""
    out, ph, inc, div, steps = [], 0, 2893, 0, 0
    for _ in range(n):
        ph = (ph + inc) & 0xFFFFFFFF
        div = (div + 1) & 0xFFFF
        if div == 0:
            if steps == 4551:
                steps, inc = 0, 2893
            else:
                steps, inc = steps + 1, inc + 190
        out.append(AMP if ph >> 31 else -AMP)
    return out

def lfsr_levels(n):
    """the noise level for clocks 1..n after RESET: 16-bit LFSR from 0xACE1, stepped every 64 clocks, top bit"""
    out, lf, div = [], 0xACE1, 0
    for _ in range(n):
        if div == 63:
            lf = ((lf << 1) & 0xFFFF) | (((lf >> 15) ^ (lf >> 13) ^ (lf >> 12) ^ (lf >> 10)) & 1)
        div = (div + 1) & 63
        out.append(AMP if lf >> 15 else -AMP)
    return out

def level(sel, k):
    """the generator's level after k clocks for the square waves (the cheap ones)"""
    if sel == 1:
        return square(k, 37125)
    if sel in (2, 5):
        return square(k, 84375)
    if sel == 0 or sel > 5:
        return 0
    raise ValueError("Sweep / Noise: use sweep_levels / lfsr_levels")

def level_r(sel, k):
    """AUDIO_R: the same as AUDIO_L, except 0 for value 5 (440 Hz left)"""
    return 0 if sel == 5 else level(sel, k)
