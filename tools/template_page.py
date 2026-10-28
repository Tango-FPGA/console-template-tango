#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_page.py -- the OSD page the sim gate shows over the Template core, and its stream.

The page is the Template's CONF_STR page 0 drawn by the bit-exact model (tools/osd-model): its tables come from
export_hw.build_tables (the tables the RTL is gated against), and the stream carries them in the order the BL616
firmware sends at core start (CAPS, STATUS, PALETTE, GEOMETRY, ATLAS, GLYPHS bank 1, ROWS bank 1, SWAP, ENABLE),
built by tools/osd-model/stream_hw.py's page_records.  The firmware's own layout of CONF_STR pages is the BL616
agent's; this page only has to be a real Tango page over a core's picture.
Its rows are derived from the CONF_STR in ../rtl/tango_core_template.v (page0 below), so the page follows the RTL.
usage: template_page.py <outdir>  -> <outdir>/template_page.bin, <outdir>/template_page_tables.json
"""
import importlib.util, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
OSD = os.path.join(HERE, '..', '..', 'tools', 'osd-model')
sys.path.insert(0, OSD)
import zosd as Z, pages as P, export_hw as E, stream_hw as SH
CORE_V = os.path.join(HERE, '..', 'rtl', 'tango_core_template.v')

def find_sys(core):
    """The core's framework: the nearest sys/ above the core file that holds tango_core_ports.vh (as sys-tango
    build_tools/confstr_expand.py find_sys): this repository's sys/ for rtl/."""
    d = os.path.dirname(os.path.abspath(core))
    while not os.path.isfile(os.path.join(d, 'sys', 'tango_core_ports.vh')):
        if os.path.dirname(d) == d:
            sys.exit(f'template_page.py: no sys/ with tango_core_ports.vh above {core}')
        d = os.path.dirname(d)
    return os.path.join(d, 'sys')

def conf_str(path=CORE_V, defines=None):
    """The CONF_STR of the core's RTL as the synthesiser builds it: the framework's sys/build_tools/confstr_expand.py
    (sys-tango video-opts) expands its macros -- the framework's Video entries `TANGO_VIDEO_CONF
    (sys/tango_video_opts.vh) -- as the Verilog preprocessor does; the quoted parts alone would miss those entries.
    `BUILD_DATE expands to nothing unless defines gives it (the sim runners' READ_CFG check: BUILD_DATE '"sim"')."""
    sd = find_sys(path)
    ex = os.path.join(sd, 'build_tools', 'confstr_expand.py')
    if not os.path.isfile(ex):
        sys.exit(f'template_page.py: {ex} missing: the Template needs a sys-tango with the Video options (video-opts)')
    sys.dont_write_bytecode = True                  # no __pycache__ left in the sys/ checkout
    spec = importlib.util.spec_from_file_location('confstr_expand', ex)
    cx = importlib.util.module_from_spec(spec); spec.loader.exec_module(cx)
    try:
        return cx.expand(path, sd, defines or {})['conf']
    except cx.ExpandError as e:
        sys.exit(f'template_page.py: the CONF_STR of {path} cannot be evaluated: {e}')

def entry_bits(conf, name):
    """(hi, lo): the status bits of the option entry called name, as the firmware's OSD finds them in CONF_STR
    (the firmware's CONF_STR parser: H#/h#/D#/d# prefixes, then P#; the O[hi:lo] and O[b] forms, absolute bit
    numbers); None if there is none."""
    for e in conf.split(';'):
        while re.match(r'[HhDd][0-9A-V]|P\d', e): e = e[2:]
        m = re.match(r'O\[(\d+)(?::(\d+))?\],([^,]*)', e)
        if m and m.group(3) == name:
            return int(m.group(1)), int(m.group(2) or m.group(1))
    return None

def page0(conf, menumask=0):
    """CONF_STR page 0 as pages.render_page rows, one per entry, in order (MiSTer's menu.cpp 1936-2215):
    the page starts at entry 2; P#<entry> is on sub-page # (not here), P#,Title opens it; H#/h# hide and D#/d# grey
    an entry when menumask bit # is set / not set; options show value 0 (the option word is 0 when the gate shows
    the page, and so is the menumask: GET_MENUMASK = 00 00).  '-' is drawn as a divider ('sep'), as this page always
    drew it (the firmware draws a blank line).  An entry kind not modelled here stops the run."""
    rows = []
    for e in conf.split(';')[2:]:
        hide = grey = False
        while re.match(r'[HhDd]\d', e):
            on = bool((menumask >> int(e[1])) & 1)
            if e[0] in 'Hh': hide |= on == (e[0] == 'H')
            else:            grey |= on == (e[0] == 'D')
            e = e[2:]
        sub = re.match(r'P\d(,?)', e)
        if sub and not sub.group(1): continue                         # an entry of sub-page #
        if hide or not e or e[0] in 'VvJjI' or e.startswith('DEFMRA'): continue   # hidden / not a page row
        f = e.split(',')
        if sub: row = ('sub', f[1])
        elif e[0] == '-': row = ('sep',) if len(f) == 1 else ('center', f[1].strip())
        elif e[0] in 'Oo': row = ('opt', f[1], f[2])
        elif e[0] in 'TtRr': row = ('act', f[1])
        else: sys.exit(f'template_page.py: page-0 entry "{e}" is not modelled here -- add its row to page0()')
        rows.append(('dis',) + row[1:] if grey and row[0] in ('opt', 'act', 'sub') else row)
    return rows

def spec(conf):
    name, rows = conf.split(';')[0], page0(conf)
    return dict(banner=name.upper(), title=name, sel=next(i for i, r in enumerate(rows) if r[0] in ('opt', 'act', 'sub')),
                legend=[('A', 'select'), ('B', 'back'), ('\x7f', 'change'), ('Menu', 'close')], rows=rows)

def tables(font, conf=None):
    got = {}
    orig = Z.Menu.render
    def spy(self, frame, x0, y0, panel, acc):
        got.update(menu=self, panel=panel, acc=acc); return frame
    Z.Menu.render = spy
    try:
        s = spec(conf if conf is not None else conf_str()); s['bg'] = lambda: None
        P.render_page(font, s)
    finally:
        Z.Menu.render = orig
    return E.build_tables(font, got['menu'], got['panel'], got['acc'])

if __name__ == '__main__':
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    font = Z.Font(*P.FONTS['saira'])
    conf = conf_str()
    print('template_page: rows', spec(conf)['rows'])
    T = tables(font, conf)
    SH.write_stream(os.path.join(out, 'template_page.bin'), SH.page_records(T, font))
    json.dump({k: v for k, v in T.items()}, open(os.path.join(out, 'template_page_tables.json'), 'w'))
