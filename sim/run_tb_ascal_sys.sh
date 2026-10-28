#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_tb_ascal_sys.sh [nframes] -- the Template core through the real ascal (GHDL-converted) and the real
# tango_sdram on the W9825G6KH model (sim/tb_ascal_sys.v).  Frames land in sim/obj_ascal_sys/out_f*.ppm.
# Needs sys/ascal_ghdl/ (sys/ascal_ghdl/gen.sh regenerates it from sys/ascal.vhd).
# TB_ARGS: run-time arguments for the bench, e.g. TB_ARGS=+status=<32 hex digits> sets the core's option word
# (the framework's Aspect ratio status[127:126], Scale status[125:124], Scanlines status[123:122]: sys/tango_video_opts.vh;
# the core's Pattern status[44:41], Source size status[47:45]); sim/measure_scale.py measures the frames.
# -DTANGO_VIDEO_OPTS: the board build's TANGO_VIDEO_OPTS=1 (build/build_template_ascal.sh): sys/tango_video.v applies
# the Video options; the CONF_STR's `TANGO_VIDEO_CONF does not compile in an ascal build without it.
# Heavy job: run alone; capped by sys/build_tools/tango_capped.sh.
set -euo pipefail                   # a bench that stops ($fatal, e.g. the CE_PIXEL contract) fails the script
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj_ascal_sys; NF=${1:-8}
mkdir -p "$OBJ"
NETLIST=sys/ascal_ghdl/ascal_fixed.v
nice -n 10 python3 tools/gen_cos.py
TANGO_MEM_CAP=${TANGO_MEM_CAP:-8G} nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" \
    verilator --binary --timing -O2 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-INITIALDLY -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-UNOPTFLAT \
    -DTANGO_VIDEO_ASCAL -DTANGO_VIDEO_OPTS -DTANGO_VIDEO_ASCAL_MAXW=384 -DTANGO_VIDEO_ASCAL_MAXH=240 '-DBUILD_DATE="sim"' \
    -DNFRAMES_DEF=$NF \
    --Mdir "$OBJ" --top-module tb_ascal_sys -I"$ROOT/sys" -I"$ROOT/rtl" \
    $(grep '\.v$' sim/tb_template_ascal.files | grep -v -e tb_template.v -e ascal_wrap_sim.v | sed "s#^#$ROOT/#") \
    sys/ascal_wrap.v sys/ascal_ghdl/ascal_shim.v $NETLIST sim/sdram_w9825_model.v sim/tb_ascal_sys.v \
    -o Vtb_ascal_sys
cd "$OBJ" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" ./Vtb_ascal_sys ${TB_ARGS:-} | tee run.log
