// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
//==============================================================================
// sdram_w9825_model -- W9825G6KH (4 banks x 8192 rows x 512 columns x 16 bits) cycle model for the
// tango_sdram unit sims.  Rules from the Winbond W9825G6KH datasheet (Rev. A03, 2016-06-01), by section:
//   - commands, address, DQM and write data are sampled on the rising clock.  The model runs on the
//     controller's clock, so it samples what the controller registered on the previous edge; on silicon
//     SDRAM_CLK lags the fabric clock by 320 degrees (its edge lands just before the next fabric edge),
//     the same ordering.
//   - CAS latency / burst (7.5, 7.12): word i of a READ sampled at edge n is sampled by the controller at
//     edge n+CL+i (the model drives it after edge n+CL+i-1).  Sequential burst within BL.
//   - 7.7 Read interrupted by a Read: legal; the new burst's words replace the old ones from n+CL on; the old
//     burst's words before n+CL are still driven.
//   - 7.8 Read interrupted by a Write: the read words due on the WRITE's clock and the next one must be masked
//     by DQM (else contention); later words of the read are not output.
//   - 11.20 Burst stop by PRECHARGE: a PRECHARGE (the burst's bank, or all) sampled at p ends the read burst
//     after the word sampled at p+CL-1.
//   - DQM (pin description LDQM/UDQM): read mask latency 2 (a word sampled at edge e is driven only if DQM was
//     low at edge e-2); write mask latency 0.
//   - 7.1 Power Up: 8 AUTO REFRESH and a MODE REGISTER SET before the first ACTIVE.
//   - 7.3 ACTIVE to an open bank; READ/WRITE to an idle bank; AUTO REFRESH / MRS with a bank open (8, Table 1).
//   - 9.5 tRCD, tRP, tRC (ACTIVE->ACTIVE, AUTO REFRESH->ACTIVE/AUTO REFRESH), tRAS (ACTIVE->PRECHARGE, also
//     to the start of an auto-precharge: 7.14, 11.15, 11.16), tRRD (ACTIVE->ACTIVE other bank), tWR.
//   - 7.14 Auto-precharge: READ with auto-precharge starts precharging BL clocks after the READ (11.15),
//     WRITE with auto-precharge tWR after the write (11.16); the bank is free tRP later (tDAL for writes);
//     no READ, WRITE or PRECHARGE while a READ with auto-precharge burst runs.
//   - bus: contention (both sides drive DQ in one clock), and turnaround: the controller may not drive in the
//     clock right after one in which the SDRAM drove (tOH 3 ns + tHZ 5 ns, 9.5, run past the next edge on the
//     board: SDRAM_CLK leads the fabric clock by 40 degrees).
//   - refresh interval: MAX_RFSH_GAP clocks between AUTO REFRESHes once running (64 ms / 8192 x 2).
// A masked or undriven read word leaves dq_mem_oe low (the bus is undriven; Verilator reads it as 0).
// Every violation increments `errors`; the first 20 are printed.
//==============================================================================
`default_nettype none
module sdram_w9825_model #(
    parameter integer T_RCD = 2,          // 15 ns at 96 MHz
    parameter integer T_RP  = 2,          // 15 ns
    parameter integer T_RC  = 6,          // 60 ns
    parameter integer T_RFC = 6,          // tRC (AUTO REFRESH period)
    parameter integer T_WR  = 2,
    parameter integer T_RAS = 5,          // 42 ns
    parameter integer T_RRD = 2,
    parameter integer MAX_RFSH_GAP = 1500 // 2 x (64 ms / 8192 at 96 MHz)
) (
    input  wire        clk,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    input  wire        dqml, dqmh,
    input  wire        ncs, nras, ncas, nwe,
    input  wire [15:0] dq_ctrl,       // the controller's DQ output value
    input  wire        dq_ctrl_oe,    // the controller drives DQ
    output reg  [15:0] dq_mem = 16'd0,
    output reg         dq_mem_oe = 1'b0,
    output reg  [31:0] errors = 32'd0,
    output reg  [31:0] n_aref = 32'd0,
    output reg  [31:0] n_act  = 32'd0,
    output reg  [31:0] n_rd   = 32'd0,
    output reg  [31:0] n_wr   = 32'd0,
    output reg  [31:0] n_masked = 32'd0,   // burst words the DQM mask kept off the bus
    output reg  [31:0] max_rfsh_gap = 32'd0
);
    reg [15:0] mem [0:(1<<24)-1];                 // {bank, row, column}
    reg        act   [0:3];
    reg [12:0] row   [0:3];
    reg [31:0] t_act [0:3];                       // edge of the last ACTIVE
    reg [31:0] t_pre [0:3];                       // edge the last precharge started
    reg [31:0] t_wr  [0:3];                       // edge of the last WRITE
    reg        ever_act [0:3];
    reg [31:0] cyc = 32'd0;
    reg [2:0]  cl = 3'd0;
    reg [3:0]  bl = 4'd0;
    reg        wb_single = 1'b0;
    reg        mrs_done = 1'b0;
    reg [31:0] t_aref = 32'd0, n_aref_pre = 32'd0;
    reg        aref_seen = 1'b0;
    reg [31:0] t_act_any = 32'd0;  reg act_seen = 1'b0;
    reg [31:0] ap_until = 32'd0;   reg ap_on = 1'b0;   // a READ with auto-precharge burst runs until ap_until
    reg [1:0]  dqm_d1 = 2'b11;                    // DQM sampled at the previous edge
    reg        mem_oe_d = 1'b0;                   // the model drove DQ in the previous clock
    reg [31:0] n_rd_int = 32'd0;                  // READs that interrupted a running burst (7.7), for the report
    // scheduled read words, by the edge the controller samples them (mod 16): {bank, row, column}
    reg        sq_v [0:15];
    reg [23:0] sq_a [0:15];

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            act[i] = 1'b0; row[i] = 13'd0; t_act[i] = 32'd0; t_pre[i] = 32'd0; t_wr[i] = 32'd0; ever_act[i] = 1'b0;
        end
        for (i = 0; i < 16; i = i + 1) begin sq_v[i] = 1'b0; sq_a[i] = 24'd0; end
    end

    task err(input [8*72-1:0] msg);
        begin
            if (errors < 32'd20) $display("[sdram] cycle %0d: %0s", cyc, msg);
            errors = errors + 32'd1;
        end
    endtask

    wire [3:0] cmd = {ncs, nras, ncas, nwe};
    localparam [3:0] C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100, C_PRE = 4'b0010,
                     C_AREF = 4'b0001, C_MRS = 4'b0000, C_BST = 4'b0110;

    always @(posedge clk) begin : model
        reg [23:0] wa;
        reg        all_idle, drove_next, any_later;
        reg [3:0]  ix;
        reg [31:0] e;
        integer    k;
        cyc <= cyc + 32'd1;

        // ---- bus: contention in the clock that ends here, and turnaround after the model's last word
        if (dq_mem_oe && dq_ctrl_oe) err("bus contention: controller and SDRAM drive DQ");
        if (dq_ctrl_oe && mem_oe_d)   err("no turnaround clock between read data and the controller driving DQ");
        mem_oe_d <= dq_mem_oe;

        // ---- the read word the controller samples at the next edge (DQM latency 2: DQM of the previous edge)
        ix = cyc[3:0] + 4'd1;
        dq_mem_oe <= 1'b0;
        drove_next = 1'b0;
        if (sq_v[ix]) begin
            if (dqm_d1 == 2'b00) begin
                dq_mem <= mem[sq_a[ix]];  dq_mem_oe <= 1'b1;  drove_next = 1'b1;
            end else begin
                n_masked <= n_masked + 32'd1;
                if (dqm_d1 != 2'b11) err("partial DQM on a read word (not modelled)");
            end
            sq_v[ix] = 1'b0;
        end
        dqm_d1 <= {dqmh, dqml};

        // 7.14: nothing but NOP / ACTIVE / AUTO REFRESH while a READ with auto-precharge burst runs
        if (ap_on && cyc > ap_until) ap_on <= 1'b0;
        if (ap_on && cyc <= ap_until && (cmd == C_RD || cmd == C_WR || cmd == C_PRE))
            err("7.14: READ/WRITE/PRECHARGE during a READ with auto-precharge burst");

        all_idle = !act[0] && !act[1] && !act[2] && !act[3];
        case (cmd)
        C_ACT: begin
            n_act <= n_act + 32'd1;
            if (!mrs_done) err("ACTIVE before MODE REGISTER SET");
            if (n_aref_pre < 32'd8) err("ACTIVE before 8 AUTO REFRESH (7.1)");
            if (act[ba]) err("ACTIVE to an open bank");
            if (cyc < t_pre[ba] + T_RP) err("tRP: ACTIVE too soon after precharge");
            if (ever_act[ba] && cyc < t_act[ba] + T_RC) err("tRC: ACTIVE too soon after ACTIVE");
            if (aref_seen && cyc < t_aref + T_RFC) err("tRFC: ACTIVE too soon after AUTO REFRESH");
            if (act_seen && cyc < t_act_any + T_RRD) err("tRRD: ACTIVE too soon after an ACTIVE");
            act[ba] <= 1'b1;  row[ba] <= a;  t_act[ba] <= cyc;  ever_act[ba] <= 1'b1;
            t_act_any <= cyc;  act_seen <= 1'b1;
        end
        C_RD: begin
            n_rd <= n_rd + 32'd1;
            if (!act[ba]) err("READ to an idle bank");
            if (cyc < t_act[ba] + T_RCD) err("tRCD: READ too soon after ACTIVE");
            // 7.7: a running burst is interrupted from n+CL on
            any_later = 1'b0;
            for (k = 1; k < 16; k = k + 1) begin
                e = cyc + k;
                if (sq_v[e[3:0]]) begin
                    any_later = 1'b1;
                    if (k >= cl) sq_v[e[3:0]] = 1'b0;
                end
            end
            if (any_later) n_rd_int <= n_rd_int + 32'd1;
            for (k = 0; k < 16; k = k + 1) if (k < bl) begin
                e = cyc + cl + k;
                sq_v[e[3:0]] = 1'b1;
                sq_a[e[3:0]] = {ba, row[ba], a[8:2], a[1:0] + k[1:0]};
            end
            if (a[10]) begin
                if (cyc + bl < t_act[ba] + T_RAS) err("tRAS: READ auto-precharge starts too soon after ACTIVE");
                act[ba] <= 1'b0;  t_pre[ba] <= cyc + {28'd0, bl};
                ap_on <= 1'b1;  ap_until <= cyc + {28'd0, bl} - 32'd1;
            end
        end
        C_WR: begin
            n_wr <= n_wr + 32'd1;
            if (!act[ba]) err("WRITE to an idle bank");
            if (cyc < t_act[ba] + T_RCD) err("tRCD: WRITE too soon after ACTIVE");
            if (!wb_single) err("burst write mode (not modelled)");
            if (!dq_ctrl_oe) err("WRITE with DQ not driven");
            // 7.8: the read word on the WRITE's second clock must be masked; later read words are cut
            if (drove_next) err("7.8: read data not masked by DQM on the WRITE's second clock");
            for (k = 2; k < 16; k = k + 1) begin e = cyc + k; sq_v[e[3:0]] = 1'b0; end
            wa = {ba, row[ba], a[8:0]};
            if (!dqml) mem[wa][7:0]  <= dq_ctrl[7:0];
            if (!dqmh) mem[wa][15:8] <= dq_ctrl[15:8];
            t_wr[ba] <= cyc;
            if (a[10]) begin
                if (cyc + T_WR < t_act[ba] + T_RAS) err("tRAS: WRITE auto-precharge starts too soon after ACTIVE");
                act[ba] <= 1'b0;  t_pre[ba] <= cyc + T_WR;
            end
        end
        C_PRE: begin
            for (i = 0; i < 4; i = i + 1) if (a[10] || ba == i) begin
                if (act[i] && cyc < t_wr[i] + T_WR) err("tWR: PRECHARGE too soon after WRITE");
                if (act[i] && cyc < t_act[i] + T_RAS) err("tRAS: PRECHARGE too soon after ACTIVE");
                act[i] <= 1'b0;  t_pre[i] <= cyc;
                // 11.20: this bank's read words after p+CL-1 are not output
                for (k = 0; k < 16; k = k + 1) begin
                    e = cyc + k;
                    if (k >= cl && sq_v[e[3:0]] && sq_a[e[3:0]][23:22] == i[1:0]) sq_v[e[3:0]] = 1'b0;
                end
            end
        end
        C_AREF: begin
            n_aref <= n_aref + 32'd1;
            if (!all_idle) err("AUTO REFRESH with a bank open");
            for (i = 0; i < 4; i = i + 1)
                if (cyc < t_pre[i] + T_RP) err("tRP: AUTO REFRESH too soon after precharge");
            if (aref_seen && cyc < t_aref + T_RFC) err("tRFC: AUTO REFRESH too soon after AUTO REFRESH");
            if (mrs_done && n_act != 32'd0 && cyc - t_aref > max_rfsh_gap) max_rfsh_gap <= cyc - t_aref;
            if (n_act == 32'd0) n_aref_pre <= n_aref_pre + 32'd1;
            t_aref <= cyc;  aref_seen <= 1'b1;
        end
        C_MRS: begin
            if (!all_idle) err("MODE REGISTER SET with a bank open");
            cl <= a[6:4];
            case (a[2:0]) 3'b000: bl <= 4'd1; 3'b001: bl <= 4'd2; 3'b010: bl <= 4'd4; default: bl <= 4'd8; endcase
            wb_single <= a[9];
            mrs_done <= 1'b1;
        end
        C_BST: err("BURST STOP (not modelled)");
        default: ;                                  // NOP / DESELECT
        endcase

        if (mrs_done && aref_seen && cyc - t_aref == MAX_RFSH_GAP) err("refresh starved");
    end
endmodule
`default_nettype wire
