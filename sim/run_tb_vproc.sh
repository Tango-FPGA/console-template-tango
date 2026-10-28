#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_tb_vproc.sh [obj-dir] -- the Template with MiSTer's video and audio processing (sys-tango README, "Video and
# audio processing", TANGO_VIDEO_PROC) through the real ascal (GHDL netlist, FRAC 8) and tango_sdram on the W9825G6KH model, with a BL616 SPI
# master playing link transfers (sim/tb_vproc.v).  Frames land in <obj-dir>/out_f*.ppm (default sim/obj_vproc).
#   TB_ARGS: +stream=<file> (transfers, e.g. from sys/build_tools/vproc_preset.py --stream), +status=<hex>,
#            +nframes=<n>, +alog=<file>, +audio_only=<ms>, +spi_at_us=<n>     (tb_vproc.v header)
#   VPROC_DEFS: extra Verilator defines, e.g. "-DTANGO_VPROC_PRESET -I<dir with tango_vproc_preset.vh>"
#               or "-DTANGO_PRESET_STATUS=128'h..." (the build-time presets, sys/tango_cfg.vh)
#   VPROC_BUILD=0: reuse the compiled bench in <obj-dir>
#   VPROC_CORE=<file>: the core (module tango_core) in place of rtl/tango_core_template.v, e.g. sim/tango_core_novideo.v
# A heavy job: run it alone; capped by sys/build_tools/tango_capped.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ="${1:-sim/obj_vproc}"
mkdir -p "$OBJ"; OBJ="$(cd "$OBJ" && pwd)"
NETLIST=sys/ascal_ghdl/ascal_fixed8_ddr3.v   # TANGO_VIDEO_DDR3 (template_vproc_ddr3.py)       # TANGO_VIDEO_PROC: ascal at FRAC 8 (sys/ascal_ghdl/gen.sh 8)
SHIM=sys/ascal_ghdl/ascal_shim8_ddr3.v
if [ "${VPROC_BUILD:-1}" = 1 ]; then
nice -n 10 python3 tools/gen_cos.py
TANGO_MEM_CAP=${TANGO_MEM_CAP:-8G} nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" \
    verilator --binary --timing -O2 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-INITIALDLY -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-UNOPTFLAT \
    -DTANGO_VIDEO_DDR3 -DTANGO_VIDEO_ASCAL -DTANGO_VIDEO_OPTS -DTANGO_VIDEO_PROC -DTANGO_VIDEO_ASCAL_MAXW=384 -DTANGO_VIDEO_ASCAL_MAXH=240 \
    '-DBUILD_DATE="sim"' ${VPROC_DEFS:-} \
    --Mdir "$OBJ" --top-module tb_vproc -I"$ROOT/sys" -I"$ROOT/sys/sim" -I"$ROOT/rtl" \
    $(grep '\.v$' sim/tb_template_ascal.files | grep -v -e tb_template.v -e ascal_wrap_sim.v -e tango_sdram.v \
      | sed "s#^rtl/tango_core_template\.v\$#${VPROC_CORE:-rtl/tango_core_template.v}#" | sed "s#^#$ROOT/#") \
    sys/ascal_wrap.v $SHIM $NETLIST sys/tango_vproc_regs.v sys/tango_gamma.v sys/tango_shmask.v \
    sys/tango_audio_filter.v sys/tango_ddr3.v sys/tango_ddr3_arb.v sys/tango_ddr3_vport.v sys/tango_ddr3_cport.v \
    sys/tango_ddr3_fifo.v sys/sim/tango_ddr3_model.v sim/tb_vproc.v \
    -o Vtb_vproc
fi
cd "$OBJ" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" ./Vtb_vproc ${TB_ARGS:-} | tee run.log
