#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_tb_tango_sdram_ab.sh -- tango_sdram ports A/B at the NES cadence + port C (ascal) + refresh against the
# W9825G6KH model (sim/tb_tango_sdram_ab.v).
#   sim/run_tb_tango_sdram_ab.sh          the working-tree controller sys/tango_sdram.v + sys/tango_ab_slot.v:
#                                         mode 0 (NES) and mode 1 (stress) at DQ round trips 4 / 8 / 12 / 14 ns,
#                                         RD_CAP 1; expect TB_RESULT PASS in every run
#   env: US=<sim microseconds per run> (default 3000), DQS="4 8 12 14", MODES="0 1", MASTER_STALLS=1,
#        RD_CAP=<0|1|2> (default 1).  RD_CAP 1 takes word 0 at the falling edge T+CL+1.5: it needs a read round
#        trip of 5.2..15.6 ns (the Console 138K: ~12 ns), so 4 ns fails with RD_CAP 1 by design, as port C always
#        did (obj_sdram_c_d4c1); RD_CAP=0 DQS=4 shows the controller right at that delay with the matching edge.
# A heavy job: run one build or bench at a time.  Memory cap: TANGO_MEM_CAP (default 4G).
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
US=${US:-3000}
DEFS="-DRD_CAP_TB=${RD_CAP:-1}"; [ "${MASTER_STALLS:-0}" = 1 ] && DEFS="$DEFS -DMASTER_STALLS"
OBJ=sim/obj_sdram_ab${MASTER_STALLS:+_stall}_c${RD_CAP:-1}; mkdir -p "$OBJ"
SRCS="sys/tango_sdram.v sys/tango_ab_slot.v"; DQS=${DQS:-"4 8 12 14"}; MODES=${MODES:-"0 1"}
TANGO_MEM_CAP=${TANGO_MEM_CAP:-4G} nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" \
    verilator --binary --timing -O2 -Wall -Wno-fatal $DEFS \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-INITIALDLY -Wno-MULTIDRIVEN -Wno-REALCVT \
    --Mdir "$OBJ" --top-module tb_tango_sdram_ab -I"$ROOT/sys" \
    $SRCS sim/sdram_w9825_model.v sim/tb_tango_sdram_ab.v -o Vtb_sdram_ab > "$OBJ/build.log" 2>&1 \
    || { tail -40 "$OBJ/build.log"; exit 2; }
RC=0
for m in $MODES; do for d in $DQS; do
    LOG="$OBJ/run_m${m}_dq${d}.log"
    TANGO_MEM_CAP=${TANGO_MEM_CAP:-4G} nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" \
        "$OBJ/Vtb_sdram_ab" +mode=$m +dq=$d +us=$US > "$LOG" 2>&1
    echo "== mode $m dq $d ns: $(grep -h 'TB_RESULT' "$LOG")"
    grep -h -E '^TB (A|min|lat|C|model|flags)' "$LOG" | sed 's/^/   /'
    grep -q 'TB_RESULT PASS' "$LOG" || RC=1
done; done
exit $RC
