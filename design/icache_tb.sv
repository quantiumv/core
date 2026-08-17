// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: icache
 *
 * Drives icache's core-facing (read-only) port directly, backed by a real
 * wb4_sram instance for its own memory-facing port -- not a behavioral
 * memory model, the actual module this cache will refill from in soc.sv.
 * Known content is backdoor-loaded straight into the SRAM's memory[]
 * array (bypassing the Wishbone protocol entirely for setup, same
 * "poke the DUT's own hierarchy for test setup" idiom check_lib.sv's own
 * header documents for check()'s hierarchical-value examples) since
 * icache's core-facing port has no write path to load through and driving
 * wb4_sram's slave port directly during setup would otherwise race
 * against icache's own mem_* master connection to that same port.
 *
 * A small num_lines=4/line_words=4 instance (16 words, 128 bytes of cache
 * vs. a 512-byte backing SRAM) deliberately forces conflict evictions at
 * low address counts, same "shrink the DUT to make edge cases reachable
 * in a short test" idiom design/wb4_sram_tb.sv itself uses
 * (num_words=64 instead of the real 4096 default).
 *
 * check() comes from testbench/check_lib.sv -- see that file for its
 * required-signal contract. This testbench does NOT use wb_driver.sv's
 * wb_cycle: icache's core-facing port is read-only (no we/dat_i/sel), so
 * ic_read below is a small hand-rolled equivalent instead.
 */
module icache_tb;

    localparam NUM_LINES  = 4;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 64; // backing SRAM: 64 dwords = 512 bytes

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // icache core-facing port
    logic [31:0] ic_addr;
    logic [63:0] ic_dat_o;
    logic        ic_cyc, ic_stb, ic_ack, ic_err;

    // icache <-> wb4_sram, memory-facing
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

    // Counts mem_cyc_o rising edges -- lets a test assert "this read
    // produced zero downstream traffic" (a hit) vs. "exactly LINE_WORDS
    // downstream transactions" (a miss + full-line refill), a white-box
    // check in the same spirit as testbench/core_a_ext_tb.sv's own
    // state-visit-count assertions.
    int mem_cyc_pulses = 0;
    logic mem_cyc_q = 0;
    always @(posedge clk) begin
        if (mem_cyc && !mem_cyc_q) mem_cyc_pulses = mem_cyc_pulses + 1;
        mem_cyc_q <= mem_cyc;
    end

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
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
        ic_addr = 0; ic_cyc = 0; ic_stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        /*
         * Backdoor-load 3 lines' worth of known, distinct content:
         *  - addr 0x00-0x18 (line index 0, tag A): line 0's content.
         *  - addr 0x80-0x98 (line index 0, tag B, since NUM_LINES=4 means
         *    index = addr[6:5] with LINE_WORDS=4/OFFSET_WIDTH=2 -- 0x80
         *    aliases the SAME index as 0x00 but a DIFFERENT tag): forces
         *    a conflict eviction against the first line.
         *  - addr 0x20-0x38 (line index 1): an independent line, used to
         *    prove eviction of index 0 doesn't disturb index 1.
         */
        mem0.memory[32'h00 >> 3] = 64'hAAAA_0000_0000_0000;
        mem0.memory[32'h08 >> 3] = 64'hAAAA_0000_0000_0001;
        mem0.memory[32'h10 >> 3] = 64'hAAAA_0000_0000_0002;
        mem0.memory[32'h18 >> 3] = 64'hAAAA_0000_0000_0003;

        mem0.memory[32'h80 >> 3] = 64'hBBBB_0000_0000_0000;
        mem0.memory[32'h88 >> 3] = 64'hBBBB_0000_0000_0001;
        mem0.memory[32'h90 >> 3] = 64'hBBBB_0000_0000_0002;
        mem0.memory[32'h98 >> 3] = 64'hBBBB_0000_0000_0003;

        mem0.memory[32'h20 >> 3] = 64'hCCCC_0000_0000_0000;
        mem0.memory[32'h28 >> 3] = 64'hCCCC_0000_0000_0001;
        mem0.memory[32'h30 >> 3] = 64'hCCCC_0000_0000_0002;
        mem0.memory[32'h38 >> 3] = 64'hCCCC_0000_0000_0003;

        // --- Cold miss: full-line refill, LINE_WORDS downstream beats ---
        mem_cyc_pulses = 0;
        ic_read(32'h08);
        check("cold miss: correct word", ic_dat_o, 64'hAAAA_0000_0000_0001);
        check("cold miss: err_o clear", {63'b0, ic_err}, 64'd0);
        check("cold miss: LINE_WORDS downstream beats", 64'(mem_cyc_pulses), 64'(LINE_WORDS));

        // --- Hit: same line, different word, zero downstream traffic ---
        mem_cyc_pulses = 0;
        ic_read(32'h10);
        check("hit: correct word", ic_dat_o, 64'hAAAA_0000_0000_0002);
        check("hit: zero downstream traffic", 64'(mem_cyc_pulses), 64'd0);

        // --- Independent line (index 1): also a cold miss, doesn't
        //     disturb index 0's now-cached line ---
        ic_read(32'h28);
        check("independent line: correct word", ic_dat_o, 64'hCCCC_0000_0000_0001);
        mem_cyc_pulses = 0;
        ic_read(32'h00);
        check("index 0 still cached after index 1 refill", ic_dat_o, 64'hAAAA_0000_0000_0000);
        check("index 0 still cached: zero downstream traffic", 64'(mem_cyc_pulses), 64'd0);

        // --- Conflict eviction: 0x80 aliases index 0 with a different
        //     tag, must miss and evict 0x00-0x18's line ---
        mem_cyc_pulses = 0;
        ic_read(32'h90);
        check("conflict miss: correct word", ic_dat_o, 64'hBBBB_0000_0000_0002);
        check("conflict miss: LINE_WORDS downstream beats", 64'(mem_cyc_pulses), 64'(LINE_WORDS));

        // --- Original line (0x00) now evicted: must miss again, not
        //     serve a stale hit ---
        mem_cyc_pulses = 0;
        ic_read(32'h00);
        check("evicted line re-misses: correct word", ic_dat_o, 64'hAAAA_0000_0000_0000);
        check("evicted line re-misses: LINE_WORDS downstream beats", 64'(mem_cyc_pulses), 64'(LINE_WORDS));

        // --- Out-of-range downstream address: err_o propagates, and the
        //     refill aborts on the FIRST beat's error rather than
        //     attempting the rest of the line (one downstream pulse, not
        //     LINE_WORDS) -- a second read re-triggers a fresh one-beat
        //     refill attempt, not a false hit on a half-written line. ---
        mem_cyc_pulses = 0;
        ic_read(32'h1000);
        check("downstream err_i propagates as err_o", {63'b0, ic_err}, 64'd1);
        check("errored refill aborts after one beat", 64'(mem_cyc_pulses), 64'd1);
        mem_cyc_pulses = 0;
        ic_read(32'h1000);
        check("errored line not installed: re-misses", 64'(mem_cyc_pulses), 64'd1);

        $display("");
        $display("icache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("icache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
