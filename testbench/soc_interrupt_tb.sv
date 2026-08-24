// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: end-to-end machine-timer-interrupt test against the REAL
 * soc.sv topology (core+decoder+cache+sram+uart+clint) and a REAL
 * toolchain-assembled program (firmware/interrupt_test.s) -- the final
 * proof for Milestone 6: everything from clint0's real free-running
 * mtime, through wb_addr_decoder's real address routing, through
 * csr_file0's real mip/mie/mstatus plumbing, through core0's real
 * interrupt-taking FSM, actually works together as wired in soc.sv, not
 * just in isolation.
 *
 * Follows testbench/core_priv_toolchain_tb.sv's exact loading
 * convention: `soc dut (.clk(clk), .rst(rst));` (soc_tb.sv's own idiom),
 * then a #1-delayed $readmemh override of dut.sram0.memory with the real
 * assembled interrupt_test.hex, run AFTER wb4_sram's own time-0
 * zero-fill+crt0.hex init so this test's image wins.
 *
 * TIMEOUT_CYCLES: generous (5000, matching this project's own
 * TIMEOUT_CYCLES_LARGE tier for real firmware) -- every fetch/load in
 * this milestone's real soc.sv topology is a genuine Wishbone
 * transaction (cache-mediated for RAM, uncached for CLINT/UART), and the
 * program's own busy-loop polls CLINT's real, uncacheable mtime once per
 * iteration until the real interrupt preempts it.
 */
module soc_interrupt_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * mcause_q snapshot, taken on the SAME edge the terminal ebreak's own
     * trap_taken first fires -- NOT read live at check() time. mtvec
     * stays armed at interrupt_test.s's own m_trap_handler through
     * crt0.s's trailing ebreak, which now really traps and bounces right
     * back into it, corrupting mcause_q afterward (same class of bug as
     * core_priv_tb.sv/core_priv_toolchain_tb.sv/core_priv_u_ecall_tb.sv --
     * see their own comments). mcause_q's own always_ff writes
     * non-blocking on i_trap_taken, so reading it on this identical edge
     * sees the PRE-edge value -- the real interrupt's own cause, before
     * this ebreak's own entry overwrites it.
     */
    logic [63:0] final_mcause_snap;
    logic final_state_captured = 1'b0;
    always @(posedge clk) if (!final_state_captured && dut.core0.trap_taken && dut.core0.is_ebreak) begin
        final_state_captured <= 1'b1;
        final_mcause_snap <= dut.core0.csr_file0.mcause_q;
    end

    localparam int TIMEOUT_CYCLES_INTERRUPT = 5000;

    initial begin
        #1; // run after wb4_sram's own time-0 init (see header comment)
        $readmemh("../firmware/interrupt_test.hex", dut.sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(TIMEOUT_CYCLES_INTERRUPT, "EBREAK trap never fired -- is firmware/interrupt_test.hex built?");

        /*
         * s1 (x9): marker set inside m_trap_handler -- proves the real
         * machine-timer interrupt fired exactly once through the real
         * CLINT/decoder/core path (mret's own MIE-restore doesn't
         * re-trigger a second entry, since the handler disarms mtimecmp
         * before returning -- if it DID re-fire, s1 would still just
         * read 1 here, so the real proof of "exactly once" is the
         * separate mtvec-only-ever-armed-once reasoning below, not s1's
         * own value).
         */
        check("s1 (handler marker): real timer interrupt fired", dut.core0.regfile0.gp_registers[9], 64'd1);

        /*
         * mcause: standard machine-timer-interrupt encoding (bit 63 set,
         * cause value 7) -- confirms the real interrupt_taken path (not
         * some other trap) is what actually redirected control.
         */
        check("final-state sample was captured (sanity on the monitor itself)", {63'b0, final_state_captured}, 64'd1);
        check("mcause == standard machine-timer-interrupt encoding", final_mcause_snap, 64'h8000_0000_0000_0007);

        /*
         * Execution genuinely resumed after the handler: interrupt_test.s
         * has exactly one ebreak (crt0.s's own trailing one) -- reaching
         * `halted` at all is only possible via busy_done's `ret`
         * falling back into it, which itself is only reachable by
         * genuinely resuming execution in busy_loop after the mret
         * (whether the loop needed 0 more iterations or several before
         * its own exit condition/bound was met).
         */
        check("EBREAK trap fired (real forward progress after the handler)", {63'b0, halted}, 64'd1);

        /* Never bootstrapped away from M -- interrupt_test.s runs entirely in M-mode. */
        check("final current_priv == M", {62'b0, dut.core0.current_priv}, 64'(2'b11));

        /*
         * clint0.mtip_o should have already deasserted by the time the
         * program halts (the handler explicitly disarms mtimecmp before
         * mret) -- a real, black-box-adjacent confirmation that the
         * disarm store actually reached the real CLINT through the real
         * bus, not just that the CPU-side mip bit read correctly once.
         */
        check("clint0.mtip_o deasserted (handler's disarm store landed)", {63'b0, dut.clint0.mtip_o}, 64'd0);

        $display("");
        $display("soc_interrupt_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_interrupt_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
