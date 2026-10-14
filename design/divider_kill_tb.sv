// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: divider's i_kill
 *
 * The pipelined core kills the divider on every flush, so a division for an
 * instruction that no longer exists never delivers a result. Covered here:
 * a kill at each stage of a division (just after the start, mid-way, one
 * and two cycles from the end, in the done cycle itself) leaves busy and
 * done low and never produces a later done pulse; a kill in the same cycle
 * as a start cancels the start; and the divider afterwards divides
 * correctly (nothing of the abandoned operands leaks into the next result).
 * i_kill defaults to 0, which divider_tb.sv and core.sv's own instance rely
 * on (neither connects it).
 */
module divider_kill_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic start = 0, kill = 0, is_signed = 1;
    logic [(`WORD_SIZE - 1):0] dividend = 0, divisor = 1;
    logic busy, done;
    logic [(`WORD_SIZE - 1):0] quotient, remainder;

    divider dut (
        .i_clk(clk), .i_rst(rst),
        .i_start(start), .i_dividend(dividend), .i_divisor(divisor), .i_signed(is_signed),
        .i_kill(kill),
        .o_busy(busy), .o_done(done), .o_quotient(quotient), .o_remainder(remainder)
    );

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(string name, logic [(`WORD_SIZE-1):0] actual, logic [(`WORD_SIZE-1):0] expected);
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    int done_pulses;
    always @(posedge clk) if (done) done_pulses <= done_pulses + 1;

    // one start pulse, then a kill after k further cycles (k = 0: the cycle after the start)
    task automatic start_then_kill(input int k);
        int waited;
        @(negedge clk);
        dividend = 64'd1000; divisor = 64'd7; is_signed = 1'b1;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        for (int i = 0; i < k; i++) @(negedge clk);
        done_pulses = 0;
        kill = 1'b1;
        @(posedge clk); #1;
        kill = 1'b0;
        check($sformatf("kill after %0d cycles: busy drops", k), {63'b0, busy}, 64'd0);
        check($sformatf("kill after %0d cycles: done low", k), {63'b0, done}, 64'd0);
        repeat (100) @(posedge clk);
        #1;
        check($sformatf("kill after %0d cycles: no done pulse ever follows", k), 64'(done_pulses), 64'd0);
        check($sformatf("kill after %0d cycles: still idle", k), {63'b0, busy}, 64'd0);
    endtask

    task automatic divide_check(input string name, input logic [63:0] a, input logic [63:0] b,
                                input logic [63:0] exp_q, input logic [63:0] exp_r);
        int waited;
        @(negedge clk);
        dividend = a; divisor = b; is_signed = 1'b1;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        waited = 0;
        while (!done && waited < 200) begin @(negedge clk); waited++; end
        check({name, ": completes"}, {63'b0, done}, 64'd1);
        check({name, ": quotient"}, quotient, exp_q);
        check({name, ": remainder"}, remainder, exp_r);
    endtask

    initial begin
        done_pulses = 0;
        repeat (3) @(posedge clk);
        #1 rst = 0;

        // a kill with nothing running is harmless
        @(negedge clk); kill = 1'b1;
        @(posedge clk); #1; kill = 1'b0;
        check("idle kill: not busy", {63'b0, busy}, 64'd0);
        check("idle kill: no done", {63'b0, done}, 64'd0);
        divide_check("after idle kill", 64'd100, 64'd7, 64'd14, 64'd2);

        // kills at every stage of a division (it takes WORD_SIZE iterations)
        start_then_kill(0);
        start_then_kill(1);
        start_then_kill(10);
        start_then_kill(`WORD_SIZE - 3);
        start_then_kill(`WORD_SIZE - 2);    // the last iteration
        start_then_kill(`WORD_SIZE - 1);
        divide_check("after kills", -64'sd100, 64'd7, -64'sd14, -64'sd2);
        divide_check("after kills (by zero)", 64'd5, 64'd0, '1, 64'd5);

        // a kill in the done cycle itself: the pulse had already been raised
        // for that cycle, but nothing follows it and the divider is idle
        @(negedge clk);
        dividend = 64'd99; divisor = 64'd9; is_signed = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        while (!done) @(negedge clk);
        kill = 1'b1;
        @(posedge clk); #1;                 // this edge ends the done cycle
        kill = 1'b0;
        done_pulses = 0;
        check("kill in the done cycle: done drops", {63'b0, done}, 64'd0);
        repeat (20) @(posedge clk);
        #1;
        check("kill in the done cycle: no second pulse", 64'(done_pulses), 64'd0);

        // a kill in the same cycle as a start cancels the start
        @(negedge clk);
        dividend = 64'd1000; divisor = 64'd7; is_signed = 1'b1;
        start = 1'b1; kill = 1'b1;
        @(posedge clk); #1;
        start = 1'b0; kill = 1'b0;
        check("kill with start: never busy", {63'b0, busy}, 64'd0);
        done_pulses = 0;
        repeat (100) @(posedge clk);
        #1;
        check("kill with start: no result", 64'(done_pulses), 64'd0);

        // a start right after a kill is accepted and correct
        start_then_kill(5);
        divide_check("start after kill", 64'd1000, 64'd7, 64'd142, 64'd6);
        divide_check("back to back", 64'd81, 64'd9, 64'd9, 64'd0);

        $display("");
        $display("divider_kill_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("divider_kill_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT: divider_kill_tb");
        $finish;
    end

endmodule: divider_kill_tb


/* ------------------------------------------------------------------------- */


/* End of file. */
