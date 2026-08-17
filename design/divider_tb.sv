// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: divider
 *
 * Unit-level, standalone -- drives divider directly, same shape as
 * alu_tb.sv/register_file_tb.sv/csr_file_tb.sv. Covers basic unsigned and
 * all-4-sign-combination signed division (proving "rounds toward zero"
 * semantics, not floor division -- they differ whenever exactly one
 * operand is negative), plus the divide-by-zero and signed-overflow
 * special cases. Those two are the actual point of this file: per
 * divider.sv's own header comment, NEITHER has any explicit detection
 * logic in the RTL -- both are claimed to fall out for free from plain
 * two's-complement magnitude arithmetic. This testbench either confirms
 * that claim or disproves it; nothing here assumes the claim is correct.
 *
 * Also confirms the busy/done handshake behaves like a real multi-cycle
 * operation (busy for more than one cycle, done exactly one cycle wide),
 * not something that silently completes combinationally -- a subtly
 * broken handshake could otherwise let a caller read garbage and still
 * coincidentally get a plausible-looking answer on simple test cases.
 *
 * Also covers the *W-variant (DIVW/DIVUW/REMW/REMUW) divide-by-zero and
 * signed-overflow special cases, fed the same pre-sign-or-zero-extended
 * 32-bit-into-64-bit operand shapes core.sv's own "M extension: divide"
 * section actually produces for those instructions -- see the dedicated
 * comment block further down for why this is sufficient to prove the *W
 * forms' underlying arithmetic without a second divider implementation,
 * and for one genuinely surprising divergence it uncovers (the DIVW/REMW
 * signed-overflow case does NOT "fall out for free" from this divider
 * alone the same way the native 64-bit INT64_MIN/-1 case does -- it only
 * becomes correct one level up, via core.sv's own post-truncation step).
 * testbench/core_m_w_edgecases_tb.sv separately proves the full
 * fetch/decode/execute/writeback pipeline gets these right end to end,
 * not just this module in isolation.
 */
module divider_tb;

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

    task automatic check(string name, logic [(`WORD_SIZE-1):0] actual, logic [(`WORD_SIZE-1):0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /*
     * Drives one division to completion and returns via quotient/remainder
     * (read directly by the caller once this returns). Also checks the
     * busy/done handshake shape on every call: busy must be low before
     * start, go high, stay high across MULTIPLE cycles (proving this
     * isn't secretly combinational), then done pulses for exactly one
     * cycle as busy drops.
     */
    task automatic run_division(logic [(`WORD_SIZE-1):0] a, logic [(`WORD_SIZE-1):0] b, logic sgn);
        @(negedge clk);
        if (busy !== 1'b0) begin
            fail_count++;
            $display("FAIL: busy was already high before start was asserted");
        end
        dividend = a; divisor = b; is_signed = sgn; start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        @(negedge clk); // one cycle after start: busy must be high, done must not have fired yet
        if (busy !== 1'b1) begin
            fail_count++;
            $display("FAIL: busy did not go high one cycle after start");
        end
        // wait for done, counting cycles to confirm this genuinely took more than one
        begin
            int cycles_waited = 0;
            while (done !== 1'b1) begin
                @(negedge clk);
                cycles_waited++;
                if (cycles_waited > `WORD_SIZE + 5) begin
                    fail_count++;
                    $display("FAIL: divider never asserted done (timeout)");
                    break;
                end
            end
            if (cycles_waited < 2) begin
                fail_count++;
                $display("FAIL: divider completed suspiciously fast (%0d cycles) -- looks combinational, not iterative", cycles_waited);
            end
        end
        @(negedge clk); // one more cycle: done must have dropped back to 0 (one-cycle pulse)
        if (done !== 1'b0) begin
            fail_count++;
            $display("FAIL: done did not drop back to 0 after one cycle (not a clean pulse)");
        end
    endtask

    initial begin
        start = 0; dividend = 0; divisor = 0; is_signed = 0;
        @(negedge clk);
        rst = 0;

        /* Basic unsigned: 100/7 = 14 remainder 2. */
        run_division(64'd100, 64'd7, 1'b0);
        check("DIVU-style: 100/7 quotient", quotient, 64'd14);
        check("REMU-style: 100/7 remainder", remainder, 64'd2);

        /*
         * All 4 signed sign-combinations on the same magnitudes (100, 7) --
         * proves "rounds toward zero" (truncating) division, not floor
         * division. They genuinely differ here: floor(-100/7) = -15, but
         * truncating gives -14 -- this is the disambiguating case.
         */
        run_division(64'd100, 64'd7, 1'b1);
        check("DIV: 100/7 (pos/pos) quotient", quotient, 64'd14);
        check("REM: 100/7 (pos/pos) remainder", remainder, 64'd2);

        run_division(64'd100, -64'sd7, 1'b1);
        check("DIV: 100/-7 (pos/neg) quotient", quotient, -64'sd14);
        check("REM: 100/-7 (pos/neg) remainder -- takes DIVIDEND's sign (positive)", remainder, 64'd2);

        run_division(-64'sd100, 64'd7, 1'b1);
        check("DIV: -100/7 (neg/pos) quotient", quotient, -64'sd14);
        check("REM: -100/7 (neg/pos) remainder -- takes DIVIDEND's sign (negative)", remainder, -64'sd2);

        run_division(-64'sd100, -64'sd7, 1'b1);
        check("DIV: -100/-7 (neg/neg) quotient", quotient, 64'd14);
        check("REM: -100/-7 (neg/neg) remainder", remainder, -64'sd2);

        /* Larger unsigned values, confirming the algorithm isn't secretly narrow. */
        run_division(64'hFFFFFFFFFFFFFFFF, 64'd3, 1'b0);
        check("DIVU: max-u64/3 quotient", quotient, 64'h5555555555555555);
        check("REMU: max-u64/3 remainder", remainder, 64'd0);

        /*
         * Divide by zero -- per divider.sv's header, no explicit detection
         * exists; these results are claimed to fall out of the algorithm
         * automatically. If that reasoning is wrong, these fail.
         */
        run_division(-64'sd1, 64'd0, 1'b1);
        check("DIV: -1/0 -> -1 (per spec override)", quotient, -64'sd1);

        run_division(64'hFFFFFFFFFFFFFFFF, 64'd0, 1'b0);
        check("DIVU: max-u64/0 -> 2^64-1 (per spec override)", quotient, 64'hFFFFFFFFFFFFFFFF);

        run_division(64'd12345, 64'd0, 1'b1);
        check("REM: 12345/0 -> dividend unchanged (per spec override)", remainder, 64'd12345);

        run_division(-64'sd12345, 64'd0, 1'b1);
        check("REM: -12345/0 -> dividend unchanged, negative (per spec override)", remainder, -64'sd12345);

        /*
         * Signed overflow: INT64_MIN / -1. Per divider.sv's header, this
         * also falls out of the algorithm automatically (taking INT64_MIN's
         * magnitude is itself a two's-complement "overflow" that lands
         * back on the correct answer). If that reasoning is wrong, this
         * fails.
         */
        run_division(64'h8000000000000000, -64'sd1, 1'b1);
        check("DIV: INT64_MIN/-1 -> INT64_MIN (per spec override, not a trap)", quotient, 64'h8000000000000000);
        check("REM: INT64_MIN/-1 -> 0 (per spec override)", remainder, 64'd0);

        /*
         * -----------------------------------------------------------
         * *W-variant divide-by-zero / signed-overflow (Pillar A gap)
         * -----------------------------------------------------------
         * Everything above tests the 64-bit DIV/DIVU/REM/REMU forms
         * directly. The *W forms (DIVW/DIVUW/REMW/REMUW) execute on this
         * exact same divider hardware -- this module never "knows" it's
         * serving a *W instruction. core.sv's own "M extension: divide"
         * section is what pre-sign-or-zero-extends a *W instruction's
         * 32-bit operands up to WORD_SIZE before they ever reach
         * i_dividend/i_divisor here (its div_dividend_in/div_divisor_in
         * wires), and separately truncates+resigns whichever of
         * o_quotient/o_remainder the instruction wants back down to a
         * sign-extended 32-bit result afterward (its div_result_raw/
         * div_result wires) -- see core.sv itself for that half of the
         * story, which is NOT exercised by this file. What IS exercised
         * here: feeding this divider the SAME pre-extended-operand shapes
         * core.sv would actually produce proves the underlying magnitude
         * arithmetic is right for the *W forms too, without a second
         * divider implementation to maintain or trust blindly.
         *
         * Divide-by-zero, quotient side (DIVW/DIVUW-style): per this
         * file's existing 64-bit cases and divider.sv's own header, the
         * divisor_mag_q==0 bypass fires for ANY zero divisor -- sign- or
         * zero-extended, since a 0 magnitude is the identical 64'h0 bit
         * pattern either way -- and unconditionally forces o_quotient to
         * all-1s REGARDLESS of i_signed or the dividend's value. That
         * means DIVW-by-zero and DIVUW-by-zero are PROVEN here to produce
         * the exact same raw quotient (both all-1s) -- a genuine ISA
         * property (the same reason DIV's and DIVU's own by-zero
         * overrides already coincide bit-for-bit above), not a weakness
         * in these two checks' ability to tell DIVW and DIVUW apart.
         */
        run_division(64'hFFFFFFFFFFFFFF9C /* -100, sign-extended: DIVW-style dividend */, 64'd0, 1'b1);
        check("DIVW-style: -100/0 -> -1 (same bit pattern as DIV's own override)", quotient, -64'sd1);

        run_division(64'h000000000000022B /* 555, zero-extended: DIVUW-style dividend */, 64'd0, 1'b0);
        check("DIVUW-style: 555/0 -> raw divider output is 2^64-1 (all-1s); core.sv's OWN separate post-truncation step (not exercised by this unit-level file) is what turns this into DIVUW's correct 32-bit-then-sign-extended 2^32-1 result -- see testbench/core_m_w_edgecases_tb.sv for that full-pipeline proof",
              quotient, 64'hFFFFFFFFFFFFFFFF);

        /*
         * Divide-by-zero, remainder side (REMW/REMUW-style): "dividend
         * unchanged", proven against the exact pre-extended operand shape
         * core.sv would actually feed in (not a native, already-64-bit
         * value), confirming the override still holds when the dividend's
         * upper 32 bits are pre-extension filler rather than "real" data.
         */
        run_division(64'hFFFFFFFFFFFFFF9C /* -100, sign-extended: REMW-style dividend */, 64'd0, 1'b1);
        check("REMW-style: -100/0 -> pre-extended dividend unchanged", remainder, 64'hFFFFFFFFFFFFFF9C);

        run_division(64'h000000000000022B /* 555, zero-extended: REMUW-style dividend */, 64'd0, 1'b0);
        check("REMUW-style: 555/0 -> pre-extended dividend unchanged", remainder, 64'h000000000000022B);

        /*
         * Signed overflow, DIVW/REMW-style: the spec override for L=32 is
         * dividend=-2^31, divisor=-1 -> quotient=-2^31 (dividend itself),
         * remainder=0. But core.sv feeds THIS divider the SIGN-EXTENDED
         * 64-bit form of -2^31, i.e. 0xFFFFFFFF80000000 -- genuinely NOT
         * the native 64-bit INT64_MIN pattern (0x8000000000000000) the
         * case above already covers, and this is deliberately checked
         * rather than assumed to behave the same way:
         *
         * Taking the magnitude of 0xFFFFFFFF80000000 is NOT itself a
         * two's-complement "overflow" at 64-bit width the way taking the
         * magnitude of the true 64-bit INT64_MIN (0x8000...0) is -- 2^31
         * is a perfectly ordinary, representable positive 64-bit value
         * (unlike 2^63, which has no positive 64-bit signed
         * representation and wraps back onto its own bit pattern). So
         * quot_q loads as an ordinary magnitude 0x0000000080000000 (=
         * 2^31), divisor_mag_q loads as 1 (magnitude of -1), and dividing
         * an ordinary representable magnitude by 1 is just an everyday
         * division: quotient magnitude 2^31, remainder 0 -- no wraparound
         * involved anywhere. Sign correction (dividend_neg_q XOR
         * divisor_neg_q = 1 XOR 1 = 0, i.e. not negated) leaves the
         * quotient at that same POSITIVE 0x0000000080000000.
         *
         * That raw quotient does NOT equal "dividend, unchanged" the way
         * the 64-bit INT64_MIN/-1 case's did above -- it only becomes the
         * spec-correct -2^31 answer one level up, in core.sv, via ITS
         * separate post-truncation step (take o_quotient's low 32 bits,
         * 0x80000000, then sign-extend on THAT bit 31, which is 1 --
         * landing on 0xFFFFFFFF80000000 by a completely different
         * mechanism than the raw-divider-level coincidence the 64-bit
         * case relies on). Confirmed here explicitly, per design; this
         * file's job stops at the divider's own raw output -- see
         * testbench/core_m_w_edgecases_tb.sv for confirmation that
         * core.sv's post-truncation step completes the correct DIVW
         * answer on top of this.
         */
        run_division(64'hFFFFFFFF80000000 /* -2^31, sign-extended: DIVW/REMW-style dividend */, -64'sd1, 1'b1);
        check("DIVW-style overflow: raw quotient is +2^31 (0x0000000080000000), NOT the sign-extended dividend pattern -- genuinely diverges from the 64-bit INT64_MIN/-1 case (see comment above); core.sv's own post-truncation is what recovers the correct -2^31 DIVW answer, not this divider alone",
              quotient, 64'h0000000080000000);
        check("REMW-style overflow: raw remainder is 0, same conclusion as the 64-bit INT64_MIN/-1 case", remainder, 64'd0);

        $display("");
        $display("divider_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("divider_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
