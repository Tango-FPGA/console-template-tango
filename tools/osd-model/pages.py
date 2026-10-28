#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""Tango pages: MiSTer layout, translucent rounded overlay, AA proportional font.
Usage: pages.py compare | pages.py sheet saira      (Tango_GAME_FRAME=png sets the game frame)"""
import os, sys
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zosd as Z
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out'); os.makedirs(OUT, exist_ok=True)
FONTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts')
GAME_FRAME = os.environ.get('Tango_GAME_FRAME', '')   # a PNG to draw behind the overlay; none: a synthetic pattern
FONTS = {   # key: (file, px)  -- all free for commercial use (OFL / Ubuntu Font Licence)
  'saira':  (os.path.join(FONTDIR, 'SairaCondensed-SemiBold.ttf'), 25),
  'ubuntu': ('/usr/share/fonts/truetype/ubuntu/Ubuntu-M.ttf', 20),
  'noto':   ('/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf', 20),
}
def game():   # a real game frame behind the overlay; falls back to a synthetic test pattern
    im = Image.new('RGB', (1280, 720))
    if GAME_FRAME and os.path.exists(GAME_FRAME):
        im.paste(Image.open(GAME_FRAME).convert('RGB').resize((864, 672), Image.NEAREST), (208, 24)); return im
    px = im.load()
    for y in range(24, 696):
        for x in range(208, 1072): px[x, y] = ((x // 48 + y // 48) % 2 * 90 + 40, (x - 208) * 200 // 864, (y - 24) * 200 // 672)
    return im
def launcher_bg():   # the menu core's own background: a quiet per-line gradient (one adder per line)
    im = Image.new('RGB', (1280, 720)); px = im.load()
    for y in range(720):
        c = (10 + y * 14 // 720, 12 + y * 16 // 720, 20 + y * 26 // 720)
        for x in range(1280): px[x, y] = c
    return im

CORES = [('Arcade', '>'), ('Console', '>'), ('Computer', '>'), ('Utility', '>'), None,
         ('Example', ''), ('Nintendo NES', ''), ('Mega Man 2', ''), None,
         ('System settings', '>'), ('Controllers', '>'), ('About', '>')]
CORE_MENU = [('Palette', 'Standard'), ('Border', 'Off'), ('Picture', 'Colour bars'), ('Frame rate', '60 Hz'), None,   # illustrative (launcher_pages EXAMPLE_PAGES)
             ('DIP switches', '>'), ('Video', '>'), ('Audio', '>'), ('Service mode', '>'), None,
             ('Reset core', ''), ('Load core', '>')]
FILES = [('..', '>')] + [(n, '') for n in ['Mach Rider', 'Magic of Scheherazade', 'Maniac Mansion', 'Mega Man',
         'Mega Man 2', 'Mega Man 3', 'Mega Man 4', 'Metal Gear', 'Metroid', "Mike Tyson's Punch-Out!!",
         'Mighty Final Fight', 'Monster Party', 'Mother']]

PANEL, TEXT, DIM, BAR, BARTXT, ACC, ACCTXT, RULE = 1, 2, 3, 4, 5, 6, 7, 8
PAL = [(0, 0, 0), (14, 16, 22), (238, 240, 244), (128, 136, 150), (242, 163, 58), (22, 14, 4),
       (242, 163, 58), (26, 16, 4), (70, 76, 90)] + [(0, 0, 0)] * 7
W, H, SW, RH, TOP = 880, 560, 42, 29, 14
TX, VX = SW + 26, W - 30          # label left, value right

# Menu colour presets (launcher setting). The BL616 derives the rest from one accent: bar and strip = accent,
# text on them = a near-black tint of the accent, or near-white if the accent is dark.  Palette write only.
ACCENTS = {'Amber': (242, 163, 58), 'Blue': (64, 142, 255), 'Green': (52, 199, 120),
           'Red': (235, 72, 72), 'Violet': (156, 110, 255), 'Cyan': (40, 196, 214)}
def palette(accent):
    r, g, b = accent; light = (r * 299 + g * 587 + b * 114) // 1000 > 110
    on = (r >> 3, g >> 3, b >> 3) if light else (246, 247, 250)
    pal = list(PAL); pal[BAR] = pal[ACC] = accent; pal[BARTXT] = pal[ACCTXT] = on
    return pal

def page(font, banner, title, right, items, sel, legend, bg, pal=None):
    m = Z.Menu(font, pal or PAL, W, H, SW, RH, TOP)
    m.banner_text(banner, ACCTXT, H - 22, (SW - font.cap) // 2 - (font.asc - font.cap))
    m.text(0, TX, title, TEXT)
    if right: m.text_r(0, VX, right, DIM)
    m.rule(0, RULE, RH - 3)
    for i, it in enumerate(items):
        r = 2 + i
        if it is None: m.rule(r, RULE); continue
        lab, val = it; on = i == sel
        if on: m.bar(r, TX - 14, VX + 14, BAR, 2)
        m.text(r, TX, lab, BARTXT if on else TEXT)
        if val == '>': m.text_r(r, VX, '\x7f', BARTXT if on else DIM)
        elif val: m.text_r(r, VX, val, BARTXT if on else DIM)
    x = TX
    for k, lab in legend:
        x = m.text(17, x, k, ACC) + 6; x = m.text(17, x, lab, DIM) + 22
    fr = bg(); m.render(fr, (1280 - W) // 2, (720 - H) // 2, PANEL, ACC)
    return fr, m

# ---- generic MiSTer-style page renderer: one call per source page ----------------------------------
# rows: ('opt', label, value)  option, value right       ('sub', label[, value])  sub-page, chevron
#       ('act', label)         action / trigger           ('info', text)           non-selectable dim line
#       ('dis', label[, value]) disabled (greyed)         ('sep',)                 divider
#       ('dir', name) ('up', '..') ('file', name[, right]) file-browser rows
VIS = 14    # content rows 2..15
# A list row may use at most G_ROW glyph slots (label + right-hand text + icon): 14 rows x 67 = 938 of a bank's
# 1024, leaving 86 for the title, position hint, legend and banner. A longer label is cut to a prefix + ELL +
# suffix (~60/40 front/back, file-manager convention), not just an end-only cut as MiSTer's fixed-width cut
# (menu.cpp PrintDirectory 8443-8447: 27 characters + a marker; 8492-8495 with a date) -- real-card name
# collisions measured ~26 visible characters at 6.4%, 64 at 0.08%, hence the wider budget and the two-sided cut.
G_ROW, ELL = 67, '...'
def fit(font, s, px, g):
    """s cut to at most g glyphs and px pixels, keeping a prefix + ELL + a suffix (~60/40 front/back,
    tango_layout.c fit())."""
    n = len(s)
    if n <= g and font.width(s) <= px: return s
    gkeep = max(g - len(ELL), 0)
    total = gkeep if gkeep <= n else n
    nf = (total * 6 + 5) // 10
    nb = total - nf
    ell = font.width(ELL)
    # give ground to the glyph cap or the pixel width: shrink the back to 0 first, then the front
    while (nf > 0 or nb > 0) and (nf + len(ELL) + nb > g or
            font.width(s[:nf]) + ell + font.width(s[n - nb:] if nb else '') > px):
        if nb > 0: nb -= 1
        else: nf -= 1
    while nf > 0 and s[nf - 1] == ' ': nf -= 1
    while nb > 0 and s[n - nb] == ' ': nb -= 1
    return s[:nf] + ELL + (s[n - nb:] if nb else '')
BLANKSPACE = 10
def fit_end(font, s, px, g):
    """a list row's name cut at its END with a marker (MiSTer's trimmed name, tango_layout.c fit_end); returns (text, characters kept or None if it fits)."""
    n = len(s)
    if n <= g and font.width(s) <= px: return s, None
    ell = font.width(ELL)
    k = max(min(n, g - 3), 0)
    while k > 0 and font.width(s[:k]) + ell > px: k -= 1
    while k > 0 and s[k - 1] == ' ': k -= 1
    return s[:k] + ELL, k
def scroll_window(font, s, off, px, g):
    t = s + ' ' * BLANKSPACE; out = ''; w = 0
    i = off
    while len(out) < g:
        c = t[i % len(t)]; a = font.adv[c if c in font.adv else '?']
        if w + a > px: break
        out += c; w += a; i += 1
    return out
def list_row(font, row):
    """geometry + analysis of a list row (tango_layout.c lrow_analyse): dict x, xmax, g, vtxt, l1, l2, scrolls, expand"""
    k = row[0]; val = row[2] if len(row) > 2 else None
    icon = k in ('dir', 'up')
    x = TX + (font.adv['\x80' if k == 'dir' else '\x81'] + 6 if icon else 0)
    if k == 'dir': vtxt = (val + '  ' if val else '') + '\x7f'
    else: vtxt = val or None
    xmax = VX - font.width(vtxt) - 8 if vtxt else VX
    g = G_ROW - icon - (len(vtxt) if vtxt else 0)
    lab = row[1]
    l1, keep = fit_end(font, lab, xmax - x, g)
    d = dict(x=x, xmax=xmax, g=g, vtxt=vtxt, l1=l1, l2='', expand=False, scrolls=False)
    if keep is None: return d
    if k == 'file' and not vtxt:
        t = min(len(lab) - keep, G_ROW - 1)
        while t > 0 and font.width(lab[len(lab) - t:]) > VX - TX: t -= 1
        d.update(expand=True, l2=lab[len(lab) - t:] if t else '', scrolls=keep + t < len(lab))
    else: d['scrolls'] = True
    return d
def render_page(font, spec, pal=None):
    m = Z.Menu(font, pal or PAL, W, H, SW, RH, TOP)
    m.banner_text(spec['banner'], ACCTXT, H - 22, (SW - font.cap) // 2 - (font.asc - font.cap))
    t = spec['title']
    if spec.get('back') or spec.get('arrow') == 'left': t = '\x83 ' + t
    if spec.get('arrow') == 'right': t = t + ' \x7f'
    m.text(0, TX, t, TEXT)
    if spec.get('right'): m.text_r(0, VX, spec['right'], DIM)
    m.rule(0, RULE, RH - 3)
    rows, sel = spec['rows'], spec.get('sel', 0)
    top = min(max(0, sel - VIS + 3), max(0, len(rows) - VIS)) if len(rows) > VIS else 0
    if 'top' in spec: top = spec['top']   # a caller-kept window (the BL616 keeps MiSTer's iFirstEntry)
    if 0 <= sel < len(rows) and rows[sel][0] in ('file', 'dir', 'up'):   # the selected file's second line needs a row (PrintDirectory: flist_iFirstEntryInc)
        if list_row(font, rows[sel])['expand'] and sel - top == VIS - 1 and sel < len(rows) - 1: top += 1
    line = 0
    for i, row in enumerate(rows[top:]):
        if line >= VIS: break
        r = 2 + line; line += 1; k = row[0]; on = (top + i) == sel
        if k == 'sep': m.rule(r, RULE); continue
        if k == 'blank': continue
        if k == 'center':
            m.text(r, (TX + VX - font.width(row[1])) // 2, row[1], row[2] if len(row) > 2 else DIM); continue
        if k == 'logo':    # the About wordmark's row: '#' = one 12 px cell (three 0x86 bricks), centred; colour = the accent
            x0 = (TX + VX - 12 * len(row[1])) // 2
            for j, c in enumerate(row[1]):
                if c == '#': m.text(r, x0 + 12 * j, '\x86\x86\x86', ACC)
            continue
        if k == 'scroll':  # a ticker row: the text starts at VX - pos and moves left; whole glyphs inside [TX, VX] only
            x = VX - row[2]
            for c in row[1]:
                a = font.adv[c if c in font.adv else '?']
                if TX <= x and x + a <= VX: m.text(r, x, c, DIM)
                x += a
            continue
        if on: m.bar(r, TX - 14, VX + 14, BAR, 2)
        fg = BARTXT if on else (DIM if k in ('info', 'dis') else TEXT)
        vfg = BARTXT if on else DIM
        x = TX
        if k == 'vol': val = None
        icon = k in ('dir', 'up')
        if icon:
            x = m.text(r, TX, '\x80' if k == 'dir' else '\x81', BARTXT if on else ACC) + 6
        val = row[2] if len(row) > 2 else None
        if k in ('file', 'dir', 'up'):    # a file list row: MiSTer's trimming, scrolling and expansion (list_row)
            lr = list_row(font, row)
            txt = lr['l1']
            if on and lr['scrolls'] and spec.get('sel_scroll', 0) > 0: txt = scroll_window(font, row[1], spec['sel_scroll'] - 1, lr['xmax'] - lr['x'], lr['g'])
            m.text(r, x, txt, fg)
            if lr['vtxt']: m.text_r(r, VX, lr['vtxt'], vfg)
            if on and lr['expand'] and line < VIS:
                r2 = 2 + line; line += 1
                m.bar(r2, TX - 14, VX + 14, BAR, 2); m.text(r2, TX, lr['l2'], fg)
            continue
        # the right-hand text first, to know where the label must stop (tango_layout.c does the same)
        if k == 'sub' or k == 'dir': vtxt, vcol = (val + '  ' if val else '') + '\x7f', vfg
        elif k == 'vol': vtxt, vcol = '\x84' * row[2] + '\x85' * (row[3] - row[2]) + '+' * (row[4] if len(row) > 4 else 0), (BARTXT if on else ACC)
        elif val: vtxt, vcol = val, vfg
        else: vtxt, vcol = None, vfg
        xmax = VX - font.width(vtxt) - 8 if vtxt else VX
        m.text(r, x, fit(font, row[1], xmax - x, G_ROW - icon - (len(vtxt) if vtxt else 0)), fg)
        if vtxt: m.text_r(r, VX, vtxt, vcol)
    if len(rows) > VIS:   # MiSTer-style position hint in the title bar
        m.text_r(0, VX, spec.get('right') or f'{sel + 1}/{len(rows)}', DIM)
    x = TX
    for k2, lab in spec.get('legend', []):
        x = m.text(17, x, k2, ACC) + 6; x = m.text(17, x, lab, DIM) + 22
    fr = spec.get('bg', launcher_bg)(); m.render(fr, (1280 - W) // 2, (720 - H) // 2, PANEL, ACC)
    return fr

LEG = [('A', 'select'), ('B', 'back'), ('\x7f', 'change'), ('Menu', 'close')]
if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'compare'
    if mode == 'compare':
        tiles = []
        for key, (path, px) in FONTS.items():
            f = Z.Font(path, px)
            im, m = page(f, 'EXAMPLE', 'Example', '', CORE_MENU, 2, LEG, game)
            n, cut = m.stats()
            print(f'{key:7s} px={px} sh={f.sh} cols={f.total_cols()} atlas={f.bsram()} BSRAM glyphs={n} cut_px={cut} clip={f.clip}')
            im.save(os.path.join(OUT, f'v5_{key}.png')); tiles.append(im.crop((200, 80, 1080, 640)))
        sh = Image.new('RGB', (880 * 2 + 20, 560 * 2 + 20), (40, 40, 40))
        for i, t in enumerate(tiles): sh.paste(t, ((i % 2) * 900, (i // 2) * 580))
        sh.save(os.path.join(OUT, 'v5_font_compare.png'))
    elif mode == 'colours':
        f = Z.Font(*FONTS['saira'])
        SETTINGS = [('Menu colour', 'Amber'), ('Boot core', 'Show picker'), ('Menu button', 'Select + Start'), None,
                    ('Controllers', '>'), ('Players', '>'), None, ('Save settings', ''), ('About', '>')]
        pg = page(f, 'TANG CONSOLE', 'System settings', '', SETTINGS, 0,
                  [('A', 'select'), ('B', 'back'), ('\x7f', 'change')], launcher_bg)[0]
        pg.save(os.path.join(OUT, 'colour_setting.png'))
        tiles = []
        for name, acc in ACCENTS.items():
            im = page(f, 'EXAMPLE', 'Example', name, CORE_MENU, 2, LEG, game, palette(acc))[0]
            tiles.append(im.crop((200, 80, 1080, 640)).resize((440, 280), Image.LANCZOS))
        sh = Image.new('RGB', (440 * 3 + 20, 280 * 2 + 10), (40, 40, 40))
        for i, t in enumerate(tiles): sh.paste(t, ((i % 3) * 450, (i // 3) * 290))
        sh.save(os.path.join(OUT, 'colour_presets.png'))
    else:
        key = sys.argv[2]; f = Z.Font(*FONTS[key])
        shots = [page(f, 'TANG CONSOLE', 'Cores', 'SD  29 GB free', CORES, 1, [('A', 'open'), ('B', 'back')], launcher_bg)[0],
                 page(f, 'EXAMPLE', 'Example', '', CORE_MENU, 2, LEG, game)[0],
                 page(f, 'NINTENDO NES', '/games/NES/M', '13 / 214', FILES, 5, [('A', 'load'), ('B', 'up'), ('L/R', 'page')], launcher_bg)[0]]
        sh = Image.new('RGB', (1280 * 3 + 40, 720), (40, 40, 40))
        for i, im in enumerate(shots): im.save(os.path.join(OUT, f'v5_{key}_{i}.png')); sh.paste(im, (i * 1300, 0))
        sh.save(os.path.join(OUT, f'sheet_v5_{key}.png'))
    print('ok')
