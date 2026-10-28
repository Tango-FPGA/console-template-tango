#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_idle_gates.sh -- "black until the core's first frame" (sys README; sys/tango_video.v show_ok) on the board's video
# path: sim/tb_vproc.v (the real ascal netlist, tango_sdram on the W9825G6KH model, no TANGO_SIM), two cases:
#   novideo  the core sends no picture (sim/tango_core_novideo.v in place of the Template: CE_PIXEL only, as nes-tango
#            before a ROM; a bench of its own), the SDRAM model filled with 8080 at time 0 (an unwritten buffer is not
#            black on the board) and an OSD page
#            played over the link (menu-tango fpga/sim/streams/s0_golden_cores_console.bin): no picture from
#            tango_video in any frame, and the last frame = that page over black (tools/idle_check.py, OSD model)
#   video    the Template's frames, from output frame 0: black until the first picture, then the whole picture in
#            every frame (the gate opens at a frame boundary)
# Before sys-tango idle-black the board path had no gate: case novideo showed the unwritten buffer in the reset window
# (0..640 x 0..359) at the top left, as a core with no picture yet (e.g. a console core before a ROM) showed it.
# Needs a menu-tango checkout (TANGO_FW) for the stream (the OSD model is tools/osd-model/).  Results:
# sim/obj_idle_gates/<case>/.  A heavy job (two bench builds, two runs): run it alone.
#   VPROC_BUILD=0 reuses the Template bench in sim/obj_idle_gates/bench (the no-picture bench is built when missing).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OUT=sim/obj_idle_gates; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
FW="${TANGO_FW:-}"
[ -n "$FW" ] || { echo "IDLE GATES: set TANGO_FW to a menu-tango checkout (case novideo plays its fpga/sim/streams/s0_golden_cores_console.bin)"; exit 2; }
STREAM="$FW/fpga/sim/streams/s0_golden_cores_console.bin"
[ -f "$STREAM" ] || { echo "IDLE GATES: no $STREAM (set TANGO_FW to a menu-tango checkout)"; exit 2; }
if [ "${VPROC_BUILD:-1}" = 1 ]; then
    VPROC_BUILD=1 TB_ARGS="+nframes=1" sim/run_tb_vproc.sh "$OUT/bench" > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "IDLE GATES: bench build FAILED"; exit 1; }
fi
if [ "${VPROC_BUILD:-1}" = 1 ] || [ ! -x "$OUT/bench_novideo/Vtb_vproc" ]; then
    VPROC_BUILD=1 VPROC_CORE=sim/tango_core_novideo.v TB_ARGS="+nframes=1" sim/run_tb_vproc.sh "$OUT/bench_novideo" \
        > "$OUT/build_novideo.log" 2>&1 || { tail -20 "$OUT/build_novideo.log"; echo "IDLE GATES: no-picture bench build FAILED"; exit 1; }
fi
PASS=0; FAIL=0
for c in "novideo:+fill_sdram=8080 +stream=$STREAM +first_dump=0 +nframes=8" "video:+first_dump=0 +nframes=8"; do
    NAME=${c%%:*}; ARGS=${c#*:}
    D="$OUT/$NAME"; rm -rf "$D"; mkdir -p "$D"
    BENCH="$OUT/bench"; [ "$NAME" = novideo ] && BENCH="$OUT/bench_novideo"
    ( cd "$D" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$BENCH/Vtb_vproc" $ARGS > run.log 2>&1 )
    RC=$?
    if [ "$NAME" = novideo ]; then CHK=$(python3 tools/idle_check.py novideo "$D" "$STREAM" 2>&1); else CHK=$(python3 tools/idle_check.py video "$D" 2>&1); fi
    CRC=$?
    echo "$CHK" > "$D/check.log"
    if [ $RC -eq 0 ] && [ $CRC -eq 0 ] && grep -q 'TB done' "$D/run.log"; then echo "PASS $NAME"; PASS=$((PASS+1))
    else echo "FAIL $NAME (tb $RC, check $CRC):"; echo "$CHK" | grep -E 'FAIL|frames' | head -6; FAIL=$((FAIL+1)); fi
done
echo "IDLE GATES: $PASS pass, $FAIL fail"
[ $FAIL -eq 0 ]
