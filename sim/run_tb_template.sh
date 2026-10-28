#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_tb_template.sh -- the Template core's sim gate: the framework (sys/, vendored) around the Template core
# (rtl/), on asynchronous clocks, driven by sim/tb_template.cpp mode=template (session: sim/tb_template.inc).
# PASS needs all of:
#   the tb's checks (sim/tb_template.inc + tb_template.cpp: link, OSD shown/hidden in the vertical blank, options,
#   menu mask, the F1 download as the firmware's sdc.c does it, pads, reset, no MISO violation at the BL616);
#   READ_CFG = the CONF_STR in rtl/tango_core_template.v;
#   frames 6 (OSD shown), 9 (options), 13 (download strip), 21 (pad A), 26 (pad square, B), 30 (after a reset),
#   32 (OSD Pattern) = the goldens of tools/template_golden.py (tools/template_model.py + the OSD model's table
#   renderer), pixel for pixel (A, B and Pattern act in the ASCAL build only: here they must change nothing).
# Standalone: everything comes from this repo (sys/, rtl/, tools/, tools/osd-model/ with its font, sim/).
# sys/ is the framework's submodule and is never rewritten:
#   - the OSD model's tables are written into sim/obj/, and sys/tango_ov_geom.vh must be IDENTICAL to the model's
#     (but for its glyph counts; else FAIL);
#   - the empty-rows stream is built into sim/obj/ with tools/osd-model/stream_hw.py's write_stream.
# The tools import the OSD model through PYTHONPATH=tools/osd-model.
#   usage: sim/run_tb_template.sh
# A heavy job: run one build or bench at a time.  Memory cap: TANGO_MEM_CAP (default 4G).
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
export PYTHONPATH="$ROOT/tools/osd-model${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$OBJ"
# the OSD model's font (tools/osd-model/fonts/, with its licence OFL.txt)
FONT=tools/osd-model/fonts/SairaCondensed-SemiBold.ttf
[ -f "$FONT" ] || { echo "no $FONT"; exit 2; }
# ---- the OSD model's tables, re-rendered and checked against the model; sys/tango_ov_geom.vh must equal them
nice -n 10 python3 - "$OBJ" <<'PY'
import os, sys
import export_hw as E, zosd as Z, pages as P
obj = os.path.abspath(sys.argv[1])
E.GEN = os.path.join(obj, 'osd_gen'); E.SYSGEN = os.path.join(obj, 'osd_sys'); E.GOLD = os.path.join(obj, 'osd_golden')
font = Z.Font(*P.FONTS['saira'])
img, bg, got = E.model_render(font)
m = got['menu']; assert (got['x0'], got['y0']) == (E.X0, E.Y0)
T = E.build_tables(font, m, got['panel'], got['acc'])
hw = E.table_render(bg, T, E.X0, E.Y0)
bad = sum(1 for p, q in zip(img.getdata(), hw.getdata()) if p != q)
print(f'OSD model: table re-render vs model render_page: {bad} mismatches')
if bad: sys.exit(1)
E.emit(T)
# OV_N_ATLAS / OV_N_GLYPH count the glyphs of the model's own sample page (no RTL uses them): not compared
cut = lambda path: [l for l in open(path).read().split('\n') if not l.startswith('localparam integer OV_N_ATLAS')]
same = cut(os.path.join(E.GEN, 'tango_ov_geom.vh')) == cut('sys/tango_ov_geom.vh')
print('OSD model: sys/tango_ov_geom.vh vs the model\'s (but for OV_N_ATLAS / OV_N_GLYPH):', 'IDENTICAL' if same else 'DIFFERENT')
sys.exit(0 if same else 1)
PY
nice -n 10 python3 - "$OBJ/model_rows_empty_bank0.bin" <<'PY'
import sys, stream_hw as SH
SH.write_stream(sys.argv[1], [[SH.T_OSD, SH.ROWS, 0, 0] + [0] * (32 * 8)])
PY
nice -n 10 python3 tools/gen_cos.py
git diff --quiet -- rtl/template_cos.vh 2>/dev/null || echo "NOTE: rtl/template_cos.vh changed by tools/gen_cos.py"
nice -n 10 python3 tools/template_page.py "$OBJ"
nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" verilator --cc --exe --build -O3 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -DTANGO_SIM_RANDOM_RAM \
    '-DBUILD_DATE="sim"' \
    -Mdir "$OBJ" --top-module tb_template -I"$ROOT/sys" -I"$ROOT/rtl" -CFLAGS "-I$ROOT/sim" \
    $(grep '\.v$' sim/tb_template.files | sed "s#^#$ROOT/#") \
    "$ROOT/sim/tb_template.cpp" -o Vtb_template
set +e
nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$OBJ/Vtb_template" "$OBJ/template_page.bin" \
    "$OBJ/model_rows_empty_bank0.bin" "$OBJ" 37500 2000 din=2000 dout=8000 tsu=3000 th=1000 mode=template
TB=$?
nice -n 10 python3 tools/template_golden.py "$OBJ/template_run.json" "$OBJ/template_page_tables.json" "$OBJ"
GO=$?
python3 - "$OBJ/conf_str.txt" rtl/tango_core_template.v <<'PY'
import subprocess, sys
got = open(sys.argv[1]).read()
# the RTL's CONF_STR with its macros expanded (the framework's Video entries, `TANGO_VIDEO_CONF):
# sys/build_tools/confstr_expand.py; BUILD_DATE as the -DBUILD_DATE above, as run_tb_template_ascal.sh does
want = subprocess.run(['python3', 'sys/build_tools/confstr_expand.py', '-D', 'BUILD_DATE="sim"', sys.argv[2]],
                      check=True, stdout=subprocess.PIPE).stdout.decode()
print(f'READ_CFG {len(got)} bytes vs the RTL CONF_STR {len(want)} bytes:', 'IDENTICAL' if got == want else 'DIFFERENT')
sys.exit(0 if got == want else 1)
PY
CS=$?
ARGS=""; for k in 6 9 13 21 26 30 32; do ARGS="$ARGS $OBJ/menu_f$k.ppm $OBJ/golden_f$k.png"; done
python3 tools/compare_frames.py $ARGS
CMP=$?
set -e
[ $TB -eq 0 ] && [ $GO -eq 0 ] && [ $CS -eq 0 ] && [ $CMP -eq 0 ] && echo "TEMPLATE SIM GATE: PASS" || \
    { echo "TEMPLATE SIM GATE: FAIL (tb $TB, golden $GO, conf_str $CS, frames $CMP)"; exit 1; }
