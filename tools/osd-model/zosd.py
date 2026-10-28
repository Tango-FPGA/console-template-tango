#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""zosd.py -- Tango: MiSTer overlay panel with a real anti-aliased PROPORTIONAL font.

Hardware modelled (per core, no SDRAM, no multipliers):
  atlas     COLUMN-MAJOR: one word per glyph column = sh rows x 2-bit coverage (e.g. 28 rows -> 56 bits).
            Glyphs packed back to back, only their real width is stored.  Address = colbase + sx (one adder).
            The same atlas draws the rotated banner: in the strip, the scanline picks the glyph COLUMN and
            the x position picks the bit -- so no rotated copy is stored.
  glyphs    list entries {x[10:0], colbase[10:0], width[4:0], colour[3:0]} = 31 bits  -> 1024 x 36 BSRAM
            per bank (2 banks; TANGO_GLYPH_SLOTS, widened from 512 to 1024)
            per row sorted by x; the active glyph is the last one whose x <= pixel x.  A glyph's ink that
            runs under the NEXT glyph's start is cut (single glyph pipe) -- the model reports how much.
  rows      row table {y, bar x0/x1/colour, first glyph, count, rule}  -> 1 BSRAM, read once per line
  panel     rounded corners: ONE 16x16 2-bit quarter mask, mirrored for the 4 corners; translucent bg = game>>2 + K
  bar       pill caps: 2-bit coverage from a small cap mask ROM
  blend     2-bit coverage -> 0, 3/8, 5/8, 1  (x3, x5 = shift-add), mix = a + ((b-a)*w)>>3
BL616 does the layout (measuring, kerning, right-align) and writes rows + glyph entries;
the atlas is uploaded at core start (Gowin BSRAM init doesn't survive on silicon).
"""
import freetype, math
from PIL import Image, ImageDraw

LV = (0, 3, 5, 8)
BSRAM_CFG = [(16384, 1), (8192, 2), (4096, 4), (2048, 9), (1024, 18), (512, 36)]

def blocks(depth, width):
    return min(math.ceil(width / w) * math.ceil(depth / d) for d, w in BSRAM_CFG)

def quarter_mask(r):   # 2-bit coverage, 16x16, for the top-left corner (mirrored for the others)
    m = [[0] * 16 for _ in range(16)]
    for y in range(16):
        for x in range(16):
            n = sum(1 for a in range(4) for b in range(4) if math.hypot(x + (a + .5) / 4 - r, y + (b + .5) / 4 - r) <= r)
            inside_square = x >= r or y >= r
            m[y][x] = 3 if inside_square else (n * 3 + 8) // 16
    return m

def mix(a, b, w8): return a + (((b - a) * w8) >> 3)

class Font:
    def __init__(self, path, px, sh=64):
        face = freetype.Face(path); face.set_pixel_sizes(0, px)
        self.asc = face.size.ascender >> 6; self.sh = sh or (self.asc + (-(face.size.descender >> 6)))
        self.cols, self.adv, self.clip = {}, {}, 0
        for c in range(32, 127):
            face.load_char(chr(c), freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_LIGHT)
            g = face.glyph; b = g.bitmap; lb = max(0, g.bitmap_left)
            w = max(1, lb + b.width); cols = [[0] * self.sh for _ in range(w)]
            for y in range(b.rows):
                for x in range(b.width):
                    Y = self.asc - g.bitmap_top + y; v = b.buffer[y * b.pitch + x]
                    if 0 <= Y < self.sh: cols[lb + x][Y] = max(cols[lb + x][Y], (v * 3 + 127) // 255)
                    elif v: self.clip += 1
            self.cols[chr(c)] = cols; self.adv[chr(c)] = int(round(g.advance.x / 64))
        rows = [y for v in self.cols.values() for col in v for y, a in enumerate(col) if a]
        t0, t1 = min(rows), max(rows) + 1
        for k in self.cols: self.cols[k] = [col[t0:t1] for col in self.cols[k]]
        self.asc -= t0; self.sh = t1 - t0
        face.load_char('H', freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_LIGHT); self.cap = face.glyph.bitmap_top
        self._chevron()
    def _icon(self, code, w, draw):   # custom glyphs: drawn once at 4x, box-filtered to 2-bit, stored like any glyph
        S = 4; h = self.sh
        im = Image.new('L', (w * S, h * S)); draw(ImageDraw.Draw(im), S, w * S, (self.asc - self.cap // 2) * S, self.cap * S)
        im = im.resize((w, h), Image.BOX); p = im.load()
        self.cols[code] = [[(p[x, y] * 3 + 127) // 255 for y in range(h)] for x in range(w)]
        self.adv[code] = w + 2
    def _chevron(self):
        lw = int(4 * max(2, self.sh / 12)); w = max(6, self.sh // 3)
        # 0x7F chevron right (sub-menu), 0x83 chevron left (back)
        self._icon('\x7f', w, lambda d, S, W, cy, ch: d.line([(S, cy - ch * .42), (W - S * 1.5, cy), (S, cy + ch * .42)], fill=255, width=lw))
        self._icon('\x83', w, lambda d, S, W, cy, ch: d.line([(W - S, cy - ch * .42), (S * 1.5, cy), (W - S, cy + ch * .42)], fill=255, width=lw))
        fw = self.cap + 5   # 0x80 folder
        def folder(d, S, W, cy, ch):
            t, b = cy - ch * .5, cy + ch * .5
            d.polygon([(S, t), (W * .42, t), (W * .52, t + ch * .16), (W - S, t + ch * .16), (W - S, b), (S, b)], fill=255)
        self._icon('\x80', fw, folder)
        def up(d, S, W, cy, ch):   # 0x81 "up one level": arrow up
            t, b = cy - ch * .5, cy + ch * .5
            d.polygon([(W / 2, t), (W - S, t + ch * .45), (W * .62, t + ch * .45), (W * .62, b), (W * .38, b), (W * .38, t + ch * .45), (S, t + ch * .45)], fill=255)
        self._icon('\x81', self.cap, up)
        def check(d, S, W, cy, ch):  # 0x82 check mark
            d.line([(S, cy), (W * .4, cy + ch * .38), (W - S, cy - ch * .45)], fill=255, width=lw)
        self._icon('\x82', self.cap, check)
        def seg(fill):   # 0x84 / 0x85 volume segment, filled / empty
            def d_(d, S, W, cy, ch):
                box = [S, cy - ch * .45, W - S * 2, cy + ch * .45]
                if fill: d.rectangle(box, fill=255)
                else: d.rectangle(box, outline=255, width=S)
            return d_
        self._icon('\x84', max(5, self.cap // 2), seg(True))
        self._icon('\x85', max(5, self.cap // 2), seg(False))
        # 0x86 wordmark brick: a solid 4-column, full-height cell.  The About page's wordmark draws each pixel of its
        # bitmap as two bricks side by side (8 px wide), so the whole logo costs 4 atlas columns, however big it is.
        self.cols['\x86'] = [[3] * self.sh for _ in range(4)]
        self.adv['\x86'] = 4
    def width(self, s): return sum(self.adv[c] for c in s)
    def total_cols(self): return sum(len(v) for v in self.cols.values())
    def bsram(self): return blocks(self.total_cols(), 2 * self.sh)

class Menu:
    """What the BL616 writes (rows, glyphs, banner) + what the RTL does (render)."""
    def __init__(self, font, pal, W, H, strip_w, row_h, top):
        self.f, self.pal, self.W, self.H = font, pal, W, H
        self.strip_w, self.row_h, self.top = strip_w, row_h, top
        self.rows = {}; self.banner = []; self.mask = quarter_mask(14)
    def row(self, i):
        return self.rows.setdefault(i, dict(bar=None, glyphs=[], rule=None))
    def text(self, i, x, s, col):
        r = self.row(i)
        for ch in s: r['glyphs'].append((x, ch, col)); x += self.f.adv[ch]
        return x
    def text_r(self, i, x_end, s, col): return self.text(i, x_end - self.f.width(s), s, col)
    def bar(self, i, x0, x1, col, inset=3): self.row(i)['bar'] = (x0, x1, col, inset)
    def rule(self, i, col, at=None): self.row(i)['rule'] = (col, self.row_h // 2 if at is None else at)
    def banner_text(self, s, col, y_bottom, x_inset):
        y = y_bottom
        for ch in s: self.banner.append((y, ch, col)); y -= self.f.adv[ch]   # reads bottom to top
        self.bx = x_inset
    def stats(self):
        n = sum(len(r['glyphs']) for r in self.rows.values()) + len(self.banner); cut = 0
        for r in self.rows.values():
            g = sorted(r['glyphs'], key=lambda e: e[0])
            for (x, ch, _), (nx, _, _) in zip(g, g[1:]):
                for sx in range(nx - x, len(self.f.cols[ch])): cut += sum(1 for v in self.f.cols[ch][sx] if v)
        return n, cut
    def render(self, frame, x0, y0, panel, acc):
        px = frame.load(); f = self.f
        K = tuple(c * 3 >> 2 for c in self.pal[panel]); A = self.pal[acc]
        lines = {}
        for i, r in self.rows.items(): lines[i] = (sorted(r['glyphs'], key=lambda e: e[0]), r)
        for y in range(self.H):
            ri = (y - self.top) // self.row_h if y >= self.top else -1; ty = (y - self.top) % self.row_h
            gl, r = lines.get(ri, ([], None))
            gy = ty - ((self.row_h + f.cap) // 2 - f.asc)          # caps centred in the row (BL616 sets the offset)
            bn = None                                              # banner glyph column for this line
            for by, ch, col in self.banner:
                sx = by - y
                if 0 <= sx < len(f.cols[ch]): bn = (f.cols[ch][sx], col)
            gi = -1
            for x in range(self.W):
                mx = x if x < 16 else (self.W - 1 - x if x >= self.W - 16 else 99)
                my = y if y < 16 else (self.H - 1 - y if y >= self.H - 16 else 99)
                cov = self.mask[my][mx] if (mx < 16 and my < 16) else 3
                if cov == 0: continue
                X, Y = x0 + x, y0 + y; g = px[X, Y]
                if x < self.strip_w:
                    c = A
                    if bn:
                        by = x - self.bx
                        if 0 <= by < f.sh: c = tuple(mix(c[k], self.pal[bn[1]][k], LV[bn[0][by]]) for k in range(3))
                else:
                    c = tuple((g[k] >> 2) + K[k] for k in range(3))
                    if r is not None:
                        if r['rule'] and ty == r['rule'][1]:
                            c = tuple(mix(c[k], self.pal[r['rule'][0]][k], 5) for k in range(3))
                        if r['bar']:
                            bx0, bx1, bc, ins = r['bar']; bh = self.row_h - 2 * ins
                            if bx0 <= x < bx1 and ins <= ty < ins + bh:
                                rad = bh / 2; yy = ty - ins
                                if bx0 + rad <= x < bx1 - rad: bcov = 3
                                else:   # cap mask ROM (2-bit), computed here
                                    cx = bx0 + rad if x < bx0 + rad else bx1 - rad
                                    n = sum(1 for a in range(4) for b in range(4)
                                            if math.hypot(x + (a + .5) / 4 - cx, yy + (b + .5) / 4 - rad) <= rad)
                                    bcov = (n * 3 + 8) // 16
                                c = tuple(mix(c[k], self.pal[bc][k], LV[bcov]) for k in range(3))
                        while gi + 1 < len(gl) and gl[gi + 1][0] <= x: gi += 1
                        if gi >= 0 and 0 <= gy < f.sh:
                            gx, ch, gc = gl[gi]; sx = x - gx
                            if sx < len(f.cols[ch]):
                                a = f.cols[ch][sx][gy]
                                if a: c = tuple(mix(c[k], self.pal[gc][k], LV[a]) for k in range(3))
                if cov < 3:
                    c = tuple(((g[k] >> 1) + (c[k] >> 1)) if cov == 2 else ((g[k] * 3 >> 2) + (c[k] >> 2)) for k in range(3))
                px[X, Y] = c
        return frame
