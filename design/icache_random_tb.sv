// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: icache_random_tb
 *
 * Randomized property test for icache.sv -- separate from the directed
 * icache_tb.sv (don't touch a passing file; one file per testbench
 * concern, same convention divider_random_tb.sv used for divider.sv).
 *
 * Backing wb4_sram is preloaded with a simple, invertible per-word
 * pattern (mem0.memory[w] = {w, ~w[31:0]}) rather than arbitrary random
 * content, so the "expected value" for any address is a plain formula on
 * its own word index -- a genuinely independent code path from icache.sv's
 * own tag/index/data-array logic, not a hand-maintained shadow array that
 * would just be re-deriving the same bookkeeping the DUT already does.
 *
 * Address generation is deliberately biased toward a small "slot" space
 * (0..255, each slot a full 32-byte line) rather than uniform-random
 * across the whole address range -- with NUM_LINES=8, 256 slots cycle
 * through only 8 distinct indices (32 possible tags per index), so
 * repeated random draws hit real conflict evictions and cache hits at
 * volume, not just cold misses. Same "shrink the space to make edge cases
 * reachable" idiom design/wb4_sram_tb.sv and icache_tb.sv itself already
 * use, applied to a random stream instead of directed picks.
 *
 * Seeding: no explicit $srandom call, same as divider_random_tb.sv/
 * csr_file_random_tb.sv -- this iverilog build's bare $urandom/
 * $urandom_range are confirmed run-to-run deterministic unseeded.
 */
module icache_random_tb;

    localparam int NUM_ITER = 2000;

    localparam NUM_LINES  = 8;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 1024; // 8KB backing SRAM -- 32 tags/index at NUM_LINES=8

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] ic_addr;
    logic [63:0] ic_dat_o;
    logic        ic_cyc, ic_stb, ic_ack, ic_err;

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_o;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    icache #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) dut (
        .clk(clk), .rst(rst),
        .addr_i(ic_addr), .dat_o(ic_dat_o), .cyc_i(ic_cyc), .stb_i(ic_stb),
        .ack_o(ic_ack), .err_o(ic_err),
        .mem_addr_o(mem_addr), .mem_dat_i(mem_dat_o), .mem_sel_o(mem_sel),
        .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    wb4_sram #(.num_words(NUM_WORDS)) mem0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(64'b0), .dat_o(mem_dat_o), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;   /* NUM_ITER checks would otherwise flood the log. */
    `include "check_lib.sv"

    task automatic ic_read(logic [31:0] a);
        @(negedge clk);
        ic_addr = a; ic_cyc = 1; ic_stb = 1;
        @(posedge clk); #1;
        while (!ic_ack && !ic_err) begin
            @(posedge clk); #1;
        end
        ic_cyc = 0; ic_stb = 0;
    endtask

    initial begin
        int unsigned w;
        int unsigned slot, word_off;
        logic [31:0] addr;
        logic [63:0] expected;

        ic_addr = 0; ic_cyc = 0; ic_stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        for (w = 0; w < NUM_WORDS; w = w + 1)
            mem0.memory[w] = {32'(w), ~32'(w)};

        for (int i = 0; i < NUM_ITER; i++) begin
            slot     = $urandom_range(0, 255);              // 256 slots -> 32 tags/index
            word_off = $urandom_range(0, LINE_WORDS - 1);
            addr     = 32'(slot) * (LINE_WORDS * 8) + 32'(word_off) * 8;

            ic_read(addr);

            w        = addr >> 3;
            expected = {32'(w), ~32'(w)};

            check($sformatf("iter %0d: addr=%h data", i, addr), ic_dat_o, expected);
            check($sformatf("iter %0d: addr=%h err_o clear", i, addr), {63'b0, ic_err}, 64'd0);
        end

        $display("");
        $display("icache_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  NUM_ITER, pass_count, fail_count);
        if (fail_count > 0) $display("icache_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
