// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, *W-variant divide-by-zero, end to end
 *
 * design/divider_tb.sv proves DIVW/DIVUW/REMW/REMUW's divide-by-zero
 * overrides at the DIVIDER level, fed the same pre-sign-or-zero-extended
 * operand shapes core.sv's own "M extension: divide" section actually
 * produces -- but that's still only half the real instruction's path.
 * This file proves the OTHER half: that a real DIVW/DIVUW/REMW/REMUW
 * instruction, fetched and decoded from real memory, genuinely reaches
 * that divider with correctly pre-extended operands, and that its result
 * comes back out through core.sv's separate post-truncation step
 * (div_result_raw/div_result -- see core.sv's "M extension: divide"
 * section) and lands in the right register with the right final value.
 * design/divider_tb.sv's own header comment flags one place this
 * specifically matters: the DIVW/REMW signed-overflow case's raw
 * quotient does NOT equal the spec-correct answer at the divider's own
 * boundary -- it only becomes correct one level up, via core.sv's
 * post-truncation sign-extending the truncated low 32 bits. That
 * specific case isn't repeated here (this file's job is the by-zero
 * overrides, per its own name), but it's the reason this second,
 * full-pipeline file exists at all rather than trusting
 * design/divider_tb.sv alone to close this gap.
 *
 * Deliberately small and focused -- 10 instructions, not a sweep -- since
 * design/divider_tb.sv already proves the underlying arithmetic and
 * testbench/core_m_ext_tb.sv already proves general M-extension decode/
 * control-unit routing (including DIVW/DIVUW's own non-zero-divisor
 * cases, using operand pairs chosen specifically to distinguish one
 * M-instruction from another). This file's only new claim is "the
 * divide-by-zero override survives the full real pipeline", so it
 * covers exactly DIVW-by-zero, DIVUW-by-zero, REMW-by-zero, and
 * REMUW-by-zero, one instruction each.
 *
 * One inherent ISA property worth flagging up front, so a reader doesn't
 * mistake it for a weak test later: DIVW-by-zero and DIVUW-by-zero are
 * PROVABLY bit-identical at this instruction's own final result (both
 * land on 64'hFFFF...FFFF, sign-extended all-1s) -- see
 * design/divider_tb.sv's own comment on why the divisor_mag_q==0 bypass
 * is unconditional on i_signed. No choice of dividend operand can make
 * these two checks distinguish "DIVW ran" from "DIVUW accidentally ran
 * instead" from their result value alone -- that specific confusion is
 * already ruled out elsewhere, by core_m_ext_tb.sv's non-zero-divisor
 * DIVW/DIVUW checks (64'hFFFFFFFFC0000000 vs 64'h0000000055555555,
 * genuinely different answers). What DIVW-by-zero/DIVUW-by-zero here
 * DO each independently prove: that instruction reaches the divider with
 * a zero divisor, doesn't hang/trap/misfire the div_stall FSM extension,
 * and the override value survives real writeback -- a real risk given
 * this is the first time this project's hardware exercises the *W
 * pre-extension path with a zero divisor specifically (design/divider.sv's
 * own zero-divisor bypass logic sits upstream of, and is entirely
 * independent from, the *W pre/post-extension wiring being tested here).
 *
 * Register discipline (see testbench/core_m_ext_tb.sv's own header for
 * why this matters): x20/x21 are plain scratch, freely overwritten
 * between steps and never check()-ed directly -- only x1/x2/x3/x4 (each
 * written by exactly one M instruction, and never touched again
 * afterward) are asserted against. x21 (the divisor) is set to 0 exactly
 * once, up front, and simply never rewritten for the rest of the
 * program, since every check in this file wants a zero divisor anyway.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv,
 * core_wb4_sram_harness.sv), same as every other core-instantiating
 * testbench in this project.
 */
module core_m_w_edgecases_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(64)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    initial begin
        #1; // run after wb4_sram's own time-0 init -- see core_wb_tb.sv's header

        /*
         * idx  addr  instruction                     notes
         *  0   0x00  addi x21, x0, 0                  x21 = 0 (divisor -- set once, reused by every check below)
         *  1   0x04  addi x20, x0, -777                x20 = -777
         *  2   0x08  divw  x1, x20, x21                x1 = DIVW(-777, 0) = -1, sign-extended     [CHECK: DIVW-by-zero]
         *  3   0x0C  addi x20, x0, 321                 x20 = 321 (reuse x20)
         *  4   0x10  divuw x2, x20, x21                x2 = DIVUW(321, 0) = 2^32-1, sign-extended [CHECK: DIVUW-by-zero]
         *  5   0x14  addi x20, x0, -555                x20 = -555 (reuse x20)
         *  6   0x18  remw  x3, x20, x21                x3 = REMW(-555, 0) = -555 unchanged        [CHECK: REMW-by-zero]
         *  7   0x1C  addi x20, x0, 999                 x20 = 999 (reuse x20)
         *  8   0x20  remuw x4, x20, x21                x4 = REMUW(999, 0) = 999 unchanged         [CHECK: REMUW-by-zero]
         *  9   0x24  ebreak
         */
        dut.sram0.memory[0] = {encode_i(-32'sd777, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                  // idx1
                                encode_i(32'sd0, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM)};                    // idx0
        dut.sram0.memory[1] = {encode_i(32'sd321, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                   // idx3
                                encode_r(7'b0000001, 5'd21, 5'd20, 3'b100, 5'd1, `OPC_OP_32)};          // idx2: divw
        dut.sram0.memory[2] = {encode_i(-32'sd555, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                  // idx5
                                encode_r(7'b0000001, 5'd21, 5'd20, 3'b101, 5'd2, `OPC_OP_32)};          // idx4: divuw
        dut.sram0.memory[3] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),                   // idx7
                                encode_r(7'b0000001, 5'd21, 5'd20, 3'b110, 5'd3, `OPC_OP_32)};          // idx6: remw
        dut.sram0.memory[4] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                      // idx9: ebreak
                                encode_r(7'b0000001, 5'd21, 5'd20, 3'b111, 5'd4, `OPC_OP_32)};          // idx8: remuw

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "dut.core0.halted never went high");

        check("DIVW-by-zero: -777/0 -> -1, sign-extended", dut.core0.regfile0.gp_registers[1], 64'hFFFFFFFFFFFFFFFF);
        check("DIVUW-by-zero: 321/0 -> 2^32-1, sign-extended", dut.core0.regfile0.gp_registers[2], 64'hFFFFFFFFFFFFFFFF);
        check("REMW-by-zero: -555/0 -> dividend unchanged, sign-extended", dut.core0.regfile0.gp_registers[3], 64'hFFFFFFFFFFFFFDD5);
        check("REMUW-by-zero: 999/0 -> dividend unchanged", dut.core0.regfile0.gp_registers[4], 64'd999);
        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_m_w_edgecases_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_m_w_edgecases_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
