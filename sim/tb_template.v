// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
// tb_template.v -- Verilator top for the Template core's sim gate (sim/tb_template.cpp, sim/run_tb_template.sh).
// Adapted from menu-tango's fpga/sim/tb_menu.v (the same authors); changed: "module tb_menu (" -> "module
// tb_template (", the TANGO_VIDEO_ASCAL SDRAM wires and ports (2 blocks), and this header.  Everything else is
// tb_menu.v, its own header included.
//------------------------------------------------------------------------------------------------------------
// tb_menu.v -- Verilator top for the core sim gates (fpga/sim/tb_menu.cpp): the menu core and the
// template core.  DUT = tango_sys (the framework fabric: everything but PLLs / HDMI encoder /
// serialiser) around whichever tango_core the build compiles (fpga/sim/*.files).
// USB-A2 (usb2_dp/dn) carries a simulated full-speed device: a second usb_fs_phy
// (the host's own bit engine, as a device) clocked by its OWN 48 MHz clock
// (clk48d, a different period from the host's clk48), driven byte-wise by the C++
// DS4 model; the device's 1.5k D+ pull-up and the host's 15k pull-downs are the
// pullup/pulldown below.  USB-A1 has nothing attached (both lines pulled down).
`default_nettype none
module tb_template (
    input  wire        clk_pix, rst_pix,
    input  wire [11:0] cx,
    input  wire [10:0] cy,
    output wire [23:0] rgb,
    output wire [23:0] rgb_dbg,         // rgb with the debug build's link blocks
    output wire [143:0] dbg_rows_o,
    input  wire        clk48, lock48,
    input  wire        spi_csn, spi_sck, spi_mosi,
    output wire        spi_miso, spi_irq_n,
    input  wire        bl616_jtagsel,
    // simulated USB device (clk48d)
    input  wire        clk48d, dev_rst_n,
    input  wire        dev_tx_start,
    input  wire [7:0]  dev_tx_data,
    input  wire        dev_tx_valid, dev_tx_last,
    output wire        dev_tx_rd, dev_tx_busy,
    output wire        dev_rx_strobe, dev_rx_eop, dev_rx_active,
    output wire [7:0]  dev_rx_data,
    // status
    output wire        osd_shown, osd_bank, osd_swap_pending,
    output wire [15:0] joy,
    output wire [7:0]  joy_flags,
    output wire [15:0] link_xfers,
    output wire [7:0]  usb2_bad_crc,
    output wire        line_dp, line_dn,
    // what the core sees (tango_core ports), for the core gates
    output wire [31:0] core_joy0,
    output wire [127:0] core_status,
    output wire        core_dl,
    output wire [11:0] core_cx,
    output wire [10:0] core_cy
`ifdef TB_KBD
    ,
    // a simulated LOW-SPEED boot keyboard on USB-A1 (tb_kbd.inc): its own usb_fs_phy with ls = 1 on clk48d
    input  wire        kdev_tx_start,
    input  wire [7:0]  kdev_tx_data,
    input  wire        kdev_tx_valid, kdev_tx_last,
    output wire        kdev_tx_rd, kdev_tx_busy,
    output wire        kline_dp, kline_dn,
    output wire [10:0] core_ps2_key,
    output wire [31:0] core_joy1
`endif
);
    assign core_cx = dut.ccx;
    assign core_cy = dut.ccy;
    assign core_joy0 = dut.joystick_0;
    assign core_status = dut.status_c;
    assign core_dl = dut.ioctl_download;
    wire usb1_dp, usb1_dn, usb2_dp, usb2_dn;
`ifdef TANGO_VIDEO_ASCAL
    wire [15:0] sdram_dq_sim;
`endif
`ifdef TB_KBD
    pulldown (usb1_dp);
    pullup   (usb1_dn);     // LS device attached: 1.5k on D- (USB 2.0 7.1.5)
    assign kline_dp = usb1_dp;
    assign kline_dn = usb1_dn;
    assign core_ps2_key = dut.ps2_key_sys;
    assign core_joy1 = dut.joystick_1;
    // trace of USB-A1's host (attach status, script step, speed, kind)
    reg [1:0] k_st_q = 2'd3; reg [3:0] k_pc_q = 4'hF; reg k_ls_q = 1'b0; reg [1:0] k_kind_q = 2'd3;
    always @(posedge clk48) begin
        k_st_q <= dut.u_usb1.status; k_pc_q <= dut.u_usb1.u_host.script_pc; k_ls_q <= dut.u_usb1.ls; k_kind_q <= dut.u_usb1.kind;
        if (k_st_q != dut.u_usb1.status || k_pc_q != dut.u_usb1.u_host.script_pc || k_ls_q != dut.u_usb1.ls || k_kind_q != dut.u_usb1.kind)
            $display("      [usb1 host] %0t: status %0d pc %0d ls %0d kind %0d", $time, dut.u_usb1.status,
                     dut.u_usb1.u_host.script_pc, dut.u_usb1.ls, dut.u_usb1.kind);
    end
    usb_fs_phy kdev (.clk48(clk48d), .rst_n(dev_rst_n), .dp(usb1_dp), .dn(usb1_dn), .bus_reset(1'b0),
        .ls(1'b1), .tx_keepalive(1'b0),
        .tx_start(kdev_tx_start), .tx_data(kdev_tx_data), .tx_valid(kdev_tx_valid), .tx_last(kdev_tx_last),
        .tx_rd(kdev_tx_rd), .tx_busy(kdev_tx_busy),
        .rx_active(), .rx_strobe(), .rx_data(), .rx_eop(), .rx_bitstuff_err(),
        .dbg_tx_st(), .dbg_tx_field(), .dbg_tx_bitcnt(),
        .dbg_tx_phase(), .dbg_tx_shift(), .dbg_tx_cur_k(),
        .dbg_rx_phase(), .dbg_rx_bitcnt(), .dbg_rx_ones(),
        .dbg_transitioned(), .dbg_line_j(), .dbg_line_k());
`else
    pulldown (usb1_dp);
    pulldown (usb1_dn);
`endif
    pullup   (usb2_dp);     // FS device attached: 1.5k on D+
    pulldown (usb2_dn);
    assign line_dp = usb2_dp;
    assign line_dn = usb2_dn;

    tango_sys #(.USB_DEBOUNCE(960_000)) dut (
        .clk50(clk48d), .audio_l(), .audio_r(),   // CLK_50M: an unrelated clock (the SD test core runs on it)
        .clk_pix(clk_pix), .rst_pix(rst_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .clk48(clk48), .lock48(lock48),
        .usb1_dp(usb1_dp), .usb1_dn(usb1_dn), .usb2_dp(usb2_dp), .usb2_dn(usb2_dn),
        .spi_csn(spi_csn), .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_miso_pad(spi_miso), .spi_irq_n(spi_irq_n), .bl616_jtagsel(bl616_jtagsel), .jtagsel_n_q(~bl616_jtagsel),
        .osd_shown(osd_shown), .osd_bank(osd_bank), .osd_swap_pending(osd_swap_pending),
        .joy(joy), .joy_flags(joy_flags), .link_xfers(link_xfers),
        .usb1_bad_crc(), .usb2_bad_crc(usb2_bad_crc), .dbg_rows(dbg_rows)
`ifdef TANGO_VIDEO_ASCAL
        , .dbg_uart_tx()
        , .clk_sdram(clk_pix)
        , .SDRAM_DQ(sdram_dq_sim), .SDRAM_A(), .SDRAM_BA()
        , .SDRAM_DQML(), .SDRAM_DQMH()
        , .SDRAM_nCS(), .SDRAM_nRAS(), .SDRAM_nCAS(), .SDRAM_nWE()
`endif
    );
    wire [143:0] dbg_rows;
    assign dbg_rows_o = dbg_rows;
    tango_link_dbg_view #(.N_ROWS(18)) u_dbg (.clk(clk_pix), .cx(cx), .cy(cy), .rgb_in(rgb),
        .rows(dbg_rows), .rgb_out(rgb_dbg));

    usb_fs_phy dev (.clk48(clk48d), .rst_n(dev_rst_n), .dp(usb2_dp), .dn(usb2_dn), .bus_reset(1'b0), .ls(1'b0), .tx_keepalive(1'b0),
        .tx_start(dev_tx_start), .tx_data(dev_tx_data), .tx_valid(dev_tx_valid), .tx_last(dev_tx_last),
        .tx_rd(dev_tx_rd), .tx_busy(dev_tx_busy),
        .rx_active(dev_rx_active), .rx_strobe(dev_rx_strobe), .rx_data(dev_rx_data), .rx_eop(dev_rx_eop),
        .rx_bitstuff_err(),
        .dbg_tx_st(), .dbg_tx_field(), .dbg_tx_bitcnt(),
        .dbg_tx_phase(), .dbg_tx_shift(), .dbg_tx_cur_k(),
        .dbg_rx_phase(), .dbg_rx_bitcnt(), .dbg_rx_ones(),
        .dbg_transitioned(), .dbg_line_j(), .dbg_line_k());
endmodule
`default_nettype wire
