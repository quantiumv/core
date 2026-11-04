// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: dcache_random_tb
 *
 * Randomized property test for dcache.sv -- separate from the directed
 * dcache_tb.sv, same convention icache_random_tb.sv/divider_random_tb.sv
 * already established for their own DUTs.
 *
 * Unlike icache_random_tb.sv (read-only, so "expected value" is a plain
 * formula on the address), this file needs a genuine shadow memory: each
 * iteration randomly reads OR writes, and a write changes what a later
 * read at the same address should return. shadow_mem starts with the
 * same simple per-word pattern icache_random_tb.sv preloads the real
 * backing SRAM with, then a write updates BOTH the DUT (through dcache)
 * and shadow_mem (via a byte-lane merge computed independently in this
 * testbench, not by calling into dcache.sv's or wb4_sram.sv's own merge
 * logic) -- catching a bug in either's merge/indexing without the
 * checking code sharing a mistake with what it's checking.
 *
 * Address generation is the same biased-slot scheme icache_random_tb.sv
 * uses (256 slots cycling through NUM_LINES=8 indices, 32 tags/index) --
 * see that file's header for the full reasoning.
 *
 * Since dcache.sv passes a write straight through, two more things are
 * random here: a quarter of the reads re-read the dword written last (so
 * a write hit is followed by a read of the same dword at once), and a
 * quarter of the writes come from a master that holds cyc through the
 * whole ack cycle, as dm.sv's SBA does. Every downstream write response
 * is counted against the writes issued: a store reaches memory exactly
 * once. DN_WAIT_MAX > 0 puts a slave with 0..DN_WAIT_MAX random wait
 * states between the D$ and wb4_sram (the latch-and-wait model of
 * cache_complex_tb.sv).
 *
 * Seeding: no explicit $srandom call, same as every other random_tb in
 * this project.
 */
module dcache_random_tb #(
    parameter int DN_WAIT_MAX = 0
);

    localparam int NUM_ITER = 2000;

    localparam NUM_LINES  = 8;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 1024; // 8KB backing SRAM -- 32 tags/index at NUM_LINES=8

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] dc_addr;
    logic [63:0] dc_dat_i, dc_dat_o;
    logic [7:0]  dc_sel;
    logic        dc_we, dc_cyc, dc_stb, dc_ack, dc_err;

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    dcache #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) dut (
        .clk(clk), .rst(rst),
        .addr_i(dc_addr), .dat_i(dc_dat_i), .dat_o(dc_dat_o), .sel_i(dc_sel),
        .we_i(dc_we), .cyc_i(dc_cyc), .stb_i(dc_stb), .ack_o(dc_ack), .err_o(dc_err),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    // Slow-slave model (DN_WAIT_MAX > 0): latch, wait a random 0..DN_WAIT_MAX
    // cycles, then present the latched request to mem0 until it answers.
    logic [31:0] dn_addr_q;
    logic [63:0] dn_dat_q;
    logic [7:0]  dn_sel_q;
    logic        dn_we_q, dn_busy_q;
    int          dn_cnt_q, dn_wait_q;
    logic        s_ack, s_err;
    wire         dn_go = dn_busy_q && dn_cnt_q == dn_wait_q && !s_ack && !s_err;
    always_ff @(posedge clk) begin
        if (rst) begin
            dn_busy_q <= 1'b0;
        end else if (!dn_busy_q) begin
            if (mem_cyc && mem_stb) begin
                dn_busy_q <= 1'b1;
                dn_cnt_q  <= 0;
                dn_wait_q <= $urandom_range(0, DN_WAIT_MAX);
                dn_addr_q <= mem_addr;
                dn_dat_q  <= mem_dat_m2s;
                dn_sel_q  <= mem_sel;
                dn_we_q   <= mem_we;
            end
        end else if (s_ack || s_err) begin
            dn_busy_q <= 1'b0;
        end else if (dn_cnt_q < dn_wait_q) begin
            dn_cnt_q <= dn_cnt_q + 1;
        end
    end

    wire slow = (DN_WAIT_MAX > 0);
    wb4_sram #(.num_words(NUM_WORDS)) mem0 (
        .clk(clk), .rst(rst),
        .addr_i(slow ? dn_addr_q : mem_addr), .dat_i(slow ? dn_dat_q : mem_dat_m2s),
        .dat_o(mem_dat_s2m), .sel_i(slow ? dn_sel_q : mem_sel),
        .ack_o(s_ack), .err_o(s_err),
        .cyc_i(slow ? dn_go : mem_cyc), .stb_i(slow ? dn_go : mem_stb), .we_i(slow ? dn_we_q : mem_we)
    );
    assign mem_ack = s_ack;
    assign mem_err = s_err;

    // the downstream write responses: one per write issued (straight to mem0, a response answers the request
    // presented the cycle before, which the D$ has dropped by then)
    int   wr_resps = 0, wr_issued = 0;
    logic req_we_q = 1'b0;
    always @(posedge clk) begin
        if (!rst && (s_ack || s_err) && (slow ? dn_we_q : req_we_q)) wr_resps = wr_resps + 1;
        if (mem_cyc) req_we_q <= mem_we;
    end

    logic [63:0] shadow_mem [0:NUM_WORDS-1];

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;   /* NUM_ITER checks would otherwise flood the log. */
    `include "check_lib.sv"

    // hold: keep cyc/stb through the ack cycle and drop them at the next edge (dm.sv's SBA)
    task automatic dc_cycle(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w, logic hold = 1'b0);
        @(negedge clk);
        dc_addr = a; dc_dat_i = d; dc_sel = s; dc_we = w; dc_cyc = 1; dc_stb = 1;
        @(posedge clk); #1;
        while (!dc_ack && !dc_err) begin
            @(posedge clk); #1;
        end
        if (hold) begin
            @(posedge clk); #1;
        end
        dc_cyc = 0; dc_stb = 0;
    endtask

    initial begin
        int unsigned w;
        int unsigned slot, word_off;
        logic [31:0] addr;
        logic [63:0] wdata;
        logic [7:0]  wsel;
        logic        is_write;
        logic [63:0] merged;
        logic [31:0] last_waddr = 32'h0;

        dc_addr = 0; dc_dat_i = 0; dc_sel = 0; dc_we = 0; dc_cyc = 0; dc_stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        for (w = 0; w < NUM_WORDS; w = w + 1) begin
            mem0.memory[w] = {32'(w), ~32'(w)};
            shadow_mem[w]  = {32'(w), ~32'(w)};
        end

        for (int i = 0; i < NUM_ITER; i++) begin
            slot     = $urandom_range(0, 255);              // 256 slots -> 32 tags/index
            word_off = $urandom_range(0, LINE_WORDS - 1);
            addr     = 32'(slot) * (LINE_WORDS * 8) + 32'(word_off) * 8;
            w        = addr >> 3;

            is_write = $urandom_range(0, 1);
            if (!is_write && $urandom_range(0, 3) == 0) begin
                addr = last_waddr;                          // re-read the dword written last
                w    = addr >> 3;
            end

            if (is_write) begin
                wdata = {$urandom(), $urandom()};
                wsel  = 8'($urandom_range(1, 255)); // never all-zero -- a no-op write proves nothing

                dc_cycle(addr, wdata, wsel, 1'b1, $urandom_range(0, 3) == 0);
                wr_issued++;
                last_waddr = addr;
                check($sformatf("iter %0d: addr=%h write err_o clear", i, addr), {63'b0, dc_err}, 64'd0);

                // Independent byte-lane merge -- not shared code with
                // dcache.sv's or wb4_sram.sv's own.
                merged = shadow_mem[w];
                for (int lane = 0; lane < 8; lane++) begin
                    if (wsel[lane]) merged[(8*lane) +: 8] = wdata[(8*lane) +: 8];
                end
                shadow_mem[w] = merged;
            end else begin
                dc_cycle(addr, 64'b0, 8'h00, 1'b0);
                check($sformatf("iter %0d: addr=%h read data", i, addr), dc_dat_o, shadow_mem[w]);
                check($sformatf("iter %0d: addr=%h read err_o clear", i, addr), {63'b0, dc_err}, 64'd0);
            end
        end

        repeat (DN_WAIT_MAX + 4) @(posedge clk);
        check("every write reached memory exactly once", 64'(wr_resps), 64'(wr_issued));

        $display("");
        $display("dcache_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  NUM_ITER, pass_count, fail_count);
        if (fail_count > 0) $display("dcache_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
