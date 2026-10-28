// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_ascal_sys -- the Template core through the REAL ascal (GHDL-converted, sys/ascal_ghdl/) and the
// real tango_sdram on the W9825G6KH model: tango_sys with TANGO_VIDEO_ASCAL and without TANGO_SIM.
// The behavioural gate (run_tb_template_ascal.sh) leaves clk_sdram and the SDRAM pins unconnected and
// replaces ascal, so it never exercises this path.
// Clocks: clk_pix 74.25 MHz (720p60 beam as hdmi.sv: 1650 x 750), clk_sdram 96 MHz, clk50, clk48.
// No BL616 link and no USB devices.  Writes out_f<N>.ppm (1280 x 720, the rgb tango_sys returns for the
// previous clock's beam) for frames FIRST_DUMP..NFRAMES-1 and prints per-frame stats and the ascal
// Avalon counters.
//==============================================================================
`default_nettype none
`timescale 1ps/1ps
module tb_ascal_sys;
    localparam integer FW = 1650, FH = 750, OW = 1280, OH = 720;
`ifdef NFRAMES_DEF
    localparam integer NFRAMES = `NFRAMES_DEF;
`else
    localparam integer NFRAMES = 8;
`endif
    localparam integer FIRST_DUMP = 2;

    reg clk_pix = 1'b0, clk_sdram = 1'b0, clk50 = 1'b0, clk48 = 1'b0;
    always #6734  clk_pix   = ~clk_pix;      // 74.25 MHz (13.468 ns)
    always #5208  clk_sdram = ~clk_sdram;    // 96 MHz
    always #10000 clk50     = ~clk50;
    always #10417 clk48     = ~clk48;

    // pixel reset: released 64 clk_pix after start (the board top waits for both PLL locks)
    reg [6:0] rcnt = 7'd0;
    wire rst_pix = (rcnt != 7'd64);
    always @(posedge clk_pix) if (rst_pix) rcnt <= rcnt + 7'd1;

    // hdmi.sv beam
    reg [11:0] cx = 12'd0;  reg [10:0] cy = 11'd0;
    always @(posedge clk_pix) begin
        if (rst_pix) begin cx <= 12'd0; cy <= 11'd0; end
        else if (cx == FW - 1) begin cx <= 12'd0; cy <= (cy == FH - 1) ? 11'd0 : cy + 11'd1; end
        else cx <= cx + 12'd1;
    end

    wire [23:0] rgb;
    wire usb1_dp, usb1_dn, usb2_dp, usb2_dn;
    pulldown (usb1_dp); pulldown (usb1_dn); pulldown (usb2_dp); pulldown (usb2_dn);
    wire [12:0] SDRAM_A;  wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE;
    wire [15:0] SDRAM_DQ, dq_mem;  wire dq_mem_oe, uart_tx;
    // read data reaches the controller DQ_DELAY_PS after the model drives it (the board's round trip;
    // see sim/tb_tango_sdram_ab.v); 12 ns reproduces the Console 138K's late read data
`ifndef DQ_DELAY_PS
`define DQ_DELAY_PS 12000
`endif
    reg  [15:0] dq_mem_d = 16'd0;  reg dq_mem_oe_d = 1'b0;
    always @(dq_mem or dq_mem_oe) begin
        dq_mem_d    <= #(`DQ_DELAY_PS) dq_mem;
        dq_mem_oe_d <= #(`DQ_DELAY_PS) dq_mem_oe;
    end
    assign SDRAM_DQ = dq_mem_oe_d ? dq_mem_d : 16'bz;

    // ---- +status=<hex>: the core's option word, set 2 us in (after the pixel reset) as the link's SET_STATUS
    // leaves it: tango_link's status and a flip of status_tog (tango_link.v 604), which tango_io latches into the
    // core's status on clk_sys (tango_io.v 63-64).  E.g. the framework's Aspect ratio, Scale and Scanlines
    // (status[127:126], [125:124], [123:122]: sys/tango_video_opts.vh; sys/tango_video.v reads them from that same
    // tango_link status word, TANGO_VIDEO_OPTS) and the core's Pattern (status[44:41]) for the scaler measurements
    // (sim/measure_scale.py).  Without it the word stays 0, as this bench always had it.
    // +status2 / +switch_frame (end of this file) change it again at run time.
    // (A force on tango_sys's status_c net had no effect in Verilator 5.020.)
    reg [127:0] tb_status = 128'd0;
    initial if ($value$plusargs("status=%h", tb_status)) begin
        #2000000;
        $display("tb: option word set to %032x", tb_status);
        dut.u_link.status = tb_status;
        dut.u_link.status_tog = ~dut.u_link.status_tog;
    end

    tango_sys #(.USB_DEBOUNCE(960_000)) dut (
        .clk50(clk50), .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .audio_l(), .audio_r(), .clk48(clk48), .lock48(1'b1),
        .usb1_dp(usb1_dp), .usb1_dn(usb1_dn), .usb2_dp(usb2_dp), .usb2_dn(usb2_dn),
        .spi_csn(1'b1), .spi_sck(1'b0), .spi_mosi(1'b0), .spi_miso(), .spi_miso_pad(1'b0), .spi_irq_n(),
        .bl616_jtagsel(1'b0), .jtagsel_n_q(1'b1),
        .osd_shown(), .osd_bank(), .osd_swap_pending(), .joy(), .joy_flags(), .link_xfers(),
        .usb1_bad_crc(), .usb2_bad_crc(), .dbg_rows(),
        .dbg_uart_tx(uart_tx),
        .clk_sdram(clk_sdram), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE));

    wire [31:0] m_errors, m_aref, m_act, m_rd, m_wr, m_masked, m_gap;
    sdram_w9825_model u_mem (
        .clk(clk_sdram), .a(SDRAM_A), .ba(SDRAM_BA), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH),
        .ncs(SDRAM_nCS), .nras(SDRAM_nRAS), .ncas(SDRAM_nCAS), .nwe(SDRAM_nWE),
        .dq_ctrl(dut.u_sdram.dq_out), .dq_ctrl_oe(!dut.u_sdram.dq_oen),
        .dq_mem(dq_mem), .dq_mem_oe(dq_mem_oe),
        .errors(m_errors), .n_aref(m_aref), .n_act(m_act), .n_rd(m_rd), .n_wr(m_wr),
        .n_masked(m_masked), .max_rfsh_gap(m_gap));

    // ---- frame capture: rgb at clock t is for the beam (cx, cy) of clock t-1
    reg [11:0] px = 12'd0;  reg [10:0] py = 11'd0;
    integer frame = 0, fd = 0, nonblack = 0, sum_r = 0, sum_g = 0, sum_b = 0;
    reg [8*32-1:0] fname;
    always @(posedge clk_pix) begin
        px <= cx;  py <= cy;
        if (!rst_pix && px < OW && py < OH) begin
            if (fd != 0) $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
            if (rgb != 24'd0) nonblack = nonblack + 1;
            sum_r = sum_r + rgb[23:16];  sum_g = sum_g + rgb[15:8];  sum_b = sum_b + rgb[7:0];
            if (px == 12'd640 && py == 11'd360)
                $display("  f%0d centre pixel %06x", frame, rgb);
        end
        if (!rst_pix && px == FW - 1 && py == FH - 1) begin
            $display("frame %0d: nonblack=%0d mean=(%0d,%0d,%0d)  ascal RC=%0d RV=%0d WC=%0d  sdram rd=%0d wr=%0d masked=%0d errors=%0d",
                     frame, nonblack, sum_r / (OW * OH), sum_g / (OW * OH), sum_b / (OW * OH),
                     dut.dbg_arc, dut.dbg_arv, dut.dbg_awc, m_rd, m_wr, m_masked, m_errors);
            $display("  geometry: core frame %0dx%0d  geo_ok=%0d  ascal window h %0d..%0d v %0d..%0d",
                     dut.u_vid.l_hs, dut.u_vid.l_vt, dut.u_vid.geo_ok,
                     dut.u_vid.v_hmin, dut.u_vid.v_hmax, dut.u_vid.v_vmin, dut.u_vid.v_vmax);
            if (fd != 0) $fclose(fd);
            fd = 0;  nonblack = 0;  sum_r = 0;  sum_g = 0;  sum_b = 0;
            frame = frame + 1;
            if (frame == NFRAMES) begin
                $display("TB done: %0d frames, sdram model errors=%0d masked=%0d max_refresh_gap=%0d",
                         frame, m_errors, m_masked, m_gap);
                $finish;
            end
            if (frame >= FIRST_DUMP) begin
                $sformat(fname, "out_f%0d.ppm", frame);
                fd = $fopen(fname, "wb");
                $fwrite(fd, "P6\n%0d %0d\n255\n", OW, OH);
            end
        end
    end

    // ---- +status2=<hex> +switch_frame=<k>: a second option word, set the same way when output frame k starts --
    // a change at run time with no reset (e.g. the Template's Source size, status[47:45]).
    reg [127:0] tb_status2 = 128'd0;
    integer     tb_switch = 0;
    initial if ($value$plusargs("status2=%h", tb_status2) && $value$plusargs("switch_frame=%d", tb_switch)) begin
        wait (frame == tb_switch);
        $display("tb: option word set to %032x at the start of frame %0d", tb_status2, frame);
        dut.u_link.status = tb_status2;
        dut.u_link.status_tog = ~dut.u_link.status_tog;
    end
endmodule
`default_nettype wire
