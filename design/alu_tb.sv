// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/alu_ops.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: alu
 *
 * Unit-level, no clock needed -- the ALU is pure combinational. Each test
 * vector below was chosen to distinguish the FIXED behaviour from the
 * SPECIFIC bug it regresses, not just to check "is the answer right" --
 * see the comment on each case for why that particular input pair matters.
 */
module alu_tb;

    logic [(`WORD_SIZE - 1):0]  operand_A, operand_B;
    logic [(`ALU_OPSIZE - 1):0] operation;
    logic [(`WORD_SIZE - 1):0]  result;

    alu dut (
        .i_operand_A(operand_A),
        .i_operation(operation),
        .i_operand_B(operand_B),
        .o_result(result)
    );

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [(`WORD_SIZE-1):0] expected);
        #1; // let the combinational logic settle
        if (result === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, result);
        end
    endtask

    initial begin
        /*
         * SLT: old buggy formula was (~A+1) < (~B+1) unsigned. That
         * formula is NOT algebraically equivalent to a signed compare in
         * general -- it happens to coincide with the right answer for many
         * inputs, which is exactly what made the bug easy to miss. Both
         * cases below were hand-verified to make the OLD formula disagree
         * with the correct signed answer.
         */

        // INT64_MIN < 0 is TRUE. Old formula: negating INT64_MIN overflows
        // back to itself (no positive counterpart in two's complement), so
        // it compares unsigned(INT64_MIN) < unsigned(0) = huge < 0 = FALSE.
        operand_A = 64'h8000000000000000; operand_B = 64'h0000000000000000;
        operation = `SLT;
        check("SLT: INT64_MIN < 0 (INT_MIN negation-overflow case)", 64'd1);

        // -1 < -2 is FALSE (-1 is the larger of the two). Old formula:
        // unsigned(-(-1))=1 < unsigned(-(-2))=2 is TRUE -- wrong sign of
        // the comparison entirely, no INT_MIN involved.
        operand_A = 64'hFFFFFFFFFFFFFFFF; operand_B = 64'hFFFFFFFFFFFFFFFE;
        operation = `SLT;
        check("SLT: -1 < -2 (general negation-trick unsoundness, no INT_MIN)", 64'd0);

        /*
         * SLT vs SLTU on the identical bit pattern: proves the signed path
         * is real and distinct, not coincidentally the same as unsigned.
         */
        operand_A = 64'h8000000000000000; operand_B = 64'h0000000000000001;
        operation = `SLT;  // signed: INT64_MIN < 1 -> true
        check("SLT: INT64_MIN < 1 (signed)", 64'd1);
        operation = `SLTU; // unsigned: 2^63 < 1 -> false
        check("SLTU: same bits, unsigned: 2^63 < 1", 64'd0);

        /*
         * SRA vs SRL on INT64_MIN: if SRA had degraded to SRL (the bug),
         * this would come back 0x0800000000000000 instead.
         */
        operand_A = 64'h8000000000000000; operand_B = 64'd4;
        operation = `SRA;
        check("SRA: INT64_MIN >>> 4 sign-extends (0xF8...)", 64'hF800000000000000);
        operation = `SRL;
        check("SRL: INT64_MIN >> 4 zero-fills (0x08...)", 64'h0800000000000000);

        /*
         * Shift-amount masking: WORD_SIZE=64 means only the low 6 bits of
         * the shift amount are used (log2(64)=6). A raw, unmasked shift by
         * 64 or 65 would behave very differently (most tools give 0 for a
         * shift-by->=width); masked, they wrap to shift-by-0 and
         * shift-by-1 respectively.
         */
        operand_A = 64'd1; operand_B = 64'd64; // 64 mod 64 = 0
        operation = `SLL;
        check("SLL: shift amount 64 wraps to 0 (no shift)", 64'd1);
        operand_A = 64'd1; operand_B = 64'd65; // 65 mod 64 = 1
        operation = `SLL;
        check("SLL: shift amount 65 wraps to 1", 64'd2);

        /*
         * RV64I word ops. SLLW: low-32 result's bit 31 ends up 1, so it
         * sign-extends negative even though the source operand (1) was
         * positive -- proves the *result's* sign drives the extension,
         * not the source operand's.
         */
        operand_A = 64'd1; operand_B = 64'd31;
        operation = `SLLW;
        check("SLLW: 1<<31 = 0x80000000, sign-extends negative", 64'hFFFFFFFF80000000);

        /*
         * SRLW vs SRAW on the SAME input and shift amount: the shift
         * itself differs (logical zero-fill vs arithmetic sign-fill), but
         * BOTH still sign-extend their 32-bit result to 64 bits per spec --
         * they diverge here because the logical shift's result happens to
         * have bit 31 = 0, while the arithmetic shift's result keeps bit
         * 31 = 1. This is the case the header comment in alu.sv warns
         * about: don't assume "logical" means "zero-extend the result".
         */
        operand_A = 64'hFFFFFFFFFFFFFFFF; operand_B = 64'd4;
        operation = `SRLW;
        check("SRLW: 0xFFFFFFFF>>4=0x0FFFFFFF, result sign-extends positive", 64'h000000000FFFFFFF);
        operation = `SRAW;
        check("SRAW: 0xFFFFFFFF>>>4=0xFFFFFFFF, result sign-extends negative", 64'hFFFFFFFFFFFFFFFF);

        $display("");
        $display("alu_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("alu_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
