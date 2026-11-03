#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# build_template_ascal.sh -- build the Template ASCAL core for the Tang Console 138K.
# Uses TANGO_VIDEO_ASCAL: the core drives 320x240 native video; the framework's ascal.vhd +
# SDRAM (port C) scales it to 720p60.  Tests the ASCAL + SDRAM video path.
# No TANGO_SD or TANGO_NES_SDRAM: the template core needs neither the SD block device nor
# the NES-compatible SDRAM ports.  TANGO_VIDEO_ASCAL_MAXW=384 overrides the default 256: the widest Source size
# (384x224 CPS; rtl/tango_core_template.v size_tab) must be measured whole by sys/tango_video.v.
# TANGO_VIDEO_OPTS=1: the CONF_STR's Aspect ratio / Scale / Scanlines are the framework's entries (`TANGO_VIDEO_CONF,
# sys/tango_video_opts.vh: status[127:122]) and sys/tango_video.v applies them; the core gives only its native 4:3.
#   build/build_template_ascal.sh        the core (tango_template_ascal138)
# Gate: sys/build_tools/sta_gate.py with --relax clk_sdram:96.0 (SDRAM PLL = 96 MHz;
#   SDC overconstrain 120 MHz forces compact placement -- see tango_console138k_sdram108.sdc).
# Archive: $TANGO_ARCHIVE (default bitstreams/ in this checkout)/tango_template_ascal138_<stamp>_g<git>.{fs,bin,txt}
# A heavy job (several GB of memory, run through sys/build_tools/tango_capped.sh): one at a time.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NAME=tango_template_ascal138
FILES="$ROOT/rtl/tango_core_template.v $ROOT/rtl/template_cos.vh"
START=$(mktemp); trap 'rm -f "$START"' EXIT
set +e
TANGO_NO_ARCHIVE=1 TANGO_VIDEO_ASCAL=1 TANGO_VIDEO_OPTS=1 TANGO_VIDEO_ASCAL_MAXW=384 TANGO_OUT=build/out \
    "$ROOT/sys/board/console138k/build_core.sh" "$NAME" - $FILES
BC=$?
set -e
IMPL="$ROOT/build/out/$NAME/impl/pnr"
FS="$IMPL/$NAME.fs"
[ $BC -eq 0 ] && [ -f "$FS" ] && [ "$FS" -nt "$START" ] || { echo "NO FRESH BITSTREAM (build_core.sh exit $BC)"; exit 1; }
set +e; GATE=$(python3 "$ROOT/sys/build_tools/sta_gate.py" "$IMPL" --relax clk_sdram:96.0); SG=$?; set -e
echo "$GATE"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
DTAG=""; [ -n "$(git status --porcelain --untracked-files=no -- rtl build sys 2>/dev/null)" ] && DTAG="-dirty"
FSHA=$(git -C sys rev-parse --short=12 HEAD); FDIRTY=$(git -C sys status --porcelain --untracked-files=no | wc -l)
ARCH="${TANGO_ARCHIVE:-$ROOT/bitstreams}"; mkdir -p "$ARCH"
STAMP="$ARCH/${NAME}_$(date +%Y%m%d-%H%M)_g${SHA}${DTAG}"; [ $SG -ne 0 ] && STAMP="${STAMP}_STA-FAIL"
cp "$FS" "$STAMP.fs" && cmp "$FS" "$STAMP.fs" && chmod 444 "$STAMP.fs"
python3 "$ROOT/sys/build_tools/fs2bin.py" "$STAMP.fs" "$STAMP.bin" && chmod 444 "$STAMP.bin"
{ echo "console-template-tango ASCAL $SHA$DTAG"; echo "framework: sys/ = sys-tango $FSHA (uncommitted files in sys/: $FDIRTY)"
  echo; echo "$GATE"
  grep -E "^\s*(Logic|CLS|Register|BSRAM|DSP|PLL)\s*\|" "$IMPL/$NAME.rpt.txt" || true; } > "$STAMP.txt"
chmod 444 "$STAMP.txt"
ls -l "$STAMP".*
[ $SG -ne 0 ] && { echo "WARNING: STA GATE FAIL -- do NOT flash"; exit 1; }
exit 0
