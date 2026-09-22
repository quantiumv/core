// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: cache_complex
 *
 * No core.sv involved -- drives cache_complex's core-facing port
 * (including ifetch_i) directly, same "real backing wb4_sram, not a
 * behavioral model" idiom icache_tb.sv/dcache_tb.sv already use. This
 * file's own job is specifically the ROUTING cache_complex.sv adds on
 * top of icache.sv/dcache.sv, which their own unit tests can't exercise
 * at all (neither one has an ifetch_i input): alternating ifetch_i=1/0
 * transactions, including immediately-back-to-back opposite-stream
 * pairs (mimicking S_MEM immediately followed by the next instruction's
 * S_FETCH, core.sv's own normal cadence), confirming no cross-talk
 * between icache0 and dcache0 on the shared downstream port.
 */
module cache_complex_tb;

    localparam NUM_LINES  = 4;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 64; // backing SRAM: 64 dwords = 512 bytes

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // cache_complex core-facing port.
    logic [31:0] cc_addr;
    logic [63:0] cc_dat_i, cc_dat_o;
    logic [7:0]  cc_sel;
    logic        cc_we, cc_ifetch, cc_cyc, cc_stb, cc_ack, cc_err;

    // cache_complex <-> wb4_sram, memory-facing.
    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    cache_complex #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) dut (
        .clk(clk), .rst(rst),
        .addr_i(cc_addr), .dat_i(cc_dat_i), .dat_o(cc_dat_o), .sel_i(cc_sel),
        .we_i(cc_we), .ifetch_i(cc_ifetch), .cyc_i(cc_cyc), .stb_i(cc_stb),
        .ack_o(cc_ack), .err_o(cc_err),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    wb4_sram #(.num_words(NUM_WORDS)) mem0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(mem_dat_m2s), .dat_o(mem_dat_s2m), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    task automatic cc_cycle(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w, logic ifetch);
        @(negedge clk);
        cc_addr = a; cc_dat_i = d; cc_sel = s; cc_we = w; cc_ifetch = ifetch;
        cc_cyc = 1; cc_stb = 1;
        @(posedge clk); #1;
        while (!cc_ack && !cc_err) begin
            @(posedge clk); #1;
        end
        cc_cyc = 0; cc_stb = 0;
    endtask

    /*
     * cc_issue: drive a core-facing request for exactly ONE cycle, then
     * drop cyc_i/stb_i -- does NOT wait for ack_o/err_o. Only valid to
     * use this way because icache.sv/dcache.sv's own CACHE_IDLE arm only
     * ever consults cyc_i/stb_i for the single cycle it samples hit vs.
     * miss (confirmed directly against the real RTL): once sampled, a
     * miss commits to CACHE_REFILL/CACHE_WRITE and runs to completion
     * autonomously off its own mem_ack_i/mem_err_i, needing nothing
     * further from cyc_i/stb_i. This lets a SECOND, different-stream
     * request be issued here on the very next cycle while the first is
     * still genuinely in flight downstream -- exactly the scenario the
     * new downstream arbiter (cache_complex.sv's own header) exists to
     * handle correctly, without this testbench needing two independent
     * core-facing ports (this module's core-facing side is still a
     * single shared one, unchanged -- see below for why that limits
     * what this test can observe directly, and how it works around it).
     */
    task automatic cc_issue(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w, logic ifetch);
        @(negedge clk);
        cc_addr = a; cc_dat_i = d; cc_sel = s; cc_we = w; cc_ifetch = ifetch;
        cc_cyc = 1; cc_stb = 1;
        @(posedge clk); #1;
        cc_cyc = 0; cc_stb = 0;
    endtask

    initial begin
        cc_addr = 0; cc_dat_i = 0; cc_sel = 0; cc_we = 0; cc_ifetch = 0; cc_cyc = 0; cc_stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Two independent lines (index 0 and index 1 at NUM_LINES=4,
        // LINE_WORDS=4 -- same address scheme as icache_tb.sv/dcache_tb.sv).
        mem0.memory[32'h00 >> 3] = 64'hAAAA_0000_0000_0000;
        mem0.memory[32'h08 >> 3] = 64'hAAAA_0000_0000_0001;
        mem0.memory[32'h20 >> 3] = 64'hCCCC_0000_0000_0000;
        mem0.memory[32'h28 >> 3] = 64'hCCCC_0000_0000_0001;

        // --- Basic correctness through the router: an I$ read (cold
        //     miss, full refill through icache0) ---
        cc_cycle(32'h00, 64'h0, 8'h00, 1'b0, 1'b1);
        check("I$ read: correct word", cc_dat_o, 64'hAAAA_0000_0000_0000);
        check("I$ read: err_o clear", {63'b0, cc_err}, 64'd0);

        // --- Basic correctness: a D$ read to a DIFFERENT line (cold
        //     miss, full refill through dcache0) -- proves the two
        //     sub-caches are genuinely independent instances (index 0 in
        //     icache0 and index 0 in dcache0 are different storage,
        //     even though the address happens to alias the SAME
        //     index/tag in each cache's own array). ---
        cc_cycle(32'h20, 64'h0, 8'h00, 1'b0, 1'b0);
        check("D$ read: correct word", cc_dat_o, 64'hCCCC_0000_0000_0000);
        check("D$ read: err_o clear", {63'b0, cc_err}, 64'd0);

        // --- I$ line from the first read is still cached: a repeat I$
        //     read for the SAME address is a hit, unaffected by the D$
        //     read of a different address in between. ---
        cc_cycle(32'h00, 64'h0, 8'h00, 1'b0, 1'b1);
        check("I$ still cached after intervening D$ read", cc_dat_o, 64'hAAAA_0000_0000_0000);

        // --- D$ write, immediately followed (same address family, back
        //     to back) by an I$ read of a DIFFERENT address -- mimics
        //     core.sv's own S_MEM -> S_FETCH cadence. Confirms the write
        //     completes correctly and the immediately-following I$
        //     transaction isn't corrupted by the D$ transaction that
        //     just preceded it. ---
        cc_cycle(32'h28, 64'hDEAD_BEEF_0000_0000, 8'hFF, 1'b1, 1'b0);
        check("D$ write: err_o clear", {63'b0, cc_err}, 64'd0);
        cc_cycle(32'h08, 64'h0, 8'h00, 1'b0, 1'b1);
        check("I$ read immediately after D$ write: correct word, no cross-talk",
              cc_dat_o, 64'hAAAA_0000_0000_0001);

        // --- Confirm the D$ write from above actually landed (both via
        //     dcache0's own cache and, transitively, SRAM, since
        //     write-through) -- immediately preceded by the I$ read
        //     above, same back-to-back-opposite-stream shape reversed. ---
        cc_cycle(32'h28, 64'h0, 8'h00, 1'b0, 1'b0);
        check("D$ read-back after intervening I$ read: correct word, no cross-talk",
              cc_dat_o, 64'hDEAD_BEEF_0000_0000);

        // --- Rapid alternation: 8 back-to-back transactions strictly
        //     alternating ifetch_i, each to an already-resident line (all
        //     hits by this point) -- every response must land in the
        //     right place every single time, not just "eventually settle". ---
        for (int i = 0; i < 8; i++) begin
            if (i % 2 == 0) begin
                cc_cycle(32'h00, 64'h0, 8'h00, 1'b0, 1'b1);
                check($sformatf("alternation %0d: I$ hit correct", i), cc_dat_o, 64'hAAAA_0000_0000_0000);
            end else begin
                cc_cycle(32'h20, 64'h0, 8'h00, 1'b0, 1'b0);
                check($sformatf("alternation %0d: D$ hit correct", i), cc_dat_o, 64'hCCCC_0000_0000_0000);
            end
        end

        /*
         * --- Genuine dual-outstanding contention (Pipelining P2
         *     prerequisite -- see cache_complex.sv's own header for the
         *     full design): an I$ cold-miss refill is issued and, BEFORE
         *     it can possibly complete (LINE_WORDS=4 beats, each needing
         *     a real round trip through wb4_sram), a D$ cold-miss
         *     refill to a DIFFERENT line is issued on top of it,
         *     exploiting cc_issue's own "sample once, move on" property
         *     -- exactly what core.sv's own future fstate/execute
         *     overlap will do. This module's core-facing ack_o/err_o/
         *     dat_o is still a single shared, active_ifetch_q-muxed
         *     output (core.sv still only issues one core-facing request
         *     at a time today), so this test can't observe BOTH
         *     streams' own completion at the top level simultaneously
         *     -- instead, it waits for the D$ request's own (now-active)
         *     ack, confirms it, then RE-ISSUES the original I$ address:
         *     if the new downstream arbiter correctly let icache0's own
         *     interrupted refill run to completion in the background,
         *     undisturbed by dcache0's own downstream traffic, this
         *     second I$ request is now a HIT with the right data.
         *
         *     Under the OLD single-latch design this test would have
         *     failed: icache0's own eventual mem_ack_i would have been
         *     silently dropped (ic_mem_ack permanently gated to 0 the
         *     instant active_ifetch_q flipped to dcache0), leaving
         *     icache0 stuck mid-refill forever with no way to complete.
         */
        mem0.memory[32'h40 >> 3] = 64'hDDDD_0000_0000_0000;
        mem0.memory[32'h48 >> 3] = 64'hDDDD_0000_0000_0001;
        mem0.memory[32'h50 >> 3] = 64'hDDDD_0000_0000_0002;
        mem0.memory[32'h58 >> 3] = 64'hDDDD_0000_0000_0003;
        mem0.memory[32'h60 >> 3] = 64'hEEEE_0000_0000_0000;
        mem0.memory[32'h68 >> 3] = 64'hEEEE_0000_0000_0001;
        mem0.memory[32'h70 >> 3] = 64'hEEEE_0000_0000_0002;
        mem0.memory[32'h78 >> 3] = 64'hEEEE_0000_0000_0003;

        // Sample icache0 into CACHE_REFILL for line 0x40, then move on
        // immediately -- icache0 is now autonomous, mid-refill.
        cc_issue(32'h40, 64'h0, 8'h00, 1'b0, 1'b1);

        // Before icache0's own refill can possibly finish, issue a D$
        // cold-miss to a DIFFERENT line: two independent, un-abortable
        // downstream transactions genuinely in flight at once.
        cc_cycle(32'h60, 64'h0, 8'h00, 1'b0, 1'b0);
        check("dual-outstanding: D$ read completes correctly despite icache0's own concurrent in-flight refill",
              cc_dat_o, 64'hEEEE_0000_0000_0000);
        check("dual-outstanding: D$ read err_o clear", {63'b0, cc_err}, 64'd0);

        // Re-issue the ORIGINAL I$ address -- if the arbiter correctly
        // let icache0's own interrupted refill complete in the
        // background, this is now a cache hit with the correct data.
        cc_cycle(32'h40, 64'h0, 8'h00, 1'b0, 1'b1);
        check("dual-outstanding: interrupted I$ refill completed correctly (now a hit, right data)",
              cc_dat_o, 64'hDDDD_0000_0000_0000);
        check("dual-outstanding: interrupted I$ refill err_o clear", {63'b0, cc_err}, 64'd0);

        // Confirm ALL FOUR words of the interrupted I$ line landed
        // correctly (not just the first beat, in case the arbiter's own
        // contention corrupted a LATER beat specifically).
        cc_cycle(32'h48, 64'h0, 8'h00, 1'b0, 1'b1);
        check("dual-outstanding: interrupted I$ refill, word 1 correct", cc_dat_o, 64'hDDDD_0000_0000_0001);
        cc_cycle(32'h50, 64'h0, 8'h00, 1'b0, 1'b1);
        check("dual-outstanding: interrupted I$ refill, word 2 correct", cc_dat_o, 64'hDDDD_0000_0000_0002);
        cc_cycle(32'h58, 64'h0, 8'h00, 1'b0, 1'b1);
        check("dual-outstanding: interrupted I$ refill, word 3 correct", cc_dat_o, 64'hDDDD_0000_0000_0003);

        // And confirm the D$ line that interrupted it is ALSO fully
        // intact, all four words.
        cc_cycle(32'h68, 64'h0, 8'h00, 1'b0, 1'b0);
        check("dual-outstanding: interrupting D$ refill, word 1 correct", cc_dat_o, 64'hEEEE_0000_0000_0001);
        cc_cycle(32'h70, 64'h0, 8'h00, 1'b0, 1'b0);
        check("dual-outstanding: interrupting D$ refill, word 2 correct", cc_dat_o, 64'hEEEE_0000_0000_0002);
        cc_cycle(32'h78, 64'h0, 8'h00, 1'b0, 1'b0);
        check("dual-outstanding: interrupting D$ refill, word 3 correct", cc_dat_o, 64'hEEEE_0000_0000_0003);

        $display("");
        $display("cache_complex_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("cache_complex_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
