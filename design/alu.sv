// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/alu_ops.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: ALU
 *
 * Pure combinational arithmetic/logic unit, WORD_SIZE (XLEN) bits wide --
 * except the RV64I "*W" ops below, which always operate on 32 bits
 * regardless of WORD_SIZE. See the comment above their `define`s in
 * defaults/alu_ops.sv for why those can't just be SLL/SRL/SRA fed
 * truncated operands.
 *
 * Input ports:
 *  i_operand_A: Source 1 (rs1) in instruction.
 *  i_operation: The operation to perform (A op B).
 *  i_operand_B: Source 2 (rs2) in instruction.
 *
 * Output port:
 *  o_result: Result of (A op B).
 */
module alu (
    input logic [(`WORD_SIZE - 1):0]        i_operand_A,
    input logic [(`ALU_OPSIZE - 1):0]       i_operation,
    input logic [(`WORD_SIZE - 1):0]        i_operand_B,

    output logic    [(`WORD_SIZE - 1):0]    o_result
);
    /*
     * RV64I "*W" intermediate results. Computed unconditionally rather than
     * inside the case arms below -- it's cheap combinational logic that
     * synthesizes away entirely when unused, and keeps the case arms
     * themselves down to one line each. Shift amount is a fixed 5 bits
     * here (not L2_WORD_SIZE): these ops are always 32-bit, regardless of
     * WORD_SIZE, so the shift amount field is always 5 bits wide too.
     */
    logic [31:0] w_sll_result, w_srl_result, w_sra_result;
    assign w_sll_result = i_operand_A[31:0] << i_operand_B[4:0];
    assign w_srl_result = i_operand_A[31:0] >> i_operand_B[4:0];
    assign w_sra_result = $signed(i_operand_A[31:0]) >>> i_operand_B[4:0];

    /*
     * Sign-extended to WORD_SIZE here, via plain `assign` rather than
     * inside the always_comb block below -- Icarus Verilog doesn't fully
     * support constant bit-selects (w_sll_result[31], etc.) inside
     * always_* processes (falls back to treating the process as sensitive
     * to the whole vector; harmless for a combinational block, but noisy
     * and worth just avoiding).
     */
    logic [(`WORD_SIZE - 1):0] w_sll_result_ext, w_srl_result_ext, w_sra_result_ext;
    assign w_sll_result_ext = {{32{w_sll_result[31]}}, w_sll_result};
    assign w_srl_result_ext = {{32{w_srl_result[31]}}, w_srl_result};
    assign w_sra_result_ext = {{32{w_sra_result[31]}}, w_sra_result};

    /*
     * Full-width shift amount, masked -- same reason as the *W results
     * above: precomputed via plain assign, not inline inside the
     * always_comb case statement below, since Icarus Verilog doesn't
     * fully support constant selects (i_operand_B[...]) inside always_*
     * processes either way.
     */
    logic [(`L2_WORD_SIZE - 1):0] shamt_masked;
    assign shamt_masked = i_operand_B[(`L2_WORD_SIZE - 1):0];

    /*
     * M extension: full 2*WORD_SIZE products, computed unconditionally
     * (same "cheap combinational logic, synthesizes away when unused"
     * reasoning as the *W intermediates above) -- the first time this file
     * has ever needed a wider-than-WORD_SIZE intermediate. MUL's low half
     * and MULHU's high half share product_uu (one unsigned multiply, not
     * two); MULH needs its own signed*signed product (product_ss).
     *
     * MULHSU (signed A * unsigned B) is the fiddly one: naively multiplying
     * a signed and an unsigned operand in the same expression makes the
     * WHOLE expression unsigned per Verilog's sign-context rules, which
     * would be wrong. Fix: sign-extend A to WORD_SIZE+1 bits, zero-extend B
     * to WORD_SIZE+1 bits (representing it as an always-non-negative signed
     * value), multiply as two same-width SIGNED values, then take the high
     * WORD_SIZE bits of that product. The extra bit of headroom beyond
     * 2*WORD_SIZE doesn't matter -- the true product's magnitude (|A| <
     * 2^(WORD_SIZE-1) times B < 2^WORD_SIZE) already fits comfortably
     * within 2*WORD_SIZE bits.
     */
    logic [(2*`WORD_SIZE - 1):0] product_uu;
    /*
     * product_ss/product_su are only ever read for their UPPER half
     * (mulh_hi/mulhsu_hi below) -- their lower bits (and, for product_su,
     * its 2 bits of extra headroom past 2*WORD_SIZE) are genuinely
     * unused, not an oversight: getting the upper half at all requires
     * computing the FULL product first, there's no narrower way to do
     * it. product_uu doesn't need the same treatment -- it serves double
     * duty (MUL's low half AND MULHU's high half both read it), so all
     * of it is used.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [(2*`WORD_SIZE - 1):0] product_ss;
    logic signed [`WORD_SIZE:0] mulhsu_a_ext, mulhsu_b_ext;
    logic signed [(2*`WORD_SIZE + 1):0] product_su;
    /* verilator lint_on UNUSEDSIGNAL */
    assign product_uu = i_operand_A * i_operand_B;
    assign product_ss = $signed(i_operand_A) * $signed(i_operand_B);
    assign mulhsu_a_ext = {i_operand_A[(`WORD_SIZE - 1)], i_operand_A};
    assign mulhsu_b_ext = {1'b0, i_operand_B};
    assign product_su = mulhsu_a_ext * mulhsu_b_ext;

    /*
     * Low/high WORD_SIZE-bit halves, precomputed via plain assign rather
     * than as inline bit-selects inside the always_comb case below -- same
     * "Icarus doesn't fully support constant selects inside always_*
     * processes" reasoning as w_sll_result_ext etc. above.
     */
    logic [(`WORD_SIZE - 1):0] mul_lo, mulh_hi, mulhsu_hi, mulhu_hi;
    assign mul_lo    = product_uu[(`WORD_SIZE - 1):0];
    assign mulh_hi   = product_ss[(2*`WORD_SIZE - 1):`WORD_SIZE];
    assign mulhsu_hi = product_su[(2*`WORD_SIZE - 1):`WORD_SIZE];
    assign mulhu_hi  = product_uu[(2*`WORD_SIZE - 1):`WORD_SIZE];

    always_comb begin: alu_ops
        case (i_operation)

        /* Arithmetic operations */
        `ADD:   o_result = i_operand_A + i_operand_B;
        `SUB:   o_result = i_operand_A - i_operand_B;

        /* Bitwise operations */
        `OR:    o_result = i_operand_A | i_operand_B;
        `AND:   o_result = i_operand_A & i_operand_B;
        `XOR:   o_result = i_operand_A ^ i_operand_B;
        `NOT:   o_result = ~i_operand_A;    /* Unary */

        /*
         * Comparison operations. Both produce a 1-bit true/false that
         * needs zero-extending to the full WORD_SIZE result per spec (rd =
         * 1 or 0, using the whole register) -- cast explicitly rather than
         * relying on the implicit 1-to-WORD_SIZE-bit expansion, which
         * verilator otherwise (correctly) flags as a width mismatch to
         * double check, even though it's intentional here.
         */
        `SLTU:  o_result = `WORD_SIZE'(i_operand_A < i_operand_B);
        /*
         * SLT compares as signed. The old (~A+1) < (~B+1) trick negates
         * both operands and compares unsigned, but that's wrong whenever
         * an operand is the most negative representable value -- negating
         * INT_MIN overflows back to itself in two's complement, since
         * there's no positive counterpart to negate to. $signed()
         * reinterprets the same bits as signed for this comparison only;
         * it doesn't change what's stored anywhere.
         */
        `SLT:   o_result = `WORD_SIZE'($signed(i_operand_A) < $signed(i_operand_B));

        /*
         * Shift operations. Shift amount is masked to L2_WORD_SIZE bits
         * (6, since WORD_SIZE is 64) per spec: shamt for a full-width
         * shift is defined as exactly log2(XLEN) bits, so an amount at or
         * beyond the operand width wraps rather than being treated as a
         * shift hardware can't actually perform.
         */
        `SLL:   o_result = i_operand_A << shamt_masked;
        `SRL:   o_result = i_operand_A >> shamt_masked;
        /*
         * Same $signed() cast as SLT, for the same underlying reason: >>>
         * only sign-extends if its LEFT operand's type is signed. Without
         * the cast, i_operand_A is a plain unsigned `logic`, so >>> would
         * silently degrade into an ordinary logical shift -- SRA would
         * behave identically to SRL instead of replicating the sign bit.
         */
        `SRA:   o_result = $signed(i_operand_A) >>> shamt_masked;

        /*
         * RV64I word ops: sign-extend the 32-bit result computed above.
         * This sign-extension applies uniformly to all three per spec --
         * notably SRLW ("logical" shift, zero-fills DURING the shift)
         * still SIGN-extends its final 32-to-64 result, same as SRAW.
         * "Logical shift" and "zero-extend the result" are two different
         * steps; only the shift itself is logical here.
         */
        `SLLW:  o_result = w_sll_result_ext;
        `SRLW:  o_result = w_srl_result_ext;
        `SRAW:  o_result = w_sra_result_ext;

        /*
         * M extension: multiply. MUL's low WORD_SIZE bits are sign-agnostic
         * (multiplication mod 2^WORD_SIZE doesn't depend on how the
         * operands' would-be-wider bits are populated), so MULW reuses this
         * op entirely rather than needing its own -- see core.sv's
         * is_word_arith for the truncate+resign step that handles MULW.
         * DIV/DIVU/REM/REMU (and their W variants) have no arms here at
         * all -- they route through design/divider.sv, a separate
         * multi-cycle module, not this (purely combinational) ALU.
         */
        `MUL:     o_result = mul_lo;
        `MULH:    o_result = mulh_hi;
        `MULHSU:  o_result = mulhsu_hi;
        `MULHU:   o_result = mulhu_hi;

        /*
         * A extension: AMOMIN/AMOMAX/AMOMINU/AMOMAXU value selection --
         * return the winning OPERAND, not a 0/1 flag, so SLT/SLTU can't be
         * reused here the way a branch comparison would. Same $signed()
         * idiom as SLT above, for the same reason (correctness at
         * INT64_MIN, where negate-and-compare-unsigned would break).
         */
        `MIN:   o_result = ($signed(i_operand_A) < $signed(i_operand_B)) ? i_operand_A : i_operand_B;
        `MAX:   o_result = ($signed(i_operand_A) < $signed(i_operand_B)) ? i_operand_B : i_operand_A;
        `MINU:  o_result = (i_operand_A < i_operand_B) ? i_operand_A : i_operand_B;
        `MAXU:  o_result = (i_operand_A < i_operand_B) ? i_operand_B : i_operand_A;

        default: o_result = 0;

        endcase
    end: alu_ops
endmodule: alu


/* ------------------------------------------------------------------------- */


/* End of file. */
