#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""stream_hw.py -- the BL616 -> FPGA SPI byte stream that draws the launcher's Cores page on a
Tango core, built from export_hw.py's hardware tables (the same tables its pure-table re-render
proves equal to the model), plus the goldens for the menu-core sim gate.

Stream file format (shared with the BL616 firmware side; tools/osd-model/tango_stream_check.py):
  binary, repeated records:  u16 little-endian length N, then N bytes.
  One record = one CSN-low transfer: byte 0 target, byte 1 command, then data.
  For reads the record carries the dummy byte and one placeholder byte per reply byte
  (the MOSI bytes clocked while the reply is read); their MISO bytes are the reply.

Wire formats (the OSD commands of the BL616 link, target 2): multi-byte fields big-endian.
  CAPS      02 10 00 + 13 x 00                         (reply bytes 3..15)
  STATUS    02 17 00 00                                (reply byte 3)
  GEOMETRY  02 11 x0 y0 w h (2 B each) strip rowpitch top glyphrows
  PALETTE   02 12 first count + count x (R G B)        (index 16 = K = 3/4 panel)
  ATLAS     02 13 col(2) + per column ATW/8 bytes, word MSB first
  GLYPHS    02 14 bank first(2) + 4-byte entries
  ROWS      02 15 bank first + 8-byte entries (entry[63:56] first)
  SWAP      02 16 bank
  ENABLE    02 01 01

Outputs:
  fpga/sim/streams/model_cores_console.bin   the firmware's core-start order: CAPS, STATUS, PALETTE,
                                      GEOMETRY, ATLAS, GLYPHS(bank 1), ROWS(bank 1), SWAP 1, ENABLE 1
  fpga/sim/streams/model_rows_empty_bank0.bin  ROWS bank 0 = 32 zero rows (the sim's swap/tear test)
  (fpga/sim/streams/s*.bin are the BL616 firmware's recordings: firmware-tango tango/test)
  fpga/sim/golden/overlay_cores_console_f42.png  Cores page over test_pattern(42)
  fpga/sim/golden/overlay_empty_f43.png           empty panel (no rows) over test_pattern(43)
  (fpga/sim/golden/overlay_cores_console_f40.png is export_hw.py's)
Usage: python3 stream_hw.py
"""
import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import export_hw as E
import zosd as Z
import pages as P
import backgrounds as B

ROOT = E.ROOT
SDIR = os.path.join(ROOT, 'fpga', 'sim', 'streams')
T_OSD = 2
ENABLE, CAPS, GEOM, PAL, ATLAS, GLYPHS, ROWS, SWAP, STATUS = 0x01, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17
CAPS_LEN = 13
ATLAS_CHUNK = 128          # columns per ATLAS transfer (any split works)
GLYPH_CHUNK = 64           # entries per GLYPHS transfer
PAGE_BANK = 1              # reset shows bank 0, so the first page goes to bank 1

def be(v, n): return list(v.to_bytes(n, 'big'))

def page_records(T, font):
    recs = []
    recs.append([T_OSD, CAPS, 0] + [0] * CAPS_LEN)
    recs.append([T_OSD, STATUS, 0, 0])
    pal = list(T['pal']) + [T['K']]
    recs.append([T_OSD, PAL, 0, len(pal)] + [c for rgb in pal for c in rgb])
    recs.append([T_OSD, GEOM] + be(E.X0, 2) + be(E.Y0, 2) + be(T['PW'], 2) + be(T['PH'], 2)
                + [T['SW'], T['RH'], T['TOP'], T['SH']])
    bpc = 2 * T['SH'] // 8
    at = T['atlas']
    for c0 in range(0, len(at), ATLAS_CHUNK):
        r = [T_OSD, ATLAS] + be(c0, 2)
        for w in at[c0:c0 + ATLAS_CHUNK]: r += be(w, bpc)
        recs.append(r)
    gl = T['glyphs']
    for g0 in range(0, len(gl), GLYPH_CHUNK):
        r = [T_OSD, GLYPHS, PAGE_BANK] + be(g0, 2)
        for w in gl[g0:g0 + GLYPH_CHUNK]: r += be(w, 4)
        recs.append(r)
    rows = T['rows']
    r = [T_OSD, ROWS, PAGE_BANK, 0]
    for i in range(32): r += be(rows[2 * i + 1], 4) + be(rows[2 * i], 4)
    recs.append(r)
    recs.append([T_OSD, SWAP, PAGE_BANK])
    recs.append([T_OSD, ENABLE, 1])
    return recs

def write_stream(path, recs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        for r in recs:
            assert all(0 <= b < 256 for b in r) and len(r) < 65536
            f.write(struct.pack('<H', len(r)) + bytes(r))
    print(f'wrote {path}: {len(recs)} transfers, {sum(len(r) for r in recs)} bytes')

def main():
    font = Z.Font(*P.FONTS['saira'])
    img40, bg40, got = E.model_render(font)
    m = got['menu']
    T = build = E.build_tables(font, m, got['panel'], got['acc'])
    # the tables re-render the model's page (export_hw.py's proof, repeated here)
    hw = E.table_render(bg40, T, E.X0, E.Y0)
    assert list(hw.getdata()) == list(img40.getdata()), 'tables != model at frame 40'
    write_stream(os.path.join(SDIR, 'model_cores_console.bin'), page_records(T, font))
    write_stream(os.path.join(SDIR, 'model_rows_empty_bank0.bin'), [[T_OSD, ROWS, 0, 0] + [0] * (32 * 8)])
    # goldens for the swap test: frame 42 still the page (SWAP sent mid-frame 42), 43 empty
    save_f = E.FRAME
    try:
        E.FRAME = 42
        img42, bg42, _ = E.model_render(font)
    finally:
        E.FRAME = save_f
    t42 = E.table_render(bg42, T, E.X0, E.Y0)
    assert list(t42.getdata()) == list(img42.getdata()), 'tables != model at frame 42'
    Te = dict(T); Te['rows'] = [0] * 64
    t43 = E.table_render(B.test_pattern(frame=43), Te, E.X0, E.Y0)
    os.makedirs(E.GOLD, exist_ok=True)
    img42.save(os.path.join(E.GOLD, 'overlay_cores_console_f42.png'))
    t43.save(os.path.join(E.GOLD, 'overlay_empty_f43.png'))
    print('wrote goldens overlay_cores_console_f42.png, overlay_empty_f43.png in', E.GOLD)

if __name__ == '__main__':
    main()
