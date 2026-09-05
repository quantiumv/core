// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: jtag_tap
 *
 * IEEE 1149.1 JTAG TAP controller (Milestone 6 of the EBREAK/JTAG staged
 * plan -- see [[dm-register-file-milestone]] for Milestone 5). This
 * project's first real top-level pins: TCK/TMS/TDI/TDO/TRST_N, clocked
 * on TCK, genuinely asynchronous to the system clock (no fixed frequency
 * or phase relationship assumed -- an external debug probe drives TCK).
 *
 * The 16-state TAP FSM below is the standard 1149.1 graph, transcribed
 * directly from the spec's own state diagram -- every arc is exactly
 * what the standard mandates, not a project-specific simplification.
 * From ANY state, holding TMS=1 for 5 consecutive TCK cycles reaches
 * Test-Logic-Reset; this falls out of the graph itself (the longest path
 * to TestLogicReset via TMS=1 is ShiftDR/ShiftIR -> Exit1 -> Update ->
 * SelectDR -> SelectIR -> TestLogicReset, 5 edges) with no special-case
 * logic needed. TRST_N is the spec's OPTIONAL async hardware reset pin,
 * included here as a genuinely asynchronous input (`negedge trst_n` in
 * the FSM's own sensitivity list) -- forces TestLogicReset immediately,
 * independent of TCK.
 *
 * Shift registers (IR and every DR) all use the SAME convention:
 * shift-right, LSB-first in and out -- `sr <= {tdi, sr[N-1:1]};
 * tdo_source = sr[0];`. TDO ITSELF IS PURELY COMBINATIONAL, NOT
 * registered on either clock edge -- see the TDO mux section further
 * down in this file for the full reasoning (a real off-by-one bug in
 * an earlier negedge-registered draft, and why combinational TDO
 * avoids it).
 *
 * IR is 5 bits (spec's own minimum recommendation). Capture-IR always
 * loads a fixed pattern ending in "01" (spec requirement, for board-
 * level interconnect testing) -- this implementation uses 5'b00001.
 * Entering Test-Logic-Reset resets the ACTIVE ir_q to the IDCODE
 * encoding (spec requirement: a debugger must be able to read IDCODE
 * immediately after reset/power-up with no IR shift needed first).
 *
 * IR encodings (RISC-V Debug Spec's own recommended/mandatory table --
 * unimplemented encodings alias to BYPASS, the spec's own mandated
 * fallback):
 *   5'h01  IDCODE  (32-bit, read-only, placeholder vendor/part fields --
 *                   see IDCODE_VAL below; no real JEDEC registration
 *                   exists for this from-scratch project)
 *   5'h10  DTMCS   (32-bit, DTM control/status -- dmireset/dmihardreset
 *                   W1 bits forwarded to dm_dmi0, dmistat mirrors its
 *                   sticky-busy state)
 *   5'h11  DMI     (41-bit, forwarded whole to dm_dmi0 -- this module
 *                   has no idea what the 41 bits mean, only that
 *                   dm_dmi0 owns that DR's capture/shift/update)
 *   5'h1F  BYPASS  (1-bit, mandatory)
 *   anything else  aliases to BYPASS
 */
module jtag_tap (
    input logic tck,
    input logic tms,
    input logic tdi,
    output logic tdo,
    input logic trst_n,

    // dm.sv's plain register interface (clk domain) -- passed straight
    // through to the internal dm_dmi0 instance.
    input  logic clk,
    input  logic rst,
    output logic [6:0]  o_reg_addr,
    output logic [31:0] o_reg_wdata,
    output logic        o_reg_we,
    input  logic [31:0] i_reg_rdata
);

    typedef enum logic [3:0] {
        TEST_LOGIC_RESET = 4'd0,
        RUN_TEST_IDLE    = 4'd1,
        SELECT_DR        = 4'd2,
        CAPTURE_DR       = 4'd3,
        SHIFT_DR         = 4'd4,
        EXIT1_DR         = 4'd5,
        PAUSE_DR         = 4'd6,
        EXIT2_DR         = 4'd7,
        UPDATE_DR        = 4'd8,
        SELECT_IR        = 4'd9,
        CAPTURE_IR       = 4'd10,
        SHIFT_IR         = 4'd11,
        EXIT1_IR         = 4'd12,
        PAUSE_IR         = 4'd13,
        EXIT2_IR         = 4'd14,
        UPDATE_IR        = 4'd15
    } tap_state_t;

    /*
     * Every TCK-domain register in this file (and in design/dm_dmi.sv's
     * own TCK-domain set) carries an explicit initial value, not just a
     * reset arm -- a real, confirmed gotcha: a constant-tied trst_n
     * (e.g. soc.sv's own ANSI default for jtag_trst_n, used by every
     * pre-existing testbench that doesn't know these pins exist) never
     * produces a genuine `negedge trst_n` event in this project's
     * Icarus build, since a value that never transitions can't trigger
     * an edge-sensitivity list. Without an initial value, these
     * registers would sit at their power-on-X value indefinitely
     * whenever no real JTAG probe (i.e. no real tck/trst_n toggling) is
     * present -- exactly the scenario soc.sv's own header comment
     * claims doesn't happen. The initial value here is what actually
     * makes that claim true. (Verilator's PROCASSINIT check flags each
     * of these initial values as redundant against its own reset arm --
     * true for a simulator that always drives a real reset edge, which
     * Verilator itself is, but not the point here; each site below is
     * deliberately, individually suppressed, not silenced blindly.)
     */
    /* verilator lint_off PROCASSINIT */
    tap_state_t state = TEST_LOGIC_RESET;
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            state <= TEST_LOGIC_RESET;
        end else begin
            case (state)
                TEST_LOGIC_RESET: state <= tap_state_t'(tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE);
                RUN_TEST_IDLE:    state <= tap_state_t'(tms ? SELECT_DR : RUN_TEST_IDLE);
                SELECT_DR:        state <= tap_state_t'(tms ? SELECT_IR : CAPTURE_DR);
                CAPTURE_DR:       state <= tap_state_t'(tms ? EXIT1_DR  : SHIFT_DR);
                SHIFT_DR:         state <= tap_state_t'(tms ? EXIT1_DR  : SHIFT_DR);
                EXIT1_DR:         state <= tap_state_t'(tms ? UPDATE_DR : PAUSE_DR);
                PAUSE_DR:         state <= tap_state_t'(tms ? EXIT2_DR  : PAUSE_DR);
                EXIT2_DR:         state <= tap_state_t'(tms ? UPDATE_DR : SHIFT_DR);
                UPDATE_DR:        state <= tap_state_t'(tms ? SELECT_DR : RUN_TEST_IDLE);
                SELECT_IR:        state <= tap_state_t'(tms ? TEST_LOGIC_RESET : CAPTURE_IR);
                CAPTURE_IR:       state <= tap_state_t'(tms ? EXIT1_IR  : SHIFT_IR);
                SHIFT_IR:         state <= tap_state_t'(tms ? EXIT1_IR  : SHIFT_IR);
                EXIT1_IR:         state <= tap_state_t'(tms ? UPDATE_IR : PAUSE_IR);
                PAUSE_IR:         state <= tap_state_t'(tms ? EXIT2_IR  : PAUSE_IR);
                EXIT2_IR:         state <= tap_state_t'(tms ? UPDATE_IR : SHIFT_IR);
                UPDATE_IR:        state <= tap_state_t'(tms ? SELECT_DR : RUN_TEST_IDLE);
                default:          state <= TEST_LOGIC_RESET;
            endcase
        end
    end

    wire capture_dr = (state == CAPTURE_DR);
    wire shift_dr   = (state == SHIFT_DR);
    wire update_dr  = (state == UPDATE_DR);
    wire capture_ir = (state == CAPTURE_IR);
    wire shift_ir   = (state == SHIFT_IR);
    wire update_ir  = (state == UPDATE_IR);

    /* ----------------------------------------------------------------- *
     * IR register
     * ----------------------------------------------------------------- */
    localparam [4:0] IR_IDCODE = 5'h01;
    localparam [4:0] IR_DTMCS  = 5'h10;
    localparam [4:0] IR_DMI    = 5'h11;
    /*
     * IR_BYPASS is documentation for the encoding table (module header
     * above), not something the RTL itself needs to test -- sel_bypass
     * below is computed as the fallback "none of the other three"
     * (matching the spec's own "unrecognized encodings alias to
     * BYPASS" mandate for BOTH IR_BYPASS's own real value AND every
     * other unimplemented encoding), so IR_BYPASS is never read.
     */
    /* verilator lint_off UNUSEDPARAM */
    localparam [4:0] IR_BYPASS = 5'h1F;
    /* verilator lint_on UNUSEDPARAM */

    /* verilator lint_off PROCASSINIT */
    logic [4:0] ir_shift_q = 5'b0;
    logic [4:0] ir_q = IR_IDCODE;  // the ACTIVE, updated IR value used for DR selection
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            ir_shift_q <= 5'b0;
            ir_q       <= IR_IDCODE;
        end else if (state == TEST_LOGIC_RESET) begin
            ir_q <= IR_IDCODE;
        end else if (capture_ir) begin
            ir_shift_q <= 5'b00001;
        end else if (shift_ir) begin
            ir_shift_q <= {tdi, ir_shift_q[4:1]};
        end else if (update_ir) begin
            ir_q <= ir_shift_q;
        end
    end

    wire sel_idcode = (ir_q == IR_IDCODE);
    wire sel_dtmcs  = (ir_q == IR_DTMCS);
    wire sel_dmi    = (ir_q == IR_DMI);
    // Anything else (including IR_BYPASS itself) aliases to BYPASS --
    // the spec's own mandated fallback for unrecognized IR encodings.
    wire sel_bypass = !sel_idcode && !sel_dtmcs && !sel_dmi;

    /* ----------------------------------------------------------------- *
     * BYPASS DR -- 1 bit, mandatory. Capture is spec-fixed to 0.
     * ----------------------------------------------------------------- */
    /* verilator lint_off PROCASSINIT */
    logic bypass_q = 1'b0;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) bypass_q <= 1'b0;
        else if (sel_bypass && capture_dr) bypass_q <= 1'b0;
        else if (sel_bypass && shift_dr)   bypass_q <= tdi;
    end

    /* ----------------------------------------------------------------- *
     * IDCODE DR -- 32 bits, read-only. No real JEDEC vendor registration
     * exists for this from-scratch project -- version/part/manufacturer
     * fields below are explicit, documented placeholders, not a claim
     * of real registration. Standard IEEE 1149.1 IDCODE layout:
     * [31:28]=version, [27:12]=part number, [11:1]=manufacturer ID
     * (JEDEC), [0]=1 (fixed, marks this as a real IDCODE rather than a
     * BYPASS'd all-1s shift).
     * ----------------------------------------------------------------- */
    localparam [31:0] IDCODE_VAL = {4'h0, 16'h0001, 11'h000, 1'b1};

    /* verilator lint_off PROCASSINIT */
    logic [31:0] idcode_sr_q = IDCODE_VAL;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) idcode_sr_q <= IDCODE_VAL;
        else if (sel_idcode && capture_dr) idcode_sr_q <= IDCODE_VAL;
        else if (sel_idcode && shift_dr)   idcode_sr_q <= {tdi, idcode_sr_q[31:1]};
    end

    /* ----------------------------------------------------------------- *
     * DTMCS DR -- 32 bits. version/abits/idle are fixed; dmistat mirrors
     * dm_dmi0's own sticky-busy state; dmireset/dmihardreset are W1
     * pulses forwarded to dm_dmi0 on Update-DR, never stored (spec
     * allows write-only semantics for both, same reasoning already
     * established for dm.sv's own dmcontrol.resumereq in Milestone 5).
     * Field layout: [17]=dmihardreset, [16]=dmireset, [15]=reserved,
     * [14:12]=idle (min. Run-Test/Idle cycles required between scans --
     * 0, since the busy/retry protocol handles arbitrary latency
     * regardless), [11:10]=dmistat, [9:4]=abits (7, matching dm.sv's
     * real 7-bit i_reg_addr), [3:0]=version (1 = "version described in
     * this spec", the 0.13.2/1.0 encoding).
     * ----------------------------------------------------------------- */
    wire [1:0] dmistat_w;
    /* verilator lint_off PROCASSINIT */
    logic [31:0] dtmcs_sr_q = 32'b0;
    /* verilator lint_on PROCASSINIT */
    wire [31:0] dtmcs_live_val = {14'b0, 1'b0, 1'b0, 1'b0, 3'b0,
                                   dmistat_w, 6'd7, 4'd1};
    always_ff @(posedge tck or negedge trst_n) begin
        if (!trst_n) dtmcs_sr_q <= 32'b0;
        else if (sel_dtmcs && capture_dr) dtmcs_sr_q <= dtmcs_live_val;
        else if (sel_dtmcs && shift_dr)   dtmcs_sr_q <= {tdi, dtmcs_sr_q[31:1]};
    end
    wire dtmcs_dmireset     = sel_dtmcs && update_dr && dtmcs_sr_q[16];
    wire dtmcs_dmihardreset = sel_dtmcs && update_dr && dtmcs_sr_q[17];

    /* ----------------------------------------------------------------- *
     * DMI DR -- forwarded whole to dm_dmi0. capture_dr/shift_dr/
     * update_dr are only meaningful to dm_dmi0 while sel_dmi is true;
     * gating them here (rather than passing raw state-derived signals
     * unconditionally) keeps dm_dmi0's own busy/sticky-error state from
     * reacting to Capture/Shift/Update-DR cycles that belong to a
     * DIFFERENT DR (e.g. while a debugger is shifting IDCODE).
     * ----------------------------------------------------------------- */
    wire dmi_tdo;
    dm_dmi dm_dmi0 (
        .tck(tck), .trst_n(trst_n),
        .i_capture_dr(sel_dmi && capture_dr),
        .i_shift_dr(sel_dmi && shift_dr),
        .i_update_dr(sel_dmi && update_dr),
        .i_tdi(tdi),
        .o_tdo(dmi_tdo),
        .i_dmireset(dtmcs_dmireset),
        .i_dmihardreset(dtmcs_dmihardreset),
        .o_dmistat(dmistat_w),
        .clk(clk), .rst(rst),
        .o_reg_addr(o_reg_addr), .o_reg_wdata(o_reg_wdata), .o_reg_we(o_reg_we),
        .i_reg_rdata(i_reg_rdata)
    );

    /* ----------------------------------------------------------------- *
     * TDO mux -- selects the currently-active DR's own TDO source while
     * shifting DR, or the IR shift register's own TDO source while
     * shifting IR. Purely combinational -- see the block comment
     * immediately below for why.
     * ----------------------------------------------------------------- */
    /*
     * TDO is purely combinational, continuously reflecting whichever
     * shift register is currently selected -- NOT registered on either
     * clock edge. This is a deliberate correction from an earlier draft
     * of this file that registered TDO on TCK's falling edge (real
     * 1149.1 silicon practice, for setup-time margin against an
     * external probe): that design had an off-by-one bug, since by the
     * time a negedge-triggered register could sample sr[0], the SAME
     * edge's own posedge-triggered shift (same tck edge, same sr) had
     * already updated sr via its own non-blocking assignment -- meaning
     * a negedge sample would present the bit AFTER this cycle's shift,
     * not the pre-shift bit the protocol requires TDO to present WHILE
     * that cycle's TDI is being received. A purely combinational TDO
     * sidesteps this entirely: the correct protocol discipline just
     * becomes "the debugger samples TDO before presenting the next
     * TMS/TDI and pulsing TCK again" -- exactly what testbench/
     * jtag_tap_tb.sv's own tck_pulse task does. A real ASIC/FPGA
     * targeting external timing closure would still want a registered
     * TDO for setup margin; that's a synthesis-stage concern this
     * same-simulation verification milestone doesn't need to solve.
     */
    wire dr_tdo_mux = sel_idcode ? idcode_sr_q[0]
                     : sel_dtmcs  ? dtmcs_sr_q[0]
                     : sel_dmi    ? dmi_tdo
                     :              bypass_q;

    assign tdo = shift_ir ? ir_shift_q[0] : dr_tdo_mux;

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
