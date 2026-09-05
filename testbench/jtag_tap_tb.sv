// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: jtag_tap, driven entirely by bit-banging TCK/TMS/TDI --
 * proves the generic TAP FSM/IR-decode/IDCODE/DTMCS/BYPASS machinery,
 * before jtag_dmi_e2e_tb.sv proves the DMI-specific Access Register
 * path through the same TAP against a real dm.sv/core.sv. The DUT's own
 * dm_dmi0 sub-instance (jtag_tap.sv always instantiates one) is left
 * with i_reg_rdata tied to a dummy constant throughout (no dm.sv exists
 * in this file's own topology) -- fine for everything this file tests,
 * including its own DMI busy/sticky-error/dmireset section near the
 * end, which only cares about dm_dmi0's own status reporting, never
 * actual register content.
 *
 * tck_pulse is the one low-level primitive everything else composes
 * from: sample TDO (reflecting whatever the PREVIOUS pulse left
 * settled), THEN present the new TMS/TDI, THEN pulse TCK. This ordering
 * matters -- TDO is purely combinational in design/jtag_tap.sv (see that
 * file's own header for why, and the off-by-one bug an earlier
 * negedge-registered draft had), so sampling it BEFORE changing
 * TMS/TDI is what correctly associates each returned bit with the shift
 * cycle it belongs to.
 */
module jtag_tap_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic tck = 1'b0;
    logic tms = 1'b1;
    logic tdi = 1'b0;
    logic tdo;
    // Starts at a DEFINED 1 (not 0) -- see the initial block's own
    // comment on why the reset pulse must be a genuine 1->0->1
    // transition, not rely on a declaration-time X->0 "edge".
    logic trst_n = 1'b1;

    logic [6:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_we;
    logic [31:0] reg_rdata = 32'b0;

    jtag_tap dut (
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .trst_n(trst_n),
        .clk(clk), .rst(rst),
        .o_reg_addr(reg_addr), .o_reg_wdata(reg_wdata), .o_reg_we(reg_we),
        .i_reg_rdata(reg_rdata)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    task automatic tck_pulse(input logic tms_val, input logic tdi_val, output logic tdo_val);
        tdo_val = tdo;
        tms = tms_val;
        tdi = tdi_val;
        #2;
        tck = 1'b1;
        #2;
        tck = 1'b0;
        #2;
    endtask

    task automatic jtag_shift(input int width, input logic [63:0] data_in, output logic [63:0] data_out);
        logic tdo_bit;
        data_out = 64'b0;
        for (int i = 0; i < width; i++) begin
            tck_pulse((i == width - 1) ? 1'b1 : 1'b0, data_in[i], tdo_bit);
            data_out[i] = tdo_bit;
        end
    endtask

    // From TEST_LOGIC_RESET or anywhere else: 5x TMS=1 reaches
    // TestLogicReset (falls out of the FSM graph itself, see
    // design/jtag_tap.sv's header), then one TMS=0 reaches RTI.
    task automatic jtag_reset_to_idle();
        logic dummy;
        repeat (5) tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    // From RTI: SelectDR -> SelectIR -> CaptureIR -> ShiftIR.
    task automatic jtag_goto_shift_ir();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    // From RTI: SelectDR -> CaptureDR -> ShiftDR.
    task automatic jtag_goto_shift_dr();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    // From Exit1-DR/Exit1-IR (reached via the last jtag_shift bit's own
    // TMS=1): Update -> RTI.
    task automatic jtag_update_and_idle();
        logic dummy;
        tck_pulse(1'b1, 1'b0, dummy);
        tck_pulse(1'b0, 1'b0, dummy);
    endtask

    task automatic jtag_write_ir(input logic [4:0] ir_val);
        logic [63:0] dummy_out;
        jtag_goto_shift_ir();
        jtag_shift(5, {59'b0, ir_val}, dummy_out);
        jtag_update_and_idle();
    endtask

    initial begin
        #1;

        // trst_n pulse: a genuine 1->0->1 transition, not just an
        // initial value -- a declaration-time X->0 "edge" (trst_n
        // starting at 1'b0 from its own declaration) does NOT reliably
        // trigger `negedge trst_n`-sensitive always_ff blocks in this
        // Icarus build (confirmed empirically: design/dm_dmi.sv's own
        // TCK-domain registers stayed permanently X under that
        // approach, since nothing else ever touches them until IR
        // genuinely selects DMI -- unlike design/jtag_tap.sv's own
        // state/ir_q, which happened to self-heal via its case
        // statement's defensive default arm on the first real TCK
        // edge, masking the same underlying bug). A real explicit
        // falling edge here avoids relying on that coincidence.
        @(posedge clk); #1;
        rst = 0;
        repeat (3) @(posedge clk);
        trst_n = 1'b0;
        repeat (3) @(posedge clk);
        trst_n = 1'b1;
        repeat (3) @(posedge clk);

        /* ----------------------------------------------------------- *
         * IDCODE -- readable immediately after reset, no IR shift
         * needed.
         * ----------------------------------------------------------- */
        jtag_reset_to_idle();
        begin
            logic [63:0] idcode_out;
            jtag_goto_shift_dr();
            jtag_shift(32, 64'b0, idcode_out);
            jtag_update_and_idle();
            // IDCODE_VAL = {version=4'h0, part=16'h0001, mfr=11'h000, 1'b1}
            //            = (16'h0001 << 12) | (11'h000 << 1) | 1 = 32'h0000_1001
            check("jtag_tap: IDCODE reads 0x00001001 after reset, with no IR shift",
                idcode_out[31:0], 32'h0000_1001);
        end

        /* ----------------------------------------------------------- *
         * DTMCS -- version=1, abits=7 (matching dm.sv's real 7-bit
         * i_reg_addr), idle=0, dmistat=0 (no DMI activity has happened
         * in this file at all).
         * ----------------------------------------------------------- */
        jtag_write_ir(5'h10);  // IR_DTMCS
        begin
            logic [63:0] dtmcs_out;
            jtag_goto_shift_dr();
            jtag_shift(32, 64'b0, dtmcs_out);
            jtag_update_and_idle();
            // abits(6 bits=7)<<4 | version(4 bits=1) = 0x70 | 0x01 = 0x71
            check("jtag_tap: DTMCS reads version=1/abits=7/dmistat=0",
                dtmcs_out[31:0], 32'h0000_0071);
        end

        /* ----------------------------------------------------------- *
         * BYPASS -- explicit encoding (5'h1F). Capture is spec-fixed to
         * 0; each subsequent shift is a 1-bit-delayed passthrough of
         * TDI.
         * ----------------------------------------------------------- */
        jtag_write_ir(5'h1F);  // IR_BYPASS
        begin
            logic [63:0] bypass_out;
            jtag_goto_shift_dr();
            jtag_shift(4, 64'b1101, bypass_out);  // presents tdi = 1,0,1,1 (LSB-first)
            jtag_update_and_idle();
            check("jtag_tap: BYPASS captures 0 (spec-fixed)", bypass_out[0], 1'b0);
            check("jtag_tap: BYPASS bit 1 == tdi bit 0 (1-bit delayed passthrough)",
                bypass_out[1], 1'b1);
            check("jtag_tap: BYPASS bit 2 == tdi bit 1", bypass_out[2], 1'b0);
            check("jtag_tap: BYPASS bit 3 == tdi bit 2", bypass_out[3], 1'b1);
        end

        /* ----------------------------------------------------------- *
         * Unrecognized IR encoding -- must alias to BYPASS (spec's own
         * mandated fallback for unimplemented encodings), proving
         * sel_bypass's fallback logic, not just the explicit 5'h1F case
         * above.
         * ----------------------------------------------------------- */
        jtag_write_ir(5'h05);  // not IDCODE/DTMCS/DMI/BYPASS -- must alias BYPASS
        begin
            logic [63:0] alias_out;
            jtag_goto_shift_dr();
            jtag_shift(2, 64'b01, alias_out);
            jtag_update_and_idle();
            check("jtag_tap: unrecognized IR aliases to BYPASS -- captures 0",
                alias_out[0], 1'b0);
            check("jtag_tap: unrecognized IR aliases to BYPASS -- 1-bit delayed passthrough",
                alias_out[1], 1'b1);
        end

        /* ----------------------------------------------------------- *
         * TMS=1 held for 5 cycles from mid-scan reaches
         * Test-Logic-Reset and re-arms IDCODE as the active IR -- no
         * special-case RTL for this, it falls out of the FSM graph
         * itself (see module header). Get into ShiftDR first (via the
         * BYPASS IR still active from above), then prove the escape.
         * ----------------------------------------------------------- */
        begin
            logic dummy;
            logic [63:0] idcode_out2;
            tck_pulse(1'b1, 1'b0, dummy);  // RTI -> SelectDR
            tck_pulse(1'b0, 1'b0, dummy);  // -> CaptureDR
            tck_pulse(1'b0, 1'b0, dummy);  // -> ShiftDR (mid-scan)
            jtag_reset_to_idle();          // TMS=1 x5 from ShiftDR -> TestLogicReset -> RTI
            jtag_goto_shift_dr();
            jtag_shift(32, 64'b0, idcode_out2);
            jtag_update_and_idle();
            check("jtag_tap: 5x TMS=1 from mid-scan reaches Test-Logic-Reset, IDCODE re-armed",
                idcode_out2[31:0], 32'h0000_1001);
        end

        /* ----------------------------------------------------------- *
         * DMI busy/sticky-error protocol (dm_dmi0, previously entirely
         * unexercised in this file -- see this file's own header).
         *
         * A GENUINE overlapping request (issuing a 2nd real DMI op
         * before the CDC round trip for the 1st one completes) can't
         * actually be produced by bit-banging here: one full 41-bit DMI
         * DR scan takes far longer in simulated time (dozens of tck
         * pulses) than dm_dmi0's own clk-domain round trip (a handful
         * of clk cycles), so a real race would never land. Instead,
         * this white-box pokes outstanding_q directly to deterministically
         * simulate "a request is genuinely still in flight" -- a
         * legitimate, established technique this project uses whenever
         * a real timing race can't be reliably reproduced (see e.g.
         * core_debug_halt_tb.sv's own dcsr pokes). This directly tests
         * design/dm_dmi.sv:152-162's busy-detection branch and its
         * dmireset recovery path (lines 165-167), and cross-checks that
         * dtmcs.dmistat and the DMI register's own op-status field
         * report the SAME busy code (both 3) for the identical
         * busy_sticky_q condition -- the exact inconsistency a prior
         * pass of this milestone shipped (dmistat wrongly reported 2).
         * ----------------------------------------------------------- */
        begin
            logic [63:0] dummy_out;
            logic [63:0] dmi_out;
            logic [63:0] dtmcs_out;

            dut.dm_dmi0.outstanding_q = 1'b1;

            jtag_write_ir(5'h11);  // IR_DMI
            jtag_goto_shift_dr();
            // op=1 (read), addr/data don't matter -- outstanding_q==1
            // means this request is refused and only sets busy_sticky_q.
            jtag_shift(41, {23'b0, 7'b0, 32'b0, 2'd1}, dummy_out);
            jtag_update_and_idle();

            jtag_goto_shift_dr();
            jtag_shift(41, {23'b0, 7'b0, 32'b0, 2'd0}, dmi_out);  // op=0 (nop) -- just read status
            jtag_update_and_idle();
            check("jtag_tap: DMI op-status == 3 (busy) after an overlapping request",
                dmi_out[1:0], 2'd3);

            jtag_write_ir(5'h10);  // IR_DTMCS
            jtag_goto_shift_dr();
            jtag_shift(32, 64'b0, dtmcs_out);
            jtag_update_and_idle();
            check("jtag_tap: dtmcs.dmistat == 3 (busy) -- same code as the DMI op-status field",
                dtmcs_out[11:10], 2'd3);

            // dmireset (DTMCS bit 16) clears the sticky busy condition.
            jtag_write_ir(5'h10);  // IR_DTMCS
            jtag_goto_shift_dr();
            jtag_shift(32, 64'h0001_0000, dummy_out);
            jtag_update_and_idle();
            dut.dm_dmi0.outstanding_q = 1'b0;  // clear the earlier white-box poke too

            jtag_write_ir(5'h11);  // IR_DMI
            jtag_goto_shift_dr();
            jtag_shift(41, {23'b0, 7'b0, 32'b0, 2'd0}, dmi_out);  // op=0 (nop)
            jtag_update_and_idle();
            check("jtag_tap: DMI op-status == 0 after dmireset clears the sticky busy condition",
                dmi_out[1:0], 2'd0);

            jtag_write_ir(5'h10);  // IR_DTMCS
            jtag_goto_shift_dr();
            jtag_shift(32, 64'b0, dtmcs_out);
            jtag_update_and_idle();
            check("jtag_tap: dtmcs.dmistat == 0 after dmireset",
                dtmcs_out[11:10], 2'd0);
        end

        $display("");
        $display("jtag_tap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("jtag_tap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
