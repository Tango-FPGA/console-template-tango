#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""export_hw.py -- the Tango overlay's HARDWARE TABLES, taken from the model objects, proven by a
pure-table re-render, emitted as Verilog logic ROMs + the golden PNG for the RTL sim gate.

  page   launcher_pages.PAGES '02_cores_console' (Cores list in a folder, NES selected),
         rendered by pages.render_page with the background = backgrounds.test_pattern(frame=40)
  font   pages.FONTS['saira']  (zosd.Font)

Tables (the renderer's memories: sys/tango_menu_overlay.v, header "Memories"):
  atlas    column-major, one word per glyph column: bit[2*gy+1:2*gy] = 2-bit coverage of row gy (sh rows)
           glyphs packed back to back in zosd.Font.cols insertion order -> colbase per glyph
  glyphs   32-bit entry {spare[31], colour[30:27], width[26:22], colbase[21:11], x[10:0]}
           text rows: entries of a row sorted by x (stable, as Menu.render); an entry followed by one with the
           SAME x is dropped (it is never "the last glyph with x <= pixel"), so x is strictly increasing.
           banner (row 31): entries in Menu.banner order, x = the glyph's bottom y (panel lines)
  rows     64-bit entry, stored as two 32-bit words (word 2*r = [31:0], word 2*r+1 = [63:32]):
           first[8:0] count[15:9] B[16] barcol[20:17] barx0[31:21] | barx1[42:32] inset[45:43] R[46]
           rulecol[50:47] ruley[55:51] texty[61:56] firsthi[62]
           texty = the glyph-row offset: gy = ty - texty (Menu.render: (row_h + cap)//2 - asc)
           firsthi = bit 9 of first (1024 glyph slots/bank need 10 bits; texty is always < 64 in
           practice so bit 62 -- word 2*r+1 bit 30 -- was free; bit 63 stays reserved)
           row 31 = banner: first[9:0]/count[16:10] packed straight into word 2*r (no bar/rule fields,
           so no stolen bit needed there), texty field (word 2*r+1) = banner x inset (Menu.bx) instead
  palette  16 x RGB888 + K = palette[panel]*3>>2 (entry 16)
  masks    corner quarter mask 16x16 2-bit (zosd.quarter_mask(14)); pill-cap coverage for the bar used:
           capL[d][yy] (d = x-bx0 < CAPL), capR[dr][yy] (dr = bx1-1-x < CAPR), yy = ty - inset

Usage: python3 export_hw.py [--sys]  -> fpga/rtl/gen/*.vh, fpga/sim/golden/overlay_cores_console_f40.png
       (--sys: also the framework's copy sys/tango_ov_geom.vh)
"""
import math, os, sys
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zosd as Z
import pages as P
import launcher_pages as L
import backgrounds as B

ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
GEN = os.path.join(ROOT, 'fpga', 'rtl', 'gen')
SYSGEN = os.path.join(ROOT, 'sys')
GOLD = os.path.join(ROOT, 'fpga', 'sim', 'golden')
PAGE, FRAME = '02_cores_console', 40
X0, Y0 = (1280 - P.W) // 2, (720 - P.H) // 2          # Menu.render(frame, x0, y0, ...) in render_page
BANNER_ROW = 31

# ------------------------------------------------------------------ model run (captures the Menu)
def model_render(font):
    spec = dict(dict(L.PAGES)[PAGE])
    bg = B.test_pattern(frame=FRAME)
    spec['bg'] = lambda: bg.copy()
    got = {}
    orig = Z.Menu.render
    def spy(self, frame, x0, y0, panel, acc):
        got.update(menu=self, x0=x0, y0=y0, panel=panel, acc=acc)
        return orig(self, frame, x0, y0, panel, acc)
    Z.Menu.render = spy
    try:
        img = P.render_page(font, spec)
    finally:
        Z.Menu.render = orig
    return img, bg, got

# ------------------------------------------------------------------ tables
def build_tables(font, m, panel, acc):
    f = font
    assert (m.W, m.H, m.strip_w, m.row_h, m.top) == (P.W, P.H, P.SW, P.RH, P.TOP)
    # atlas
    colbase, atlas = {}, []
    for ch, cols in f.cols.items():
        colbase[ch] = len(atlas)
        for col in cols:
            assert len(col) == f.sh
            atlas.append(sum(v << (2 * y) for y, v in enumerate(col)))
    assert len(atlas) <= 1024, len(atlas)
    def gent(x, ch, col):
        w = len(f.cols[ch])
        assert 0 <= x < 2048 and 1 <= w <= 31 and 0 <= col < 16 and colbase[ch] < 2048, (x, ch, w, col)
        return x | colbase[ch] << 11 | w << 22 | col << 27
    texty = (m.row_h + f.cap) // 2 - f.asc
    assert 0 <= texty < 64
    glyphs, rows, dropped, insets = [], [0] * 64, 0, set()
    for i in range(BANNER_ROW):
        r = m.rows.get(i)
        if r is None: continue
        g = sorted(r['glyphs'], key=lambda e: e[0])
        keep = [e for k, e in enumerate(g) if not (k + 1 < len(g) and g[k + 1][0] == e[0])]
        dropped += len(g) - len(keep)
        xs = [e[0] for e in keep]; assert all(a < b for a, b in zip(xs, xs[1:]))
        first = len(glyphs); glyphs += [gent(*e) for e in keep]
        lo = first & 0x1FF | len(keep) << 9; hi = texty << 24 | (first >> 9 & 1) << 30
        assert first < 1024 and len(keep) < 128
        if r['bar']:
            bx0, bx1, bc, ins = r['bar']; insets.add(ins)
            assert 0 <= bx0 < bx1 < 2048 and ins < 8
            lo |= 1 << 16 | bc << 17 | bx0 << 21; hi |= bx1 | ins << 11
        if r['rule']:
            rc, ry = r['rule']; assert 0 <= ry < 32
            hi |= 1 << 14 | rc << 15 | ry << 19
        rows[2 * i], rows[2 * i + 1] = lo, hi
    # banner (row 31)
    first = len(glyphs)
    for by, ch, col in m.banner: glyphs.append(gent(by, ch, col))
    assert 0 <= m.bx < 64
    rows[2 * BANNER_ROW] = first & 0x3FF | len(m.banner) << 10   # no bar/rule fields: no stolen bit needed
    rows[2 * BANNER_ROW + 1] = m.bx << 24
    assert len(glyphs) <= 1024
    # palette + K
    pal = [tuple(c) for c in m.pal]; assert len(pal) == 16
    K = tuple(c * 3 >> 2 for c in pal[panel])
    # corner mask
    mask = [row[:] for row in m.mask]
    # pill caps for the one bar height used (Menu.render's cap coverage, evaluated at the page's own bar)
    if not insets:   # a page with no selection bar (Define buttons, MENU_JOYDIGMAP): no caps to derive from it
        return dict(atlas=atlas, glyphs=glyphs, rows=rows, pal=pal, K=K, mask=mask, capL=[], capR=[],
                    CAPL=0, CAPR=0, BH=0, INSET=0, SH=f.sh, strip_col=acc, dropped=dropped,
                    PW=m.W, PH=m.H, SW=m.strip_w, RH=m.row_h, TOP=m.top)
    assert len(insets) == 1, insets
    ins = insets.pop(); bh = m.row_h - 2 * ins; rad = bh / 2
    bars = [r['bar'] for r in m.rows.values() if r['bar']]
    bx0, bx1 = bars[0][0], bars[0][1]
    def cov(x, yy, cx):
        n = sum(1 for a in range(4) for b in range(4)
                if math.hypot(x + (a + .5) / 4 - cx, yy + (b + .5) / 4 - rad) <= rad)
        return (n * 3 + 8) // 16
    CAPL = sum(1 for d in range(64) if bx0 + d < bx0 + rad)          # x < bx0 + rad
    CAPR = sum(1 for dr in range(64) if bx1 - 1 - dr >= bx1 - rad)    # x >= bx1 - rad
    capL = [[cov(bx0 + d, yy, bx0 + rad) for yy in range(bh)] for d in range(CAPL)]
    capR = [[cov(bx1 - 1 - dr, yy, bx1 - rad) for yy in range(bh)] for dr in range(CAPR)]
    for bb in bars:   # every bar on the page must give the same cap tables (position-independent)
        for d in range(CAPL):
            for yy in range(bh):
                assert cov(bb[0] + d, yy, bb[0] + rad) == capL[d][yy]
        for dr in range(CAPR):
            for yy in range(bh):
                assert cov(bb[1] - 1 - dr, yy, bb[1] - rad) == capR[dr][yy]
    return dict(atlas=atlas, glyphs=glyphs, rows=rows, pal=pal, K=K, mask=mask, capL=capL, capR=capR,
                CAPL=CAPL, CAPR=CAPR, BH=bh, INSET=ins, SH=f.sh, strip_col=acc, dropped=dropped,
                PW=m.W, PH=m.H, SW=m.strip_w, RH=m.row_h, TOP=m.top)

# ------------------------------------------------------------------ pure-table re-render (mirrors the RTL)
LV = (0, 3, 5, 8)
def mix(a, b, lv):                      # a + ((b-a)*w)>>3, arithmetic shift on the signed product
    d = b - a; p = (d << 1) + d if lv == 1 else (d << 2) + d if lv == 2 else (d << 3) if lv == 3 else 0
    return a + (p >> 3)
def mix3(a, b, lv): return tuple(mix(a[k], b[k], lv) for k in range(3))

def table_render(bg, T, x0, y0):
    out = bg.copy(); px = out.load(); gp = bg.load()
    PW, PH, SW, RH, TOP, SH = T['PW'], T['PH'], T['SW'], T['RH'], T['TOP'], T['SH']
    atlas, gl, rows, pal, K = T['atlas'], T['glyphs'], T['rows'], T['pal'], T['K']
    def ge(w): return dict(x=w & 0x7FF, cb=w >> 11 & 0x7FF, w=w >> 22 & 31, col=w >> 27 & 15)
    A = pal[T['strip_col']]
    b_lo, b_hi = rows[2 * BANNER_ROW], rows[2 * BANNER_ROW + 1]
    bfirst, bcount, bx = b_lo & 0x3FF, b_lo >> 10 & 127, b_hi >> 24 & 63
    for ly in range(PH):
        # ---- line setup (RTL: FSM in the previous line's blanking) ----
        rowok = ly >= TOP and (ly - TOP) // RH < BANNER_ROW
        ri, ty = ((ly - TOP) // RH, (ly - TOP) % RH) if rowok else (0, 0)
        lo, hi = (rows[2 * ri], rows[2 * ri + 1]) if rowok else (0, 0)
        first, count, Bon, bcol, bx0 = (lo & 511) | (hi >> 30 & 1) << 9, lo >> 9 & 127, lo >> 16 & 1, lo >> 17 & 15, lo >> 21 & 0x7FF
        bx1, ins, Ron, rcol, ry, texty = hi & 0x7FF, hi >> 11 & 7, hi >> 14 & 1, hi >> 15 & 15, hi >> 19 & 31, hi >> 24 & 63
        rule_line = Ron and ty == ry
        bar_line = Bon and ins <= ty < RH - ins; yy = ty - ins
        gy = ty - texty; gline = rowok and 0 <= gy < SH
        bm = None                                                  # banner: last entry with 0 <= x - ly < width
        for i in range(bfirst, bfirst + bcount):
            e = ge(gl[i]); d = e['x'] - ly
            if 0 <= d < e['w']: bm = (atlas[e['cb'] + d], e['col'])
        my = ly if ly < 16 else (PH - 1 - ly if ly >= PH - 16 else None)
        ents = [ge(gl[i]) for i in range(first, first + count)]; ptr = 0; cur = None
        for lx in range(PW):
            if ptr < len(ents) and ents[ptr]['x'] == lx: cur = ents[ptr]; ptr += 1    # walker pop
            mx = lx if lx < 16 else (PW - 1 - lx if lx >= PW - 16 else None)
            cv = T['mask'][my][mx] if (mx is not None and my is not None) else 3
            X, Y = x0 + lx, y0 + ly; g = gp[X, Y]
            if cv == 0: continue
            if lx < SW:
                c = A; by = lx - bx
                if bm and 0 <= by < SH: c = mix3(c, pal[bm[1]], bm[0] >> (2 * by) & 3)
            else:
                c = tuple((g[k] >> 2) + K[k] for k in range(3))
                if rule_line: c = mix3(c, pal[rcol], 2)
                if bar_line and bx0 <= lx < bx1:
                    d, dr = lx - bx0, bx1 - 1 - lx
                    bc = 3 if (d >= T['CAPL'] and dr >= T['CAPR']) else T['capL'][d][yy] if d < T['CAPL'] else T['capR'][dr][yy]
                    c = mix3(c, pal[bcol], bc)
                if gline and cur is not None:
                    sx = lx - cur['x']
                    if sx < cur['w']:
                        a = atlas[cur['cb'] + sx] >> (2 * gy) & 3
                        c = mix3(c, pal[cur['col']], a)
            if cv == 2: c = tuple((g[k] >> 1) + (c[k] >> 1) for k in range(3))
            elif cv == 1: c = tuple((((g[k] << 1) + g[k]) >> 2) + (c[k] >> 2) for k in range(3))
            px[X, Y] = c
    return out

# ------------------------------------------------------------------ Verilog emit
HDR = """// GENERATED by tools/osd-model/export_hw.py -- do not edit.
// Page {page} (launcher_pages.PAGES), font pages.FONTS['saira'], background test_pattern(frame={frame}).
// TEST-ONLY SCAFFOLDING: these constant tables are LOGIC ROMs that the overlay's start-up copier
// writes into the renderer BSRAMs (GW5A BSRAM initial contents do not survive on silicon).
// In the product the BL616 writes the same BSRAMs over SPI (OSD commands ATLAS/GLYPHS/ROWS/PALETTE).
"""
def case_rom(name, T_list, aw, dw, comment):
    s = HDR.format(page=PAGE, frame=FRAME) + f"// {comment}\n// {len(T_list)} entries x {dw} bits\n"
    s += f"case (a)\n"
    for i, v in enumerate(T_list):
        s += f"    {aw}'d{i}: q = {dw}'h{v:0{(dw + 3) // 4}x};\n"
    s += f"    default: q = {dw}'d0;\nendcase\n"
    open(os.path.join(GEN, name), 'w').write(s)

def emit(T):
    os.makedirs(GEN, exist_ok=True)
    case_rom('tango_ov_rom_atlas.vh', T['atlas'], 10, 2 * T['SH'], 'font atlas: word i = glyph column i, bit[2*gy+1:2*gy] = coverage of row gy')
    case_rom('tango_ov_rom_glyphs.vh', T['glyphs'], 9, 32, 'glyph list bank 0: {spare,colour[30:27],width[26:22],colbase[21:11],x[10:0]}')
    case_rom('tango_ov_rom_rows.vh', T['rows'], 6, 32, 'row table bank 0: word 2r = entry[31:0], word 2r+1 = entry[63:32]; row 31 = banner')
    pal = [(r << 16 | g << 8 | b) for r, g, b in T['pal']] + [T['K'][0] << 16 | T['K'][1] << 8 | T['K'][2]]
    case_rom('tango_ov_rom_pal.vh', pal, 5, 24, 'palette 0..15 RGB888, entry 16 = K = palette[panel]*3>>2')
    g = HDR.format(page=PAGE, frame=FRAME).replace('LOGIC ROMs that', 'fixed geometry + mask ROMs;\n// the renderer tables are LOGIC ROMs that')
    g += f"""// geometry (pages.py W,H,SW,RH,TOP; render_page x0,y0; zosd.Font.sh) -- GEOMETRY command later
localparam integer OV_X0 = {X0}, OV_Y0 = {Y0};
localparam integer OV_PW = {T['PW']}, OV_PH = {T['PH']};
localparam integer OV_SW = {T['SW']}, OV_RH = {T['RH']}, OV_TOP = {T['TOP']};
localparam integer OV_SH = {T['SH']};
localparam integer OV_STRIP_COL = {T['strip_col']};     // strip colour = palette[acc] (Menu.render acc)
localparam integer OV_N_ATLAS = {len(T['atlas'])}, OV_N_GLYPH = {len(T['glyphs'])}, OV_N_ROWW = 64, OV_N_PAL = 17;
// pill caps (Menu.render cap coverage, 4x4 supersampled, for bar height {T['BH']} = RH - 2*{T['INSET']})
localparam integer OV_CAPL = {T['CAPL']}, OV_CAPR = {T['CAPR']}, OV_BH = {T['BH']};
// corner quarter mask row my: bit[2*mx+1:2*mx] = coverage (zosd.quarter_mask(14))
function [31:0] ov_corner_row(input [3:0] my);
    case (my)
"""
    for y in range(16):
        v = sum(T['mask'][y][x] << (2 * x) for x in range(16))
        g += f"        4'd{y}: ov_corner_row = 32'h{v:08x};\n"
    g += "        default: ov_corner_row = 32'hffffffff;\n    endcase\nendfunction\n"
    for side, tab, n in (('l', T['capL'], T['CAPL']), ('r', T['capR'], T['CAPR'])):
        g += f"// {'left' if side == 'l' else 'right'} cap, line yy: bit[2*d+1:2*d] = coverage, d = {'x-bx0' if side == 'l' else 'bx1-1-x'}\n"
        g += f"function [{2 * n - 1}:0] ov_cap{side}_row(input [4:0] yy);\n    case (yy)\n"
        for yy in range(T['BH']):
            v = sum(tab[d][yy] << (2 * d) for d in range(n))
            g += f"        5'd{yy}: ov_cap{side}_row = {2 * n}'h{v:0{(2 * n + 3) // 4}x};\n"
        g += f"        default: ov_cap{side}_row = {2 * n}'d0;\n    endcase\nendfunction\n"
    open(os.path.join(GEN, 'tango_ov_geom.vh'), 'w').write(g)
    # the framework carries its own copy (sys/tango_ov_geom.vh), which the cores include: written only with --sys,
    # since sys/ is the sys-tango submodule and its copy changes with sys-tango
    if '--sys' in sys.argv[1:]:
        os.makedirs(SYSGEN, exist_ok=True)
        open(os.path.join(SYSGEN, 'tango_ov_geom.vh'), 'w').write(g)

if __name__ == '__main__':
    font = Z.Font(*P.FONTS['saira'])
    img, bg, got = model_render(font)
    m = got['menu']; assert (got['x0'], got['y0']) == (X0, Y0)
    T = build_tables(font, m, got['panel'], got['acc'])
    hw = table_render(bg, T, X0, Y0)
    a, b = img.load(), hw.load()
    bad = [(x, y, a[x, y], b[x, y]) for y in range(720) for x in range(1280) if a[x, y] != b[x, y]]
    print(f'atlas {len(T["atlas"])} cols x {2 * T["SH"]} bits; glyph entries {len(T["glyphs"])} '
          f'(banner {len(m.banner)}, dropped shadowed {T["dropped"]}); caps L{T["CAPL"]} R{T["CAPR"]} x {T["BH"]}')
    print(f'table re-render vs model render_page: {len(bad)} mismatches of {1280 * 720}')
    for x, y, p, q in bad[:20]: print(f'  ({x},{y}) model={p} tables={q}')
    if bad: sys.exit(1)
    emit(T)
    os.makedirs(GOLD, exist_ok=True)
    img.save(os.path.join(GOLD, 'overlay_cores_console_f40.png'))
    print('wrote', GEN, 'and', os.path.join(GOLD, 'overlay_cores_console_f40.png'))
