// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: divider_random_tb
 *
 * Randomized property test for divider.sv -- separate from the existing
 * directed divider_tb.sv (don't touch an 18/18-passing file; this repo's
 * convention is one file per testbench concern, same reasoning
 * csr_file_random_tb.sv used for csr_file.sv). Duplicates that file's
 * clk/rst/dut-instantiation/run_division-style scaffold rather than
 * sharing it, per the same convention divider_tb.sv itself already
 * established for this DUT.
 *
 * Approach: NUM_ITER iterations, each driving one randomized division to
 * completion and checking BOTH o_quotient and o_remainder against a
 * shadow model that is a genuinely independent code path from
 * divider.sv's own iterative shift-subtract-restore algorithm --
 * SystemVerilog's native signed / and % (which round toward zero per
 * IEEE 1800-2017 5.7.1, exactly matching the RV64M spec's own "rounds
 * towards zero" requirement) for the general signed case, and native
 * unsigned / and % for the general unsigned case. A real algorithm bug
 * in the RTL is very unlikely to coincidentally reproduce the same wrong
 * answer as this unrelated code path.
 *
 * The two spec-mandated override cases -- divide by zero and signed
 * overflow (dividend = -2^63, divisor = -1) -- are NOT checked against
 * native / and % (dividing by zero produces 'x'/undefined in simulation,
 * not a real number to compare against); those iterations instead check
 * against the literal override table from the M-extension spec (see
 * design/divider.sv's own header for the full derivation of why the RTL
 * is claimed to produce these values with almost no explicit special-case
 * logic -- this file's divide-by-zero/overflow iterations are what
 * actually stress that claim at volume, on top of divider_tb.sv's small
 * number of directed examples of the same two cases).
 *
 * Input distribution is explicitly biased ($urandom_range(0,9)), not
 * uniform-random over the full 64-bit space -- uniform random 64-bit
 * dividend/divisor pairs would almost never land exactly on divisor==0 or
 * on the single-point signed-overflow pattern, so both would go
 * essentially untested at any reasonable iteration count:
 *   0-1: divisor forced to 0 (divide-by-zero), dividend random.
 *   2:   dividend forced to the overflow pattern (-2^63) AND divisor
 *        forced to -1 AND i_signed forced to 1 (signed overflow is only
 *        meaningful when the divide is actually signed -- as DIVU/REMU,
 *        -2^63's bit pattern and -1's bit pattern are just two ordinary
 *        unsigned magnitudes with nothing special about them).
 *   3-5: small values (single/double-digit magnitudes) on both operands
 *        -- likely to produce genuinely interesting nonzero quotients and
 *        remainders that are easy to sanity-eyeball if something ever
 *        needs hand-checking, unlike wide-random values.
 *   6-9: fully wide-randomized 64-bit-composed dividend/divisor, for
 *        broad coverage of the general case.
 * i_signed is randomized independently (roughly 50/50) except where the
 * bucket above forces it (the overflow bucket, which forces 1).
 *
 * Seeding: same as csr_file_random_tb.sv -- no explicit $srandom call;
 * this iverilog build's bare $urandom/$urandom_range are confirmed
 * run-to-run deterministic unseeded.
 */
module divider_random_tb;

    localparam int NUM_ITER = 2000;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic start;
    logic [(`WORD_SIZE - 1):0] dividend, divisor;
    logic is_signed;
    logic busy, done;
    logic [(`WORD_SIZE - 1):0] quotient, remainder;

    divider dut (
        .i_clk(clk), .i_rst(rst),
        .i_start(start), .i_dividend(dividend), .i_divisor(divisor), .i_signed(is_signed),
        .o_busy(busy), .o_done(done), .o_quotient(quotient), .o_remainder(remainder)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;   /* NUM_ITER * 2 checks would otherwise flood the log with thousands of PASS lines. */
    `include "check_lib.sv"

    /*
     * Drives one division to completion, same handshake shape as
     * divider_tb.sv's own run_division (busy low before start, start
     * pulse, poll for done). Deliberately does NOT re-check the
     * busy-multiple-cycles/done-one-cycle-pulse timing properties here --
     * divider_tb.sv already covers that ground directly; this file's
     * whole incremental value is checking the ANSWER across a wide
     * randomized input space, not re-proving the handshake shape.
     */
    task automatic run_division(logic [(`WORD_SIZE-1):0] a, logic [(`WORD_SIZE-1):0] b, logic sgn);
        @(negedge clk);
        dividend = a; divisor = b; is_signed = sgn; start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        while (done !== 1'b1) @(negedge clk);
    endtask

    initial begin
        int unsigned bucket;
        logic [(`WORD_SIZE - 1):0] a, b;
        logic                      sgn;
        logic [(`WORD_SIZE - 1):0] exp_quot, exp_rem;

        start = 0; dividend = 0; divisor = 0; is_signed = 0;
        @(negedge clk);
        rst = 0;

        for (int i = 0; i < NUM_ITER; i++) begin
            sgn = 1'($urandom_range(0, 1));

            bucket = $urandom_range(0, 9);
            case (bucket)
                0, 1: begin
                    /* Divide by zero -- dividend random, divisor forced to 0. */
                    a = {$urandom(), $urandom()};
                    b = `WORD_SIZE'(0);
                end
                2: begin
                    /* Signed overflow: INT64_MIN / -1, only meaningful when signed. */
                    a   = 64'h8000000000000000;
                    b   = -64'sd1;
                    sgn = 1'b1;
                end
                3, 4, 5: begin
                    /* Small magnitudes -- easy-to-eyeball quotients/remainders. */
                    a = `WORD_SIZE'($urandom_range(0, 99));
                    b = `WORD_SIZE'($urandom_range(1, 99));   /* 1..99: this bucket isn't the divide-by-zero bucket */
                    /* Occasionally flip a/b negative when signed, to exercise small-value sign combinations too. */
                    if (sgn) begin
                        if ($urandom_range(0, 1) == 1) a = (~a + 1'b1);
                        if ($urandom_range(0, 1) == 1) b = (~b + 1'b1);
                    end
                end
                default: begin
                    /* 6,7,8,9: fully wide-randomized. */
                    a = {$urandom(), $urandom()};
                    b = {$urandom(), $urandom()};
                end
            endcase

            run_division(a, b, sgn);

            /* Shadow model -- independent of divider.sv's own algorithm. */
            if (b == `WORD_SIZE'(0)) begin
                /* Divide-by-zero override table (fact 11 / RV64M spec, L=64 here). */
                exp_quot = sgn ? {`WORD_SIZE{1'b1}} : {`WORD_SIZE{1'b1}};   /* DIV -> -1, DIVU -> 2^64-1: same bit pattern */
                exp_rem  = a;                                              /* REM/REMU -> dividend, unchanged */
            end else if (sgn && (a == 64'h8000000000000000) && (b == -64'sd1)) begin
                /* Signed overflow override table (fact 11). */
                exp_quot = 64'h8000000000000000;   /* DIV -> dividend itself */
                exp_rem  = `WORD_SIZE'(0);         /* REM -> 0 */
            end else if (sgn) begin
                /* General signed case: native signed / and % round toward zero, matching the spec. */
                exp_quot = $signed(a) / $signed(b);
                exp_rem  = $signed(a) % $signed(b);
            end else begin
                /* General unsigned case. */
                exp_quot = a / b;
                exp_rem  = a % b;
            end

            check($sformatf("iter %0d (bucket %0d, signed=%0d): a=%h b=%h quotient", i, bucket, sgn, a, b),
                  quotient, exp_quot);
            check($sformatf("iter %0d (bucket %0d, signed=%0d): a=%h b=%h remainder", i, bucket, sgn, a, b),
                  remainder, exp_rem);
        end

        $display("");
        $display("divider_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  NUM_ITER, pass_count, fail_count);
        if (fail_count > 0) $display("divider_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
