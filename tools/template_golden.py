#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""template_golden.py -- the goldens of a Template sim run: template_model.py's picture for every captured
frame, with the OSD page (template_page.py's tables, export_hw.table_render: the RTL's integer ops) composited on
the frames the testbench recorded as shown.
usage: template_golden.py <run.json> <page_tables.json> <outdir>   -> <outdir>/golden_f<k>.png"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools', 'osd-model'))
import template_model as M
import export_hw as E
run_json, tab_json, out = sys.argv[1:4]
J = json.load(open(run_json))
T = json.load(open(tab_json))
T['pal'] = [tuple(c) for c in T['pal']]; T['K'] = tuple(T['K'])
rec = [(int(f['status'], 16), f['joy']) for f in J['frames']]
data = list(open(J['file'], 'rb').read()[:32]) if J.get('file') else []
imgs = M.run(rec, J['capture'], data + [0] * (32 - len(data)), J.get('dl_frame'))
os.makedirs(out, exist_ok=True)
for k, im in imgs.items():
    if k in J.get('osd_frames', []): im = E.table_render(im, T, E.X0, E.Y0)
    p = os.path.join(out, f'golden_f{k}.png'); im.save(p); print('wrote', p)
