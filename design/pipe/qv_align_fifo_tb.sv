// SPDX-License-Identifier: MIT

/*
 * qv_align_fifo_tb -- standalone test for design/pipe/qv_align.sv and
 * design/pipe/qv_fifo.sv, wired the way core_pipe uses them (fetch
 * buffer -> align -> IQ).
 *
 * Stream checks: a builder lays a random mix of 16- and 32-bit
 * instructions into memory from a random 2-byte-aligned start pc, the
 * source plays the covering dwords out like the fetch buffer (the first
 * one carrying the real start pc, the rest dword-aligned), and every
 * instruction leaving the IQ must match the builder's list in pc, bits
 * and length. Run under random consumer backpressure, with flushes both
 * between streams and mid-stream (so a held crossing half or a part-used
 * dword must not leak into the next stream), and with fetch faults.
 * Plus direct checks: no movement without IQ room, FIFO threshold,
 * wraparound and empty-pop behavior.
 */
module qv_align_fifo_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    localparam int W = $bits(fe_instr_t);

    // ---------------- align -> fifo ----------------
    logic        buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic        buf_pop;
    logic        p0_valid, p1_valid, push_ready;
    fe_instr_t   p0_data, p1_data;
    logic        flush = 1'b0;
    logic        head_valid;
    logic [W-1:0] head_bits;
    fe_instr_t   head;
    logic        pop_en = 1'b0;
    int          pop_pct = 100;
    logic        force_pop = 1'b0;
    logic        pop;

    assign head = fe_instr_t'(head_bits);

    qv_align align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(buf_valid), .i_buf_pc(buf_pc), .i_buf_data(buf_data), .i_buf_err(buf_err),
        .o_buf_pop(buf_pop),
        .o_push0_valid(p0_valid), .o_push0_data(p0_data),
        .o_push1_valid(p1_valid), .o_push1_data(p1_data),
        .i_push_ready(push_ready)
    );

    qv_fifo #(.WIDTH(W), .DEPTH(4)) iq0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push0_valid(p0_valid), .i_push0_data(p0_data),
        .i_push1_valid(p1_valid), .i_push1_data(p1_data),
        .o_push_ready(push_ready),
        .o_head_valid(head_valid), .o_head_data(head_bits),
        .i_pop(pop)
    );

    // ---------------- consumer ----------------
    logic pop_roll;
    always @(negedge clk) pop_roll = ($urandom % 100) < pop_pct;
    assign pop = (pop_en && head_valid && pop_roll) || force_pop;

    localparam int MAXI = 128;
    logic [63:0] log_pc   [0:MAXI-1];
    logic [31:0] log_raw  [0:MAXI-1];
    logic        log_rvc  [0:MAXI-1];
    logic        log_xcpt [0:MAXI-1];
    logic [3:0]  log_cause[0:MAXI-1];
    logic        log_hi   [0:MAXI-1];
    int log_n = 0;
    always @(posedge clk) begin
        if (!rst && !flush && pop && head_valid && log_n < MAXI) begin
            log_pc[log_n]    <= head.pc;
            log_raw[log_n]   <= head.raw;
            log_rvc[log_n]   <= head.rvc;
            log_xcpt[log_n]  <= head.xcpt;
            log_cause[log_n] <= head.xcpt_cause;
            log_hi[log_n]    <= head.xcpt_hi;
            log_n            <= log_n + 1;
        end
    end

    // ---------------- fetch-buffer source ----------------
    localparam int MAXD = 64;
    logic [63:0] src_pc   [0:MAXD-1];
    logic [63:0] src_data [0:MAXD-1];
    logic        src_err  [0:MAXD-1];
    int src_n = 0, src_i = 0;
    logic src_en = 1'b0;
    always @(posedge clk) begin
        if (rst || flush)                     src_i <= 0;
        else if (src_en && buf_pop)           src_i <= src_i + 1;
    end
    always_comb begin
        buf_valid = src_en && (src_i < src_n);
        buf_pc    = buf_valid ? src_pc[src_i]   : '0;
        buf_data  = buf_valid ? src_data[src_i] : '0;
        buf_err   = buf_valid ? src_err[src_i]  : 1'b0;
    end

    // ---------------- stream builder ----------------
    logic [15:0] hwm [0:4*MAXD-1];        // halfword image from the first dword's base
    logic [63:0] exp_pc   [0:MAXI-1];
    logic [31:0] exp_raw  [0:MAXI-1];
    logic        exp_rvc  [0:MAXI-1];
    int exp_n;

    function automatic logic [15:0] rand_c();       // low bits != 11
        logic [15:0] h;
        h = 16'($urandom);
        if (h[1:0] == 2'b11) h[1:0] = 2'($urandom % 3);
        return h;
    endfunction

    // Lay out n instructions from start (rvc_pct% compressed); fill the
    // source with the covering dwords plus one more, so a trailing
    // crossing instruction still completes.
    task automatic build(input logic [63:0] start, input int n, input int rvc_pct);
        logic [63:0] b0;
        int h, k;
        b0 = {start[63:3], 3'b000};
        for (k = 0; k < 4 * MAXD; k++) hwm[k] = rand_c();
        h = int'(start[2:1]);
        for (k = 0; k < n; k++) begin
            exp_pc[k] = b0 + 64'(2 * h);
            if (($urandom % 100) < rvc_pct) begin
                hwm[h] = rand_c();
                exp_raw[k] = {16'b0, hwm[h]};
                exp_rvc[k] = 1'b1;
                h += 1;
            end else begin
                hwm[h]     = {14'($urandom), 2'b11};
                hwm[h + 1] = 16'($urandom);
                exp_raw[k] = {hwm[h + 1], hwm[h]};
                exp_rvc[k] = 1'b0;
                h += 2;
            end
        end
        exp_n = n;
        src_n = (h + 3) / 4 + 1;
        for (k = 0; k < src_n; k++) begin
            src_pc[k]   = (k == 0) ? start : b0 + 64'(8 * k);
            src_data[k] = {hwm[4*k+3], hwm[4*k+2], hwm[4*k+1], hwm[4*k]};
            src_err[k]  = 1'b0;
        end
    endtask

    task automatic flush_all();
        @(negedge clk);
        src_en = 1'b0;
        pop_en = 1'b0;
        flush  = 1'b1;
        @(negedge clk);
        flush  = 1'b0;
        log_n  = 0;
    endtask

    // play the built stream; check the first upto entries
    task automatic play_and_check(input string name, input int upto, input int max_cycles);
        int c;
        src_en = 1'b1;
        pop_en = 1'b1;
        for (c = 0; c < max_cycles && log_n < upto; c++) @(posedge clk);
        #1;
        check({name, ": instruction count"}, 64'(log_n >= upto), 64'd1);
        for (int k = 0; k < upto && k < log_n; k++) begin
            check($sformatf("%s: #%0d pc", name, k), log_pc[k], exp_pc[k]);
            check($sformatf("%s: #%0d raw", name, k), {32'b0, log_raw[k]}, {32'b0, exp_raw[k]});
            check($sformatf("%s: #%0d rvc", name, k), {63'b0, log_rvc[k]}, {63'b0, exp_rvc[k]});
            check($sformatf("%s: #%0d no fault", name, k), {63'b0, log_xcpt[k]}, 64'd0);
        end
    endtask

    function automatic logic [31:0] w32(input int x);   // a 32-bit encoding (low bits 11)
        return {x[29:0], 2'b11};
    endfunction

    int k, s, cut;
    logic [63:0] st;

    initial begin
        for (k = 0; k < MAXD; k++) src_err[k] = 1'b0;
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;

        // ---- D1: four RVC in one dword -> two cycles, popped once ----
        build(64'h100, 4, 100);
        play_and_check("D1 four rvc", 4, 40);
        flush_all();

        // ---- D2: a 32-bit instruction at halfword 3 crosses into the next dword ----
        build(64'h206, 3, 0);                 // starts at the dword's last halfword
        play_and_check("D2 crossing from the start", 3, 40);
        flush_all();
        for (k = 0; k < MAXD; k++) hwm[k] = rand_c();
        hwm[0] = rand_c(); hwm[1] = rand_c(); hwm[2] = rand_c();
        hwm[3] = 16'hABC3; hwm[4] = 16'h1234;              // crossing at 0x306
        src_n = 3;
        for (k = 0; k < src_n; k++) begin
            src_pc[k]   = 64'h300 + 64'(8 * k);
            src_data[k] = {hwm[4*k+3], hwm[4*k+2], hwm[4*k+1], hwm[4*k]};
            src_err[k]  = 1'b0;
        end
        exp_n = 4;
        for (k = 0; k < 3; k++) begin
            exp_pc[k] = 64'h300 + 64'(2 * k); exp_raw[k] = {16'b0, hwm[k]}; exp_rvc[k] = 1'b1;
        end
        exp_pc[3] = 64'h306; exp_raw[3] = 32'h1234_ABC3; exp_rvc[3] = 1'b0;
        play_and_check("D2 crossing mid-stream", 4, 40);
        flush_all();

        // ---- D3: redirect-style starts at every halfword ----
        for (s = 0; s < 4; s++) begin
            build(64'h400 + 64'(2 * s), 6, 50);
            play_and_check($sformatf("D3 start hw %0d", s), 6, 60);
            flush_all();
        end

        // ---- D4: no movement without IQ room ----
        build(64'h500, 8, 50);
        src_en = 1'b1;
        force push_ready = 1'b0;
        #1;
        check("D4: no pop without room", {63'b0, buf_pop}, 64'd0);
        check("D4: no push without room", {63'b0, p0_valid | p1_valid}, 64'd0);
        repeat (3) @(posedge clk);
        release push_ready;
        play_and_check("D4: stream intact after the stall", 8, 80);
        flush_all();

        // ---- D5: flush while a crossing half is held ----
        for (k = 0; k < MAXD; k++) hwm[k] = rand_c();
        hwm[3] = 16'hFFFF;                                  // 32-bit low half at 0x606
        src_n = 1;                                          // its high half never arrives
        src_pc[0] = 64'h600; src_data[0] = {hwm[3], hwm[2], hwm[1], hwm[0]}; src_err[0] = 1'b0;
        src_en = 1'b1; pop_en = 1'b1;
        repeat (10) @(posedge clk);
        #1;
        check("D5: the three rvc before it came out", 64'(log_n), 64'd3);
        flush_all();
        build(64'h700, 6, 50);                              // must start clean
        play_and_check("D5: no stale half after flush", 6, 60);
        flush_all();

        // ---- D6: fetch faults ----
        build(64'h800, 10, 50);
        src_err[1] = 1'b1;
        // the first instruction touching dword 1 (0x808) is the marker
        cut = 0;
        while (cut < exp_n && exp_pc[cut] + (exp_rvc[cut] ? 64'd2 : 64'd4) <= 64'h808) cut++;
        src_en = 1'b1; pop_en = 1'b1;
        repeat (30) @(posedge clk);
        #1;
        check("D6: instructions up to the fault", 64'(log_n >= cut + 1), 64'd1);
        for (k = 0; k < cut; k++) begin
            check($sformatf("D6: #%0d before fault pc", k), log_pc[k], exp_pc[k]);
            check($sformatf("D6: #%0d before fault clean", k), {63'b0, log_xcpt[k]}, 64'd0);
        end
        check("D6: marker pc", log_pc[cut], exp_pc[cut]);
        check("D6: marker faulted", {63'b0, log_xcpt[cut]}, 64'd1);
        check("D6: marker cause 1", {60'b0, log_cause[cut]}, 64'd1);
        check("D6: marker xcpt_hi iff it crossed in", {63'b0, log_hi[cut]}, {63'b0, exp_pc[cut] < 64'h808});
        flush_all();
        // a crossing instruction whose second dword faults
        for (k = 0; k < MAXD; k++) hwm[k] = rand_c();
        hwm[3] = 16'h0003;
        src_n = 2;
        src_pc[0] = 64'h900; src_data[0] = {hwm[3], hwm[2], hwm[1], hwm[0]}; src_err[0] = 1'b0;
        src_pc[1] = 64'h908; src_data[1] = '0;                src_err[1] = 1'b1;
        src_en = 1'b1; pop_en = 1'b1;
        repeat (10) @(posedge clk);
        #1;
        check("D6b: three rvc then the marker", 64'(log_n), 64'd4);
        check("D6b: marker at the crossing pc", log_pc[3], 64'h906);
        check("D6b: marker faulted", {63'b0, log_xcpt[3]}, 64'd1);
        check("D6b: marker xcpt_hi", {63'b0, log_hi[3]}, 64'd1);
        flush_all();

        // ---- R1: random streams under random backpressure ----
        for (s = 0; s < 300; s++) begin
            st = 64'h1000 + 64'(($urandom % 64) * 2);
            pop_pct = 20 + $urandom % 81;
            build(st, 1 + $urandom % 30, (s % 3 == 0) ? 0 : (s % 3 == 1) ? 50 : 90);
            play_and_check($sformatf("R1 stream %0d", s), exp_n, 400);
            flush_all();
        end

        // ---- R2: mid-stream flushes, then an exact clean stream ----
        for (s = 0; s < 200; s++) begin
            pop_pct = 30 + $urandom % 71;
            build(64'h2000 + 64'(($urandom % 64) * 2), 20, 50);
            src_en = 1'b1; pop_en = 1'b1;
            repeat ($urandom % 12) @(posedge clk);
            flush_all();
            build(64'h3000 + 64'(($urandom % 64) * 2), 1 + $urandom % 20, 50);
            play_and_check($sformatf("R2 after flush %0d", s), exp_n, 300);
            flush_all();
        end
        pop_pct = 100;

        // ---- F1: fifo ready threshold and wraparound ordering ----
        for (k = 0; k < 4; k++) begin
            src_pc[k] = 64'(8 * k);
            src_data[k] = {w32(16 * (k + 1) + 1), w32(16 * (k + 1))};
            src_err[k] = 1'b0;
        end
        src_n = 4;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F1: ready at count 2", {63'b0, push_ready}, 64'd1);
        @(posedge clk); #1;
        check("F1: not ready at count 4 (full)", {63'b0, push_ready}, 64'd0);
        repeat (3) @(posedge clk);
        #1;
        check("F1: still full, source stalled", 64'(src_i), 64'd2);
        pop_en = 1'b1;
        repeat (20) @(posedge clk);
        #1;
        check("F1: all 8 instructions out", 64'(log_n), 64'd8);
        for (k = 0; k < 8; k++) begin
            check($sformatf("F1: order %0d pc", k), log_pc[k], 64'(4 * k));
            check($sformatf("F1: order %0d raw", k), {32'b0, log_raw[k]},
                  {32'b0, w32((k / 2 + 1) * 16 + (k % 2))});
        end
        flush_all();

        // ---- F2: flush empties the queue ----
        src_pc[0] = 64'h200; src_data[0] = {w32(2), w32(1)}; src_err[0] = 1'b0;
        src_n = 1;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F2: non-empty before flush", {63'b0, head_valid}, 64'd1);
        flush_all();
        check("F2: empty after flush", {63'b0, head_valid}, 64'd0);
        check("F2: ready after flush", {63'b0, push_ready}, 64'd1);

        // ---- F3: a pop while empty is ignored, not an underflow ----
        force_pop = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        force_pop = 1'b0;
        check("F3: still empty after popping an empty queue", {63'b0, head_valid}, 64'd0);
        check("F3: still ready after popping an empty queue", {63'b0, push_ready}, 64'd1);
        src_pc[0] = 64'h300; src_data[0] = {w32(32'h3B), w32(32'h3A)}; src_err[0] = 1'b0;
        src_n = 1;
        src_en = 1'b1;
        pop_en = 1'b1;
        repeat (6) @(posedge clk);
        #1;
        check("F3: exactly the 2 pushed entries come out", 64'(log_n), 64'd2);
        check("F3: first entry", {32'b0, log_raw[0]}, {32'b0, w32(32'h3A)});
        check("F3: second entry", {32'b0, log_raw[1]}, {32'b0, w32(32'h3B)});
        check("F3: empty again", {63'b0, head_valid}, 64'd0);

        $display("");
        $display("qv_align_fifo_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_align_fifo_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT: qv_align_fifo_tb");
        $finish;
    end
endmodule
