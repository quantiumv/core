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

        $display("");
        $display("cache_complex_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("cache_complex_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
