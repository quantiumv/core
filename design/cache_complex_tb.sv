// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: cache_complex
 *
 * No core.sv involved -- drives cache_complex's two core-facing ports
 * (fetch port into icache0, data port into dcache0) directly, same "real
 * backing wb4_sram, not a behavioral model" idiom icache_tb.sv and
 * dcache_tb.sv already use. This file's own job is what cache_complex.sv
 * adds on top of those two modules: per-port response routing and the
 * shared downstream arbiter. Each port is driven as a proper Wishbone
 * classic master (cyc/stb held until its OWN ack/err), and the concurrent
 * cases run both masters at once and check each port independently.
 *
 * DN_WAIT > 0 puts a slow slave in front of the SRAM: it latches each
 * downstream request on its first cycle and answers DN_WAIT+1 cycles
 * later, like a real slave that starts work as soon as it sees a request.
 * The concurrent cases then land a second request while a beat is
 * outstanding, so a grant that moves mid-beat (sending one cache's
 * response to the other) shows up as wrong data and port counts, and the
 * stability monitor below flags the moved request itself.
 */
module cache_complex_tb #(
    parameter int DN_WAIT = 0
);

    localparam NUM_LINES  = 4;
    localparam LINE_WORDS = 4;
    localparam NUM_WORDS  = 64;  // backing SRAM: 64 dwords = 512 bytes
    localparam MAX_WAIT   = 200; // per-request ack/err timeout, in cycles

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // Fetch port (read-only, permanently wired to icache0).
    logic [31:0] fp_addr;
    logic [63:0] fp_dat;
    logic        fp_cyc, fp_stb, fp_ack, fp_err;

    // Data port (permanently wired to dcache0).
    logic [31:0] dp_addr;
    logic [63:0] dp_dat_i, dp_dat_o;
    logic [7:0]  dp_sel;
    logic        dp_we, dp_cyc, dp_stb, dp_ack, dp_err;

    // cache_complex <-> wb4_sram, memory-facing.
    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    cache_complex #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) dut (
        .clk(clk), .rst(rst),
        .fetch_addr_i(fp_addr), .fetch_cyc_i(fp_cyc), .fetch_stb_i(fp_stb),
        .fetch_dat_o(fp_dat), .fetch_ack_o(fp_ack), .fetch_err_o(fp_err),
        .data_addr_i(dp_addr), .data_dat_i(dp_dat_i), .data_dat_o(dp_dat_o), .data_sel_i(dp_sel),
        .data_we_i(dp_we), .data_cyc_i(dp_cyc), .data_stb_i(dp_stb),
        .data_ack_o(dp_ack), .data_err_o(dp_err),
        .flush_i(1'b0),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    // Slow-slave model (DN_WAIT > 0): latch, wait DN_WAIT cycles, then
    // present the latched request to mem0 until it answers.
    logic [31:0] dn_addr_q;
    logic [63:0] dn_dat_q;
    logic [7:0]  dn_sel_q;
    logic        dn_we_q, dn_busy_q;
    int          dn_cnt_q;
    logic        s_ack, s_err;
    wire         dn_go = dn_busy_q && dn_cnt_q == DN_WAIT && !s_ack && !s_err;
    always_ff @(posedge clk) begin
        if (rst) begin
            dn_busy_q <= 1'b0;
        end else if (!dn_busy_q) begin
            if (mem_cyc && mem_stb) begin
                dn_busy_q <= 1'b1;
                dn_cnt_q  <= 0;
                dn_addr_q <= mem_addr;
                dn_dat_q  <= mem_dat_m2s;
                dn_sel_q  <= mem_sel;
                dn_we_q   <= mem_we;
            end
        end else if (s_ack || s_err) begin
            dn_busy_q <= 1'b0;
        end else if (dn_cnt_q < DN_WAIT) begin
            dn_cnt_q <= dn_cnt_q + 1;
        end
    end

    wire slow = (DN_WAIT > 0);
    wb4_sram #(.num_words(NUM_WORDS)) mem0 (
        .clk(clk), .rst(rst),
        .addr_i(slow ? dn_addr_q : mem_addr), .dat_i(slow ? dn_dat_q : mem_dat_m2s),
        .dat_o(mem_dat_s2m), .sel_i(slow ? dn_sel_q : mem_sel),
        .ack_o(s_ack), .err_o(s_err),
        .cyc_i(slow ? dn_go : mem_cyc), .stb_i(slow ? dn_go : mem_stb), .we_i(slow ? dn_we_q : mem_we)
    );
    assign mem_ack = s_ack;
    assign mem_err = s_err;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    int cycle = 0;
    always @(posedge clk) cycle++;

    // Each port's most recent request, captured on its own ack/err.
    logic [63:0] fp_rdat, dp_rdat;
    logic        fp_rerr, dp_rerr;
    int          fp_start, fp_done, dp_start, dp_done;
    int          fp_reqs = 0, dp_reqs = 0;

    /*
     * Response monitors, sampled at negedge (every registered output is
     * stable there). A cache's ack_o is exactly one cycle per response, so
     * counting ack-high cycles per port catches a lost, duplicated, or
     * misdelivered response even when the returned data happens to match.
     */
    int   fp_acks = 0, fp_errs = 0, dp_acks = 0, dp_errs = 0, mem_resps = 0;
    int   mem_base, ties_base;
    int   ties = 0, tie_violations = 0, dn_violations = 0;
    logic both_busy_seen = 1'b0;

    /*
     * Downstream request stability. A request starts in a cycle with cyc
     * high and nothing outstanding, or in the response cycle of the one
     * before; it is outstanding from the next cycle until its own ack/err.
     * While outstanding with no response this cycle, cyc must stay high
     * and addr/we/sel (and write data) must not change.
     */
    logic        dn_out_q = 1'b0;
    logic [31:0] dn_cap_addr;
    logic [63:0] dn_cap_dat;
    logic [7:0]  dn_cap_sel;
    logic        dn_cap_we;
    wire         dn_resp = mem_ack || mem_err;
    wire         dn_hold = dn_out_q && !dn_resp;
    always @(posedge clk) begin
        if (rst) begin
            dn_out_q <= 1'b0;
        end else begin
            if (dn_hold && !(mem_cyc && mem_stb && mem_addr == dn_cap_addr && mem_we == dn_cap_we
                             && mem_sel == dn_cap_sel && (!mem_we || mem_dat_m2s == dn_cap_dat)))
                dn_violations++;
            if (mem_cyc && !dn_hold) begin
                dn_cap_addr <= mem_addr;
                dn_cap_dat  <= mem_dat_m2s;
                dn_cap_sel  <= mem_sel;
                dn_cap_we   <= mem_we;
            end
            dn_out_q <= mem_cyc;
        end
    end

    always @(negedge clk) begin
        if (fp_ack) fp_acks++;
        if (fp_err) fp_errs++;
        if (dp_ack) dp_acks++;
        if (dp_err) dp_errs++;
        if (mem_ack || mem_err) mem_resps++;
        // Proof of genuine dual-outstanding: both sub-caches mid-transaction at once.
        if (dut.icache0.state_q != 0 && dut.dcache0.state_q != 0) both_busy_seen = 1'b1;
        // Priority invariant: whenever both sub-caches request the shared bus
        // in a cycle where it is free to choose (no beat outstanding), the
        // bus must carry dcache0's request.
        if (dut.icache0.mem_cyc_o && dut.dcache0.mem_cyc_o && !dn_hold) begin
            ties++;
            if (!(mem_cyc && mem_stb && mem_addr === dut.dcache0.mem_addr_o && mem_we === dut.dcache0.mem_we_o))
                tie_violations++;
        end
    end

    // Global backstop, in case a mutant wedges something MAX_WAIT can't catch.
    initial begin
        #200000;
        $display("cache_complex_tb: watchdog timeout");
        $display("cache_complex_tb: %0d passed, %0d failed", pass_count, fail_count + 1);
        $display("cache_complex_tb: FAILURES PRESENT");
        $finish;
    end

    // One Wishbone classic read on the fetch port: cyc/stb held until this
    // port's own ack/err. A MAX_WAIT timeout is logged as a FAIL, so a lost
    // response fails cleanly instead of hanging the run.
    task automatic fetch_cycle(logic [31:0] a);
        int waited = 0;
        @(negedge clk);
        fp_addr = a; fp_cyc = 1; fp_stb = 1;
        fp_reqs++; fp_start = cycle;
        @(posedge clk); #1;
        while (!fp_ack && !fp_err && waited < MAX_WAIT) begin
            @(posedge clk); #1;
            waited++;
        end
        if (waited >= MAX_WAIT)
            check($sformatf("fetch port: request to %h timed out (no ack/err)", a), 64'd0, 64'd1);
        fp_rdat = fp_dat; fp_rerr = fp_err; fp_done = cycle;
        fp_cyc = 0; fp_stb = 0; fp_addr = 0;
    endtask

    // Same as fetch_cycle, on the data port (read or write).
    task automatic data_cycle(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w);
        int waited = 0;
        @(negedge clk);
        dp_addr = a; dp_dat_i = d; dp_sel = s; dp_we = w; dp_cyc = 1; dp_stb = 1;
        dp_reqs++; dp_start = cycle;
        @(posedge clk); #1;
        while (!dp_ack && !dp_err && waited < MAX_WAIT) begin
            @(posedge clk); #1;
            waited++;
        end
        if (waited >= MAX_WAIT)
            check($sformatf("data port: request to %h timed out (no ack/err)", a), 64'd0, 64'd1);
        dp_rdat = dp_dat_o; dp_rerr = dp_err; dp_done = cycle;
        dp_cyc = 0; dp_stb = 0; dp_addr = 0; dp_dat_i = 0; dp_sel = 0; dp_we = 0;
    endtask

    // Cumulative per-port response accounting: exactly one ack per request
    // on each port, and err only where an error was actually expected.
    task automatic check_port_counts(string tag, int exp_fp_errs, int exp_dp_errs);
        repeat (3) @(negedge clk); // let any stray late response land first
        check($sformatf("%s: fetch port acks == fetch requests", tag), fp_acks, fp_reqs);
        check($sformatf("%s: data port acks == data requests", tag), dp_acks, dp_reqs);
        check($sformatf("%s: fetch port err count", tag), fp_errs, exp_fp_errs);
        check($sformatf("%s: data port err count", tag), dp_errs, exp_dp_errs);
        check($sformatf("%s: every downstream tie granted to dcache0", tag), tie_violations, 0);
        check($sformatf("%s: every outstanding downstream request held stable", tag), dn_violations, 0);
    endtask

    // All four words of an I$ line and a D$ line, read back as same-cycle
    // hit pairs on both ports: each port must get its OWN line's word.
    task automatic check_lines(string tag, logic [31:0] fa, logic [63:0] fpat,
                               logic [31:0] da, logic [63:0] dpat);
        mem_base = mem_resps;
        for (int w = 0; w < LINE_WORDS; w++) begin
            fork
                fetch_cycle(fa + 32'(8*w));
                data_cycle(da + 32'(8*w), 64'h0, 8'h00, 1'b0);
            join
            check($sformatf("%s: I$ line word %0d correct (fetch port)", tag, w), fp_rdat, fpat + 64'(w));
            check($sformatf("%s: D$ line word %0d correct (data port)", tag, w), dp_rdat, dpat + 64'(w));
            check($sformatf("%s: word %0d both err clear", tag, w), {62'b0, fp_rerr, dp_rerr}, 64'd0);
        end
        repeat (2) @(negedge clk);
        check($sformatf("%s: line read-back all hits (no downstream traffic)", tag), mem_resps - mem_base, 0);
    endtask

    task automatic fill_line(logic [31:0] base, logic [63:0] pat);
        for (int w = 0; w < LINE_WORDS; w++)
            mem0.memory[(base >> 3) + w] = pat + 64'(w);
    endtask

    initial begin
        fp_addr = 0; fp_cyc = 0; fp_stb = 0;
        dp_addr = 0; dp_dat_i = 0; dp_sel = 0; dp_we = 0; dp_cyc = 0; dp_stb = 0;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Two independent lines (index 0 and index 1 at NUM_LINES=4,
        // LINE_WORDS=4 -- same address scheme as icache_tb.sv/dcache_tb.sv).
        mem0.memory[32'h00 >> 3] = 64'hAAAA_0000_0000_0000;
        mem0.memory[32'h08 >> 3] = 64'hAAAA_0000_0000_0001;
        mem0.memory[32'h20 >> 3] = 64'hCCCC_0000_0000_0000;
        mem0.memory[32'h28 >> 3] = 64'hCCCC_0000_0000_0001;

        // --- Basic correctness on the fetch port: an I$ read (cold miss,
        //     full refill through icache0) ---
        fetch_cycle(32'h00);
        check("I$ read: correct word", fp_rdat, 64'hAAAA_0000_0000_0000);
        check("I$ read: err_o clear", {63'b0, fp_rerr}, 64'd0);

        // --- Basic correctness on the data port: a D$ read to a DIFFERENT
        //     line (cold miss, full refill through dcache0) ---
        data_cycle(32'h20, 64'h0, 8'h00, 1'b0);
        check("D$ read: correct word", dp_rdat, 64'hCCCC_0000_0000_0000);
        check("D$ read: err_o clear", {63'b0, dp_rerr}, 64'd0);

        // --- Independent storage: a D$ read of the line icache0 already
        //     holds is still a dcache0 cold miss (full 4-beat refill). ---
        mem_base = mem_resps;
        data_cycle(32'h00, 64'h0, 8'h00, 1'b0);
        check("D$ read of I$-resident line: correct word", dp_rdat, 64'hAAAA_0000_0000_0000);
        repeat (2) @(negedge clk);
        check("D$ read of I$-resident line: genuine dcache0 miss (4 downstream beats)", mem_resps - mem_base, 4);

        // --- I$ line from the first read is still cached: a repeat I$
        //     read for the SAME address is a hit (no downstream traffic),
        //     unaffected by the D$ reads in between. ---
        mem_base = mem_resps;
        fetch_cycle(32'h00);
        check("I$ still cached after intervening D$ reads", fp_rdat, 64'hAAAA_0000_0000_0000);
        repeat (2) @(negedge clk);
        check("I$ repeat read is a hit (no downstream traffic)", mem_resps - mem_base, 0);

        // --- D$ write, immediately followed (next cycle, other port) by
        //     an I$ read of a DIFFERENT address -- mimics core.sv's own
        //     S_MEM -> S_FETCH cadence. No cross-talk either way. ---
        data_cycle(32'h28, 64'hDEAD_BEEF_0000_0000, 8'hFF, 1'b1);
        check("D$ write: err_o clear", {63'b0, dp_rerr}, 64'd0);
        fetch_cycle(32'h08);
        check("I$ read immediately after D$ write: correct word, no cross-talk",
              fp_rdat, 64'hAAAA_0000_0000_0001);

        // --- Confirm the D$ write from above actually landed (dcache0's
        //     own copy and, via write-through, SRAM) -- same back-to-back
        //     opposite-port shape reversed. ---
        dp_rdat = 64'h0;
        data_cycle(32'h28, 64'h0, 8'h00, 1'b0);
        check("D$ read-back after intervening I$ read: correct word, no cross-talk",
              dp_rdat, 64'hDEAD_BEEF_0000_0000);
        check("D$ write reached SRAM (write-through)", mem0.memory[32'h28 >> 3], 64'hDEAD_BEEF_0000_0000);

        // --- Rapid alternation: 8 back-to-back transactions strictly
        //     alternating ports, each to an already-resident line (all
        //     hits by this point) -- every response must land on the right
        //     port every single time, not just "eventually settle". ---
        for (int i = 0; i < 8; i++) begin
            if (i % 2 == 0) begin
                fetch_cycle(32'h00);
                check($sformatf("alternation %0d: I$ hit correct", i), fp_rdat, 64'hAAAA_0000_0000_0000);
            end else begin
                data_cycle(32'h20, 64'h0, 8'h00, 1'b0);
                check($sformatf("alternation %0d: D$ hit correct", i), dp_rdat, 64'hCCCC_0000_0000_0000);
            end
        end
        check_port_counts("single-port phase", 0, 0);

        /*
         * --- Genuine dual-outstanding contention, observed DIRECTLY (see
         *     cache_complex.sv's own header for the arbiter design): both
         *     ports hold a cold-miss request at once, and each port's own
         *     ack/err/dat is checked independently. ---
         */

        // S1: both ports first assert cyc/stb in the very same cycle.
        fill_line(32'h40, 64'hDDDD_0000_0000_0000); // I$ line (index 2)
        fill_line(32'h60, 64'hEEEE_0000_0000_0000); // D$ line (index 3)
        mem_base = mem_resps; ties_base = ties; both_busy_seen = 1'b0;
        fork
            fetch_cycle(32'h40);
            data_cycle(32'h60, 64'h0, 8'h00, 1'b0);
            begin
                // Fixed priority: dcache0 takes the first contended downstream beat.
                @(negedge clk); @(posedge clk); #1;
                check("S1 same-cycle: first downstream beat granted to dcache0 (fixed priority)",
                      {31'b0, mem_cyc, mem_addr}, {31'b0, 1'b1, 32'h60});
            end
        join
        check("S1 same-cycle: both ports issued in the same cycle", fp_start, dp_start);
        check("S1 same-cycle: fetch port correct word", fp_rdat, 64'hDDDD_0000_0000_0000);
        check("S1 same-cycle: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S1 same-cycle: data port correct word", dp_rdat, 64'hEEEE_0000_0000_0000);
        check("S1 same-cycle: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S1 same-cycle: both sub-caches were busy at once", {63'b0, both_busy_seen}, 64'd1);
        check("S1 same-cycle: data port completes first (dcache0 priority)", {63'b0, dp_done < fp_done}, 64'd1);
        check("S1 same-cycle: a downstream tie actually occurred", {63'b0, ties > ties_base}, 64'd1);
        repeat (2) @(negedge clk);
        check("S1 same-cycle: exactly 8 downstream beats (two 4-beat refills)", mem_resps - mem_base, 8);
        check_port_counts("S1 same-cycle", 0, 0);
        check_lines("S1 same-cycle", 32'h40, 64'hDDDD_0000_0000_0000, 32'h60, 64'hEEEE_0000_0000_0000);

        // S2: data request arrives mid-I$-refill (after 2 of its 4 beats),
        // landing between icache0's beat requests (no tie). Fetch asks for
        // word 2, data for word 3 (served straight off the last beat).
        fill_line(32'h80, 64'h1111_0000_0000_0000); // I$ line (index 0, evicts 0x00)
        fill_line(32'hA0, 64'h2222_0000_0000_0000); // D$ line (index 1, evicts 0x20)
        mem_base = mem_resps; both_busy_seen = 1'b0;
        fork
            fetch_cycle(32'h90);
            begin
                wait (mem_resps >= mem_base + 2);
                data_cycle(32'hB8, 64'h0, 8'h00, 1'b0);
            end
        join
        check("S2 data mid-I$-refill: data issued while fetch still outstanding",
              {63'b0, dp_start > fp_start && dp_start < fp_done}, 64'd1);
        check("S2 data mid-I$-refill: fetch port correct word", fp_rdat, 64'h1111_0000_0000_0002);
        check("S2 data mid-I$-refill: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S2 data mid-I$-refill: data port correct word", dp_rdat, 64'h2222_0000_0000_0003);
        check("S2 data mid-I$-refill: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S2 data mid-I$-refill: both sub-caches were busy at once", {63'b0, both_busy_seen}, 64'd1);
        repeat (2) @(negedge clk);
        check("S2 data mid-I$-refill: exactly 8 downstream beats", mem_resps - mem_base, 8);
        check_port_counts("S2 data mid-I$-refill", 0, 0);
        check_lines("S2 data mid-I$-refill", 32'h80, 64'h1111_0000_0000_0000, 32'hA0, 64'h2222_0000_0000_0000);

        // S2t: same, but in phase -- the data request is sampled on the edge
        // icache0 captures its 2nd beat, so both want the bus next cycle: a
        // genuine mid-refill tie, which dcache0 must win without losing either.
        fill_line(32'h120, 64'h8888_0000_0000_0000); // I$ line (index 1)
        fill_line(32'h180, 64'h9999_0000_0000_0000); // D$ line (index 0, evicts 0x00)
        mem_base = mem_resps; ties_base = ties; both_busy_seen = 1'b0;
        fork
            fetch_cycle(32'h138);
            begin
                @(posedge mem_ack); @(posedge mem_ack); // 2nd I$ beat's ack cycle
                data_cycle(32'h190, 64'h0, 8'h00, 1'b0);
            end
        join
        check("S2t tie mid-I$-refill: data issued while fetch still outstanding",
              {63'b0, dp_start > fp_start && dp_start < fp_done}, 64'd1);
        check("S2t tie mid-I$-refill: a downstream tie actually occurred", {63'b0, ties > ties_base}, 64'd1);
        check("S2t tie mid-I$-refill: fetch port correct word", fp_rdat, 64'h8888_0000_0000_0003);
        check("S2t tie mid-I$-refill: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S2t tie mid-I$-refill: data port correct word", dp_rdat, 64'h9999_0000_0000_0002);
        check("S2t tie mid-I$-refill: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S2t tie mid-I$-refill: both sub-caches were busy at once", {63'b0, both_busy_seen}, 64'd1);
        repeat (2) @(negedge clk);
        check("S2t tie mid-I$-refill: exactly 8 downstream beats", mem_resps - mem_base, 8);
        check_port_counts("S2t tie mid-I$-refill", 0, 0);
        check_lines("S2t tie mid-I$-refill", 32'h120, 64'h8888_0000_0000_0000, 32'h180, 64'h9999_0000_0000_0000);

        // S3: the reverse -- fetch request arrives mid-D$-refill.
        fill_line(32'hE0, 64'h3333_0000_0000_0000); // I$ line (index 3)
        fill_line(32'hC0, 64'h4444_0000_0000_0000); // D$ line (index 2)
        mem_base = mem_resps; both_busy_seen = 1'b0;
        fork
            data_cycle(32'hC8, 64'h0, 8'h00, 1'b0);
            begin
                wait (mem_resps >= mem_base + 2);
                fetch_cycle(32'hE0);
            end
        join
        check("S3 fetch mid-D$-refill: fetch issued while data still outstanding",
              {63'b0, fp_start > dp_start && fp_start < dp_done}, 64'd1);
        check("S3 fetch mid-D$-refill: fetch port correct word", fp_rdat, 64'h3333_0000_0000_0000);
        check("S3 fetch mid-D$-refill: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S3 fetch mid-D$-refill: data port correct word", dp_rdat, 64'h4444_0000_0000_0001);
        check("S3 fetch mid-D$-refill: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S3 fetch mid-D$-refill: both sub-caches were busy at once", {63'b0, both_busy_seen}, 64'd1);
        repeat (2) @(negedge clk);
        check("S3 fetch mid-D$-refill: exactly 8 downstream beats", mem_resps - mem_base, 8);
        check_port_counts("S3 fetch mid-D$-refill", 0, 0);
        check_lines("S3 fetch mid-D$-refill", 32'hE0, 64'h3333_0000_0000_0000, 32'hC0, 64'h4444_0000_0000_0000);

        // S4: a partial-sel D$ store (hit on the S1 line) lands mid-I$-refill:
        // the store's single write beat must reach SRAM intact, the I$ line too.
        fill_line(32'h100, 64'h5555_0000_0000_0000); // I$ line (index 0, evicts 0x80)
        mem_base = mem_resps; both_busy_seen = 1'b0;
        fork
            fetch_cycle(32'h118);
            begin
                wait (mem_resps >= mem_base + 1);
                data_cycle(32'h68, 64'h1234_5678_CAFE_F00D, 8'h0F, 1'b1);
            end
        join
        check("S4 store mid-I$-refill: store issued while fetch still outstanding",
              {63'b0, dp_start > fp_start && dp_start < fp_done}, 64'd1);
        check("S4 store mid-I$-refill: fetch port correct word", fp_rdat, 64'h5555_0000_0000_0003);
        check("S4 store mid-I$-refill: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S4 store mid-I$-refill: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S4 store mid-I$-refill: both sub-caches were busy at once", {63'b0, both_busy_seen}, 64'd1);
        repeat (2) @(negedge clk);
        check("S4 store mid-I$-refill: exactly 5 downstream beats (4-beat refill + 1 write)", mem_resps - mem_base, 5);
        check("S4 store mid-I$-refill: sel-merged store reached SRAM",
              mem0.memory[32'h68 >> 3], 64'hEEEE_0000_CAFE_F00D);
        check_port_counts("S4 store mid-I$-refill", 0, 0);
        // Store was a write HIT: dcache0's own cached copy must carry the merge too.
        mem_base = mem_resps;
        fork
            fetch_cycle(32'h100);
            data_cycle(32'h68, 64'h0, 8'h00, 1'b0);
        join
        check("S4 store mid-I$-refill: I$ line word 0 intact", fp_rdat, 64'h5555_0000_0000_0000);
        check("S4 store mid-I$-refill: dcache0 cached copy carries the merged store", dp_rdat, 64'hEEEE_0000_CAFE_F00D);
        repeat (2) @(negedge clk);
        check("S4 store mid-I$-refill: read-back pair all hits", mem_resps - mem_base, 0);

        // S5a: a fetch-side bus error, same cycle as a D$ cold-miss refill --
        // the err must reach ONLY the fetch port.
        fill_line(32'h140, 64'h6666_0000_0000_0000); // D$ line (index 2, evicts 0xC0)
        mem_base = mem_resps;
        fork
            fetch_cycle(32'h1000); // beyond NUM_WORDS: wb4_sram err_o
            data_cycle(32'h140, 64'h0, 8'h00, 1'b0);
        join
        check("S5a fetch err + D$ refill: fetch port err set", {63'b0, fp_rerr}, 64'd1);
        check("S5a fetch err + D$ refill: data port err clear", {63'b0, dp_rerr}, 64'd0);
        check("S5a fetch err + D$ refill: data port correct word", dp_rdat, 64'h6666_0000_0000_0000);
        repeat (2) @(negedge clk);
        check("S5a fetch err + D$ refill: 5 downstream responses (1 err + 4 beats)", mem_resps - mem_base, 5);
        check_port_counts("S5a fetch err + D$ refill", 1, 0);

        // S5b: the reverse -- a data-side bus error mid-I$-refill.
        fill_line(32'h160, 64'h7777_0000_0000_0000); // I$ line (index 3, evicts 0xE0)
        mem_base = mem_resps;
        fork
            fetch_cycle(32'h168);
            begin
                wait (mem_resps >= mem_base + 1);
                data_cycle(32'h2000, 64'h0, 8'h00, 1'b0);
            end
        join
        check("S5b data err mid-I$-refill: data issued while fetch still outstanding",
              {63'b0, dp_start > fp_start && dp_start < fp_done}, 64'd1);
        check("S5b data err mid-I$-refill: data port err set", {63'b0, dp_rerr}, 64'd1);
        check("S5b data err mid-I$-refill: fetch port err clear", {63'b0, fp_rerr}, 64'd0);
        check("S5b data err mid-I$-refill: fetch port correct word", fp_rdat, 64'h7777_0000_0000_0001);
        repeat (2) @(negedge clk);
        check("S5b data err mid-I$-refill: 5 downstream responses (4 beats + 1 err)", mem_resps - mem_base, 5);
        check_port_counts("S5b data err mid-I$-refill", 1, 1);
        check_lines("S5b data err mid-I$-refill", 32'h160, 64'h7777_0000_0000_0000, 32'h140, 64'h6666_0000_0000_0000);

        $display("");
        $display("cache_complex_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("cache_complex_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
