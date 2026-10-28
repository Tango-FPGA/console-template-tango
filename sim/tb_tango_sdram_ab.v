// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_tango_sdram_ab -- tango_sdram ports A/B at the NES's real cadence, port C as ascal, refresh, against
// sdram_w9825_model with the board's read round trip (-DDQ_DELAY_NS, default 12) and RD_CAP 1.
// NES side (its own 21.505 MHz clock, asynchronous to clk_sdram 96 MHz).  A dot (slot) is 4 NES clocks; a
// request is a window of 4 NES clocks starting at a dot boundary E0 (nestang: nes.v 179-188, 441-442,
// ppu.v 832; measured A 4..4, B 4..4 in the deadline sim).  The NES samples the byte at E0+8 (PPU: ppu.v
// 506-515) or E0+12 (CPU: T65 Enable = cpu_ce, nes.v 277), proven by sweeping the memory latency.
//   +mode=0  NES: A (PPU) reads on even dots from CHR 0x20xxxx / VRAM 0x30xxxx; every 8th frame-like phase is a
//            "vblank" where A writes VRAM in the CPU's dot instead; B (CPU) on dots 0 and 3 of 6: PRG 0x00xxxx,
//            RAM 0x38xxxx (1 in 4 a write, read back soon after).
//   +mode=1  stress: A and B in EVERY slot, both in bank 1, random reads and writes, small regions (same and
//            different rows) -- more than the NES ever asks.
// Port C: an ascal-like master (sys/ascal.vhd 1686-1733), 32-beat bursts in banks 2/3 only,
// random reads / writes / gaps; every read beat checked against a shadow.
// Checks: model errors (every rule it knows), masked words, A/B overrun / lost, C data, refresh rate, and
//   every A/B read: the right byte, in order, before its deadline (new controller: at the controller's update,
//   min slack reported per port); in mode 0 also the byte on doutX AT the NES sample edge (both controllers).
// -DOLD_IF builds the bench for the controller's earlier interface: no tango_ab_slot, clkref toggling every NES
// clock and the raw request windows on the ports (as tango_nes.v drives it), mode 0 only.
//==============================================================================
`default_nettype none
`timescale 1ns/1ps
module tb_tango_sdram_ab;
`ifndef RD_CAP_TB
`define RD_CAP_TB 1
`endif
    localparam integer BLEN = 32, NSLOT = 32;
    localparam real    NES_HALF = 23.25;             // 21.505 MHz
    localparam real    OUT_MARGIN = 30.0;            // doutA/doutB -> NES flop budget (set_max_delay in the core SDC)
    reg clk = 1'b0;   always #5.208 clk = ~clk;      // clk_sdram 96 MHz
    reg nclk = 1'b0;  initial #3.7 forever #(NES_HALF) nclk = ~nclk;
    reg [3:0] rst_cnt = 4'd0;
    wire resetn = (rst_cnt == 4'd8);
    always @(posedge clk) if (!resetn) rst_cnt <= rst_cnt + 4'd1;

    integer mode, run_us;
    real    dq_delay;
    initial begin
        if (!$value$plusargs("mode=%d", mode)) mode = 0;
        if (!$value$plusargs("dq=%f", dq_delay)) dq_delay = 12.0;
        if (!$value$plusargs("us=%d", run_us)) run_us = 3000;
`ifdef OLD_IF
        mode = 0;
`endif
        $display("TB tb_tango_sdram_ab mode=%0d us=%0d dq_delay=%0.1f ns RD_CAP=%0d%s", mode, run_us, dq_delay,
                 `RD_CAP_TB,
`ifdef OLD_IF
                 " OLD_IF (earlier interface)");
`else
                 "");
`endif
    end

    // ---- DUT + model (read data reaches the controller +dq= ns after the model drives it: the board's round trip)
    wire [12:0] SDRAM_A;  wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_CKE, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE;
    wire [15:0] SDRAM_DQ, dq_mem;  wire dq_mem_oe;
    reg  [15:0] dq_mem_d = 16'd0;  reg dq_mem_oe_d = 1'b0;
    always @(dq_mem or dq_mem_oe) begin
        dq_mem_d    <= #(dq_delay) dq_mem;
        dq_mem_oe_d <= #(dq_delay) dq_mem_oe;
    end
    assign SDRAM_DQ = dq_mem_oe_d ? dq_mem_d : 16'bz;

    // NES-side request windows (nclk registers, as the NES's combinational outputs settle after E0)
    reg  [21:0] n_addrA = 22'd0, n_addrB = 22'd0;
    reg         n_oeA = 1'b0, n_weA = 1'b0, n_oeB = 1'b0, n_weB = 1'b0;
    reg  [7:0]  n_dinA = 8'd0, n_dinB = 8'd0;
    reg  [1:0]  ph = 2'd0;                            // NES clock within the dot (0: the clock after E0)
    wire [7:0]  doutA, doutB;
    // port C
    reg  [28:0] avl_address = 29'd0;
    reg         avl_write = 1'b0, avl_read = 1'b0;
    reg  [63:0] avl_writedata = 64'd0;
    wire [63:0] avl_readdata;
    wire        avl_readdatavalid, avl_waitrequest, busy;
`ifdef OLD_IF
    reg clkref = 1'b0;
    always @(posedge nclk) clkref <= ~clkref;         // as the NES core drives it
    tango_sdram #(.INIT_CYCLES(400), .RD_CAP(`RD_CAP_TB)) u_sdram (
        .clk(clk), .resetn(resetn), .busy(busy),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .addrA(n_addrA), .oeA(n_oeA), .weA(n_weA), .dinA(n_dinA), .doutA(doutA),
        .addrB(n_addrB), .oeB(n_oeB), .weB(n_weB), .dinB(n_dinB), .doutB(doutB), .clkref(clkref),
        .avl_address(avl_address), .avl_write(avl_write), .avl_writedata(avl_writedata), .avl_read(avl_read),
        .avl_burstcount(BLEN[7:0]), .avl_byteenable(8'hFF), .avl_readdata(avl_readdata),
        .avl_readdatavalid(avl_readdatavalid), .avl_waitrequest(avl_waitrequest));
`else
    wire [21:0] h_addrA, h_addrB;  wire h_oeA, h_weA, h_oeB, h_weB, slot_tog, slot_lost;  wire [7:0] h_dinA, h_dinB;
    tango_ab_slot u_slot (.clk(nclk), .slot_ce(ph == 2'd0),
        .addrA(n_addrA), .oeA(n_oeA), .weA(n_weA), .dinA(n_dinA),
        .addrB(n_addrB), .oeB(n_oeB), .weB(n_weB), .dinB(n_dinB),
        .h_addrA(h_addrA), .h_oeA(h_oeA), .h_weA(h_weA), .h_dinA(h_dinA),
        .h_addrB(h_addrB), .h_oeB(h_oeB), .h_weB(h_weB), .h_dinB(h_dinB), .slot_tog(slot_tog), .lost(slot_lost));
    tango_sdram #(.INIT_CYCLES(400), .RD_CAP(`RD_CAP_TB), .AB_SLOTS(1)) u_sdram (
        .clk(clk), .resetn(resetn), .busy(busy),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .addrA(h_addrA), .oeA(h_oeA), .weA(h_weA), .dinA(h_dinA), .doutA(doutA),
        .addrB(h_addrB), .oeB(h_oeB), .weB(h_weB), .dinB(h_dinB), .doutB(doutB), .clkref(slot_tog),
        .avl_address(avl_address), .avl_write(avl_write), .avl_writedata(avl_writedata), .avl_read(avl_read),
        .avl_burstcount(BLEN[7:0]), .avl_byteenable(8'hFF), .avl_readdata(avl_readdata),
        .avl_readdatavalid(avl_readdatavalid), .avl_waitrequest(avl_waitrequest));
`endif
    wire [31:0] m_errors, m_aref, m_act, m_rd, m_wr, m_masked, m_gap;
    sdram_w9825_model u_mem (
        .clk(clk), .a(SDRAM_A), .ba(SDRAM_BA), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH),
        .ncs(SDRAM_nCS), .nras(SDRAM_nRAS), .ncas(SDRAM_nCAS), .nwe(SDRAM_nWE),
        .dq_ctrl(u_sdram.dq_out), .dq_ctrl_oe(!u_sdram.dq_oen), .dq_mem(dq_mem), .dq_mem_oe(dq_mem_oe),
        .errors(m_errors), .n_aref(m_aref), .n_act(m_act), .n_rd(m_rd), .n_wr(m_wr),
        .n_masked(m_masked), .max_rfsh_gap(m_gap));

    // ---- A/B shadow (byte address), preloaded into the model: pat(a), as tango_sdram maps A/B
    //      (bank {0, a[21]}, row a[20:10], column a[9:1], byte a[0])
    function [7:0] pat(input [21:0] a); pat = a[7:0] ^ {a[15:10], a[9:8]} ^ {2'b0, a[21:16]} ^ 8'h5A; endfunction
    reg [7:0] shadow [0:(1<<22)-1];
    task preload(input [21:0] base, input integer len);
        integer k; reg [21:0] a;
        begin
            for (k = 0; k < len; k = k + 2) begin
                a = base + k[21:0];
                u_mem.mem[{1'b0, a[21], 2'b00, a[20:10], a[9:1]}] = {pat(a | 22'd1), pat(a & ~22'd1)};
                shadow[a] = pat(a & ~22'd1);  shadow[a | 22'd1] = pat(a | 22'd1);
            end
        end
    endtask
    initial begin
        preload(22'h000000, 32768);  preload(22'h200000, 16384);  preload(22'h300000, 4096);
        preload(22'h380000, 2048);   preload(22'h3C0000, 8192);
    end

    // ================================================================ NES side
    reg [31:0] lfsr = 32'h1234_5678;
    reg [31:0] nedge = 32'd0;                          // NES clock edges
    reg [2:0]  dot = 3'd0;                             // dot within 6 (2 CPU cycles)
    reg [7:0]  fr = 8'd0;                              // "frame" phase: dots / 256 (vblank when fr[2:0] == 7)
    reg [15:0] dcnt = 16'd0;
    reg        started = 1'b0, ending = 1'b0;
    // expected reads per port: FIFO of {deadline (ns), expected byte, addr}; and the sample-edge checks
    localparam integer QD = 8;
    real       qa_dl [0:QD-1], qb_dl [0:QD-1];
    reg [7:0]  qa_x [0:QD-1], qb_x [0:QD-1];
    reg [21:0] qa_ad [0:QD-1], qb_ad [0:QD-1];
    reg [31:0] qa_se [0:QD-1], qb_se [0:QD-1];       // the NES edge that samples it
    integer    qa_w = 0, qa_r = 0, qb_w = 0, qb_r = 0, qa_s = 0, qb_s = 0;
    integer    n_a = 0, n_b = 0, n_aw = 0, n_bw = 0, n_ab = 0;
    integer    err_upd_a = 0, err_upd_b = 0, err_smp_a = 0, err_smp_b = 0;
    real       slack_a = 1.0e9, slack_b = 1.0e9;
    task push_a(input [21:0] ad, input [7:0] x, input [31:0] se);
        begin qa_dl[qa_w % QD] = $realtime + 8.0 * 2.0 * NES_HALF - OUT_MARGIN; qa_x[qa_w % QD] = x; qa_ad[qa_w % QD] = ad;
              qa_se[qa_w % QD] = se; qa_w = qa_w + 1; end
    endtask
    task push_b(input [21:0] ad, input [7:0] x, input [31:0] se);
        begin qb_dl[qb_w % QD] = $realtime + 12.0 * 2.0 * NES_HALF - OUT_MARGIN; qb_x[qb_w % QD] = x; qb_ad[qb_w % QD] = ad;
              qb_se[qb_w % QD] = se; qb_w = qb_w + 1; end
    endtask
    always @(posedge nclk) begin : nes
        reg [21:0] a, b;  reg [2:0] nd;  reg vbl;  reg [7:0] v;
        nedge <= nedge + 32'd1;
        lfsr  <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        if (!busy && resetn && nedge > 32'd64) started <= 1'b1;
        ph <= ph + 2'd1;
        // ---- sample-edge checks (mode 0): the NES samples doutX at this edge
        if (mode == 0) begin
            if (qa_s < qa_w && qa_se[qa_s % QD] == nedge) begin
                if (doutA !== qa_x[qa_s % QD]) begin
                    err_smp_a = err_smp_a + 1;
                    if (err_smp_a <= 5) $display("TB A sample miss t=%0t addr %06x got %02x want %02x", $time,
                                                 qa_ad[qa_s % QD], doutA, qa_x[qa_s % QD]);
                end
                qa_s = qa_s + 1;
            end
            if (qb_s < qb_w && qb_se[qb_s % QD] == nedge) begin
                if (doutB !== qb_x[qb_s % QD]) begin
                    err_smp_b = err_smp_b + 1;
                    if (err_smp_b <= 5) $display("TB B sample miss t=%0t addr %06x got %02x want %02x", $time,
                                                 qb_ad[qb_s % QD], doutB, qb_x[qb_s % QD]);
                end
                qb_s = qb_s + 1;
            end
        end
        // ---- request windows: new at the dot boundary (this edge ends ph 3), held 4 NES clocks; stress mode
        //      asks in every slot, so its windows end one clock early (a port's request is one rising edge)
        if (mode == 1 && ph == 2'd2) begin n_oeA <= 1'b0;  n_weA <= 1'b0;  n_oeB <= 1'b0;  n_weB <= 1'b0; end
        if (ph == 2'd3) begin
            n_oeA <= 1'b0;  n_weA <= 1'b0;  n_oeB <= 1'b0;  n_weB <= 1'b0;
            nd = (dot == 3'd5) ? 3'd0 : dot + 3'd1;
            dot <= nd;  dcnt <= dcnt + 16'd1;
            vbl = (dcnt[10:8] == 3'd7);
            if (started && !ending) begin
                if (mode == 0) begin
                    // A: PPU reads on even dots while "rendering"; VRAM writes in the CPU's dot during "vblank"
                    if (!vbl && nd[0] == 1'b0) begin
                        a = lfsr[0] ? {9'b10_0000_000, lfsr[12:0]} : {12'b11_0000_0000_00, lfsr[23:14]};
                        n_addrA <= a;  n_oeA <= 1'b1;  push_a(a, shadow[a], nedge + 32'd8);  n_a = n_a + 1;
                    end else if (vbl && (nd == 3'd0 || nd == 3'd3) && lfsr[5]) begin
                        a = {12'b11_0000_0000_00, lfsr[23:14]};
                        v = lfsr[31:24];
                        n_addrA <= a;  n_weA <= 1'b1;  n_dinA <= v;  shadow[a] = v;  n_aw = n_aw + 1;
                    end
                    // B: CPU on dots 0 and 3 (not in a vblank A-write dot)
                    if ((nd == 3'd0 || nd == 3'd3) && !(vbl && lfsr[5])) begin
                        b = lfsr[6] ? {7'd0, lfsr[21:7]} : {16'b11_1000_0000_0000_00, lfsr[11:7], 1'b0} | {21'd0, lfsr[8]};
                        if (!lfsr[6] && lfsr[25:24] == 2'd0) begin
                            v = lfsr[31:24] ^ 8'hC3;
                            n_addrB <= b;  n_weB <= 1'b1;  n_dinB <= v;  shadow[b] = v;  n_bw = n_bw + 1;
                        end else begin
                            n_addrB <= b;  n_oeB <= 1'b1;  push_b(b, shadow[b], nedge + 32'd12);  n_b = n_b + 1;
                        end
                        if (!vbl && nd[0] == 1'b0) n_ab = n_ab + 1;
                    end
                end else begin
                    // stress: A and B in every slot, bank 1, two rows each, reads and writes
                    a = {9'b10_0000_000, lfsr[0], 3'b000, lfsr[9:1]};               // CHR rows 0x800 / 0x804
                    b = {11'b11_1000_0000_0, lfsr[1], 1'b0, lfsr[18:10]};           // RAM rows 0x600 / 0x601
                    if (lfsr[2]) begin
                        v = lfsr[31:24];  n_addrA <= a;  n_weA <= 1'b1;  n_dinA <= v;  shadow[a] = v;  n_aw = n_aw + 1;
                    end else begin
                        n_addrA <= a;  n_oeA <= 1'b1;  push_a(a, shadow[a], nedge + 32'd8);  n_a = n_a + 1;
                    end
                    if (lfsr[3]) begin
                        v = lfsr[23:16] ^ 8'h3C;  n_addrB <= b;  n_weB <= 1'b1;  n_dinB <= v;  shadow[b] = v;  n_bw = n_bw + 1;
                    end else begin
                        n_addrB <= b;  n_oeB <= 1'b1;  push_b(b, shadow[b], nedge + 32'd12);  n_b = n_b + 1;
                    end
                    n_ab = n_ab + 1;
                end
            end
        end
    end

`ifndef OLD_IF
    // ---- internal invariants (new controller): the grant register is one-hot; a C write burst's words to grant
    //      = words in the beat buffers (4 per valid buffer, less the head's index) + 4 x beats still to come
    integer err_inv = 0;
    always @(posedge clk) if (resetn) begin
        if ((u_sdram.g & (u_sdram.g - 11'd1)) != 11'd0) begin
            err_inv = err_inv + 1;  if (err_inv <= 5) $display("TB invariant: grant not one-hot %b t=%0t", u_sdram.g, $time);
        end
        if (!u_sdram.c_i && !u_sdram.c_rd &&
                u_sdram.c_wleft != 10'd4 * (u_sdram.wv0 + u_sdram.wv1) - u_sdram.ri + {u_sdram.c_bleft, 2'b00}) begin
            err_inv = err_inv + 1;  if (err_inv <= 5) $display("TB invariant: C words %0d != buffers %0d%0d - %0d + 4 x %0d beats t=%0t",
                                                              u_sdram.c_wleft, u_sdram.wv0, u_sdram.wv1, u_sdram.ri, u_sdram.c_bleft, $time);
        end
    end
`endif
`ifndef OLD_IF
    // ---- controller updates: every A/B read, in order, the right byte, before its deadline
    localparam integer RI = (`RD_CAP_TB != 0) ? 4 : 3;
    localparam real    TCK = 10.416;                   // clk period (above)
    reg upd_d = 1'b0, upd_pt = 1'b0;  real upd_t = 0.0;
    // latency of every A/B read: from the clk edge that captures its slot (u_sdram.cap with the held oeX: the
    // controller's registers take the request at this edge) to the edge that loads doutX, in clk; and from the
    // dot boundary E0 (the request's NES edge) to that edge, in ns
    real    ca_t [0:QD-1], cb_t [0:QD-1];
    integer ca_w = 0, ca_r = 0, cb_w = 0, cb_r = 0;
    integer lat_a_min = 1000, lat_a_max = 0, lat_b_min = 1000, lat_b_max = 0, lat_k;
    real    e0_a_max = 0.0, e0_b_max = 0.0, e0_a_min = 1.0e9, e0_b_min = 1.0e9, e0;
    always @(posedge clk) begin
        upd_d <= u_sdram.rt_ab[RI];  upd_pt <= u_sdram.rt_pt[RI];
        if (u_sdram.rt_ab[RI]) upd_t = $realtime;
        if (u_sdram.cap && h_oeA && started) begin ca_t[ca_w % QD] = $realtime;  ca_w = ca_w + 1; end
        if (u_sdram.cap && h_oeB && started) begin cb_t[cb_w % QD] = $realtime;  cb_w = cb_w + 1; end
    end
    always @(negedge clk) if (upd_d) begin
        if (!upd_pt) begin
            if (ca_r < ca_w) begin
                lat_k = $rtoi((upd_t - ca_t[ca_r % QD]) / TCK + 0.5);  ca_r = ca_r + 1;
                if (lat_k < lat_a_min) lat_a_min = lat_k;
                if (lat_k > lat_a_max) lat_a_max = lat_k;
            end
            if (qa_r >= qa_w) begin err_upd_a = err_upd_a + 1; $display("TB A update with no request t=%0t", $time); end
            else begin
                e0 = upd_t - (qa_dl[qa_r % QD] - 8.0 * 2.0 * NES_HALF + OUT_MARGIN);
                if (e0 > e0_a_max) e0_a_max = e0;
                if (e0 < e0_a_min) e0_a_min = e0;
                if (doutA !== qa_x[qa_r % QD] || upd_t > qa_dl[qa_r % QD]) begin
                    err_upd_a = err_upd_a + 1;
                    if (err_upd_a <= 5) $display("TB A update t=%0t addr %06x got %02x want %02x late %0.1f ns", $time,
                                                 qa_ad[qa_r % QD], doutA, qa_x[qa_r % QD], upd_t - qa_dl[qa_r % QD]);
                end
                if (qa_dl[qa_r % QD] - upd_t < slack_a) slack_a = qa_dl[qa_r % QD] - upd_t;
                qa_r = qa_r + 1;
            end
        end else begin
            if (cb_r < cb_w) begin
                lat_k = $rtoi((upd_t - cb_t[cb_r % QD]) / TCK + 0.5);  cb_r = cb_r + 1;
                if (lat_k < lat_b_min) lat_b_min = lat_k;
                if (lat_k > lat_b_max) lat_b_max = lat_k;
            end
            if (qb_r >= qb_w) begin err_upd_b = err_upd_b + 1; $display("TB B update with no request t=%0t", $time); end
            else begin
                e0 = upd_t - (qb_dl[qb_r % QD] - 12.0 * 2.0 * NES_HALF + OUT_MARGIN);
                if (e0 > e0_b_max) e0_b_max = e0;
                if (e0 < e0_b_min) e0_b_min = e0;
                if (doutB !== qb_x[qb_r % QD] || upd_t > qb_dl[qb_r % QD]) begin
                    err_upd_b = err_upd_b + 1;
                    if (err_upd_b <= 5) $display("TB B update t=%0t addr %06x got %02x want %02x late %0.1f ns", $time,
                                                 qb_ad[qb_r % QD], doutB, qb_x[qb_r % QD], upd_t - qb_dl[qb_r % QD]);
                end
                if (qb_dl[qb_r % QD] - upd_t < slack_b) slack_b = qb_dl[qb_r % QD] - upd_t;
                qb_r = qb_r + 1;
            end
        end
    end
`endif

    // ================================================================ port C: ascal's Avalon master
    // slots: bank 2/3 (s[0]), 256-byte block s[2:1] of the row, row from s[4:3]
    function [31:0] slot_addr(input [4:0] s);
        reg [12:0] r;
        begin
            case (s[4:3]) 2'd0: r = 13'h1000; 2'd1: r = 13'd5; 2'd2: r = 13'd1116; default: r = 13'd8191; endcase
            slot_addr = {7'd0, 1'b1, s[0], r, s[2:1], 8'd0};
        end
    endfunction
    function [63:0] cpat(input [15:0] g, input [4:0] s, input [4:0] i);
        cpat = {g, 1'b0, s, i, 5'b10110, ~{g, 1'b0, s, i, 5'b10110}};
    endfunction
    reg [63:0] cshadow [0:NSLOT*BLEN-1];
    reg [15:0] gen    [0:NSLOT-1];
    reg        cvalid [0:NSLOT-1];
    integer n;
    initial for (n = 0; n < NSLOT; n = n + 1) begin gen[n] = 16'd0; cvalid[n] = 1'b0; end
    localparam [2:0] M_DEC = 3'd0, M_WADR = 3'd1, M_WBEAT = 3'd2, M_RREQ = 3'd3, M_GAP = 3'd4, M_STOP = 3'd5;
    reg [2:0]  m_st = M_DEC;
    reg [4:0]  m_slot = 5'd0;
    reg [5:0]  m_beat = 6'd0;
    reg [15:0] m_gen = 16'd0;
    reg [7:0]  m_gapc = 8'd0;
    reg [1:0]  m_pause = 2'd0;
    reg [31:0] mlfsr = 32'hACE1_2345;
    reg [31:0] ccyc = 32'd0;
    integer    c_wops = 0, c_rops = 0, c_rv = 0, c_err = 0, c_extra = 0, c_stall = 0;
    reg [4:0]  rq_slot [0:3];
    reg [1:0]  rq_wp = 2'd0, rq_rp = 2'd0;
    reg [2:0]  rq_n = 3'd0;
    reg [5:0]  rq_beat = 6'd0;
    always @(posedge clk) begin
        ccyc  <= ccyc + 32'd1;
        mlfsr <= {mlfsr[30:0], mlfsr[31] ^ mlfsr[21] ^ mlfsr[1] ^ mlfsr[0]};
        case (m_st)
        M_DEC: if (resetn && !busy) begin
            if (ending) m_st <= M_STOP;
            else if (mlfsr[0] || !cvalid[mlfsr[12:8]]) begin m_slot <= mlfsr[12:8]; m_st <= M_WADR; end
            else begin m_slot <= mlfsr[12:8]; m_st <= M_RREQ; end
        end
        M_WADR: begin
            avl_address   <= slot_addr(m_slot) >> 3;
            m_gen         <= gen[m_slot] + 16'd1;
            avl_writedata <= cpat(gen[m_slot] + 16'd1, m_slot, 5'd0);
            m_beat        <= 6'd0;
            m_st          <= M_WBEAT;
        end
        M_WBEAT: if (m_pause != 2'd0) begin
            m_pause <= m_pause - 2'd1;
            if (m_pause == 2'd1) avl_write <= 1'b1;
        end else begin
            avl_write <= 1'b1;
            if (avl_write && !avl_waitrequest) begin
                cshadow[{m_slot, m_beat[4:0]}] <= avl_writedata;
                if (m_beat == BLEN - 1) begin
                    avl_write <= 1'b0;  gen[m_slot] <= m_gen;  cvalid[m_slot] <= 1'b1;  c_wops = c_wops + 1;
                    m_gapc <= mlfsr[17:16] == 2'd0 ? 8'd0 : {2'd0, mlfsr[23:18]};
                    m_st <= M_GAP;
                end
`ifdef MASTER_STALLS
                else if (mlfsr[25:24] == 2'd0) begin
                    avl_write <= 1'b0;  m_pause <= {1'b0, mlfsr[26]} + 2'd1;  c_stall = c_stall + 1;
                end
`endif
                m_beat <= m_beat + 6'd1;
                avl_writedata <= cpat(m_gen, m_slot, m_beat[4:0] + 5'd1);
            end
        end
        M_RREQ: begin
            avl_address <= slot_addr(m_slot) >> 3;
            avl_read    <= 1'b1;
            if (avl_read && !avl_waitrequest) begin
                avl_read <= 1'b0;
                rq_slot[rq_wp] <= m_slot;  rq_wp <= rq_wp + 2'd1;  c_rops = c_rops + 1;
                m_gapc <= mlfsr[17:16] == 2'd0 ? 8'd0 : {2'd0, mlfsr[23:18]};
                m_st <= M_GAP;
            end
        end
        M_GAP: if (m_gapc == 8'd0) m_st <= M_DEC; else m_gapc <= m_gapc - 8'd1;
        M_STOP: ;
        default: m_st <= M_DEC;
        endcase
        // queue depth (a read is queued on the edge that accepts it)
        if (m_st == M_RREQ && avl_read && !avl_waitrequest) begin
            if (!(avl_readdatavalid && rq_beat == BLEN - 1)) rq_n <= rq_n + 3'd1;
        end else if (avl_readdatavalid && rq_beat == BLEN - 1) rq_n <= rq_n - 3'd1;
        if (avl_readdatavalid) begin
            c_rv = c_rv + 1;
            if (rq_n == 3'd0) c_extra = c_extra + 1;
            else begin
                if (avl_readdata !== cshadow[{rq_slot[rq_rp], rq_beat[4:0]}]) begin
                    if (c_err < 5) $display("TB C t=%0t slot %0d beat %0d got %016x want %016x", $time, rq_slot[rq_rp],
                                            rq_beat, avl_readdata, cshadow[{rq_slot[rq_rp], rq_beat[4:0]}]);
                    c_err = c_err + 1;
                end
                if (rq_beat == BLEN - 1) begin rq_beat <= 6'd0;  rq_rp <= rq_rp + 2'd1; end
                else rq_beat <= rq_beat + 6'd1;
            end
        end
    end

`ifdef DBG_AB
    integer dbgn = 0;
    always @(posedge clk) if (!busy && started && dbgn < 120) begin
        dbgn = dbgn + 1;
        $display("DBG t=%0t cap%0d reqA%0d reqB%0d ab i%0d a%0d rw%0d p%0d we%0d port%0d bank%0d pa%0d pb%0d g=%b bk_open=%b bk_ok=%b rf%0d%0d c i%0d a%0d r%0d",
                 $time, u_sdram.cap, u_sdram.reqA, u_sdram.reqB, u_sdram.ab_i, u_sdram.ab_a, u_sdram.ab_rw, u_sdram.ab_p,
                 u_sdram.ab_we, u_sdram.ab_port, u_sdram.ab_bank, u_sdram.pa_v, u_sdram.pb_v, u_sdram.g, u_sdram.bk_open,
                 u_sdram.bk_ok, u_sdram.rf_p, u_sdram.rf_r, u_sdram.c_i, u_sdram.c_a, u_sdram.c_r);
    end
`endif
`ifdef DBG_C
    always #(5000.0) if (!busy)
        $display("DBG t=%0t c_i%0d c_a%0d c_r%0d rd%0d wq_n=%0d wleft=%0d bleft=%0d rleft=%0d wreq=%0d avl_w=%0d avl_r=%0d m_st=%0d ab i%0d a%0d rw%0d p%0d pa%0d pb%0d rf %0d%0d due=%0d bk_open=%b bk_ok=%b g=%b",
                 $time, u_sdram.c_i, u_sdram.c_a, u_sdram.c_r, u_sdram.c_rd, u_sdram.wq_n, u_sdram.c_wleft, u_sdram.c_bleft,
                 u_sdram.c_rleft, avl_waitrequest, avl_write, avl_read, m_st, u_sdram.ab_i, u_sdram.ab_a, u_sdram.ab_rw,
                 u_sdram.ab_p, u_sdram.pa_v, u_sdram.pb_v, u_sdram.rf_p, u_sdram.rf_r, u_sdram.rf_due, u_sdram.bk_open,
                 u_sdram.bk_ok, u_sdram.g);
`endif
    // ================================================================ end
    real t_busy_end = 0.0;
    always @(negedge busy) t_busy_end = $realtime;
    initial begin
        #(1000.0 * run_us);
        ending = 1'b1;
        #(20000.0);                                   // let the last requests, bursts and checks finish
        begin : report
            integer aref_need, sfail, overrun, lost, row_err;
            real    span;
            span      = $realtime - t_busy_end;
            aref_need = $rtoi(span / 7812.5) - 2;
`ifdef OLD_IF
            overrun = 0;  lost = 0;  row_err = 0;
`else
            overrun = u_sdram.ab_overrun;  lost = slot_lost;  row_err = u_sdram.c_err_row;
`endif
            $display("TB A: reads %0d writes %0d | B: reads %0d writes %0d | A+B same slot %0d", n_a, n_aw, n_b, n_bw, n_ab);
`ifndef OLD_IF
            $display("TB A/B at the controller's update: A errors %0d (%0d of %0d checked), B errors %0d (%0d of %0d)",
                     err_upd_a, qa_r, qa_w, err_upd_b, qb_r, qb_w);
            $display("TB min slack (deadline = NES sample edge - %0.0f ns doutX path): A %0.1f ns, B %0.1f ns",
                     OUT_MARGIN, slack_a, slack_b);
            $display("TB latency (slot capture -> doutX, clk): A %0d..%0d, B %0d..%0d (%0d / %0d reads); from the dot boundary (ns): A %0.1f..%0.1f, B %0.1f..%0.1f",
                     lat_a_min, lat_a_max, lat_b_min, lat_b_max, ca_r, cb_r, e0_a_min, e0_a_max, e0_b_min, e0_b_max);
            if (ca_r != qa_r || cb_r != qb_r || ca_w != ca_r || cb_w != cb_r)
                $display("TB latency: capture / update counts disagree (A %0d %0d %0d, B %0d %0d %0d)", ca_w, ca_r, qa_r, cb_w, cb_r, qb_r);
`endif
            $display("TB A/B at the NES sample edge (mode 0): A misses %0d, B misses %0d", err_smp_a, err_smp_b);
            $display("TB C: write bursts %0d, read bursts %0d, read beats %0d, data errors %0d, extra beats %0d, reads outstanding %0d, stalls %0d",
                     c_wops, c_rops, c_rv, c_err, c_extra, rq_n, c_stall);
            $display("TB model: errors=%0d aref=%0d (need >= %0d) act=%0d rd=%0d wr=%0d masked_words=%0d max_refresh_gap=%0d interrupted_reads=%0d",
                     m_errors, m_aref, aref_need, m_act, m_rd, m_wr, m_masked, m_gap, u_mem.n_rd_int);
            $display("TB flags: ab_overrun=%0d slot_lost=%0d c_row_cross=%0d", overrun, lost, row_err);
            sfail = 0;
            if (err_upd_a != 0 || err_upd_b != 0 || err_smp_a != 0 || err_smp_b != 0) sfail = 1;
`ifndef OLD_IF
            if (qa_r != qa_w || qb_r != qb_w) sfail = 1;
`endif
            if (c_err != 0 || c_extra != 0 || rq_n != 0 || c_wops == 0 || c_rops == 0) sfail = 1;
            if (m_errors != 0 || m_masked != 0 || m_gap > 1500 || m_aref < aref_need) sfail = 1;
            if (overrun != 0 || lost != 0 || row_err != 0) sfail = 1;
`ifndef OLD_IF
            $display("TB invariants: %0d violations", err_inv);
            if (err_inv != 0) sfail = 1;
`endif
            if (n_a == 0 || n_b == 0) sfail = 1;
            $display("TB_RESULT %s", sfail ? "FAIL" : "PASS");
        end
        $finish;
    end
endmodule
`default_nettype wire
