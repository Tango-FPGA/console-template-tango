#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_tb_template_ascal.sh -- Template ASCAL sim gate.
# Compiles tango_sys with -DTANGO_VIDEO_ASCAL -DTANGO_SIM, using ascal_wrap_sim.v
# (behavioral replacement for ascal.vhd + SDRAM) to verify the signal path
# from tango_core_template through ascal_wrap_sim to 720p output.
#
# PASS needs:
#   the tb checks (same as run_tb_template.sh: link, OSD, pads, CONF_STR);
#   the ASCAL output window is NOT all-black (ascal_wrap_sim producing the picture);
#   sampled pixels at the top strip and the left column match the nn formula and the test pattern the session
#   selected (the pad's A / B and the OSD's Pattern: tools/template_ascal_golden.py, tools/template_patterns.py).
#
# A heavy job: run one build or bench at a time (memory).
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj_ascal
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
export PYTHONPATH="$ROOT/tools/osd-model${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$OBJ"

# OSD font (same dependency as run_tb_template.sh)
FONT=tools/osd-model/fonts/SairaCondensed-SemiBold.ttf
[ -f "$FONT" ] || { echo "no $FONT"; exit 2; }

# OSD model tables (same as run_tb_template.sh)
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
nice -n 10 python3 tools/template_page.py "$OBJ"

# Compile with ASCAL defines: -DTANGO_VIDEO_ASCAL activates the SDRAM path in tango_sys,
# -DTANGO_SIM makes tango_video pick ascal_wrap_sim instead of ascal_wrap.
# -DTANGO_VIDEO_OPTS: the board build's TANGO_VIDEO_OPTS=1 (build/build_template_ascal.sh): the CONF_STR's
# `TANGO_VIDEO_CONF entries, applied by sys/tango_video.v (it does not compile in an ascal build without it).
# TANGO_VIDEO_ASCAL_MAXW=384 / _MAXH=240: the template's widest and tallest Source sizes (384x224, 320x240).
nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" verilator --cc --exe --build -O3 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -DTANGO_SIM_RANDOM_RAM \
    -DTANGO_VIDEO_ASCAL -DTANGO_VIDEO_OPTS -DTANGO_SIM \
    -DTANGO_VIDEO_ASCAL_MAXW=384 -DTANGO_VIDEO_ASCAL_MAXH=240 \
    '-DBUILD_DATE="sim"' \
    -Mdir "$OBJ" --top-module tb_template -I"$ROOT/sys" -I"$ROOT/rtl" -CFLAGS "-I$ROOT/sim" \
    $(grep '\.v$' sim/tb_template_ascal.files | sed "s#^#$ROOT/#") \
    "$ROOT/sim/tb_template.cpp" -o Vtb_template

set +e
nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$OBJ/Vtb_template" "$OBJ/template_page.bin" \
    "$OBJ/model_rows_empty_bank0.bin" "$OBJ" 37500 2000 din=2000 dout=8000 tsu=3000 th=1000 mode=template
TB=$?

# ASCAL pattern check (frames 6, 9, 13, 21, 26, 30, 32 — same frames as run_tb_template.sh)
# The golden checker verifies the picture is not all-black and shows the pattern selected by then (run.json).
ASCAL_FRAMES=""
NMISS=0
for k in 6 9 13 21 26 30 32; do
    f="$OBJ/menu_f$k.ppm"
    if [ -f "$f" ]; then ASCAL_FRAMES="$ASCAL_FRAMES $f"; else echo "ASCAL GOLDEN: $f missing"; NMISS=$((NMISS + 1)); fi
done
if [ -z "$ASCAL_FRAMES" ] || [ $NMISS -ne 0 ]; then
    echo "ASCAL GOLDEN: $NMISS of the 7 frames missing in $OBJ"
    AG=1
else
    nice -n 10 python3 tools/template_ascal_golden.py "$OBJ/template_run.json" $ASCAL_FRAMES
    AG=$?
fi

nice -n 10 python3 tools/template_golden.py "$OBJ/template_run.json" "$OBJ/template_page_tables.json" "$OBJ"
GO=$?

python3 - "$OBJ/conf_str.txt" rtl/tango_core_template.v <<'PY'
import subprocess, sys
got = open(sys.argv[1]).read()
# the RTL's CONF_STR with its macros expanded (the framework's Video entries, `TANGO_VIDEO_CONF):
# sys/build_tools/confstr_expand.py; BUILD_DATE as the sim's -DBUILD_DATE="sim" above
want = subprocess.run(['python3', 'sys/build_tools/confstr_expand.py', '-D', 'BUILD_DATE="sim"', sys.argv[2]],
                      check=True, stdout=subprocess.PIPE).stdout.decode()
print(f'READ_CFG {len(got)} bytes vs the RTL CONF_STR {len(want)} bytes:', 'IDENTICAL' if got == want else 'DIFFERENT')
sys.exit(0 if got == want else 1)
PY
CS=$?
set -e
[ $TB -eq 0 ] && [ $AG -eq 0 ] && [ $GO -eq 0 ] && [ $CS -eq 0 ] && \
    echo "TEMPLATE ASCAL SIM GATE: PASS" || \
    { echo "TEMPLATE ASCAL SIM GATE: FAIL (tb $TB, ascal_golden $AG, template_golden $GO, conf_str $CS)"; exit 1; }
