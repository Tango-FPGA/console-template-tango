// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 the Tango authors
// Contains Template_MiSTer text and arithmetic (GPL-2.0-or-later): the CONF_STR entries of its Template.sv and the
// picture lines that follow its rtl/mycore.v and rtl/lfsr.v; and the "Stereo Mix" entry of MegaDrive_MiSTer's
// MegaDrive.sv (GPL-2.0-or-later).  NOTICE lists each with its source lines.
//==============================================================================
// tango_core (Template) -- the Tango template core: Template_MiSTer's picture and menu on the Tango
// framework (the picture is MiSTer's TV static, as in Template_MiSTer).  Behaviour read from
// Template_MiSTer (19e89ce) Template.sv 58-87 (CONF_STR) and 122-167, rtl/mycore.v, rtl/lfsr.v,
// rtl/cos.sv; the lines that follow mycore.v and lfsr.v: NOTICE.  Bit-exact model: tools/template_model.py.
//
// Picture: TV static.  A 63-bit LFSR (mycore/lfsr.v's taps, but clocked: MiSTer's free-running lcell
// ring could not be followed by a golden) gives rnd_c = {r0, r1, r2, r2, r2, r2}; a cosine wave that
// rolls down the screen gives cos_g = cos(vvc + 4 * line)[7:3] + 32; video = cos_g - rnd_c (x4), or 0.
// Bare mode (default): 320 x 240 "core pixels" scaled to 720p: 3 lines each, 4 px wide (Aspect ratio Full
//   Screen / 16:9) or 3 px wide with black bars (Original / 4:3).  VID_RGB is the pixel for (VID_CX, VID_CY)
//   two clocks earlier.
// ASCAL mode (TANGO_VIDEO_ASCAL): a native frame of the chosen source size (below; default 320 x 240: 400
//   pixels/line, 262 lines, CE_PIXEL every 12th CLK_PIX clock -> 6.1875 MHz pixels, 59.0 Hz), CLK_VIDEO =
//   CLK_PIX, CE_PIXEL pulsing through the blanking.  Outputs a test pattern (below; 0 Gradient: R = x,
//   G = y, B = 0x80) with a joystick-movable white square, proving the ASCAL + SDRAM path; ascal outputs
//   720p60.  The ioctl strip is also displayed at the bottom of the native image.
// Options (CONF_STR below: Template.sv's without its Noise entry, with the framework's Video entries in place of
// its Aspect ratio, plus Pattern, Source size and a J line; status bits as Template.sv where it has the entry):
//   `TANGO_VIDEO_CONF  the framework's Video entries (sys/tango_video_opts.vh; the ASCAL build opts in with
//              TANGO_VIDEO_OPTS=1): O[127:126] Aspect ratio Original / Full Screen / 4:3 / 16:9, O[125:124] Scale
//              Normal / V-Integer / Narrower HV-Integer / Wider HV-Integer, O[123:122] Scanlines None / 25% / 50% /
//              75%, all applied in sys/tango_video.v.  ASCAL: the core gives only its native shape,
//              VIDEO_ARX/ARY = 4:3 ("Original") for every source size, and VIDEO_SCALE = VGA_SL = 0.  Bare (no
//              scaler): the core reads the Aspect ratio itself and draws Original / 4:3 at 960 px, Full Screen /
//              16:9 at 1280; Scale and Scanlines have no effect.  (Template_MiSTer's own "O[122:121],Aspect ratio"
//              lies in the framework's bits: it is the entry the framework's replaces.)
//   O[2]       TV Mode NTSC / PAL: sets the wave roll speed (bare mode) / unused (ASCAL).
//   O[44:41]   Pattern (ASCAL): the test pattern, 0 Gradient, 1 Pixel grid (below).  Not in Template_MiSTer:
//              a Tango test aid.  Bare: no effect (the static is the picture).
//   O[47:45]   Source size (ASCAL): the native frame, 320x240 / 256x240 NES / 256x224 SNES / 384x224 CPS /
//              160x144 GB (the table below), so the Scale modes meet sources that do not fit 720p by an
//              integer.  VIDEO_ARX/ARY stay 4:3 for every size (the framework's Aspect ratio and Scale apply to
//              each).  Not in Template_MiSTer: a Tango test aid.  Bare: no effect.
//   status[4:3] the noise colour (bare mode): 0 White, 1 Red, 2 Green, 3 Blue / unused (ASCAL).  Not in
//              the menu (Template.sv's O[4:3] Noise entry is left out, as it does nothing
//              in the ASCAL build), so the noise stays White; the other options keep their bits.
//   O[50:48]   Audio test: Off / 1 kHz square / 440 Hz square / Sweep / Noise / 440 Hz left on AUDIO_L and AUDIO_R (both modes;
//              below).  Not in Template_MiSTer (its AUDIO is 0): a Tango test aid, so the framework's audio filter
//              (sys TANGO_AUDIO_FILTER, sys-tango README "Build options") can be heard and measured.
//   O[5], O[10], O[7:6], S0: as in Template_MiSTer; do nothing in the picture.
//   T[0] / R[0] status[0]: reset -- clears vvc (bare mode).
//   J,A,B      the pad's button names for the firmware's Define buttons: A = joystick_0[4], B = joystick_0[5]
//              (sys/tango_core_ports.vh joystick_0; the power-up map is A <- circle, B <- cross,
//              sys/tango_link.v default_padmap).  Not in Template_MiSTer (it has no J line): Tango addition.
// Test aids (not in MiSTer's template):
//   a 24 x 24 white square moved 4 px per frame by joystick_0's d-pad (proves the pads);
//   after an F1 (index 1) download, the file's first 32 bytes as grey cells at the bottom
//   (proves ioctl).  ioctl_wait is held for 3 clocks after every byte, to exercise the wait path.
//   Test patterns (ASCAL mode; a library the Template keeps and adds to): pattern() below,
//   one case per pattern, a function of the native x, y, the active size w x h and the frame number;
//   tools/template_patterns.py has the same functions at the same index, and CONF_STR's Pattern entry
//   names them in that order:
//     0 Gradient    R = x, G = y, B = 0x80 -- the colour path and where the picture lands (corners, edges);
//     1 Pixel grid  1-px white/black columns (the top third of the lines: 3y < h), rows (the middle third:
//                   3y < 2h) and a checkerboard (the rest); at 320 x 240: lines 0-79, 80-159, 160-239 -- every
//                   stripe is k output pixels at an integer scale; a non-integer scale makes them uneven.
//   Audio test: audio_test() below, one case per signal, on CLK_PIX (the clock AUDIO_L/R are in,
//     sys/tango_core_ports.vh), signed, +-8192 (-12 dBFS); tools/template_audio.py is the model:
//       1 1 kHz square   the level flips every 37125 clocks (74.25 MHz / 2 kHz, exact)
//       2 440 Hz square  every 84375 clocks (74.25 MHz / 880 Hz, exact): its harmonics alias at 48 kHz, 1 kHz's do not
//       3 Sweep          a square from a 32-bit phase accumulator: increment 2893 (50.0 Hz) + 190 every 65536 clocks,
//                        back to the start after 4552 steps (4.02 s, 14.97 kHz at the end)
//       4 Noise          a 16-bit LFSR (x^16 + x^14 + x^13 + x^11 + 1) stepped every 64 clocks, its top bit -> +-8192
//       5 440 Hz left    the 440 Hz square on AUDIO_L only, AUDIO_R silent (the framework's Stereo Mix test)
//     Off, or any other value: 0.  The generator runs from RESET; the selection applies at once.
//   O[52:51] Stereo Mix (MegaDrive_MiSTer's entry, MegaDrive.sv "P1O[58:57],Stereo Mix,..."): AUDIO_MIX, which the
//     framework's audio filter applies as MiSTer's audio_out.sv (None / 25% / 50% / 100% = mono); only in builds with
//     the framework's audio filter (TANGO_AUDIO_FILTER / TANGO_VIDEO_PROC: tango_core_ports.vh AUDIO_MIX).
//   Source sizes (ASCAL mode): size_tab() below, one row per size (active size, totals, CE
//     divider: about 60 Hz each); template_patterns.py SIZES mirrors it.  The size is taken at the native frame
//     end, so an OSD change re-times the next frame without a reset; the square goes back to the middle.
//   The pattern shown follows the OSD's Pattern when status[44:41] changes (a value with no pattern shows
//   Gradient); otherwise joystick_0 A steps to the next pattern and B to the previous one, one step per press,
//   wrapping.  Both apply at the native frame end, as the square does.  The framework cannot write the option
//   word back, so after A / B the OSD still shows its own last choice.  README: "Adding a test pattern".
//==============================================================================
`default_nettype none
module tango_core (
    `include "tango_core_ports.vh"
);
    `include "template_cos.vh"
    assign CLK_SYS = CLK_PIX;
    wire clk = CLK_PIX;

    localparam CONF_STR = {
        "Template;;",
        "-;",
        `TANGO_VIDEO_CONF,                  // the framework's Aspect ratio, Scale, Scanlines (header)
        "O[2],TV Mode,NTSC,PAL;",
        "O[44:41],Pattern,Gradient,Pixel grid;",
        "O[47:45],Source size,320x240,256x240 NES,256x224 SNES,384x224 CPS,160x144 GB;",
        "O[50:48],Audio test,Off,1 kHz square,440 Hz square,Sweep,Noise,440 Hz left;",
        "O[52:51],Stereo Mix,None,25%,50%,100%;",
        "-;",
        "P1,Test Page 1;",
        "P1-;",
        "P1-, -= Options in page 1 =-;",
        "P1-;",
        "P1O[5],Option 1-1,Off,On;",
        "d0P1F1,BIN;",
        "H0P1O[10],Option 1-2,Off,On;",
        "-;",
        "P2,Test Page 2;",
        "P2-;",
        "P2-, -= Options in page 2 =-;",
        "P2-;",
        "P2S0,DSK;",
        "P2O[7:6],Option 2,1,2,3,4;",
        "-;",
        "-;",
        "T[0],Reset;",
        "R[0],Reset and close OSD;",
        "J,A,B;",
        "v,1;",                             // config version 1: the Video options moved bits (a new v,N resets the saved options)
        "V,",`BUILD_DATE
    };
    tango_conf_rom #(.CONF_STR(CONF_STR)) u_conf (.clk(CLK_PIX), .addr(conf_addr), .q(conf_char));
    assign status_menumask = {15'd0, status[5]};

    // ---- the audio test (header "Audio test"): one signal per value of status[50:48], on CLK_PIX; at_* names (the
    //      bare build's picture below has its own sq1, v1, ...)
    reg  [16:0] at_c1k = 17'd0, at_c440 = 17'd0;        // half-period counters, 1 kHz and 440 Hz
    reg         at_l1k = 1'b0, at_l440 = 1'b0;
    reg  [31:0] at_swph = 32'd0, at_swinc = 32'd2893;  // sweep: phase, increment
    reg  [15:0] at_swdiv = 16'd0;  reg [12:0] at_swn = 13'd0;
    reg  [15:0] at_lfsr = 16'hACE1;  reg [5:0] at_nzdiv = 6'd0;
    always @(posedge clk) begin
        if (RESET) begin
            at_c1k <= 17'd0; at_c440 <= 17'd0; at_l1k <= 1'b0; at_l440 <= 1'b0;
            at_swph <= 32'd0; at_swinc <= 32'd2893; at_swdiv <= 16'd0; at_swn <= 13'd0;
            at_lfsr <= 16'hACE1; at_nzdiv <= 6'd0;
        end else begin
            if (at_c1k == 17'd37124) begin at_c1k <= 17'd0; at_l1k <= ~at_l1k; end else at_c1k <= at_c1k + 17'd1;
            if (at_c440 == 17'd84374) begin at_c440 <= 17'd0; at_l440 <= ~at_l440; end else at_c440 <= at_c440 + 17'd1;
            at_swph <= at_swph + at_swinc;
            at_swdiv <= at_swdiv + 16'd1;
            if (at_swdiv == 16'hFFFF) begin
                if (at_swn == 13'd4551) begin at_swn <= 13'd0; at_swinc <= 32'd2893; end
                else begin at_swn <= at_swn + 13'd1; at_swinc <= at_swinc + 32'd190; end
            end
            at_nzdiv <= at_nzdiv + 6'd1;
            if (at_nzdiv == 6'd63) at_lfsr <= {at_lfsr[14:0], at_lfsr[15] ^ at_lfsr[13] ^ at_lfsr[12] ^ at_lfsr[10]};
        end
    end
    function automatic [15:0] audio_test(input [2:0] sel, input l1, input l4, input sw, input nz);
        case (sel)
        3'd1:    audio_test = l1 ? 16'h2000 : 16'hE000;   // +-8192
        3'd2:    audio_test = l4 ? 16'h2000 : 16'hE000;
        3'd3:    audio_test = sw ? 16'h2000 : 16'hE000;
        3'd4:    audio_test = nz ? 16'h2000 : 16'hE000;
        default: audio_test = 16'h0000;
        endcase
    endfunction
    reg [15:0] at_out = 16'd0;
    reg  at_left = 1'b0;                                 // value 5: the 440 Hz square on the left only
    always @(posedge clk) begin
        at_out <= audio_test((status[50:48] == 3'd5) ? 3'd2 : status[50:48], at_l1k, at_l440, at_swph[31], at_lfsr[15]);
        at_left <= (status[50:48] == 3'd5);
    end
    assign AUDIO_L = at_out;  assign AUDIO_R = at_left ? 16'd0 : at_out;
`ifdef TANGO_CORE_AUDIO_MIX
    assign AUDIO_MIX = status[52:51];
`endif

    wire        reset = RESET | status[0];

    // ---- ioctl: shared -- store the first 32 bytes from an F1 download
    reg [7:0] strip [0:31];
    reg       loaded = 1'b0, dl_q = 1'b0;
    reg [1:0] waitc = 2'd0;
    wire      dl_mine = (ioctl_index[5:0] == 6'd1);
    always @(posedge clk) begin
        dl_q <= ioctl_download;
        if (ioctl_download && dl_mine && ioctl_wr && ioctl_addr < 27'd32) strip[ioctl_addr[4:0]] <= ioctl_dout;
        if (dl_q && !ioctl_download && dl_mine) loaded <= 1'b1;
        if (ioctl_wr) waitc <= 2'd3; else if (waitc != 2'd0) waitc <= waitc - 2'd1;
    end
    assign ioctl_wait = (waitc != 2'd0);

`ifdef TANGO_VIDEO_ASCAL
    // ======================================================================
    // ASCAL mode: the native frame of the chosen source size (size_tab below; default 320 x 240).
    // CLK_VIDEO = CLK_PIX, one pixel per CE_DIV clocks.  CE_PIXEL pulses through the blanking too
    // (sys/tango_core_ports.vh: the scaler samples VGA_HS / VGA_VS / VGA_DE only on CE).
    // ======================================================================
    // ascal writes every input frame to SDRAM, so the input rate must be a real core's: about 60 Hz.
    // (CE_PIXEL = 1 gave 708 Hz, whose writes alone exceed the SDRAM's bandwidth, and ascal serves writes
    // before reads.)
    // ---- the source sizes (header "Source sizes"): ONE TABLE, one row per size; tools/
    // template_patterns.py SIZES has the same rows at the same index and CONF_STR's Source size entry their names.
    //   #  name          active   total      CE_DIV  pixels       frames     like
    //   0  320x240       320x240  400 x 262  12      6.1875 MHz   59.04 Hz   the Template's own (as before)
    //   1  256x240 NES   256x240  341 x 262  14      5.3036 MHz   59.36 Hz   NES: 341 dots x 262 lines
    //   2  256x224 SNES  256x224  341 x 262  14      5.3036 MHz   59.36 Hz   SNES, Mega Drive H32: 224 lines
    //   3  384x224 CPS   384x224  525 x 262   9      8.25 MHz     59.98 Hz   Capcom CPS: 384 wide at 8 MHz
    //   4  160x144 GB    160x144  448 x 154  18      4.125 MHz    59.79 Hz   Game Boy: 144 of 154 lines
    // (pixels = 74.25 MHz / CE_DIV; frames = pixels / total.)  VS: lines NH .. NH+2; HS (ascal does not use
    // it): NW+10 .. NW+21; DE: x < NW and y < NH.
    localparam [2:0] NSIZE = 3'd5;                     // sizes 0 .. NSIZE-1 exist; any other value is 0
    function automatic [42:0] size_tab(input [2:0] s); // {NW[9:0], NH[8:0], FNW[9:0], FNH[8:0], CE_DIV[4:0]}
        case (s)
        3'd1:    size_tab = {10'd256, 9'd240, 10'd341, 9'd262, 5'd14};   // 256x240 NES
        3'd2:    size_tab = {10'd256, 9'd224, 10'd341, 9'd262, 5'd14};   // 256x224 SNES
        3'd3:    size_tab = {10'd384, 9'd224, 10'd525, 9'd262, 5'd9};    // 384x224 CPS
        3'd4:    size_tab = {10'd160, 9'd144, 10'd448, 9'd154, 5'd18};   // 160x144 GB
        default: size_tab = {10'd320, 9'd240, 10'd400, 9'd262, 5'd12};   // 0 320x240
        endcase
    endfunction

    // ---- the size in use: the OSD's Source size (status[47:45]; a value with no size is 0), taken at the native
    // frame end, at the CE clock where the CE counter restarts, so the next frame has the new timing from its
    // first pixel.  No reset: sys/tango_video.v measures every frame (its geometry follows), as ascal does.
    wire [2:0]  sz_osd  = status[47:45];
    wire [2:0]  sz_nxt  = (sz_osd < NSIZE) ? sz_osd : 3'd0;
    wire [42:0] tab_nxt = size_tab(sz_nxt);
    reg  [2:0]  sz = 3'd0;
    reg  [9:0]  nw = 10'd320, fnw = 10'd400;           // size_tab(0)
    reg  [8:0]  nh = 9'd240,  fnh = 9'd262;
    reg  [4:0]  cdiv = 5'd12;
    reg  [4:0]  ce_cnt = 5'd0;
    wire        ce = (ce_cnt == cdiv - 5'd1);
    always @(posedge clk) ce_cnt <= ce ? 5'd0 : ce_cnt + 5'd1;
    assign CLK_VIDEO      = CLK_PIX;
    assign CE_PIXEL       = ce;
    assign VGA_SL         = 2'd0;                           // the framework's Scanlines (TANGO_VIDEO_OPTS, header)
    assign VIDEO_ARX      = 13'd4;                          // the native shape, 4:3 whatever the size: the
    assign VIDEO_ARY      = 13'd3;                          // framework's Aspect ratio "Original" (header)
    assign HDMI_FREEZE    = 1'b0;
    assign VIDEO_SCALE    = 3'd0;                           // the framework's Scale (TANGO_VIDEO_OPTS, header)
    assign VIDEO_CROP_SIZE = 12'd0;
    assign VIDEO_CROP_OFF  = 5'd0;

    reg [9:0] nat_cx = 10'd0;  reg [8:0] nat_cy = 9'd0;
    wire nat_le = (nat_cx == fnw - 10'd1);
    wire nat_fe = nat_le && (nat_cy == fnh - 9'd1);
    // The beam advances on ce; the two pixel stages below run every clock and have settled long before
    // the next ce, which is when ascal samples VGA_*.
    always @(posedge clk) if (ce) begin
        if (nat_le) begin
            nat_cx <= 10'd0;
            nat_cy <= nat_fe ? 9'd0 : nat_cy + 9'd1;
        end else nat_cx <= nat_cx + 10'd1;
    end
    always @(posedge clk) if (ce && nat_fe) begin
        sz <= sz_nxt;
        {nw, nh, fnw, fnh, cdiv} <= tab_nxt;
    end
    wire nat_de = (nat_cx < nw) && (nat_cy < nh);

    assign VGA_DE = nat_de;
    assign VGA_VS = (nat_cy >= nh) && (nat_cy < nh + 9'd3);
    assign VGA_HS = (nat_cx >= nw + 10'd10) && (nat_cx < nw + 10'd22);   // in blanking (ascal does not use HS)

    // joystick square: 24 x 24 white, 4 native px per frame (native coords), inside the active area; a new
    // size puts it back in the middle ((NW-24)/2, (NH-24)/2: (148, 108) at 320 x 240)
    reg [8:0] sqx = 9'd148, sqy = 9'd108;
    wire jr = joystick_0[0], jl = joystick_0[1], jd = joystick_0[2], ju = joystick_0[3];
    always @(posedge clk) if (ce && nat_fe) begin
        if (sz_nxt != sz) begin
            sqx <= (tab_nxt[42:33] - 10'd24) >> 1;
            sqy <= (tab_nxt[32:24] - 9'd24) >> 1;
        end else begin
            if (jr && !jl) sqx <= ({1'b0, sqx} >= nw - 10'd28) ? nw - 10'd24 : sqx + 9'd4;
            if (jl && !jr) sqx <= (sqx <= 9'd4) ? 9'd0 : sqx - 9'd4;
            if (jd && !ju) sqy <= (sqy >= nh - 9'd28) ? nh - 9'd24 : sqy + 9'd4;
            if (ju && !jd) sqy <= (sqy <= 9'd4) ? 9'd0 : sqy - 9'd4;
        end
    end

    // ioctl strip: 32 cells × 8 px wide, 12 px tall, at bottom of native image (lines NH-15 .. NH-4)
    wire [9:0] stx = nat_cx - 10'd16;         // x relative to strip origin
    wire [4:0] sk  = stx[7:3];                // cell index (8 px wide cells)
    wire nat_in_strip = loaded && (nat_cy >= nh - 9'd15) && (nat_cy < nh - 9'd3) &&
                        (nat_cx >= 10'd16) && (nat_cx < 10'd272) && stx[2:0] < 3'd7;

    // ---- the test patterns (header "Test patterns"): pattern p's colour at native (x, y) of a w x h frame,
    // native frame number f.  ONE CASE PER PATTERN, nothing about a pattern anywhere else;
    // tools/template_patterns.py has the same function at the same index and CONF_STR's Pattern entry its
    // name.  Add a pattern: README "Adding a test pattern" (its case here, NPAT + 1, its Python function, its name
    // in CONF_STR, the sim gates).
    localparam [3:0] NPAT = 4'd2;                     // patterns 0 .. NPAT-1 exist; any other value shows 0
    function automatic [23:0] pattern(input [3:0] p, input [9:0] x, input [8:0] y, input [9:0] w, input [8:0] h,
                                      input [7:0] f);
        reg [10:0] y3;
        begin
            y3 = {2'b00, y} + {1'b0, y, 1'b0};        // 3y
            case (p)
            4'd1:    // Pixel grid: 1-px stripes, white on even and black on odd -- columns (3y < h), rows (3y < 2h),
                     // checkerboard (the rest)
                     pattern = {24{(y3 < {2'b00, h}) ? ~x[0] : (y3 < {1'b0, h, 1'b0}) ? ~y[0] : ~(x[0] ^ y[0])}};
            default: // 0 Gradient (and any value with no pattern): R = x, G = y, B = 0x80
                     pattern = {x[7:0], y[7:0], 8'h80};
            endcase
        end
    endfunction

    // ---- the pattern shown (header): the OSD's Pattern when status[44:41] changes, else A = next, B = previous
    // (joystick_0 bits 4 and 5, tango_core_ports.vh), one step per press, wrapping over 0 .. NPAT-1.  Sampled
    // at the native frame end, where the square moves; a press is seen if it spans one (17 ms).
    wire [3:0] pat_osd = status[44:41];
    wire       ja = joystick_0[4], jb = joystick_0[5];
    reg  [3:0] pat = 4'd0, pat_osd_q = 4'd0;
    reg        ja_q = 1'b0, jb_q = 1'b0;
    wire       a_hit = ja && !ja_q, b_hit = jb && !jb_q;
    reg  [7:0] nat_fc = 8'd0;                          // the native frame number (pattern() f)
    always @(posedge clk) if (ce && nat_fe) begin
        nat_fc    <= nat_fc + 8'd1;
        pat_osd_q <= pat_osd;
        ja_q <= ja;  jb_q <= jb;
        if (pat_osd != pat_osd_q)  pat <= (pat_osd < NPAT) ? pat_osd : 4'd0;
        else if (a_hit && !b_hit)  pat <= (pat == NPAT - 4'd1) ? 4'd0 : pat + 4'd1;
        else if (b_hit && !a_hit)  pat <= (pat == 4'd0) ? NPAT - 4'd1 : pat - 4'd1;
    end

    // stage 1
    reg nat_sq1 = 1'b0, nat_st1 = 1'b0, nat_de1 = 1'b0;
    reg [7:0] nat_sb1 = 8'd0;
    reg [23:0] nat_pat1 = 24'd0;
    always @(posedge clk) begin
        nat_sq1 <= (nat_cx >= {1'b0, sqx}) && (nat_cx < {1'b0, sqx} + 10'd24) &&
                   (nat_cy >= sqy) && (nat_cy < sqy + 9'd24);
        nat_st1 <= nat_in_strip;
        nat_de1 <= nat_de;
        nat_sb1 <= strip[sk];
        nat_pat1 <= pattern(pat, nat_cx, nat_cy, nw, nh, nat_fc);
    end
    // stage 2
    reg [23:0] nat_rgb = 24'd0;
    always @(posedge clk) begin
        if (nat_sq1)       nat_rgb <= 24'hFFFFFF;
        else if (nat_st1)  nat_rgb <= {nat_sb1, nat_sb1, nat_sb1};
        else if (!nat_de1) nat_rgb <= 24'h000000;
        else               nat_rgb <= nat_pat1;
    end
    assign VGA_R = nat_rgb[23:16];
    assign VGA_G = nat_rgb[15:8];
    assign VGA_B = nat_rgb[7:0];

`else
    // ======================================================================
    // Bare mode: 320 x 240 core pixels scaled to 720p (3 lines, 3-4 px wide).
    // VID_RGB is the pixel for (VID_CX, VID_CY) two clocks earlier.
    // ======================================================================
    localparam integer FW = 1650, FH = 750, W = 1280, H = 720;
    // the framework's Aspect ratio entry (header): no scaler here, so the core draws it
    wire [1:0]  ar    = status[127:126];    // check_confstr: status[127:126] bare build: no scaler, the core draws the Aspect ratio
    wire        full  = (ar == 2'd1) || (ar == 2'd3);              // Full Screen, 16:9: 1280 wide; Original, 4:3: 960
    wire [10:0] x0    = full ? 11'd0 : 11'd160;
    wire [10:0] iw    = full ? 11'd1280 : 11'd960;
    wire [11:0] cx = VID_CX;  wire [10:0] cy = VID_CY;
    wire        line_end  = (cx == FW - 1);
    wire        frame_end = line_end && (cy == FH - 1);
    wire [10:0] ny = (cy == FH - 1) ? 11'd0 : cy + 11'd1;

    // ---- noise: LFSR stepped at the last pixel of every core pixel of a visible line
    reg  [62:0] r = 63'd0, rsave = 63'd0;
    wire [10:0] xr = cx[10:0] - x0;
    wire        in_img = (cy < H) && (cx >= {1'b0, x0}) && (cx < {1'b0, x0} + {1'b0, iw});
    wire        blk_last = full ? (xr[1:0] == 2'd3) : ((xr % 11'd3) == 11'd2);
    wire        fb = ~(r[62] ^ r[60] ^ r[59] ^ r[57] ^ r[53]);
    // core line (0..239) and the phase (0..2) of the output line inside it
    reg  [7:0]  cl = 8'd0;  reg [1:0] ph = 2'd0;
    always @(posedge clk) begin
        if (in_img && blk_last && !RESET) r <= {r[61:0], fb};
        if (line_end) begin
            if (ny == 11'd0) begin cl <= 8'd0; ph <= 2'd0; end
            else if (ph == 2'd2) begin cl <= cl + 8'd1; ph <= 2'd0; end
            else ph <= ph + 2'd1;
            if (ny < H) begin
                if (ny == 11'd0 || ph == 2'd2) rsave <= r;   // a new core line starts
                else r <= rsave;                               // its 2nd / 3rd output line repeats it
            end
        end
    end

    // ---- the wave: vvc rolls once per frame
    reg  [9:0]  vvc = 10'd0;
    always @(posedge clk)
        if (reset) vvc <= 10'd0;                                  // mycore.v: if(reset) vvc <= 0
        else if (frame_end) vvc <= vvc + (status[2] ? 10'd5 : 10'd6);
    // cosine, 1024 steps per period, from the quarter table
    wire [9:0]  cph = vvc + {cl, 2'b00};
    wire [7:0]  qi  = cph[8] ? ~cph[7:0] : cph[7:0];
    wire [6:0]  qv  = template_qcos(qi);
    wire [7:0]  cosv = (cph[9] ^ cph[8]) ? (8'd127 - {1'b0, qv}) : (8'd128 + {1'b0, qv});
    wire [5:0]  cos_g = {1'b0, cosv[7:3]} + 6'd32;
    wire [5:0]  rnd_c = {r[0], r[1], r[2], r[2], r[2], r[2]};
    wire [7:0]  video = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

    // ---- test aids: the square (pads) and the download strip (ioctl)
    reg  [10:0] sqx = 11'd628, sqy = 11'd348;
    wire        jr = joystick_0[0], jl = joystick_0[1], jd = joystick_0[2], ju = joystick_0[3];
    always @(posedge clk) if (frame_end) begin
        if (jr && !jl) sqx <= (sqx >= 11'd1252) ? 11'd1256 : sqx + 11'd4;
        if (jl && !jr) sqx <= (sqx <= 11'd4) ? 11'd0 : sqx - 11'd4;
        if (jd && !ju) sqy <= (sqy >= 11'd692) ? 11'd696 : sqy + 11'd4;
        if (ju && !jd) sqy <= (sqy <= 11'd4) ? 11'd0 : sqy - 11'd4;
    end
    // ---- stage 1: the pixel's parts; stage 2: the colour
    reg  [7:0]  v1 = 8'd0;  reg img1 = 1'b0, sq1 = 1'b0, st1 = 1'b0;  reg [7:0] sb1 = 8'd0;  reg [1:0] col1 = 2'd0;
    wire [11:0] sx = cx - 12'd16;
    wire [11:0] skw = sx / 12'd20;                          // strip cell k (0..31 inside the strip)
    wire [4:0]  sk = skw[4:0];
    wire        in_strip = loaded && (cy >= 11'd688) && (cy < 11'd704) && (cx >= 12'd16) && (cx < 12'd656) &&
                           ((sx % 12'd20) < 12'd16);
    always @(posedge clk) begin
        v1   <= video;
        img1 <= in_img;
        col1 <= status[4:3];   // check_confstr: status[4:3] the noise colour; its Noise entry is left out on purpose (header), so it reads 0 = White
        sq1  <= (cx >= {1'b0, sqx}) && (cx < {1'b0, sqx} + 12'd24) && (cy >= sqy) && (cy < sqy + 11'd24);
        st1  <= in_strip;
        sb1  <= strip[sk];
    end
    reg [23:0] rgb = 24'd0;
    always @(posedge clk) begin
        if (sq1)       rgb <= 24'hFFFFFF;
        else if (st1)  rgb <= {sb1, sb1, sb1};
        else if (!img1) rgb <= 24'h000000;
        else rgb <= {((col1 == 2'd0 || col1 == 2'd1) ? v1 : 8'd0),
                     ((col1 == 2'd0 || col1 == 2'd2) ? v1 : 8'd0),
                     ((col1 == 2'd0 || col1 == 2'd3) ? v1 : 8'd0)};
    end
    assign VID_RGB = rgb;
`endif

endmodule
`default_nettype wire
