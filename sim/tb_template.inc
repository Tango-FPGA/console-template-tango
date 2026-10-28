// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
// tb_template.inc -- the Template core's session for sim/tb_template.cpp (mode=template), included there.
// The BL616 side as the firmware does it, on the async-clock bench:
//   0  SYS STATUS 5C 42; IRQ_CTRL/IRQ_SRC; READ_CFG (dumped to <outdir>/conf_str.txt, checked by the run
//      script against the CONF_STR in rtl/tango_core_template.v); GET_MENUMASK = 00 00; GET_DB9 arms
//   1  the OSD page stream (tools/template_page.py) -> STATUS until the swap is done
//   2  frame 6: shown (golden: the picture + the page); ENABLE 0 sent mid-frame -> gone from frame 7
//   3  vblank after frame 7: SET_STATUS: Aspect ratio Full Screen (the framework's O[127:126], sys/tango_video_opts.vh),
//      TV Mode PAL, Noise Red, Option 1-1 On
//   4  GET_MENUMASK = 00 01 (status_menumask = status[5], Template.sv 99)
//   5  frame 10: F1 download (index 1, 300 bytes) exactly as sdc.c does it: SELECT, STATUS/WRITE chunks of the
//      space offered, SELECT size 0; the SDC interrupt (pending bit 3) must be up while it is open
//   7  the DS4 on USB-A2 holds the d-pad right+down for 8 frames (the square moves); meanwhile circle (A, the
//      power-up pad map) is pressed for 2 frames: ASCAL builds step to the next test pattern (Pixel grid,
//      frame 21); with the d-pad's release cross (B) is pressed for 2 frames: back to Gradient (frame 26)
//   9  vblank after frame 26: the OSD's Pattern = 1 (status[44:41]) and Source size = 3, 384x224 (status[47:45]):
//      ASCAL builds jump to Pixel grid and re-time their native frame without a reset (frames 30, 32);
//      vblank after frame 27: status[0] = 1 (T[0] Reset), after frame 28: 0 again (the wave restarts) -- both
//      words keep Pattern and Source size, as the firmware sends the whole option word.
//      Bare builds ignore A, B, Pattern and Source size: their goldens do not depend on them.
// Every frame end the core's option word and joystick_0 are recorded (<outdir>/template_run.json); the
// goldens are tools/template_golden.py's from that record.
#define TPL_CAPTURE std::vector<int>{6, 9, 13, 21, 26, 30, 32}
static int tpl_dl_frame = -1, tpl_press_frame = -1, tpl_dl_q = 0, tpl_ab = 0, tpl_pat_sent = 0;
static std::vector<uint8_t> tpl_file;
static size_t tpl_sent = 0;
static std::string tpl_conf;
// byte 15 of every option word below: the framework's Aspect ratio O[127:126] (sys/tango_video_opts.vh
// TANGO_VO_B_ASPECT) = 1, Full Screen -- bit 126 = byte 15 bit 6.  (Before the framework's entries: the Template's own
// O[122:121] = 1, byte 15 bit 1.)  Scale O[125:124] and Scanlines O[123:122] stay 0: Normal, None.
static const uint8_t TPL_B15_FULL = 0x40;
static std::vector<uint8_t> status_word(uint8_t b0, uint8_t b15, uint8_t b5 = 0) {
    std::vector<uint8_t> x = {0, 0x10, 0};
    for (int k = 0; k < 16; k++) x.push_back(k == 0 ? b0 : k == 15 ? b15 : k == 5 ? b5 : 0);
    return x;
}
static void tpl_dl_next() {      // one sdc.c round: IMAGE STATUS, then a WRITE of what was offered
    xfer({3, 8, 0, 1, 0, 0, 0}, [](Xfer &x) {
        int open = x.rx[4] & 0x80, offer = (x.rx[5] << 8) | x.rx[6];
        if (!open) { CHECK(false, "IMAGE STATUS: download not open (%02X)", x.rx[4]); waiting = false; step = 6; return; }
        if (tpl_sent == tpl_file.size()) {
            xfer({3, 8, 1, 1, 0, 0, 0, 0}, [](Xfer &) { printf("      download closed (SELECT size 0)\n"); waiting = false; step = 6; });
            return;
        }
        size_t n = std::min((size_t)offer, tpl_file.size() - tpl_sent);
        std::vector<uint8_t> w = {3, 8, 2, 1};
        w.insert(w.end(), tpl_file.begin() + tpl_sent, tpl_file.begin() + tpl_sent + n);
        tpl_sent += n;
        printf("      IMAGE STATUS offered %d, WRITE %zu (%zu/%zu)\n", offer, n, tpl_sent, tpl_file.size());
        xfer(w, [](Xfer &) { tpl_dl_next(); });
    });
}
static void tpl_clock() {        // every clk_pix edge (tb_menu.cpp pix_after_posedge)
    if (tpl_dl_q && !t->core_dl && tpl_dl_frame < 0) { tpl_dl_frame = frame; printf("      ioctl_download fell in frame %d line %d\n", frame, cy); }
    tpl_dl_q = t->core_dl;
}
static void script_template() {
    switch (step) {
    case 0: {
        if (now < 50000000) return;
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &x) {
            CHECK(x.rx[3] == 0x5C && x.rx[4] == 0x42, "SYS STATUS -> %s", hex(x.rx, 3, 4).c_str()); });
        xfer({0, 5, 0xFF, 0}, nullptr);
        xfer({0, 6, 0, 0}, nullptr);
        std::vector<uint8_t> c = {0, 8, 0}; c.resize(3 + 1200, 0);
        xfer(c, [](Xfer &x) {
            for (size_t i = 3; i < x.rx.size() && x.rx[i]; i++) tpl_conf += char(x.rx[i]);
            FILE *f = fopen((outdir + "/conf_str.txt").c_str(), "wb"); fwrite(tpl_conf.data(), 1, tpl_conf.size(), f); fclose(f);
            printf("      READ_CFG: %zu bytes, \"%.40s...\"\n", tpl_conf.size(), tpl_conf.c_str()); });
        xfer({0, 0x11, 0, 0, 0}, [](Xfer &x) {
            CHECK(x.rx[3] == 0 && x.rx[4] == 0, "GET_MENUMASK -> %s(want 00 00)", hex(x.rx, 3, 2).c_str()); });
        xfer({1, 4, 0, 0, 0, 0}, nullptr);
        play_stream(page);
        step = 1; return; }
    case 1:
        if (!xq.empty()) return;
        waiting = true;
        xfer({2, 0x17, 0, 0}, [](Xfer &x) {
            waiting = false;
            if ((x.rx[3] & 2) == 0) { printf("ok:   OSD page shown (STATUS %02X) at frame %d\n", x.rx[3], frame); step = 2; }
        });
        return;
    case 2:
        if (frame < 6 || cy < 360) return;
        CHECK(frame == 6 && t->osd_shown, "the OSD is shown in frame 6 (frame %d, shown %d)", frame, t->osd_shown);
        xfer({2, 0x01, 0}); step = 3; return;
    case 3:
        if (frame < 7 || cy < 722) return;
        CHECK(frame == 7, "options sent in the vertical blank after frame 7 (frame %d)", frame);
        // O[127:126] = 1 Full Screen (byte 15 bit 6), O[2] PAL, O[4:3] = 1 Red, O[5] Option 1-1 On
        xfer(status_word(0x2C, TPL_B15_FULL)); step = 4; return;
    case 4:
        if (frame < 8) return;
        waiting = true;
        xfer({0, 0x11, 0, 0, 0}, [](Xfer &x) {
            waiting = false;
            CHECK(x.rx[3] == 0 && x.rx[4] == 1, "GET_MENUMASK -> %s(want 00 01: Option 1-1 On)", hex(x.rx, 3, 2).c_str());
            step = 5; });
        return;
    case 5: {
        if (frame < 10 || cy < 100) return;
        tpl_file.resize(300);
        for (size_t i = 0; i < tpl_file.size(); i++) tpl_file[i] = (uint8_t)(i * 37 + 11);
        FILE *f = fopen((outdir + "/template_file.bin").c_str(), "wb"); fwrite(tpl_file.data(), 1, tpl_file.size(), f); fclose(f);
        waiting = true;
        xfer({3, 8, 1, 1, 0, 0, 0x01, 0x2C}, [](Xfer &) {                      // SELECT index 1, 300 bytes
            printf("      SELECT index 1, 300 bytes (frame %d)\n", frame); });
        xfer({0, 5, 0x00, 0}, [](Xfer &x) {                                     // IRQ_CTRL, no ack
            CHECK(x.rx[3] & 0x08, "SDC interrupt pending while the download is open (%02X)", x.rx[3]);
            CHECK(t->spi_irq_n == 0, "IRQn low"); });
        xfer({3, 1, 0, 0, 0, 0, 0, 0}, [](Xfer &x) {                            // SDC STATUS: no sector request
            CHECK(x.rx[3] == 0, "SDC STATUS request byte 00 (%02X)", x.rx[3]); tpl_dl_next(); });
        step = 6; return; }                     // (script() waits while the chain runs: waiting)
    case 6:
        if (tpl_dl_frame < 0) return;
        // the SDC interrupt is gone (pending bit3; HID bit1 may be up from the pad's connect
        // (the firmware's Define buttons), and is not this check's business)
        waiting = true;
        xfer({0, 5, 0x00, 0}, [](Xfer &x) { waiting = false;
            CHECK((x.rx[3] & 0x08) == 0, "SDC interrupt gone once the download is closed (pending %02X)", x.rx[3]); });
        step = 7; return;
    case 7:
        if (dev.enum_at_frame < 0 || frame < 14) return;
        dev.r5_ovr = 0x03; dev.r6_ovr = 0x00; tpl_press_frame = frame;          // hat SE: right + down
        printf("      [usb] d-pad right+down from frame %d\n", frame);
        step = 8; return;
    case 8:
        // report byte 5 = {triangle, circle, cross, square, hat}: circle = A, cross = B (tango_link.v default_padmap)
        if (tpl_ab == 0 && frame >= tpl_press_frame + 1) {
            dev.r5_ovr = 0x43; tpl_ab = 1; printf("      [usb] + circle (A) at frame %d\n", frame); }
        if (tpl_ab == 1 && frame >= tpl_press_frame + 3) {
            dev.r5_ovr = 0x03; tpl_ab = 2; printf("      [usb] circle (A) released at frame %d\n", frame); }
        if (frame < tpl_press_frame + 8) return;
        dev.r5_ovr = 0x28; tpl_ab = 3; printf("      [usb] released at frame %d; cross (B) pressed\n", frame);
        step = 9; return;
    case 9:
        if (tpl_ab == 3 && frame >= tpl_press_frame + 10) {
            dev.r5_ovr = 0x08; tpl_ab = 4; printf("      [usb] cross (B) released at frame %d\n", frame); }
        if (!tpl_pat_sent && frame >= 26 && cy >= 722) {
            CHECK(frame == 26, "Pattern sent in the vertical blank after frame 26 (frame %d)", frame);
            xfer(status_word(0x2C, TPL_B15_FULL, 0x62)); tpl_pat_sent = 1;   // + O[44:41] = 1 (byte 5 bit 1), O[47:45] = 3 (bits 5-6)
        }
        if (frame < 27 || cy < 722) return;
        CHECK(frame == 27, "reset sent in the vertical blank after frame 27 (frame %d)", frame);
        xfer(status_word(0x2D, TPL_B15_FULL, 0x62)); step = 10; return;
    case 10:
        if (frame < 28 || cy < 722) return;
        xfer(status_word(0x2C, TPL_B15_FULL, 0x62)); step = 11; return;
    case 11:
        if (frame < 33) return;                 // the run ends 20 us into frame 33: frame 32 is the last captured
        step = 12; return;
    default: return;
    }
}
static void template_finish() {
    FILE *f = fopen((outdir + "/template_run.json").c_str(), "w");
    std::string cap;
    for (int k : TPL_CAPTURE) cap += (cap.empty() ? "" : ", ") + std::to_string(k);
    fprintf(f, "{\n \"capture\": [%s],\n \"osd_frames\": [6],\n \"dl_frame\": %d,\n", cap.c_str(), tpl_dl_frame);
    fprintf(f, " \"file\": \"%s/template_file.bin\",\n \"frames\": [\n", outdir.c_str());
    for (size_t k = 0; k < frame_rec.size(); k++)
        fprintf(f, "  {\"status\": \"%s\", \"joy\": %u}%s\n", frame_rec[k].status.c_str(), frame_rec[k].joy,
                k + 1 < frame_rec.size() ? "," : "");
    fprintf(f, " ]\n}\n"); fclose(f);
    printf("     template: %zu frame records, download fell in frame %d, d-pad from frame %d\n",
           frame_rec.size(), tpl_dl_frame, tpl_press_frame);
    CHECK(frame_rec.size() >= 33, "a frame-end record for every frame (%zu)", frame_rec.size());
    int na = 0, nb = 0;                      // joystick_0 A (bit 4) and B (bit 5) presses the core saw at frame ends
    for (size_t k = 1; k < frame_rec.size(); k++) {
        na += ((frame_rec[k].joy >> 4) & 1) && !((frame_rec[k - 1].joy >> 4) & 1);
        nb += ((frame_rec[k].joy >> 5) & 1) && !((frame_rec[k - 1].joy >> 5) & 1);
    }
    CHECK(na == 1 && nb == 1, "joystick_0 A pressed once (%d) and B once (%d) at the frame ends", na, nb);
}
