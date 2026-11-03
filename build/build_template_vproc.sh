#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# build_template_vproc.sh [tag] -- the Template ASCAL core with MiSTer's video and audio processing (sys-tango README,
# "Video and audio processing"; TANGO_VIDEO_PROC=1: polyphase filters, gamma, shadow mask, audio filter), otherwise as
# build/build_template_ascal.sh (TANGO_VIDEO_OPTS=1, TANGO_VIDEO_ASCAL_MAXW=384).
# Optional build-time presets (sys/tango_cfg.vh; for boards without the Tango firmware, e.g. JTAG tests):
#   TANGO_PRESET_STATUS=<32 hex digits>   the option word at power-up (Pattern, Source size, Audio test, Scanlines ...)
#   TANGO_VPROC_PRESET="<vproc_preset.py settings>"   e.g. "--hfilter 'Interpolation (Sharp).txt' --sfilter
#                                         'Scanlines - Default.txt'" (MiSTer's filter files, from the folder TANGO_FILTERS_ROOT)
#   [tag]  a name for the preset, added to the archive name
# TANGO_VIDEO_DDR3=1 (sys-tango README, "The DDR3 path"): ascal's frames in the DDR3 (no tango_sdram, no
# SDRAM PLL); the archive gets _ddr3 after _vproc.
# Gate: sys/build_tools/sta_gate.py, every clock.
# Archive: $TANGO_ARCHIVE (default bitstreams/ in this checkout)/tango_template_ascal138_<stamp>_g<git>_vproc[_<tag>].{fs,bin,txt}
#   (the .txt has the gate, resources, the presets and the preset tables' json).
# A heavy job (several GB of memory, run through sys/build_tools/tango_capped.sh): one at a time.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NAME=tango_template_ascal138
TAG="${1:-}"
FILES="$ROOT/rtl/tango_core_template.v $ROOT/rtl/template_cos.vh"
START=$(mktemp); trap 'rm -f "$START"' EXIT
set +e
# Native-rate video (sys-tango README, "Native-rate video (vsync_adjust)"): BUILT IN (TANGO_VSYNC_ADJUST=1, Stage 2 only: the
# totals planned at 74.25 MHz from the core's measured frame rate) with the fixed 60 Hz raster as the DEFAULT
# (TANGO_VSYNC_DEFAULT=0): native only when Tango.ini says VSYNC_ADJUST=1. Both env-overridable;
# TANGO_VSYNC_ADJUST=0 builds the plain core.
VSA="${TANGO_VSYNC_ADJUST:-1}"; VSD="${TANGO_VSYNC_DEFAULT:-0}"
TANGO_NO_ARCHIVE=1 TANGO_VIDEO_ASCAL=1 TANGO_VIDEO_DDR3=1 TANGO_VIDEO_OPTS=1 TANGO_VIDEO_PROC=1 TANGO_VIDEO_ASCAL_MAXW=384 TANGO_OUT=build/out \
    TANGO_VSYNC_ADJUST="$VSA" TANGO_VSYNC_DEFAULT="$VSD" \
    "$ROOT/sys/board/console138k/build_core.sh" "$NAME" - $FILES
BC=$?
set -e
IMPL="$ROOT/build/out/$NAME/impl/pnr"
FS="$IMPL/$NAME.fs"
[ $BC -eq 0 ] && [ -f "$FS" ] && [ "$FS" -nt "$START" ] || { echo "NO FRESH BITSTREAM (build_core.sh exit $BC)"; exit 1; }
set +e; GATE=$(python3 "$ROOT/sys/build_tools/sta_gate.py" "$IMPL"); SG=$?; set -e   # TANGO_VIDEO_DDR3: no clk_sdram
echo "$GATE"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
DTAG=""; [ -n "$(git status --porcelain --untracked-files=no -- rtl build sys 2>/dev/null)" ] && DTAG="-dirty"
FSHA=$(git -C sys rev-parse --short=12 HEAD); FDIRTY=$(git -C sys status --porcelain --untracked-files=no | wc -l)
ARCH="${TANGO_ARCHIVE:-$ROOT/bitstreams}"; mkdir -p "$ARCH"
STAMP="$ARCH/${NAME}_$(date +%Y%m%d-%H%M)_g${SHA}${DTAG}_vproc_ddr3${TAG:+_$TAG}"; [ $SG -ne 0 ] && STAMP="${STAMP}_STA-FAIL"
cp "$FS" "$STAMP.fs" && cmp "$FS" "$STAMP.fs" && chmod 444 "$STAMP.fs"
python3 "$ROOT/sys/build_tools/fs2bin.py" "$STAMP.fs" "$STAMP.bin" && chmod 444 "$STAMP.bin"
{ echo "console-template-tango ASCAL + TANGO_VIDEO_PROC + TANGO_VIDEO_DDR3 $SHA$DTAG"; echo "framework: sys/ = sys-tango $FSHA (uncommitted files in sys/: $FDIRTY)"
  echo "TANGO_PRESET_STATUS=${TANGO_PRESET_STATUS:-}"; echo "TANGO_VPROC_PRESET=${TANGO_VPROC_PRESET:-}"
  echo "TANGO_VSYNC_ADJUST=$VSA TANGO_VSYNC_DEFAULT=$VSD"
  echo; echo "$GATE"
  grep -E "^\s*(Logic|CLS|Register|BSRAM|DSP|PLL)\s*\|" "$IMPL/$NAME.rpt.txt" || true
  J="$ROOT/build/out/${NAME}_vproc_preset.json"; [ -n "${TANGO_VPROC_PRESET:-}" ] && [ -f "$J" ] && { echo; echo "preset tables:"; cat "$J"; }
} > "$STAMP.txt"
chmod 444 "$STAMP.txt"
sha256sum "$STAMP.fs" "$STAMP.bin"
ls -l "$STAMP".*
[ $SG -ne 0 ] && { echo "WARNING: STA GATE FAIL -- do NOT flash"; exit 1; }
exit 0
