#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# run_vproc_gates.sh [case ...] -- the video gates of MiSTer's video processing (sys-tango README, "Video and audio processing") on the
# Template: each case loads real MiSTer files over the link (sim/tb_vproc.v's SPI master playing what
# sys/build_tools/vproc_preset.py makes of them), runs the real ascal netlist + tango_sdram + the SDRAM model, and
# compares the last frame pixel for pixel with the models (tools/vproc_golden.py; ascal at FRAC 8, 256 phases: the
# bench builds sys/ascal_ghdl/ascal_fixed8.v).  Case frac8_256_4 loads a 256-phase file (every phase lands in its own
# slot; FRAC 4 kept every 16th) and a 4-phase one (each phase filling 64 slots).  Case nn also compares with the
# framework's picture before TANGO_VIDEO_PROC (the reference frame of run_tb_ascal_sys.sh, md5 REF_NN).  Case audio
# runs the Audio test through a Filters_Audio file against sys/build_tools/iir_model.py; case afilter_cycle toggles the
# Audio filter Custom <-> Internal four times (each load must restart the filter from zero taps); case preset_rom builds
# a second bench with the build-time presets (case all's settings as the logic ROM).
# Filter files from FILTERS: a folder laid out as a MiSTer SD card's (Filters/, Gamma/, Shadow_Masks/, Presets/,
# Filters_Audio/; sys/build_tools/vproc_preset.py --root); every case but nn loads files, and stops here without it.
# Results: sim/obj_vproc_gates/<case>/.
# A heavy job (one bench build, then one run per case): run it alone.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OUT=sim/obj_vproc_gates; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
FILTERS="${FILTERS:-}"
REF_NN=0e08bf27d3b6186e7fa73848755eaa69    # run_tb_ascal_sys.sh frame 3-7, status 0
st() {  # status word: pattern size scanlines aspect scale audio -> 32 hex digits
    python3 -c "import sys; p,s,l,a,c,u=map(int,sys.argv[1:]); print('%032x' % ((p<<41)|(s<<45)|(u<<48)|(l<<122)|(c<<124)|(a<<126)))" "$@"
}
#     name           status (pattern size scanlines aspect scale audio)   nframes  vproc_preset.py settings
CASES=(
  "nn            $(st 0 0 0 0 0 0) 6 -"
  "grid_sharp    $(st 1 0 0 0 0 0) 5 --hfilter 'Interpolation (Sharp).txt'"
  "nes_lanczos   $(st 1 1 0 0 0 0) 6 --hfilter 'Upscaling - Lanczos Bicubic etc/lanczos3_16p_256.txt' --vfilter 'Upscaling - Lanczos Bicubic etc/lanczos2_8p_256.txt'"
  "frac8_256_4   $(st 1 1 0 0 0 0) 6 --hfilter 'Upscaling - Lanczos Bicubic etc/lanczos2_256p_256.txt' --vfilter 'Upscaling - Lanczos Bicubic etc/lanczos2_4p_128.txt'"
  "scan_filter   $(st 0 0 2 0 0 0) 5 --hfilter 'Interpolation (Sharp).txt' --sfilter 'Scanlines - Default.txt'"
  "scan_25       $(st 1 0 1 0 0 0) 5 --hfilter 'Interpolation (Medium).txt' --sfilter 'Scanlines - Default.txt'"
  "dim_poly      $(st 1 0 1 0 0 0) 5 --hfilter 'Interpolation (Medium).txt'"
  "adaptive      $(st 1 0 0 0 0 0) 5 --preset 'Scanlines - Soft.ini'"
  "gamma         $(st 0 0 0 0 0 0) 5 --gamma 'Pure_Gamma/gamma_150.txt'"
  "mask_1x       $(st 1 0 0 0 0 0) 5 --mask 'Simple (Monochrome)/Aperture Grille (1968).txt' --maskmode 1x"
  "mask_2xrot    $(st 0 0 0 0 0 0) 5 --mask 'Sony PVM (Generic) (~1980).txt' --maskmode '2x rotated'"
  "all           $(st 1 0 2 0 0 0) 5 --hfilter 'Interpolation (Sharp).txt' --sfilter 'Scanlines - Default.txt' --gamma 'Pure_Gamma/gamma_120.txt' --mask 'JVC D-Series (~2000).txt' --maskmode 1x"
)
WANT=" $* "
NEED=""                 # the selected cases that load filter files (all but nn)
for c in "${CASES[@]}"; do
    read -r NAME _ _ ARGS <<< "$c"
    [ "$ARGS" = - ] && continue
    { [ $# -eq 0 ] || [[ "$WANT" == *" $NAME "* ]]; } && NEED="$NEED $NAME"
done
for NAME in audio audio_mix afilter_cycle preset_rom; do
    { [ $# -eq 0 ] || [[ "$WANT" == *" $NAME "* ]]; } && NEED="$NEED $NAME"
done
if [ -n "$NEED" ] && [ ! -d "${FILTERS:-/nonexistent}" ]; then
    echo "VPROC GATES: cases$NEED load MiSTer's filter files: set FILTERS to a folder laid out as a MiSTer SD card's"
    echo "  (Filters/, Gamma/, Shadow_Masks/, Presets/, Filters_Audio/), or run only case nn: sim/run_vproc_gates.sh nn"
    exit 2
fi
if [ "${VPROC_BUILD:-1}" = 1 ]; then
    VPROC_BUILD=1 TB_ARGS="+nframes=1" sim/run_tb_vproc.sh "$OUT/bench" > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "VPROC GATES: bench build FAILED"; exit 1; }
fi
PASS=0; FAIL=0
for c in "${CASES[@]}"; do
    read -r NAME STATUS NF ARGS <<< "$c"
    [ $# -gt 0 ] && [[ "$WANT" != *" $NAME "* ]] && continue
    D="$OUT/$NAME"; rm -rf "$D"; mkdir -p "$D"
    SARG=""
    if [ "$ARGS" != - ]; then
        eval "python3 sys/build_tools/vproc_preset.py --root \"$FILTERS\" --status $STATUS $ARGS --stream \"$D/stream.bin\" --json \"$D/tables.json\"" > "$D/preset.log" 2>&1 || { echo "$NAME: vproc_preset.py FAILED"; cat "$D/preset.log"; FAIL=$((FAIL+1)); continue; }
        SARG="+stream=$D/stream.bin"
    fi
    ( cd "$D" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$OUT/bench/Vtb_vproc" +status=$STATUS +nframes=$NF $SARG > run.log 2>&1 )
    RC=$?
    LAST=$((NF - 1))
    WIN=$(grep -o 'ascal window h [0-9]*\.\.[0-9]* v [0-9]*\.\.[0-9]*' "$D/run.log" | tail -1 | sed -E 's/ascal window h ([0-9]+)\.\.([0-9]+) v ([0-9]+)\.\.([0-9]+)/\1,\2,\3,\4/')
    TARG=""; [ "$ARGS" != - ] && TARG="--tables $D/tables.json"
    GOLD=$(python3 tools/vproc_golden.py "$D/out_f$LAST.ppm" $TARG --status $STATUS --win "$WIN" --diff "$D/diff.png" 2>&1)
    GRC=$?
    EXTRA=""
    if [ "$NAME" = nn ]; then
        M=$(md5sum < "$D/out_f$LAST.ppm" | cut -d' ' -f1)
        [ "$M" = "$REF_NN" ] && EXTRA=" = the framework's frame before TANGO_VIDEO_PROC (md5 $M)" || { EXTRA=" md5 $M != $REF_NN"; GRC=1; }
    fi
    if [ $RC -eq 0 ] && [ $GRC -eq 0 ] && grep -q 'TB done' "$D/run.log"; then
        echo "PASS $NAME: $(echo "$GOLD" | head -1 | sed 's/^vproc_golden: //')$EXTRA"; PASS=$((PASS+1))
    else
        echo "FAIL $NAME (tb exit $RC): $GOLD$EXTRA"; tail -3 "$D/run.log"; FAIL=$((FAIL+1))
    fi
done
# audio: the Template's Audio test (440 Hz square) through a Filters_Audio file loaded over the link, 260 ms: every
# filter step's two outputs, every 48 kHz hand-over and every HDMI-side sample against sys/build_tools/iir_model.py
# (MiSTer's IIR arithmetic, the DC blocker, aud_mix_top), bit for bit.  audio_mix: the tone on the left only, the
# Template's Stereo Mix 25 % (AUDIO_MIX), the core volume's boost x2 (0x39) and the global volume att 1 (0x26).
for AC in "audio $(st 0 0 0 0 0 2) -" \
          "audio_mix $(python3 -c "print('%032x' % ((5 << 48) | (1 << 51)))") --volume 0x20 --audvol 1"; do
    read -r NAME STATUS XARGS <<< "$AC"
    [ $# -eq 0 ] || [[ "$WANT" == *" $NAME "* ]] || continue
    [ "$XARGS" = - ] && XARGS=""
    D="$OUT/$NAME"; rm -rf "$D"; mkdir -p "$D"
    python3 sys/build_tools/vproc_preset.py --root "$FILTERS" --afilter 'Arcade LPF/Arcade LPF 2khz 2nd.txt' $XARGS \
        --stream "$D/stream.bin" --json "$D/tables.json" > "$D/preset.log" 2>&1
    PRC=$?
    ( cd "$D" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$OUT/bench/Vtb_vproc" +status=$STATUS \
        +stream="$D/stream.bin" +audio_only=260 +alog="$D/audio.alog" > run.log 2>&1 )
    RC=$?
    CHK=$(python3 sys/build_tools/iir_model.py check "$D/audio.alog" --json "$D/tables.json" 2>&1); CRC=$?
    echo "$CHK" > "$D/iir_model.log"; rm -f "$D/audio.alog"                  # the log is ~70 MB
    if [ $PRC -eq 0 ] && [ $RC -eq 0 ] && [ $CRC -eq 0 ]; then
        echo "PASS $NAME: $(echo "$CHK" | tail -1 | sed 's/^iir_model: //')"; PASS=$((PASS+1))
    else
        echo "FAIL $NAME (preset $PRC, tb $RC, model $CRC): $(echo "$CHK" | tail -3)"; tail -3 "$D/run.log"; FAIL=$((FAIL+1))
    fi
done
# afilter_cycle: the in-core OSD's Audio filter Custom <-> Internal four times (vproc_preset.py --afilter-cycle: the 2 kHz
# file, 60 ms, Internal, 60 ms, ...; seen on the board: Internal after Custom oscillated at 9.6 kHz):
# every load must start its filter from zero taps (MiSTer: sys_top.v 386-395 areset, iir_filter.v 179-181), so the
# model -- which clears the taps at each load -- must agree bit for bit through all eight loads, and the run must end
# on the power-up coefficients.  iir_model.py spectrum prints each stretch's lines (afilter_cycle/spectrum.log).
if [ $# -eq 0 ] || [[ "$WANT" == *" afilter_cycle "* ]]; then
    D="$OUT/afilter_cycle"; rm -rf "$D"; mkdir -p "$D"
    python3 sys/build_tools/vproc_preset.py --root "$FILTERS" --afilter 'Arcade LPF/Arcade LPF 2khz 2nd.txt' \
        --afilter-cycle 60,60 --cycles 4 --stream "$D/stream.bin" > "$D/preset.log" 2>&1
    PRC=$?
    python3 -c "import sys, json; sys.path.insert(0, 'sys/build_tools'); from vproc_preset import AF_DEFAULTS; json.dump({'audio': AF_DEFAULTS}, open('$D/default.json', 'w'))"
    ( cd "$D" && nice -n 10 "$ROOT/sys/build_tools/tango_capped.sh" "$OUT/bench/Vtb_vproc" +status=$(st 0 0 0 0 0 2) \
        +stream="$D/stream.bin" +audio_only=520 +alog="$D/audio.alog" > run.log 2>&1 )
    RC=$?
    CHK=$(python3 sys/build_tools/iir_model.py check "$D/audio.alog" --json "$D/default.json" 2>&1); CRC=$?
    echo "$CHK" > "$D/iir_model.log"
    python3 sys/build_tools/iir_model.py spectrum "$D/audio.alog" > "$D/spectrum.log" 2>&1; rm -f "$D/audio.alog"
    NZ=$(echo "$CHK" | grep -o 'resets [0-9]*' | grep -o '[0-9]*')
    if [ $PRC -eq 0 ] && [ $RC -eq 0 ] && [ $CRC -eq 0 ] && [ "${NZ:-0}" -ge 9 ]; then
        echo "PASS afilter_cycle: $(echo "$CHK" | tail -1 | sed 's/^iir_model: //')"; PASS=$((PASS+1))
    else
        echo "FAIL afilter_cycle (preset $PRC, tb $RC, model $CRC, resets ${NZ:-?}): $(echo "$CHK" | tail -3)"; tail -3 "$D/run.log"; FAIL=$((FAIL+1))
    fi
fi
# preset_rom: the build-time presets (sys/tango_cfg.vh: TANGO_PRESET_STATUS + TANGO_VPROC_PRESET), as a JTAG test build
# makes them: a second bench with case all's option word compiled in and case all's transfers as the logic ROM, and no
# link traffic at all.  Its last frame must equal case all's (md5) and the golden.
if [ $# -eq 0 ] || [[ "$WANT" == *" preset_rom "* ]]; then
    D="$OUT/preset_rom"; rm -rf "$D"; mkdir -p "$D"
    read -r _ STATUS NF ARGS <<< "${CASES[${#CASES[@]}-1]}"      # case all
    eval "python3 sys/build_tools/vproc_preset.py --root \"$FILTERS\" --status $STATUS $ARGS --vh \"$D/tango_vproc_preset.vh\" --json \"$D/tables.json\"" > "$D/preset.log" 2>&1
    PRC=$?
    VPROC_BUILD=1 VPROC_DEFS="${VPROC_DEFS:-} -DTANGO_VPROC_PRESET -I$D -DTANGO_PRESET_STATUS=128'h$STATUS" TB_ARGS="+nframes=$NF" \
        sim/run_tb_vproc.sh "$D" > "$D/build_run.log" 2>&1
    RC=$?
    LAST=$((NF - 1))
    WIN=$(grep -o 'ascal window h [0-9]*\.\.[0-9]* v [0-9]*\.\.[0-9]*' "$D/run.log" 2>/dev/null | tail -1 | sed -E 's/ascal window h ([0-9]+)\.\.([0-9]+) v ([0-9]+)\.\.([0-9]+)/\1,\2,\3,\4/')
    GOLD=$(python3 tools/vproc_golden.py "$D/out_f$LAST.ppm" --tables "$D/tables.json" --status $STATUS --win "$WIN" --diff "$D/diff.png" 2>&1)
    GRC=$?
    M1=$(md5sum < "$D/out_f$LAST.ppm" 2>/dev/null | cut -d' ' -f1); M2=$(md5sum < "$OUT/all/out_f$LAST.ppm" 2>/dev/null | cut -d' ' -f1)
    if [ $PRC -eq 0 ] && [ $RC -eq 0 ] && [ $GRC -eq 0 ] && grep -q 'TB done' "$D/run.log" && [ -n "$M1" ] && [ "$M1" = "$M2" ]; then
        echo "PASS preset_rom: $(echo "$GOLD" | head -1 | sed 's/^vproc_golden: //') = case all's frame over the link (md5 $M1)"; PASS=$((PASS+1))
    else
        echo "FAIL preset_rom (preset $PRC, tb $RC, md5 $M1 vs all $M2): $GOLD"; tail -5 "$D/build_run.log"; FAIL=$((FAIL+1))
    fi
fi
echo "VPROC GATES: $PASS PASS, $FAIL FAIL"
[ $FAIL -eq 0 ]
