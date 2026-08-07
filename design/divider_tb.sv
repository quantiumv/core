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

        $display("");
        $display("divider_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("divider_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
