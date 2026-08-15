// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: dcache
 *
 * Same structure as design/icache_tb.sv (real backing wb4_sram, not a
 * behavioral model; backdoor-loaded known content; a small
 * num_lines=4/line_words=4 instance to force conflict evictions at low
 * address counts) -- see that file's own header for the full reasoning,
 * not repeated here. This file's own incremental coverage is the write
 * path: write-through propagation, byte-lane-qualified write-hit update,
 * and no-write-allocate on a write-miss.
 *
 * check() comes from testbench/check_lib.sv. wb_driver.sv's wb_cycle IS
 * usable here (unlike icache_tb.sv) since dcache's core-facing port is a
 * full read/write Wishbone slave, matching wb_cycle's required signal
 * contract exactly.
 */
module dcache_tb;

    localparam NUM_LINES  = 4;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 64; // backing SRAM: 64 dwords = 512 bytes

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // dcache core-facing port -- named to match wb_driver.sv's required
    // contract (addr/dat_i/dat_o/sel/we/cyc/stb/ack/err).
    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        we, cyc, stb, ack, err;

    // dcache <-> wb4_sram, memory-facing
    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    dcache #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    wb4_sram #(.num_words(NUM_WORDS)) mem0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(mem_dat_m2s), .dat_o(mem_dat_s2m), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

    // Same white-box downstream-traffic counter as icache_tb.sv.
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
    `include "wb_driver.sv"

    initial begin
        addr = 0; dat_i = 0; sel = 8'h00; we = 0; cyc = 0; stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Same address layout as icache_tb.sv: 0x00-0x18 (index 0, tag A),
        // 0x80-0x98 (index 0, tag B, conflicts with the first), 0x20-0x38
        // (index 1, independent).
        mem0.memory[32'h00 >> 3] = 64'hAAAA_0000_0000_0000;
        mem0.memory[32'h08 >> 3] = 64'hAAAA_0000_0000_0001;
        mem0.memory[32'h10 >> 3] = 64'hAAAA_0000_0000_0002;
        mem0.memory[32'h18 >> 3] = 64'hAAAA_0000_0000_0003;

        // --- Cold miss read: full-line refill, same as icache_tb.sv ---
        mem_cyc_pulses = 0;
        wb_cycle(32'h08, 64'h0, 8'h00, 1'b0);
        check("cold miss read: correct word", dat_o, 64'hAAAA_0000_0000_0001);
        check("cold miss read: LINE_WORDS downstream beats", 64'(mem_cyc_pulses), 64'(LINE_WORDS));

        // --- Read hit: zero downstream traffic ---
        mem_cyc_pulses = 0;
        wb_cycle(32'h10, 64'h0, 8'h00, 1'b0);
        check("read hit: correct word", dat_o, 64'hAAAA_0000_0000_0002);
        check("read hit: zero downstream traffic", 64'(mem_cyc_pulses), 64'd0);

        // --- Write hit: full-dword store to a cached line -- exactly
        //     one downstream beat (never slower than the baseline), the
        //     cached copy updates in place, and a FOLLOWING read confirms
        //     it via the cache (zero further downstream traffic), not by
        //     coincidentally re-reading from SRAM. ---
        mem_cyc_pulses = 0;
        wb_cycle(32'h08, 64'hFEED_FACE_0000_0000, 8'hFF, 1'b1);
        check("write hit: ack, err clear", {63'b0, err}, 64'd0);
        check("write hit: exactly one downstream beat", 64'(mem_cyc_pulses), 64'd1);
        mem_cyc_pulses = 0;
        wb_cycle(32'h08, 64'h0, 8'h00, 1'b0);
        check("write hit: cached copy updated in place", dat_o, 64'hFEED_FACE_0000_0000);
        check("write hit: read-back is a cache hit (zero downstream traffic)", 64'(mem_cyc_pulses), 64'd0);

        // --- Write-through propagation: the SAME value is visible
        //     directly in the backing SRAM, not just through the cache. ---
        check("write-through: visible directly in backing SRAM",
              mem0.memory[32'h08 >> 3], 64'hFEED_FACE_0000_0000);

        // --- Byte-lane-qualified write-hit update: only lanes 0-1
        //     (sel=8'h03) change; lanes 2-7 (FE ED FA CE 00 00 from
        //     above) must stay untouched -- direct analog of
        //     wb4_sram_tb.sv's own byte-enable check. ---
        wb_cycle(32'h08, 64'h0000_0000_0000_A5A5, 8'h03, 1'b1);
        wb_cycle(32'h08, 64'h0, 8'h00, 1'b0);
        check("byte-enable write-hit only touches enabled lanes", dat_o, 64'hFEED_FACE_0000_A5A5);

        // --- Write miss: no-write-allocate -- an address NOT currently
        //     cached (index 1, never read yet) gets written straight
        //     through to SRAM without installing a line: exactly one
        //     downstream beat (not LINE_WORDS, since no refill happens),
        //     and a FOLLOWING read to that address is still a genuine
        //     miss (full LINE_WORDS refill), proving the write really
        //     didn't allocate. ---
        mem_cyc_pulses = 0;
        wb_cycle(32'h20, 64'hC0FF_EE00_0000_0000, 8'hFF, 1'b1);
        check("write miss: exactly one downstream beat (no line fetch)", 64'(mem_cyc_pulses), 64'd1);
        check("write miss: value reached SRAM", mem0.memory[32'h20 >> 3], 64'hC0FF_EE00_0000_0000);
        mem_cyc_pulses = 0;
        wb_cycle(32'h20, 64'h0, 8'h00, 1'b0);
        check("write miss: did not allocate -- read still misses", 64'(mem_cyc_pulses), 64'(LINE_WORDS));
        check("write miss: read-back correct after the real refill", dat_o, 64'hC0FF_EE00_0000_0000);

        // --- Conflict eviction on a read, exactly like icache_tb.sv:
        //     0x90 aliases index 0 with a different tag, evicting the
        //     line installed by the writes above. ---
        mem0.memory[32'h90 >> 3] = 64'hBBBB_0000_0000_0002;
        mem_cyc_pulses = 0;
        wb_cycle(32'h90, 64'h0, 8'h00, 1'b0);
        check("conflict miss: correct word", dat_o, 64'hBBBB_0000_0000_0002);
        check("conflict miss: LINE_WORDS downstream beats", 64'(mem_cyc_pulses), 64'(LINE_WORDS));

        // --- Out-of-range write: err_o propagates, exactly one
        //     downstream beat attempted (matches icache_tb.sv's read-side
        //     error-abort behavior). ---
        mem_cyc_pulses = 0;
        wb_cycle(32'h1000, 64'hDEAD, 8'hFF, 1'b1);
        check("out-of-range write: err_o asserted", {63'b0, err}, 64'd1);
        check("out-of-range write: exactly one downstream beat", 64'(mem_cyc_pulses), 64'd1);

        $display("");
        $display("dcache_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("dcache_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
