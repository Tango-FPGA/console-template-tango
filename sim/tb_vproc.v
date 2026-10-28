// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_vproc -- MiSTer's video and audio processing (sys-tango README, TANGO_VIDEO_PROC) on the Template
// core: tango_sys with the REAL ascal (GHDL netlist, sys/ascal_ghdl/) and the real tango_sdram on the W9825G6KH model,
// as tb_ascal_sys.v, plus a BL616 SPI master that plays link transfers into tango_link, asynchronous to clk_pix.
//   +stream=<file>      transfers to play (link-stream format: u16 little-endian length, then the bytes; made by
//                       sys/build_tools/vproc_preset.py --stream or by the firmware's host tests); started at
//                       +spi_at_us=<n> (default 5).  Replies (MISO byte 3) of SYS 2B / 32 / 39 / 3E are printed.
//                       A length of 0xFFFF is a wait: u32 little-endian microseconds follow (the
//                       firmware's host tests: the in-core OSD's Audio filter sequences).
//   +status=<hex>       the option word, set 2 us in (tb_ascal_sys.v)
//   +nframes=<n>        output frames to run (default NFRAMES_DEF); frames FIRST_DUMP.. land in out_f<N>.ppm
//   +alog=<file>        audio log (text, one record per line: tag, two 16-bit hex values; below) for
//                       sys/build_tools/iir_model.py
//   +audio_only=<ms>    no frame dumps; stop after <ms> of simulated time
//   +first_dump=<n>     the first frame dumped (default 2)
//   +fill_sdram=<hex>   every 16-bit word of the SDRAM model set to <hex> at time 0 (the board's SDRAM is not zero at
//                       power-up: what ascal reads from a buffer no frame has been written to)
// Per frame the bench prints the non-black pixels and "picture=<n>": the clocks of the frame with tango_video's de_out
// high (the whole 1280x720 once a picture shows; 0 = black from tango_video, the OSD aside).  tango_video's beam leads
// this bench's frame boundary by a few clocks, so the frame before the first picture counts its first ~14 clocks.
// A core that sends no picture: build the bench with VPROC_CORE=sim/tango_core_novideo.v (sim/run_tb_vproc.sh).
// SPI master (the BL616 in SPI mode 1, as fpga/sim/tb_menu.cpp of menu-tango): SCK half period 37.5 ns +- 2 ns,
// MOSI changes 3 ns after each rising edge, MISO sampled at each falling edge, 0-1.5 us between bytes.
//==============================================================================
`default_nettype none
`timescale 1ps/1ps
module tb_vproc;
    localparam integer FW = 1650, FH = 750, OW = 1280, OH = 720;
`ifdef NFRAMES_DEF
    localparam integer NFRAMES_D = `NFRAMES_DEF;
`else
    localparam integer NFRAMES_D = 6;
`endif
    integer FIRST_DUMP = 2;
    integer NFRAMES = NFRAMES_D;
    integer audio_ms = 0;

    reg clk_pix = 1'b0, clk_sdram = 1'b0, clk50 = 1'b0, clk48 = 1'b0;
    always #6734  clk_pix   = ~clk_pix;      // 74.25 MHz (13.468 ns)
    always #5208  clk_sdram = ~clk_sdram;    // 96 MHz
    always #10000 clk50     = ~clk50;
    always #10417 clk48     = ~clk48;

`ifdef TANGO_VIDEO_DDR3
    // TANGO_VIDEO_DDR3 (sys-tango sim/ddr3_gates/template_vproc_ddr3.py): the DDR3 IP model on tango_sys's DDR3 ports
`include "tango_ddr3_silicon.vh"
    reg clk_ddr = 1'b0;
    initial begin #3217; forever #5000 clk_ddr = ~clk_ddr; end       // 100 MHz, its own phase
    wire         ddr_calib, ddr_cmd_ready, ddr_cmd_en, ddr_wr_data_rdy, ddr_wr_data_en, ddr_rd_data_valid;
    wire [2:0]   ddr_cmd;
    wire [28:0]  ddr_addr;
    wire [255:0] ddr_wr_data, ddr_rd_data;
    wire [31:0]  ddr_wr_data_mask, ddr_n_refresh, ddr_n_rowmiss, ddr_n_bad_cmd;
    reg          ddr_rst_n = 1'b0;
    initial #200000 ddr_rst_n = 1'b1;
    tango_ddr3_model #(.MEM_LOG2(20), .INIT_CLKS(1000), .CMD_DEPTH(SIL_CMD_DEPTH), .WDATA_DEPTH(SIL_WDATA_DEPTH),
                       .RD_LAT(SIL_RD_LAT), .RD_JITTER(SIL_RD_JITTER), .T_BL(1), .T_ROWMISS(SIL_T_ROWMISS),
                       .T_TURN(SIL_T_TURN), .REF_PERIOD(SIL_REF_PERIOD), .REF_LEN(SIL_REF_LEN)) u_ddr (
        .clk(clk_ddr), .rst_n(ddr_rst_n), .init_calib_complete(ddr_calib),
        .cmd(ddr_cmd), .cmd_en(ddr_cmd_en), .addr(ddr_addr), .cmd_ready(ddr_cmd_ready),
        .wr_data(ddr_wr_data), .wr_data_en(ddr_wr_data_en), .wr_data_end(ddr_wr_data_en),
        .wr_data_mask(ddr_wr_data_mask), .wr_data_rdy(ddr_wr_data_rdy), .rd_data(ddr_rd_data),
        .rd_data_valid(ddr_rd_data_valid), .rd_data_end(), .force_stall(1'b0), .ref_burst(1'b0),
        .fault_en(1'b0), .fault_word(25'd0), .fault_xor(256'd0),
        .n_refresh(ddr_n_refresh), .n_rowmiss(ddr_n_rowmiss), .n_bad_cmd(ddr_n_bad_cmd));
`endif

    reg [6:0] rcnt = 7'd0;
    wire rst_pix = (rcnt != 7'd64);
    always @(posedge clk_pix) if (rst_pix) rcnt <= rcnt + 7'd1;

    reg [11:0] cx = 12'd0;  reg [10:0] cy = 11'd0;
`ifdef TANGO_VSYNC_ADJUST
    // sys-tango's native-rate video (its README, "Native-rate video (vsync_adjust)"): the beam is hdmi.sv's with
    // runtime totals -- the next frame's (tango_vsync, vt_nxt_*) taken in reset and at the wrap, the current frame's
    // (bw / bh) given back to tango_sys as hdmi.sv's frame_width / frame_height.  The frame capture below assumes
    // FW x FH: a raster change is reported (the gates run TANGO_VSYNC_DEFAULT=0 with no SYS 0x70: none expected).
    wire [11:0] vt_nxt_w;  wire [10:0] vt_nxt_h;
    reg  [11:0] bw = FW;   reg  [10:0] bh = FH;
    always @(posedge clk_pix) begin
        if (rst_pix) begin cx <= 12'd0; cy <= 11'd0; bw <= vt_nxt_w; bh <= vt_nxt_h; end
        else if (cx == bw - 12'd1) begin
            cx <= 12'd0;
            if (cy == bh - 11'd1) begin
                cy <= 11'd0;  bw <= vt_nxt_w;  bh <= vt_nxt_h;
                if (vt_nxt_w != FW || vt_nxt_h != FH)
                    $display("tb: RASTER %0d x %0d (not %0d x %0d: the frame capture assumes FW x FH)", vt_nxt_w, vt_nxt_h, FW, FH);
            end else cy <= cy + 11'd1;
        end else cx <= cx + 12'd1;
    end
`else
    always @(posedge clk_pix) begin
        if (rst_pix) begin cx <= 12'd0; cy <= 11'd0; end
        else if (cx == FW - 1) begin cx <= 12'd0; cy <= (cy == FH - 1) ? 11'd0 : cy + 11'd1; end
        else cx <= cx + 12'd1;
    end
`endif

    wire [23:0] rgb;
    wire [15:0] audio_l, audio_r;
    wire usb1_dp, usb1_dn, usb2_dp, usb2_dn;
    pulldown (usb1_dp); pulldown (usb1_dn); pulldown (usb2_dp); pulldown (usb2_dn);
    wire [12:0] SDRAM_A;  wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE;
    wire [15:0] SDRAM_DQ, dq_mem;  wire dq_mem_oe, uart_tx;
`ifndef DQ_DELAY_PS
`define DQ_DELAY_PS 12000
`endif
    reg  [15:0] dq_mem_d = 16'd0;  reg dq_mem_oe_d = 1'b0;
    always @(dq_mem or dq_mem_oe) begin
        dq_mem_d    <= #(`DQ_DELAY_PS) dq_mem;
        dq_mem_oe_d <= #(`DQ_DELAY_PS) dq_mem_oe;
    end
    assign SDRAM_DQ = dq_mem_oe_d ? dq_mem_d : 16'bz;

    reg [127:0] tb_status = 128'd0;
    initial if ($value$plusargs("status=%h", tb_status)) begin
        #2000000;
        $display("tb: option word set to %032x", tb_status);
        dut.u_link.status = tb_status;
        dut.u_link.status_tog = ~dut.u_link.status_tog;
    end

    // ---- +fill_sdram=<hex>: the SDRAM model's power-up contents (header)
    reg [15:0] fill_w = 16'd0;  integer fi;
`ifndef TANGO_VIDEO_DDR3
    initial if ($value$plusargs("fill_sdram=%h", fill_w)) begin
        for (fi = 0; fi < (1 << 24); fi = fi + 1) u_mem.mem[fi] = fill_w;
        $display("tb: +fill_sdram: every SDRAM word = %04x", fill_w);
    end
`else
    // TANGO_VIDEO_DDR3: +fill_sdram=<hex> fills the DDR3 model's memory with the 16-bit word repeated (the board's DDR3 is
    // not zero at power-up either: what ascal reads from a buffer no frame has been written to)
    initial if ($value$plusargs("fill_sdram=%h", fill_w)) begin
        #1;   // after the model's own power-up zeroing (its initial block)
        for (fi = 0; fi < (1 << 20); fi = fi + 1) u_ddr.mem[fi] = {16{fill_w}};
        $display("tb: +fill_sdram: every DDR3 model word = %04x x 16", fill_w);
    end
`endif

    // ---- the SPI master
    reg spi_csn = 1'b1, spi_sck = 1'b0, spi_mosi = 1'b0;
    wire spi_miso;
    integer sfd = 0, at_us = 5, nrec = 0, nbytes = 0, rlen, ri, c0, c1, jit, jit2, gap;
    reg [31:0] wait_us = 32'd0;
    reg [7:0] tx [0:8191];
    reg [7:0] rx_b;
    reg [8*256-1:0] sname;
    task automatic spi_byte(input [7:0] b, output [7:0] r);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                jit = 35500 + ($urandom % 4001);  jit2 = 32500 + ($urandom % 4001);
                #(jit) spi_sck = 1'b1;                     // rising edge: the slave launches MISO
                #3000 spi_mosi = b[k];                     // MOSI 3 ns after the rising edge
                #(jit2) spi_sck = 1'b0;                    // falling edge: both sample
                r[k] = spi_miso;
            end
        end
    endtask
    initial begin
        if ($value$plusargs("stream=%s", sname)) begin
            void'($value$plusargs("spi_at_us=%d", at_us));
            sfd = $fopen(sname, "rb");
            if (sfd == 0) begin $display("tb: cannot open stream %0s", sname); $fatal(1, "no stream"); end
            #(at_us * 1000000);
            forever begin
                c0 = $fgetc(sfd); c1 = $fgetc(sfd);
                if (c0 < 0 || c1 < 0) break;
                rlen = c0 | (c1 << 8);
                if (rlen == 16'hFFFF) begin                 // a wait record: u32 little-endian microseconds
                    wait_us = $fgetc(sfd); wait_us = wait_us | ($fgetc(sfd) << 8);
                    wait_us = wait_us | ($fgetc(sfd) << 16); wait_us = wait_us | ($fgetc(sfd) << 24);
                    $display("tb: %0t wait %0d us", $time, wait_us);
                    #(wait_us * 64'd1000000);
                    continue;
                end
                for (ri = 0; ri < rlen; ri = ri + 1) tx[ri] = $fgetc(sfd);
                if (rlen >= 3 && tx[0] == 8'h00 && tx[1] == 8'h39)
                    $display("tb: %0t transfer %0d: SYS 39 (SET_AFILTER), %0d bytes", $time, nrec, rlen);
                spi_csn = 1'b0;
                #50000;
                for (ri = 0; ri < rlen; ri = ri + 1) begin
                    spi_byte(tx[ri], rx_b);
                    if (ri == 3 && tx[0] == 8'h00 && (tx[1] == 8'h2B || tx[1] == 8'h32 || tx[1] == 8'h39 || tx[1] == 8'h3E))
                        $display("tb: %0t SYS %02x reply byte 3 = %02x", $time, tx[1], rx_b);
                    gap = $urandom % 10;
                    if (gap >= 4) begin gap = $urandom % 1500001; #(gap); end
                end
                #40000 spi_csn = 1'b1;
                #2000000;                                   // the firmware's gap between transfers (>= 2 us)
                nrec = nrec + 1; nbytes = nbytes + rlen;
            end
            $display("tb: stream done: %0d transfers, %0d bytes, at %0t", nrec, nbytes, $time);
        end
    end

    tango_sys #(.USB_DEBOUNCE(960_000)) dut (
        .clk50(clk50), .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .audio_l(audio_l), .audio_r(audio_r), .clk48(clk48), .lock48(1'b1),
        .usb1_dp(usb1_dp), .usb1_dn(usb1_dn), .usb2_dp(usb2_dp), .usb2_dn(usb2_dn),
        .spi_csn(spi_csn), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_miso_pad(spi_miso),
        .spi_irq_n(), .bl616_jtagsel(1'b0), .jtagsel_n_q(1'b1),
        .osd_shown(), .osd_bank(), .osd_swap_pending(), .joy(), .joy_flags(), .link_xfers(),
        .usb1_bad_crc(), .usb2_bad_crc(), .dbg_rows(),
`ifdef TANGO_VSYNC_ADJUST
        .vt_cur_w(bw), .vt_cur_h(bh), .vt_nxt_w(vt_nxt_w), .vt_nxt_h(vt_nxt_h),
`endif
        .dbg_uart_tx(uart_tx),
`ifdef TANGO_VIDEO_DDR3
        .clk_ddr(clk_ddr), .ddr_rst(!ddr_rst_n), .ddr_calib(ddr_calib),
        .ddr_cmd_ready(ddr_cmd_ready), .ddr_cmd_en(ddr_cmd_en), .ddr_cmd(ddr_cmd), .ddr_addr(ddr_addr),
        .ddr_wr_data_rdy(ddr_wr_data_rdy), .ddr_wr_data_en(ddr_wr_data_en), .ddr_wr_data(ddr_wr_data),
        .ddr_wr_data_mask(ddr_wr_data_mask), .ddr_rd_data_valid(ddr_rd_data_valid), .ddr_rd_data(ddr_rd_data));
`else
        .clk_sdram(clk_sdram), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE));
`endif

    wire [31:0] m_errors, m_aref, m_act, m_rd, m_wr, m_masked, m_gap;
`ifdef TANGO_VIDEO_DDR3
    assign m_errors = ddr_n_bad_cmd; assign m_masked = 32'd0;      // the model's protocol errors stand in
`else
    sdram_w9825_model u_mem (
        .clk(clk_sdram), .a(SDRAM_A), .ba(SDRAM_BA), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH),
        .ncs(SDRAM_nCS), .nras(SDRAM_nRAS), .ncas(SDRAM_nCAS), .nwe(SDRAM_nWE),
        .dq_ctrl(dut.u_sdram.dq_out), .dq_ctrl_oe(!dut.u_sdram.dq_oen),
        .dq_mem(dq_mem), .dq_mem_oe(dq_mem_oe),
        .errors(m_errors), .n_aref(m_aref), .n_act(m_act), .n_rd(m_rd), .n_wr(m_wr),
        .n_masked(m_masked), .max_rfsh_gap(m_gap));
`endif

    // ---- audio log
    integer afd = 0, n_steps = 0, n_outs = 0;
    reg [8*256-1:0] aname;
    initial if ($value$plusargs("alog=%s", aname)) afd = $fopen(aname, "w");
    task automatic rec(input [7:0] tag, input [15:0] a, input [15:0] b);   // one text line per record
        begin $fdisplay(afd, "%c %h %h", tag, a, b); end
    endtask
    // records (3 words: tag, a, b), in this order within a clock: z (the filter's reset is low again at this edge),
    // H (the 48 kHz hand-over takes y_l, y_r, the values before this edge), W (channel a's IIR output b is written at
    // this edge), S (the step's samples a, b are in il / ir), O (out_l, out_r take a, b at this edge), Z (the reset
    // is high from this edge: the taps, y and the mute count are cleared); after z, K records: the coefficients
    // (rate, cx, cx0-2, cy0-2 as 16-bit pieces) the filter runs with from then on.  The mix stage (MiSTer's
    // aud_mix_top): P (its inputs at this edge, before any O: att, {boost, mix}) whenever they change; M (out_l, out_r
    // after the stage moved, the clock after an O)
    reg af_rst_q = 1'b0, af_d2_q = 1'b0;
    reg [8:0] af_par = 9'h1FF;
    always @(posedge clk_pix) if (afd != 0) begin
        af_rst_q <= dut.u_afilt.reset;
        af_d2_q <= dut.u_afilt.d2;
        if ({dut.u_afilt.att, dut.u_afilt.boost, dut.u_afilt.mix_q} != af_par) begin
            af_par <= {dut.u_afilt.att, dut.u_afilt.boost, dut.u_afilt.mix_q};
            rec("P", {11'd0, dut.u_afilt.att}, {12'd0, dut.u_afilt.boost, dut.u_afilt.mix_q});
        end
        if (af_d2_q) rec("M", dut.u_afilt.out_l, dut.u_afilt.out_r);
        if (!dut.u_afilt.reset && af_rst_q) begin       // z, then the coefficients in force from now: K <index> <16 bits>
            rec("z", 16'd0, 16'd0);
            rec("K", 16'd0, dut.u_afilt.rate[31:16]); rec("K", 16'd1, dut.u_afilt.rate[15:0]);
            rec("K", 16'd2, {8'd0, dut.u_afilt.cx[39:32]}); rec("K", 16'd3, dut.u_afilt.cx[31:16]); rec("K", 16'd4, dut.u_afilt.cx[15:0]);
            rec("K", 16'd5, {8'd0, dut.u_afilt.cx0}); rec("K", 16'd6, {8'd0, dut.u_afilt.cx1}); rec("K", 16'd7, {8'd0, dut.u_afilt.cx2});
            rec("K", 16'd8, {8'd0, dut.u_afilt.cy0[23:16]}); rec("K", 16'd9, dut.u_afilt.cy0[15:0]);
            rec("K", 16'd10, {8'd0, dut.u_afilt.cy1[23:16]}); rec("K", 16'd11, dut.u_afilt.cy1[15:0]);
            rec("K", 16'd12, {8'd0, dut.u_afilt.cy2[23:16]}); rec("K", 16'd13, dut.u_afilt.cy2[15:0]);
        end
        if (dut.u_afilt.s48) rec("H", dut.u_afilt.y_l, dut.u_afilt.y_r);
        if (dut.u_afilt.s4_v && !dut.u_afilt.reset) begin
            rec("W", {15'd0, dut.u_afilt.s4_c}, dut.u_afilt.yc);
        end
        if (dut.u_afilt.dbg_step) begin
            rec("S", dut.u_afilt.il, dut.u_afilt.ir);
            n_steps = n_steps + 1;
        end
        if (dut.u_afilt.d2) begin
            rec("O", dut.u_afilt.mute_n[13] ? dut.u_afilt.dy_l[38:23] : 16'd0,
                     dut.u_afilt.mute_n[13] ? dut.u_afilt.dy_r[38:23] : 16'd0);
            n_outs = n_outs + 1;
        end
        if (dut.u_afilt.reset && !af_rst_q) rec("Z", 16'd0, 16'd0);
    end

    // ---- frame capture: rgb at clock t is for the beam (cx, cy) of clock t-1
    reg [11:0] px = 12'd0;  reg [10:0] py = 11'd0;
    integer frame = 0, fd = 0, nonblack = 0, picture = 0;
    reg [8*32-1:0] fname;
    initial begin
        void'($value$plusargs("nframes=%d", NFRAMES));
        void'($value$plusargs("first_dump=%d", FIRST_DUMP));
        if (FIRST_DUMP == 0) begin
            fd = $fopen("out_f0.ppm", "wb");
            $fwrite(fd, "P6\n%0d %0d\n255\n", OW, OH);
        end
        void'($value$plusargs("audio_only=%d", audio_ms));
        if (audio_ms != 0) begin
            #(audio_ms * 64'd1000000000);
            $display("TB done: %0d ms of audio: %0d filter steps, %0d outputs logged", audio_ms, n_steps, n_outs);
            if (afd != 0) $fclose(afd);
            $finish;
        end
    end
    always @(posedge clk_pix) begin
        px <= cx;  py <= cy;
        if (!rst_pix && px < OW && py < OH) begin
            if (fd != 0) $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
            if (rgb != 24'd0) nonblack = nonblack + 1;
        end
        if (!rst_pix && dut.u_vid.de_out) picture = picture + 1;
        if (!rst_pix && px == FW - 1 && py == FH - 1 && audio_ms == 0) begin
            $display("frame %0d: nonblack=%0d  flt_mode=%0d gam_en=%0d mask=%0d/%0d%0d  sdram errors=%0d  af rate=%0d",
                     frame, nonblack, dut.vp_flt_mode, dut.vp_gam_en, dut.u_vid.u_mask.m_en, dut.u_vid.u_mask.m_rot,
                     dut.u_vid.u_mask.m_2x, m_errors, dut.af_rate);
            $display("  geometry: core frame %0dx%0d  geo_ok=%0d  ascal window h %0d..%0d v %0d..%0d",
                     dut.u_vid.l_hs, dut.u_vid.l_vt, dut.u_vid.geo_ok,
                     dut.u_vid.v_hmin, dut.u_vid.v_hmax, dut.u_vid.v_vmin, dut.u_vid.v_vmax);
            $display("  picture=%0d (tango_video de_out clocks)", picture);
            if (fd != 0) $fclose(fd);
            fd = 0;  nonblack = 0;  picture = 0;
            frame = frame + 1;
            if (frame == NFRAMES) begin
                $display("TB done: %0d frames, sdram model errors=%0d masked=%0d; audio %0d steps %0d outputs",
                         frame, m_errors, m_masked, n_steps, n_outs);
                if (afd != 0) $fclose(afd);
                $finish;
            end
            if (frame >= FIRST_DUMP) begin
                $sformat(fname, "out_f%0d.ppm", frame);
                fd = $fopen(fname, "wb");
                $fwrite(fd, "P6\n%0d %0d\n255\n", OW, OH);
            end
        end
    end
endmodule
`default_nettype wire
