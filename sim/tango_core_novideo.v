// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tango_core_novideo -- a test core (module tango_core, the framework's core ports) that sends no picture, as nes-tango
// does before a ROM is loaded: CE_PIXEL keeps pulsing (sys/tango_core_ports.vh RULE), VGA_HS / VGA_VS / VGA_DE stay
// low, so the framework never sees a frame.  sim/run_idle_gates.sh case novideo builds sim/tb_vproc.v with it in place
// of rtl/tango_core_template.v (sim/run_tb_vproc.sh VPROC_CORE=): the picture must stay black, with the OSD drawn over
// it.  (A Verilator force on tango_sys's vga_vs / vga_de nets, tried first, did not reach tango_video in this design.)
//==============================================================================
`default_nettype none
module tango_core (
    `include "tango_core_ports.vh"
);
    localparam CONF_STR = {"NOVIDEO;;", "V,sim"};
    tango_conf_rom #(.CONF_STR(CONF_STR)) u_conf (.clk(CLK_PIX), .addr(conf_addr), .q(conf_char));
    assign CLK_SYS         = CLK_PIX;
    assign status_menumask = 16'd0;
    assign ioctl_wait      = 1'b0;
    // video: a pixel every 12th CLK_PIX clock (the Template's rate), nothing else
    reg [3:0] ce_div = 4'd0;
    always @(posedge CLK_PIX) ce_div <= (ce_div == 4'd11) ? 4'd0 : ce_div + 4'd1;
    assign CLK_VIDEO       = CLK_PIX;
    assign CE_PIXEL        = (ce_div == 4'd0);
    assign VGA_R = 8'd0;  assign VGA_G = 8'd0;  assign VGA_B = 8'd0;
    assign VGA_HS = 1'b0;  assign VGA_VS = 1'b0;  assign VGA_DE = 1'b0;
    assign VGA_SL          = 2'd0;
    assign VIDEO_ARX       = 13'd4;
    assign VIDEO_ARY       = 13'd3;
    assign HDMI_FREEZE     = 1'b0;
    assign VIDEO_SCALE     = 3'd0;
    assign VIDEO_CROP_SIZE = 12'd0;
    assign VIDEO_CROP_OFF  = 5'd0;
    assign AUDIO_L = 16'd0;  assign AUDIO_R = 16'd0;
`ifdef TANGO_CORE_AUDIO_MIX
    assign AUDIO_MIX       = 2'd0;
`endif
endmodule
`default_nettype wire
