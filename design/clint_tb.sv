// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: clint
 *
 * Drives the Wishbone port directly -- no core.sv involved, same idiom
 * as design/wb4_sram_tb.sv and design/uart_tx_tb.sv. check() and
 * wb_cycle() come from testbench/check_lib.sv and testbench/wb_driver.sv
 * (see each for its required-signal contract) -- resolved via a bare
 * filename plus -I testbench on the iverilog command line, per those
 * files' own headers.
 */
module clint_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;
    logic        mtip;

    clint dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .mtip_o(mtip)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'h00;
        @(posedge clk); #1;
        rst = 0;

        /*
         * -- 1. mtime free-run rate --
         * Read mtime twice, N wb_cycle() calls apart (each wb_cycle is
         * itself one clock period end-to-end: negedge-set, then the next
         * posedge is when the DUT registers the read and ack), and check
         * the delta against whatever N wb_cycle() calls actually advance
         * mtime_q by -- determined empirically below rather than assumed,
         * per the milestone's own instructions.
         */
        wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
        begin
            logic [63:0] mtime_first, mtime_second;
            mtime_first = dat_o;
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            mtime_second = dat_o;
            // 3 wb_cycle() calls separate the two reads above; empirically
            // each wb_cycle() advances mtime_q by exactly 1 (one posedge
            // per call), so the delta is exactly 3.
            check("mtime free-run delta == 3 over 3 wb_cycle() calls",
                  mtime_second - mtime_first, 64'd3);
        end

        /*
         * -- 2. mtimecmp resets to all-ones --
         * Already proven true by construction (rst deasserted once above,
         * before any write to mtimecmp), so read it now, before this
         * testbench performs its first write, below.
         */
        wb_cycle(32'h8, 64'h0, 8'h00, 1'b0);
        check("mtimecmp resets to all-ones", dat_o, 64'hFFFF_FFFF_FFFF_FFFF);

        /*
         * -- 3. mtimecmp byte-lane writes --
         * Full-word write first to get a known non-all-ones, non-zero
         * value into every lane, then a partial write (lanes 0-1 only)
         * and confirm lanes 2-7 keep the prior full-word value while
         * lanes 0-1 take the new bytes.
         */
        wb_cycle(32'h8, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h8, 64'h0, 8'h00, 1'b0);
        check("full 8-byte (sel_i=8'hFF) write reads back exactly", dat_o, 64'hDEADBEEF_CAFEF00D);

        wb_cycle(32'h8, 64'h0000_0000_0000_A5A5, 8'h03, 1'b1);
        wb_cycle(32'h8, 64'h0, 8'h00, 1'b0);
        check("byte-enable write only touches enabled lanes", dat_o, 64'hDEADBEEF_CAFEA5A5);

        /*
         * -- 3b. A write to mtime's own address (0x0) is a no-op --
         * mtime has no write path at all; confirm a write attempt there
         * neither corrupts mtime_q's free-run nor spuriously asserts
         * err_o, rather than assuming silence means correctness.
         */
        begin
            logic [63:0] mtime_before_noop_write, mtime_after_noop_write;
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            mtime_before_noop_write = dat_o;
            wb_cycle(32'h0, 64'hFFFF_FFFF_FFFF_FFFF, 8'hFF, 1'b1);
            check("write to mtime's address doesn't assert err_o", {63'b0, err}, 64'd0);
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            mtime_after_noop_write = dat_o;
            // The write plus the final read are 2 wb_cycle() calls between
            // the two capture points (mtime_before_noop_write is captured
            // AFTER the first read, so it isn't itself one of the 2), same
            // 1-tick-per-call rate already established above -- confirms
            // the write attempt didn't ALSO stomp mtime_q with the bogus
            // all-ones write data on top of its own natural free-run
            // advance.
            check("write to mtime's address doesn't corrupt its free-running value",
                mtime_after_noop_write - mtime_before_noop_write, 64'd2);
        end

        /*
         * -- 4. mtip_o comparison correctness --
         * Program mtimecmp to a near-future deadline (current mtime plus
         * a small delta), confirm mtip_o is low before mtime reaches it
         * and goes high once mtime >= mtimecmp, letting simulated time
         * actually advance between the two checks rather than comparing
         * static values.
         */
        begin
            logic [63:0] mtime_now, deadline;
            int          wait_cycles;
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            mtime_now = dat_o;
            deadline  = mtime_now + 64'd5;
            wb_cycle(32'h8, deadline, 8'hFF, 1'b1);
            check("mtip_o low before deadline reached", {63'b0, mtip}, 64'd0);
            /*
             * Bounded, not `while (mtip !== 1'b1) @(posedge clk);` --
             * found by code review: an unbounded wait here means a
             * genuinely broken comparator (e.g. mtip_o wired to `<=`
             * instead of `>=`) would hang this testbench forever instead
             * of failing cleanly, unlike every other wait in this
             * project's suite (halt_wait.sv's wait_halted_or_timeout,
             * wb_cycle()'s own !ack&&!err loop, which is bounded in
             * practice by every real slave always eventually
             * ack/err-ing). 20 cycles is generous headroom over the
             * 5-cycle deadline programmed above. Also adds the #1 settle
             * testbench/wb_driver.sv's own header documents by name --
             * mtip_o is combinational off mtime_q/mtimecmp_q, both
             * NBA-updated, so reading it immediately upon resuming from
             * @(posedge clk) risks the same one-edge-stale read class
             * that file's own history already found and fixed once.
             */
            wait_cycles = 0;
            while (mtip !== 1'b1 && wait_cycles < 20) begin
                @(posedge clk); #1;
                wait_cycles = wait_cycles + 1;
            end
            check("mtip_o high once mtime >= mtimecmp (within 20 cycles)", {63'b0, mtip}, 64'd1);
        end

        /*
         * -- 4b. mtip_o comparison correctness: deadline already passed --
         * Program mtimecmp to a value already at-or-below current mtime
         * and confirm mtip_o reads high immediately, not just eventually
         * -- the other edge of the comparison this project's own review
         * flagged as an explicitly-requested case not otherwise covered.
         */
        begin
            logic [63:0] mtime_now;
            wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
            mtime_now = dat_o;
            wb_cycle(32'h8, mtime_now, 8'hFF, 1'b1);
            #1;
            check("mtip_o high immediately when mtimecmp is set to an already-passed deadline",
                {63'b0, mtip}, 64'd1);
        end

        /*
         * -- 5. ack/err timing --
         * ack_o must NOT assert combinationally in the same cycle
         * cyc_i/stb_i first go high -- it's a registered, 1-wait-state
         * response. Drive the bus signals directly here (bypassing
         * wb_cycle(), which already waits a cycle for ack) so the
         * same-cycle value can actually be observed.
         *
         * Settle first: whatever immediately precedes this block used
         * wb_cycle(), which returns with cyc/stb freshly deasserted but
         * ack still HIGH from that transaction's own completion -- ack
         * only clears on the NEXT edge where cyc&&stb reads false, and
         * nothing above guarantees that edge has actually happened yet
         * (a `#1`-only tail, with no intervening @(posedge clk), leaves
         * this block's own very next `@(negedge clk)` sharing the SAME
         * cycle as that still-pending clear). Explicitly waiting for
         * ack==0 here removes the dependency on however many posedges
         * happened to elapse in whatever code happens to run immediately
         * before this block -- found by exactly this failure mode when a
         * new test was inserted directly above during code review.
         */
        while (ack) @(posedge clk);
        @(negedge clk);
        addr = 32'h0; dat_i = 64'h0; sel = 8'h00; we = 1'b0; cyc = 1'b1; stb = 1'b1;
        #1;
        check("ack_o not combinational same-cycle as cyc/stb", {63'b0, ack}, 64'd0);
        @(posedge clk); #1;
        check("ack_o asserts one cycle after cyc_i&&stb_i", {63'b0, ack}, 64'd1);
        cyc = 0; stb = 0;
        @(negedge clk);

        // err_o must never assert, for any address/access pattern tried
        // above (already implicitly checked by wb_cycle()'s own
        // !ack && !err wait loop never hanging), plus explicit checks
        // across both registers and both access directions here.
        wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
        check("err_o never asserts (mtime read)", {63'b0, err}, 64'd0);
        wb_cycle(32'h8, 64'h0, 8'h00, 1'b0);
        check("err_o never asserts (mtimecmp read)", {63'b0, err}, 64'd0);
        wb_cycle(32'h8, 64'hFFFF_FFFF_FFFF_FFFF, 8'hFF, 1'b1);
        check("err_o never asserts (mtimecmp write)", {63'b0, err}, 64'd0);

        $display("");
        $display("clint_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("clint_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
