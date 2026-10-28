// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
// tb_template.cpp -- the Template core's sim gate driver (sim/run_tb_template.sh runs it with mode=template).
// Adapted from menu-tango's fpga/sim/tb_menu.cpp (the same authors); changed ONLY:
//   - "Vtb_menu" -> "Vtb_template" (4 places: the Verilated top is sim/tb_template.v);
//   - the other cores' sessions removed: the three lines #include "tb_padmap.inc" / "tb_sd.inc" / (TB_KBD)
//     "tb_kbd.inc" and their dispatch in script(); "mode=" now only recognises "template".  mode_padmap,
//     mode_sd, mode_kbd stay declared (always false) so every other line is tb_menu.cpp's, checks included.
//   - this header.  The session itself is sim/tb_template.inc.  Everything below is tb_menu.cpp, its own header
//     included (paths there are menu-tango's).
//------------------------------------------------------------------------------------------------------------
// tb_menu.cpp -- sim gate for the Tango menu core (fpga/sim/tb_menu.v -> tango_menu_core).
//
// ASYNCHRONOUS CLOCKS (lockstep clocks cannot catch CDC bugs): an event scheduler in
// picoseconds drives four unrelated clocks --
//   clk_pix 74.25 MHz (13468 ps), clk48 (host USB, 20834 ps), clk48d (the simulated
//   USB device's own 48 MHz, 20812 ps = +0.1 %), and the BL616 SPI master's SCK
//   (13.33 MHz nominal, every half period jittered +-JIT ps, random gaps between bytes).
// The SPI master models the BL616 in SPI mode 1: MOSI changes 3 ns after SCK rises,
// the master samples MISO at SCK's falling edge using the value the DUT drove at least
// T_MISO_SU (12 ns: pad + board + BL616 setup) before it.
//
// What it plays: the page stream file (records: u16 little-endian length + bytes, one record = one
// CSN-low transfer; default fpga/sim/streams/model_cores_console.bin, from
// tools/osd-model/stream_hw.py; the BL616 firmware's own recordings use the same format),
// wrapped in a scripted session:
//   1  SYS STATUS         -> 5C 42 00 01  (coldboot 1)          IRQn low (cold boot)
//   2  SYS IRQ_CTRL ff    -> 01, then IRQn high; IRQ_SRC -> 01, again -> 00
//   3  SYS READ_CFG       -> "MENU;" ... NUL
//   4  HID GET_DB9        -> 00 00 (arms the HID interrupt)
//   5  the page stream    (CAPS checked = 5A 4F 01 04 00 18 04 00 20 05 00 02 D0)
//   6  OSD STATUS polled until swap pending clears -> shown bank 1
//   7  USB: the DS4 model enumerates on USB-A2; 5 reports with a BAD CRC and every button
//      pressed are sent first (must be rejected: joy stays 0, no IRQ, bad_crc = 5); then
//      circle+up+options pressed -> IRQn low -> IRQ_CTRL has bit1 -> GET_DB9 = 18 08;
//      released -> IRQ -> GET_DB9 = 00 00
//   8  frame 40 captured (compared with the golden by compare_frames.py)
//   9  ROWS bank 0 := empty; at frame 42 line 360 SWAP 0 is sent mid-frame; STATUS right
//      after -> pending 1, shown 1; frames 42 (must still be the page) and 43 (empty)
//      captured; the shown bank may only ever change on a line >= 720 (vertical blank)
//  10  BL616 JTAG request: bl616_jtagsel high 20 us -> link reset -> STATUS coldboot 1 again
//
// usage: Vtb_template <page.bin[,page2.bin,...]> <rows_empty.bin> <outdir> [sck_half_ps=37500] [jitter_ps=2000] [dev_period_ps]
// (several page streams are played in order; the empty rows go to whichever bank is hidden after frame 40)
#include "Vtb_template.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <deque>
#include <functional>
#include <random>

typedef int64_t ps_t;
static const int FW = 1650, FH = 750, W = 1280, H = 720;
static Vtb_template *t;
static ps_t now = 0;
static int fails = 0;
static std::mt19937_64 rng(12345);
#define CHECK(cond, ...) do { if (!(cond)) { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } \
                              else { printf("ok:   "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------------ clocks
struct Clk { ps_t half_hi, half_lo, next; int v; };
static Clk cpix = {6734, 6734, 1000, 0};
static Clk c48  = {10417, 10417, 1300, 0};
static Clk c48d = {10406, 10406, 1700, 0};

// ------------------------------------------------------------------ beam + capture
static int cx = 0, cy = 0, frame = 0, rst_cnt = 0;
static bool in_reset = true;
static std::vector<unsigned char> img(W * H * 3), img_dbg(W * H * 3);
static std::string outdir;
static std::vector<int> want_frames = {40, 42, 43};
static bool mode_template = false;
static bool mode_padmap = false;
static bool mode_kbd = false;     // mode=kbd: a low-speed boot keyboard on USB-A1 (tb_kbd.inc), built with TB_KBD
static bool mode_sd = false;      // mode=sd: the block device (tb_sd.inc), on the sim-only core tb_sdcore.v  // mode=padmap: Define buttons (tb_padmap.inc), on the Template core
static void tpl_clock();          // mode=template: the Template core's session (tb_template.inc)
struct FrameRec { std::string status; unsigned joy; };
static std::vector<FrameRec> frame_rec;     // what the core saw at the end of every frame
static int bank_changes = 0, bank_bad = 0, shown_changes = 0;
static int last_bank = -1, last_shown = -1;
static void save_ppm(int f) {
    char p[512]; snprintf(p, sizeof p, "%s/menu_f%d.ppm", outdir.c_str(), f);
    FILE *o = fopen(p, "wb"); fprintf(o, "P6\n%d %d\n255\n", W, H);
    fwrite(img.data(), 1, img.size(), o); fclose(o);
    printf("      wrote %s\n", p);
}
static bool capturing(int f) { for (int w : want_frames) if (w == f) return true; return false; }

// MISO history (value after each clk_pix posedge)
struct MisoEv { ps_t t; int v; };
static std::deque<MisoEv> miso_hist;
static int miso_at(ps_t ts) {
    int v = 0;
    for (auto &e : miso_hist) { if (e.t <= ts) v = e.v; else break; }
    return v;
}

static void pix_posedge() {
    // hdmi.sv beam into the DUT for this edge (tb_overlay.cpp convention)
    t->cx = cx; t->cy = cy;
}
static void pix_after_posedge() {
    if (in_reset) {
        if (++rst_cnt == 16) { in_reset = false; t->rst_pix = 0; }
        return;
    }
    if (capturing(frame) && cx < W && cy < H) {
        unsigned v = t->rgb; unsigned char *p = &img[(cy * W + cx) * 3];
        p[0] = v >> 16; p[1] = v >> 8; p[2] = v;
    }
    if (mode_template && t->core_cx == 1649 && t->core_cy == 749) {
        // the core's frame-end cycle: the option word and joystick_0 it uses there (template_model.py)
        char h[40]; std::string st;
        for (int w = 3; w >= 0; w--) { snprintf(h, sizeof h, "%08x", t->core_status[w]); st += h; }
        if ((int)frame_rec.size() == frame) frame_rec.push_back({st, (unsigned)t->core_joy0});
    }
    if (mode_template) tpl_clock();
    if (frame == 41 && cx < W && cy < H) {          // the debug build's picture (tango_link_dbg_view)
        unsigned v = t->rgb_dbg; unsigned char *p = &img_dbg[(cy * W + cx) * 3];
        p[0] = v >> 16; p[1] = v >> 8; p[2] = v;
    }
    // the shown bank may only change in the vertical blank
    int b = t->osd_bank, s = t->osd_shown;
    if (last_bank >= 0 && b != last_bank) {
        bank_changes++;
        // the commit point is the lead beam (1, 720) = hdmi (FW-5, 719): after the last
        // visible pixel of the frame and before any line setup of the next one
        bool ok = cy >= H || (cy == H - 1 && cx >= W);
        if (!ok) bank_bad++;
        printf("      shown bank %d -> %d at frame %d line %d x %d %s\n", last_bank, b, frame, cy, cx, ok ? "(blank)" : "(ACTIVE: TORN)");
    }
    if (last_shown >= 0 && s != last_shown) {
        shown_changes++;
        if (!(cy >= H || (cy == H - 1 && cx >= W))) bank_bad++;
        printf("      shown %d -> %d at frame %d line %d\n", last_shown, s, frame, cy);
    }
    last_bank = b; last_shown = s;
    if (++cx == FW) {
        cx = 0;
        if (++cy == FH) {
            cy = 0;
            if (capturing(frame)) save_ppm(frame);
            if (frame == 41) {
                char p[512]; snprintf(p, sizeof p, "%s/menu_dbg_f41.ppm", outdir.c_str());
                FILE *o = fopen(p, "wb"); fprintf(o, "P6\n%d %d\n255\n", W, H);
                fwrite(img_dbg.data(), 1, img_dbg.size(), o); fclose(o);
                printf("      wrote %s (debug-build picture); link debug rows now:", p);
                for (int r = 0; r < 18; r++) printf(" %02X", (unsigned)((t->dbg_rows_o[(17 - r) / 4] >> (8 * ((17 - r) % 4))) & 0xFF));
                printf("\n");
            }
            frame++;
        }
    }
}

// ------------------------------------------------------------------ SPI master (BL616 model)
// The master's own pins change at its SCK edges; the DUT sees them D_IN later (pad + trace + input
// buffer).  MISO at the master's pin is the DUT's MISO D_OUT earlier (output buffer + trace).  The
// master samples MISO at (its falling edge + SAMPLE_OFF); a MISO transition inside the window
// [sample - T_SU, sample + T_H] makes that bit random (a setup/hold violation).  SAMPLE_OFF = 0 is
// the textbook mode-1 sample at the falling edge; the silicon-failure hunt sweeps it.
static ps_t sck_half = 37500, jit = 2000;
static ps_t D_IN = 0, D_OUT = 0, SAMPLE_OFF = 0, T_SU = 0, T_H = 0;
static long miso_viol = 0;
struct Xfer { std::vector<uint8_t> tx; std::vector<uint8_t> rx; std::function<void(Xfer &)> done; std::string name; };
static std::deque<Xfer> xq;
enum { SP_IDLE, SP_LEAD, SP_HI, SP_LO, SP_TAIL, SP_GAP };
static int sp = SP_IDLE; static ps_t sp_next = 0;
static size_t sp_byte = 0; static int sp_bit = 0;
static uint64_t spi_bytes = 0, spi_xfers = 0;
// DUT-side pin changes (delayed by D_IN)
struct PinEv { ps_t t; int pin; int v; };            // pin 0 CSN, 1 SCK, 2 MOSI
static std::deque<PinEv> pin_q;
static void pin_set(int pin, int v, ps_t extra = 0) { pin_q.push_back({now + D_IN + extra, pin, v}); }
static ps_t pin_next() { return pin_q.empty() ? (1LL << 62) : pin_q.front().t; }
static void pin_apply() {
    while (!pin_q.empty() && pin_q.front().t <= now) {
        PinEv e = pin_q.front(); pin_q.pop_front();
        if (e.pin == 0) t->spi_csn = e.v; else if (e.pin == 1) t->spi_sck = e.v; else t->spi_mosi = e.v;
    }
}
// MISO samples of the current transfer
static std::vector<ps_t> samp_t;                     // sample instants, one per bit
static std::vector<int> samp_v;
static ps_t miso_margin_min = 1LL << 60, miso_lat_max = 0, last_fall_t = -1;
static void resolve_samples() {                       // bits whose sample instant is in the past
    for (size_t i = samp_v.size(); i < samp_t.size(); i++) {
        ps_t ts = samp_t[i];
        if (ts + T_H + D_OUT > now) break;            // not yet decidable
        ps_t tp = ts - D_OUT;                         // the DUT-side instant that reaches the master at ts
        int v = miso_at(tp);
        bool viol = false;
        for (auto &e : miso_hist) if (e.t > tp - T_SU && e.t <= tp + T_H) viol = true;
        if (viol) { miso_viol++; v = rng() & 1; }
        // margin bookkeeping (reply bytes only): time from the last MISO change to the sample
        if (i >= 24) {
            ps_t lc = -1; for (auto &e : miso_hist) if (e.t <= tp) lc = e.t;
            if (lc >= 0 && tp - lc < miso_margin_min) miso_margin_min = tp - lc;
        }
        samp_v.push_back(v);
    }
}
static ps_t jitter() { return (ps_t)(rng() % (2 * jit + 1)) - jit; }
static void spi_event() {
    Xfer &x = xq.front();
    switch (sp) {
    case SP_LEAD:     // CSN is low; first rising edge
    case SP_LO:       // SCK was low -> rise
        if (sp == SP_LO && sp_bit == 8) {           // byte finished
            spi_bytes++; sp_byte++; sp_bit = 0;
            if (sp_byte == x.tx.size()) { sp = SP_TAIL; sp_next = now + 60000 + (rng() % 100000); return; }
            // inter-byte gap: 40 % back to back, else up to 1.5 us (polled bflb_spi_poll_send)
            if (rng() % 10 >= 4) { sp = SP_GAP; sp_next = now + (rng() % 1500000); return; }
        }
        pin_set(1, 1);
        pin_set(2, (x.tx[sp_byte] >> (7 - sp_bit)) & 1, 3000);   // MOSI 3 ns after the rising edge
        sp = SP_HI; sp_next = now + sck_half + jitter();
        return;
    case SP_GAP:
        sp = SP_LO; sp_next = now; return;         // continue as if SCK low elapsed
    case SP_HI:       // falling edge: the master's sample instant is now + SAMPLE_OFF
        pin_set(1, 0);
        samp_t.push_back(now + SAMPLE_OFF);
        last_fall_t = now;
        sp_bit++;
        sp = SP_LO; sp_next = now + sck_half + jitter();
        return;
    case SP_TAIL:     // CSN high, transfer done
        pin_set(0, 1); pin_set(2, 0); spi_xfers++;
        resolve_samples();
        x.rx.assign(x.tx.size(), 0);
        for (size_t i = 0; i < samp_v.size() && i / 8 < x.rx.size(); i++) x.rx[i / 8] = (x.rx[i / 8] << 1) | samp_v[i];
        if (samp_v.size() != samp_t.size()) { printf("TB: unresolved MISO samples (SAMPLE_OFF too large)\n"); fails++; }
        samp_t.clear(); samp_v.clear();
        { Xfer done = x; xq.pop_front(); if (done.done) done.done(done); }
        sp = SP_IDLE; sp_next = now + 2000000;       // 2 us between transfers
        return;
    }
}
static void spi_start_if_idle() {
    if (sp != SP_IDLE || xq.empty() || now < sp_next) return;
    pin_set(0, 0); sp_byte = 0; sp_bit = 0;
    sp = SP_LEAD; sp_next = now + 150000 + (rng() % 200000);
}
static void xfer(std::vector<uint8_t> tx, std::function<void(Xfer &)> done = nullptr, std::string name = "") {
    xq.push_back({tx, {}, done, name});
}
static std::string hex(const std::vector<uint8_t> &v, size_t from, size_t n) {
    std::string s; char b[8];
    for (size_t i = from; i < from + n && i < v.size(); i++) { snprintf(b, sizeof b, "%02X ", v[i]); s += b; }
    return s;
}

// ------------------------------------------------------------------ USB DS4 device model (clk48d)
static uint16_t crc16(const uint8_t *d, int n) {
    uint16_t c = 0xFFFF;
    for (int i = 0; i < n; i++) { c ^= d[i]; for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xA001 : (c >> 1); }
    return ~c;
}
// Device-side USB receiver of the TB model (a real SIE's behaviour, not our host PHY's): runs on
// the wire samples at clk48d, ignores J->K->J excursions shorter than half a bit, finds SYNC by its
// pattern (>= 3 transitions then KK), NRZI-decodes with bit unstuffing, ends a packet on SE0.
struct SieRx {
    int st = 0;            // 0 idle, 1 hunting SYNC, 2 data
    int last = 2;          // line state at the previous bit centre (J)
    int ph = 0, run = 0, zeros = 0, ones = 0, nb = 0; uint8_t sh = 0;
    int kcount = 0, prev = 2, se0 = 0;
    std::vector<uint8_t> pkt; bool done = false;
    void sample(int ln) {  // ln: 2 J, 1 K, 0 SE0
        done = false;
        if (ln == 0) { if (++se0 >= 3 && st == 2) { done = true; st = 0; } if (se0 >= 3) st = 0; prev = ln; return; }
        se0 = 0;
        if (st == 0) {
            if (ln == 1) { if (++kcount >= 2) { st = 1; last = 2; ph = 1; zeros = 0; kcount = 0; pkt.clear(); } }
            else kcount = 0;
            prev = ln; return;
        }
        if (ln != prev) { ph = 0; }                 // transition: resync, sample 2 clocks later
        else if ((ph = (ph + 1) & 3) == 2) {       // then every 4 samples (bit centres)
            int bit = (ln == last) ? 1 : 0; last = ln;
            if (st == 1) {
                if (bit == 0) zeros++;
                else if (zeros >= 3) { st = 2; ones = 1; nb = 0; sh = 0; }
                else { st = 0; }                    // not a SYNC
            } else {
                if (ones == 6) { ones = 0; }        // stuffed zero
                else {
                    ones = bit ? ones + 1 : 0;
                    sh = (sh >> 1) | (bit << 7);
                    if (++nb == 8) { pkt.push_back(sh); nb = 0; }
                }
            }
        }
        prev = ln;
    }
} sie;
static std::deque<int> line_ring;   // (dp<<1|dn) per clk48d posedge, for the first bad packet
static int line_dumped = 0;
static std::deque<int> first_strobe_ring;   // line trace at the first byte of the current packet
static ps_t first_strobe_t = 0;
struct Dev {
    std::vector<uint8_t> rx, txq;
    size_t tx_i = 0; int tx_wait = -1; bool tx_on = false;
    int addr = 0, new_addr = -1; bool cfg = false, cfg_pending = false, setup_seen = false;
    int toggle = 0; bool ep4_sent = false; int bad_left = 0, bad_sent = 0;
    bool pressed = false; int counter = 0; long reports = 0; int bad_pkts = 0;
    int r5_ovr = -1, r6_ovr = -1;      // template gate: report bytes 5/6 as given (e.g. hat SE)
    int r7_ovr = -1;                   // padmap gate: report byte 7 (bit0 PS, bit1 touchpad)
    // GET_DESCRIPTOR(DEVICE): a DualShock 4 v2's device descriptor, VID 054C PID 09CC,
    // bMaxPacketSize0 64 (so all 18 bytes come in one DATA1); the control read ends with OUT DATA1 len 0
    bool desc_pending = false, desc_stall = false, out_seen = false; int desc_reqs = 0, status_outs = 0, stalls = 0, desc_val = 0;
    bool answer_desc = true;           // false: STALL GET_DESCRIPTOR (the host must fall back to VID/PID 0)
    int aborted = 0, aborted_bytes = 0; int was_active = 0;
    // bus timing, measured on the wire at clk48d samples
    int line_prev = 2; ps_t se0_end = -1; ps_t k_start = -1; bool dev_last = false;
    ps_t ipd_host_min = 1LL << 60, ipd_host_max = 0;    // device EOP -> host SOP
    ps_t ipd_dev_min = 1LL << 60, ipd_dev_max = 0;      // host EOP -> device SOP
    int glitches = 0, ack_in_squelch = 0; ps_t dev_tx_end = -1;
    long enum_at_frame = -1;
    void respond(std::vector<uint8_t> p) { txq = p; tx_i = 0; tx_wait = 24; }
    void bad(const char *why) {
        if (line_dumped++ < 2) {
            printf("      [usb dev] line trace at the packet's FIRST byte (%.6f ms; oldest first, J=2 K=1 SE0=0):\n        ", first_strobe_t / 1e9);
            int k = 0; for (int v : first_strobe_ring) { printf("%d", v); if (++k % 100 == 0) printf("\n        "); }
            printf("\n");
        }
        if (bad_pkts++ < 12) {
            printf("      [usb dev] bad packet (%s) frame %d:", why, frame);
            for (size_t i = 0; i < rx.size() && i < 12; i++) printf(" %02X", rx[i]);
            printf(" (%zu bytes)\n", rx.size());
        }
    }
    void handle() {
        if (rx.empty()) return;
        uint8_t pid = rx[0];

        if (((pid >> 4) ^ 0xF) != (pid & 0xF)) { bad("pid"); return; }
        if (pid == 0xA5) return;                                    // SOF
        if (pid == 0x2D || pid == 0x69 || pid == 0xE1) {            // SETUP / IN / OUT token
            if (rx.size() != 3) { bad("token length"); return; }
            int a = rx[1] | (rx[2] << 8); int ad = a & 0x7F, ep = (a >> 7) & 0xF;
            if (ad != addr) return;
            if (pid == 0x2D) { setup_seen = true; return; }
            if (pid == 0xE1) { if (ep == 0) out_seen = true; return; }   // OUT: control-read status stage
            if (pid == 0x69) {
                if (ep == 0 && desc_stall) { respond({0x1E}); stalls++; }   // STALL the data stage
                else if (ep == 0 && desc_pending) {                 // GET_DESCRIPTOR data stage
                    static const uint8_t dd[18] = {0x12, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40, 0x4C, 0x05, 0xCC, 0x09,
                                                   0x00, 0x01, 0x01, 0x02, 0x00, 0x01};
                    // CONFIGURATION (wValue 02xx): its first 18 bytes = the configuration + interface 0
                    // descriptors, HID class 03, subclass 00, protocol 00 (a DS4 v2 is no boot device)
                    static const uint8_t cd[18] = {0x09, 0x02, 0x29, 0x00, 0x01, 0x01, 0x00, 0xC0, 0xFA,
                                                   0x09, 0x04, 0x00, 0x00, 0x02, 0x03, 0x00, 0x00, 0x00};
                    const uint8_t *d = ((desc_val >> 8) == 2) ? cd : dd;
                    std::vector<uint8_t> p = {0x4B};                // DATA1
                    p.insert(p.end(), d, d + 18);
                    uint16_t c = crc16(d, 18); p.push_back(c & 0xFF); p.push_back(c >> 8);
                    respond(p); desc_pending = false;
                } else if (ep == 0) {                               // status stage of a control write
                    respond({0x4B, 0x00, 0x00});                    // DATA1, zero length
                    if (new_addr >= 0) { addr = new_addr; new_addr = -1; }
                    if (cfg_pending) { cfg = true; cfg_pending = false; enum_at_frame = frame;
                                       printf("      [usb] device configured (frame %d)\n", frame); }
                } else if (ep == 4 && cfg) {
                    uint8_t r[64] = {0};
                    r[0] = 0x01; r[1] = r[2] = r[3] = r[4] = 0x80;
                    bool bad = bad_left > 0;
                    r[5] = bad ? 0xF0 : pressed ? (0x40 | 0x0) : 0x08;   // circle + hat up
                    r[6] = bad ? 0xFF : pressed ? 0x20 : 0x00;           // options
                    if (!bad && r5_ovr >= 0) r[5] = r5_ovr;
                    if (!bad && r6_ovr >= 0) r[6] = r6_ovr;
                    r[7] = (counter++ << 2) & 0xFC;
                    if (!bad && r7_ovr >= 0) r[7] = (r[7] & 0xFC) | (r7_ovr & 0x03);   // PS / touchpad
                    std::vector<uint8_t> p = {uint8_t(toggle ? 0x4B : 0xC3)};
                    p.insert(p.end(), r, r + 64);
                    uint16_t c = crc16(r, 64);
                    if (bad) { c ^= 0x0100; bad_left--; bad_sent++; }
                    p.push_back(c & 0xFF); p.push_back(c >> 8);
                    respond(p); ep4_sent = true; reports++;
                }
            }
            return;
        }
        if ((pid == 0xC3 || pid == 0x4B) && setup_seen) {           // SETUP data stage
            setup_seen = false;
            if (rx.size() != 11 || crc16(&rx[1], 8) != (rx[9] | (rx[10] << 8))) { bad("setup data"); return; }
            respond({0xD2});                                        // ACK
            uint8_t req = rx[2]; int val = rx[3] | (rx[4] << 8);
            desc_stall = false;
            if (req == 5) { new_addr = val & 0x7F; printf("      [usb] SET_ADDRESS %d (frame %d)\n", new_addr, frame); }
            if (req == 9) { cfg_pending = true; printf("      [usb] SET_CONFIGURATION %d\n", val); }
            if (req == 6) {
                desc_reqs++; desc_val = val;
                if (answer_desc) { desc_pending = true; printf("      [usb] GET_DESCRIPTOR %04X (frame %d)\n", val, frame); }
                else desc_stall = true;                                   // the data stage will STALL
            }
            return;
        }
        if ((pid == 0xC3 || pid == 0x4B) && out_seen) {                   // status OUT data: ACK
            out_seen = false; status_outs++;
            respond({0xD2});
            return;
        }
        if (pid == 0xD2 && ep4_sent) { toggle ^= 1; ep4_sent = false; return; }  // host ACKed our report
    }
    void before_posedge() {             // inputs for this clk48d edge
        t->dev_tx_start = 0;
        if (tx_wait > 0) { tx_wait--; return; }
        if (tx_wait == 0) {
            tx_wait = -1; tx_on = true; tx_i = 0;
            t->dev_tx_start = 1; t->dev_tx_data = txq[0]; t->dev_tx_valid = 1; t->dev_tx_last = (txq.size() == 1);
        }
    }
    void after_posedge() {
        int ln = (t->line_dp << 1) | t->line_dn;
        if (line_prev == 0 && ln == 2) se0_end = now;                     // SE0 -> J: end of an EOP
        if (line_prev == 2 && ln == 1) k_start = now;                     // J -> K: SOP or glitch
        if (line_prev == 1 && ln == 1 && k_start >= 0 && now - k_start < 30000 && now - k_start > 0) {
            // K held for a second sample: a real start of packet (glitches last one sample)
            if (se0_end >= 0 && se0_end < k_start) {
                ps_t d = k_start - se0_end;
                if (tx_on || t->dev_tx_busy) { if (d < ipd_dev_min) ipd_dev_min = d; if (d > ipd_dev_max) ipd_dev_max = d; }
                else if (dev_last) { if (d < ipd_host_min) ipd_host_min = d; if (d > ipd_host_max) ipd_host_max = d; }
            }
            dev_last = tx_on || t->dev_tx_busy;
            se0_end = -1; k_start = -1;
        }
        if (line_prev == 1 && ln == 2 && k_start >= 0 && now - k_start < 30000) { glitches++; k_start = -1; }   // K shorter than half a bit
        line_prev = ln;
        if (tx_on) dev_tx_end = now;
        line_ring.push_back(ln);
        if (line_ring.size() > 600) line_ring.pop_front();
        if (tx_on && t->dev_tx_rd && tx_i < txq.size()) {
            tx_i++;
            if (tx_i < txq.size()) { t->dev_tx_data = txq[tx_i]; t->dev_tx_valid = 1; t->dev_tx_last = (tx_i == txq.size() - 1); }
            else { t->dev_tx_valid = 0; t->dev_tx_last = 0; tx_on = false; }
        }
        // receive with the TB's own SIE model (never while we drive the bus ourselves)
        if (!t->dev_tx_busy && !tx_on) {
            sie.sample(ln);
            if (sie.pkt.size() == 1 && rx.empty()) { first_strobe_ring = line_ring; first_strobe_t = now; }
            if (sie.done) { rx = sie.pkt; handle(); rx.clear(); sie.pkt.clear(); }
        } else { sie.st = 0; sie.pkt.clear(); sie.prev = ln; }
        // the device PHY's own receiver is not used (it is our host PHY); count its idle-aborts only
        if (was_active && !t->dev_rx_active && !t->dev_rx_eop) aborted++;
        was_active = t->dev_rx_active;
    }
} dev;

// ------------------------------------------------------------------ session script
static std::vector<std::vector<uint8_t>> load_stream(const char *p) {  // records: u16 little-endian length + bytes
    std::vector<std::vector<uint8_t>> r; FILE *f = fopen(p, "rb");
    if (!f) { printf("cannot open %s\n", p); exit(2); }
    for (;;) {
        uint8_t h[2]; if (fread(h, 1, 2, f) != 2) break;
        int n = h[0] | (h[1] << 8); std::vector<uint8_t> v(n);
        if ((int)fread(v.data(), 1, n, f) != n) { printf("truncated %s\n", p); exit(2); }
        r.push_back(v);
    }
    fclose(f); return r;
}
static std::vector<std::vector<uint8_t>> page, empty_rows;
static int step = 0;
static int sweep_n = 0, sweep_seen = 0, sweep_ok = 0, sweep_bad_shown = 0; static bool sweep_done = false;
static bool waiting = false;
static ps_t irq_low_since = -1;
static int status_polls = 0, stream_status_waits = 0, page_bank = -1, tear_bank = -1;
static std::vector<uint8_t> db9_last;
static const uint8_t CAPS_EXP[13] = {0x5A, 0x4F, 0x01, 0x04, 0x00, 0x18, 0x04, 0x00, 0x20, 0x05, 0x00, 0x02, 0xD0};

static void play_stream(const std::vector<std::vector<uint8_t>> &s) {
    for (auto &r : s) {
        if (r.size() >= 2 && r[0] == 2 && r[1] == 0x10) {
            xfer(r, [](Xfer &x) {
                bool ok = x.rx.size() >= 16 && !memcmp(&x.rx[3], CAPS_EXP, 13);
                CHECK(ok, "OSD CAPS -> %s", hex(x.rx, 3, 13).c_str());
            });
        } else if (r.size() >= 4 && r[0] == 2 && r[1] == 0x17) {
            // the firmware polls STATUS until bit1 (swap pending) is 0: so does the TB
            xfer(r, [](Xfer &x) {
                if (x.rx[3] & 2) { stream_status_waits++; xq.push_front({x.tx, {}, x.done, x.name}); }
            });
        } else if (r.size() >= 4 && r[0] == 0 && r[1] == 8) {
            xfer(r, [](Xfer &x) { std::string s; for (size_t i = 3; i < x.rx.size() && x.rx[i]; i++) s += char(x.rx[i]);
                                  CHECK(s.rfind("MENU;", 0) == 0, "SYS READ_CFG (stream) -> \"%s\"", s.c_str()); });
        } else xfer(r);
    }
}

#include "tb_template.inc"
static void script() {
    if (waiting) return;
    if (mode_template) { script_template(); return; }
    if (sweep_n) {                               // SYS STATUS only, as sys_wait4fpga polls it
        if (step == 0 && now >= 50000000) {
            for (int i = 0; i < sweep_n; i++)
                xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &x) {
                    sweep_seen++;
                    if (x.rx[3] == 0x5C && x.rx[4] == 0x42) sweep_ok++;
                    else if (sweep_bad_shown++ < 3) printf("      STATUS read %s\n", hex(x.rx, 3, 4).c_str());
                    if (sweep_seen == sweep_n) sweep_done = true;
                });
            step = 1;
        }
        return;
    }
    switch (step) {
    case 0:
        if (now < 50000000) return;               // 50 us after start
        CHECK(t->spi_irq_n == 0, "IRQn low after reset (cold boot)");
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &x) {
            CHECK(x.rx[3] == 0x5C && x.rx[4] == 0x42 && x.rx[5] == 0x00 && x.rx[6] == 0x01,
                  "SYS STATUS -> %s(want 5C 42 00 01)", hex(x.rx, 3, 4).c_str()); });
        xfer({0, 5, 0xFF, 0}, [](Xfer &x) { CHECK(x.rx[3] == 0x01, "SYS IRQ_CTRL ff -> %02X (want 01)", x.rx[3]); });
        xfer({0, 6, 0, 0}, [](Xfer &x) { CHECK(x.rx[3] == 0x01, "SYS IRQ_SRC -> %02X (want 01 coldboot)", x.rx[3]); });
        xfer({0, 6, 0, 0}, [](Xfer &x) {
            CHECK(x.rx[3] == 0x00, "SYS IRQ_SRC again -> %02X (want 00)", x.rx[3]);
            CHECK(t->spi_irq_n == 1, "IRQn high after the ack"); });
        {
            std::vector<uint8_t> c = {0, 8, 0}; c.resize(3 + 32, 0);
            xfer(c, [](Xfer &x) {
                std::string s; for (size_t i = 3; i < x.rx.size() && x.rx[i]; i++) s += char(x.rx[i]);
                CHECK(s == "MENU;;V,v260928", "SYS READ_CFG -> \"%s\"", s.c_str()); });
        }
        xfer({1, 0, 0, 0, 0}, [](Xfer &x) { CHECK(x.rx[3] == 0x5C && x.rx[4] == 0x42, "HID STATUS -> %s", hex(x.rx, 3, 2).c_str()); });
        xfer({1, 4, 0, 0, 0, 0}, [](Xfer &x) {
            CHECK(x.rx[3] == 0 && x.rx[4] == 0, "HID GET_DB9 (arms) -> %s", hex(x.rx, 3, 3).c_str()); });
        play_stream(page);
        step = 1; return;
    case 1:                                        // poll STATUS until the page is shown
        if (!xq.empty()) return;
        waiting = true;
        xfer({2, 0x17, 0, 0}, [](Xfer &x) {
            waiting = false; status_polls++;
            if ((x.rx[3] & 2) == 0) {
                page_bank = x.rx[3] & 1;
                printf("ok:   OSD STATUS -> %02X (bank %d shown, no swap pending) after %d polls, frame %d line %d; "
                       "stream STATUS polls that saw a pending swap: %d\n", x.rx[3], page_bank, status_polls, frame, cy,
                       stream_status_waits);
                step = 2;
            } else if (status_polls > 20000) { CHECK(false, "OSD STATUS never settled (%02X)", x.rx[3]); step = 2; }
        });
        return;
    case 2:                                        // USB: wait for enumeration, then the bad-CRC burst
        if (dev.enum_at_frame < 0 || dev.reports < 20) return;
        printf("ok:   DS4 model enumerated at frame %ld, %ld reports polled so far\n", dev.enum_at_frame, dev.reports);
        CHECK(t->joy == 0 && (t->joy_flags & 2), "idle pad: joy %04X flags %02X (USB-A2 live)", t->joy, t->joy_flags);
        // the pad's connect raised the HID interrupt (the firmware's Define buttons: on raw or connect change):
        // ack it and re-arm with GET_DB9, as the firmware does on any HID interrupt
        CHECK(t->spi_irq_n == 0, "the pad's connect raised the HID interrupt");
        waiting = true;
        xfer({0, 5, 0xFF, 0}, [](Xfer &x) { CHECK(x.rx[3] & 0x02, "IRQ_CTRL -> %02X (HID bit1: connect)", x.rx[3]); });
        xfer({1, 4, 0, 0, 0, 0}, [](Xfer &) { waiting = false; });
        dev.bad_left = 5; step = 3; return;
    case 3:
        if (dev.bad_left > 0 || dev.reports < 0) return;
        if (irq_low_since < 0) irq_low_since = now;
        if (now - irq_low_since < 20000000000LL) return;   // 20 ms of good idle reports after the bad ones
        irq_low_since = -1;
        CHECK(t->usb2_bad_crc == 5, "bad-CRC reports rejected: host bad_crc = %d (want 5)", t->usb2_bad_crc);
        CHECK(t->joy == 0 && t->spi_irq_n == 1, "no phantom press: joy %04X, IRQn %d", t->joy, t->spi_irq_n);
        dev.pressed = true; printf("      [usb] circle + up + options pressed (frame %d)\n", frame);
        step = 4; return;
    case 4:                                        // IRQ from the press
        if (t->spi_irq_n) return;
        printf("ok:   IRQn low after the press (frame %d line %d)\n", frame, cy);
        waiting = true;
        xfer({0, 5, 0xFF, 0}, [](Xfer &x) { CHECK(x.rx[3] & 0x02, "IRQ_CTRL -> %02X (bit1 HID)", x.rx[3]); });
        xfer({1, 4, 0, 0, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == 0x18 && x.rx[4] == 0x08, "GET_DB9 -> %s(want 18 08: up, A, Start)", hex(x.rx, 3, 3).c_str());
            CHECK(x.rx[5] == 0x02, "GET_DB9 flags -> %02X (want 02: USB-A2 pad live)", x.rx[5]);
            CHECK(t->spi_irq_n == 1, "IRQn high after ack + read");
            dev.pressed = false; printf("      [usb] released (frame %d)\n", frame);
            step = 5; });
        return;
    case 5:
        if (t->spi_irq_n) return;
        printf("ok:   IRQn low after the release\n");
        waiting = true;
        xfer({0, 5, 0xFF, 0}, [](Xfer &x) { CHECK(x.rx[3] & 0x02, "IRQ_CTRL -> %02X (bit1 HID)", x.rx[3]); });
        xfer({1, 4, 0, 0, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == 0 && x.rx[4] == 0, "GET_DB9 -> %s(want 00 00)", hex(x.rx, 3, 3).c_str());
            step = 6; });
        return;
    case 6:                                        // after frame 40: empty rows into the hidden bank
        if (frame < 41) return;
        tear_bank = 1 - t->osd_bank;
        for (auto r : empty_rows) { r[2] = tear_bank; xfer(r); }
        step = 7; return;
    case 7:                                        // SWAP 0 in the middle of frame 42
        if (frame < 42 || cy < 360) return;
        if (frame > 42) { CHECK(false, "missed frame 42 for the mid-frame SWAP"); step = 8; return; }
        waiting = true;
        printf("      SWAP %d sent at frame %d line %d\n", tear_bank, frame, cy);
        xfer({2, 0x16, uint8_t(tear_bank)});
        xfer({2, 0x17, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == (0x02 | (1 - tear_bank)), "OSD STATUS right after a mid-frame SWAP -> %02X (want %02X: pending, old bank still shown) at line %d",
                  x.rx[3], 0x02 | (1 - tear_bank), cy);
            step = 8; });
        return;
    case 8:
        if (frame < 43 || cy < 10) return;
        waiting = true;
        xfer({2, 0x17, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == tear_bank, "OSD STATUS in frame 43 -> %02X (want %02X: the new bank shown)", x.rx[3], tear_bank);
            step = 9; });
        return;
    case 9:                                        // after frame 43: BL616 JTAG request
        if (frame < 44) return;
        t->bl616_jtagsel = 1; irq_low_since = now; step = 10; return;
    case 10:
        if (now - irq_low_since < 20000000) return;
        t->bl616_jtagsel = 0; irq_low_since = now; step = 11; return;
    case 11:
        if (now - irq_low_since < 1000000) return;
        waiting = true;
        CHECK(t->spi_irq_n == 0, "IRQn low again after the JTAG request (SYS cold boot re-raised)");
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == 0x5C && x.rx[4] == 0x42 && x.rx[6] == 0x01, "SYS STATUS after JTAG release -> %s", hex(x.rx, 3, 4).c_str());
            CHECK(t->osd_shown == 1 && t->osd_bank == tear_bank, "overlay state kept across the JTAG request (shown %d bank %d)",
                  t->osd_shown, t->osd_bank);
            step = 12; });
        return;
    default: return;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { printf("usage: %s page.bin rows_empty.bin outdir [sck_half_ps] [jitter_ps]\n", argv[0]); return 2; }
    {   // one or more page streams, comma-separated, played in order (the firmware's s1..s4 build on each other)
        std::string l = argv[1]; size_t p0 = 0;
        for (;;) { size_t c = l.find(',', p0); auto v = load_stream(l.substr(p0, c - p0).c_str());
                   page.insert(page.end(), v.begin(), v.end()); if (c == std::string::npos) break; p0 = c + 1; }
    }
    empty_rows = load_stream(argv[2]); outdir = argv[3];
    if (argc > 4) sck_half = atoll(argv[4]);
    if (argc > 5) jit = atoll(argv[5]);
    if (argc > 6 && !strchr(argv[6], '=')) { c48d.half_hi = c48d.half_lo = atoll(argv[6]) / 2; }   // device clock period (ps)
    for (int i = 4; i < argc; i++) {              // key=value options (ps): din dout off tsu th sweep
        const char *e = strchr(argv[i], '='); if (!e) continue;
        std::string k(argv[i], e - argv[i]); long long v = atoll(e + 1);
        if (k == "din") D_IN = v; else if (k == "dout") D_OUT = v; else if (k == "off") SAMPLE_OFF = v;
        else if (k == "tsu") T_SU = v; else if (k == "th") T_H = v; else if (k == "sweep") sweep_n = (int)v;
        else if (k == "sck") sck_half = v; else if (k == "jit") jit = v;
        else if (k == "mode") { mode_template = !strcmp(e + 1, "template"); }
        else if (k == "nodesc") dev.answer_desc = (v == 0);
    }
    printf("stream %s: %zu transfers; SCK half period %lld ps +- %lld (%.2f MHz)\n", argv[1], page.size(),
           (long long)sck_half, (long long)jit, 1e6 / (2.0 * sck_half));
    t = new Vtb_template;
    t->clk_pix = 0; t->rst_pix = 1; t->cx = 0; t->cy = 0;
    t->clk48 = 0; t->lock48 = 0; t->clk48d = 0; t->dev_rst_n = 0;
    t->spi_csn = 1; t->spi_sck = 0; t->spi_mosi = 0; t->bl616_jtagsel = 0;
    t->dev_tx_start = 0; t->dev_tx_data = 0; t->dev_tx_valid = 0; t->dev_tx_last = 0;
#ifdef TB_KBD
    t->kdev_tx_start = 0; t->kdev_tx_data = 0; t->kdev_tx_valid = 0; t->kdev_tx_last = 0;
#endif
    t->eval();
    const int END_FRAME = mode_template ? 34 : (mode_padmap || mode_sd || mode_kbd) ? 30 : 48;
    if (mode_padmap || mode_sd || mode_kbd) want_frames = {};
    if (mode_template) want_frames = TPL_CAPTURE;
    long evals = 0;
    ps_t end_at = -1; int last_bc = 0;
    while (frame < END_FRAME && (end_at < 0 || now < end_at)) {
        if (step >= ((mode_padmap || mode_sd || mode_kbd) ? 14 : 12) && end_at < 0) end_at = now + 20000000;   // let the DUT see the last CSN rise
        // next event
        ps_t nx = cpix.next;
        if (c48.next < nx) nx = c48.next;
        if (c48d.next < nx) nx = c48d.next;
        if (sp != SP_IDLE && sp_next < nx) nx = sp_next;
        if (pin_next() < nx) nx = pin_next();
        now = nx;
        if (now > 2000000) t->lock48 = 1;
        if (now > 1000000) t->dev_rst_n = 1;
        bool pe = false, de = false;
        if (sp != SP_IDLE && sp_next == now) spi_event();
        pin_apply();
        if (cpix.next == now) { cpix.v ^= 1; t->clk_pix = cpix.v; cpix.next += cpix.v ? cpix.half_hi : cpix.half_lo;
                                if (cpix.v) { pix_posedge(); pe = true; } }
        if (c48.next == now)  { c48.v ^= 1; t->clk48 = c48.v; c48.next += c48.half_hi; }
        if (c48d.next == now) { c48d.v ^= 1; t->clk48d = c48d.v; c48d.next += c48d.half_hi;
                                if (c48d.v) { dev.before_posedge();
#ifdef TB_KBD
                                              kdev.before_posedge();
#endif
                                              de = true; } }
        t->eval(); evals++;
        if (pe) pix_after_posedge();
        if (de) dev.after_posedge();
#ifdef TB_KBD
        if (de) kdev.after_posedge();
#endif
        if (pe || de) t->eval();                    // settle input changes made after the edge
        {   // MISO history at every event (it may change on clk_pix or on SCK edges)
            int m = t->spi_miso;
            if (miso_hist.empty() || miso_hist.back().v != m) {
                miso_hist.push_back({now, m});
                while (miso_hist.size() > 64) miso_hist.pop_front();
            }
        }
        if (!samp_t.empty() && samp_v.size() < samp_t.size()) resolve_samples();
        if (sweep_n && sweep_done) break;
        if (sp == SP_IDLE) { script(); spi_start_if_idle(); }
        if (de && t->usb2_bad_crc != last_bc) {
            last_bc = t->usb2_bad_crc;
            printf("      [usb host] bad_crc -> %d at %.3f ms (device bad-CRC reports sent so far %d)\n", last_bc, now / 1e9, dev.bad_sent);
        }
    }
    if (sweep_n) {
        printf("SWEEP din=%lld dout=%lld off=%lld tsu=%lld th=%lld sck_half=%lld: STATUS 5C 42 read %d/%d, MISO violations %ld\n",
               (long long)D_IN, (long long)D_OUT, (long long)SAMPLE_OFF, (long long)T_SU, (long long)T_H, (long long)sck_half,
               sweep_ok, sweep_seen, miso_viol);
        t->final(); delete t; return sweep_ok == sweep_n ? 0 : 1;
    }
    printf("---- end at frame %d, %.1f ms simulated, %ld evals, %llu SPI transfers / %llu bytes\n", frame, now / 1e9,
           evals, (unsigned long long)spi_xfers, (unsigned long long)spi_bytes);
    printf("     usb: %ld reports polled, %d bad-CRC sent, host bad_crc %d, device-side bad packets %d\n",
           dev.reports, dev.bad_sent, t->usb2_bad_crc, dev.bad_pkts);
    printf("     usb: the device-side usb_fs_phy receiver (unused) idle-aborted %d times\n", dev.aborted);
    printf("     usb wire: DS4-model response gap %.2f..%.2f bit times; host turnaround after a device packet (min) %.2f bit times (USB 2.0 7.1.18.1: >= 2)\n",
           dev.ipd_dev_min / 83333.0, dev.ipd_dev_max / 83333.0, dev.ipd_host_min / 83333.0);
    CHECK(dev.ipd_host_min >= 2 * 83333, "host inter-packet delay >= 2 bit times (%.2f)", dev.ipd_host_min / 83333.0);
    printf("     usb wire: %d sub-half-bit K glitches seen on the bus\n", dev.glitches);
    CHECK(dev.bad_pkts == 0, "every other host packet the device model received was well formed (%d bad)", dev.bad_pkts);
    printf("     link transfers counted by the DUT: %d\n", t->link_xfers);
    printf("     MISO at the master (D_IN %.1f ns, D_OUT %.1f ns, sample at fall %+.1f ns, setup %.1f / hold %.1f ns): "
           "min time from the last MISO change to a reply-bit sample %.1f ns; setup/hold violations %ld\n",
           D_IN / 1000.0, D_OUT / 1000.0, SAMPLE_OFF / 1000.0, T_SU / 1000.0, T_H / 1000.0,
           (miso_margin_min - D_OUT) / 1000.0, miso_viol);
    CHECK(miso_viol == 0, "no MISO setup/hold violation at the master (%ld)", miso_viol);
    CHECK(step >= ((mode_padmap || mode_sd || mode_kbd) ? 14 : 12), "session script completed (step %d)", step);
    if (!mode_padmap && !mode_sd && !mode_kbd)
    CHECK(bank_bad == 0 && bank_changes >= (mode_template ? 1 : 2), "shown bank/enable changed %d/%d times, all in vertical blank (%d not)",
          bank_changes, shown_changes, bank_bad);
    if (mode_template) template_finish();
    CHECK((long long)t->link_xfers == (long long)(spi_xfers & 0xFFFF), "DUT counted %d transfers, master sent %llu",
          t->link_xfers, (unsigned long long)spi_xfers);
    printf("%s: %d check(s) failed\n", fails ? "TB FAIL" : "TB PASS", fails);
    t->final(); delete t;
    return fails ? 1 : 0;
}
