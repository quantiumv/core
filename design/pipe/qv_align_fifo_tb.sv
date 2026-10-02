// SPDX-License-Identifier: MIT

/*
 * qv_align_fifo_tb -- standalone test for design/pipe/qv_align.sv and
 * design/pipe/qv_fifo.sv, wired together the way core_pipe uses them
 * (fetch buffer -> align -> IQ), plus direct checks on each.
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
    logic        buf_valid = 1'b0, buf_err = 1'b0;
    logic [63:0] buf_pc = '0, buf_data = '0;
    logic        buf_pop;
    logic        p0_valid, p1_valid, push_ready;
    fe_instr_t   p0_data, p1_data;
    logic        flush = 1'b0;
    logic        head_valid;
    logic [W-1:0] head_bits;
    fe_instr_t   head;
    logic        pop_en = 1'b0;
    logic        force_pop = 1'b0;          // pops even when empty (F3)
    wire         pop = (pop_en && head_valid) || force_pop;

    assign head = fe_instr_t'(head_bits);

    qv_align align0 (
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

    // ---------------- consumer log ----------------
    logic [63:0] log_pc  [0:63];
    logic [31:0] log_raw [0:63];
    int log_n = 0;
    always @(posedge clk) begin
        if (!rst && pop && head_valid) begin
            log_pc[log_n]  <= head.pc;
            log_raw[log_n] <= head.raw;
            log_n          <= log_n + 1;
        end
    end

    // ---------------- scripted fetch-buffer source ----------------
    // Each entry is one fetched dword; the source presents the head and
    // advances whenever align pops it.
    logic [63:0] src_pc   [0:15];
    logic [63:0] src_data [0:15];
    int src_n = 0, src_i = 0;
    logic src_en = 1'b0;
    always @(posedge clk) begin
        if (!rst && src_en && buf_pop) src_i <= src_i + 1;
    end
    always_comb begin
        if (src_en && src_i < src_n) begin
            buf_valid = 1'b1;
            buf_pc    = src_pc[src_i];
            buf_data  = src_data[src_i];
        end else if (src_en) begin
            buf_valid = 1'b0;
            buf_pc    = '0;
            buf_data  = '0;
        end
    end

    task automatic do_reset();
        src_en = 1'b0;
        pop_en = 1'b0;
        rst    = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        rst   = 1'b0;
        log_n = 0;
        src_i = 0;
    endtask

    int k, expect_n;
    logic [63:0] exp_pc  [0:63];
    logic [31:0] exp_raw [0:63];

    initial begin
        // ---- A1-A4: align, combinational ----
        rst = 1'b0;
        #1;
        buf_valid = 1'b1; buf_err = 1'b0;
        buf_pc = 64'h100; buf_data = {32'hBBBB_BBBB, 32'hAAAA_AAAA};
        force push_ready = 1'b1;
        #1;
        check("A1: pop when ready", {63'b0, buf_pop}, 64'd1);
        check("A1: slot0 valid", {63'b0, p0_valid}, 64'd1);
        check("A1: slot1 valid", {63'b0, p1_valid}, 64'd1);
        check("A1: slot0 pc", p0_data.pc, 64'h100);
        check("A1: slot0 raw", {32'b0, p0_data.raw}, 64'hAAAA_AAAA);
        check("A1: slot1 pc", p1_data.pc, 64'h104);
        check("A1: slot1 raw", {32'b0, p1_data.raw}, 64'hBBBB_BBBB);
        check("A1: no fault", {63'b0, p0_data.xcpt | p1_data.xcpt}, 64'd0);

        buf_pc = 64'h104;
        #1;
        check("A2: high-half-only slot0 valid", {63'b0, p0_valid}, 64'd1);
        check("A2: high-half-only slot1 not valid", {63'b0, p1_valid}, 64'd0);
        check("A2: slot0 pc", p0_data.pc, 64'h104);
        check("A2: slot0 raw is the high half", {32'b0, p0_data.raw}, 64'hBBBB_BBBB);

        buf_pc = 64'h100; buf_err = 1'b1;
        #1;
        check("A3: fault marked slot0", {63'b0, p0_data.xcpt}, 64'd1);
        check("A3: fault cause slot0", {60'b0, p0_data.xcpt_cause}, 64'd1);
        check("A3: fault marked slot1", {63'b0, p1_data.xcpt}, 64'd1);
        buf_err = 1'b0;

        force push_ready = 1'b0;
        #1;
        check("A4: no pop without room", {63'b0, buf_pop}, 64'd0);
        check("A4: no push without room", {63'b0, p0_valid | p1_valid}, 64'd0);
        release push_ready;
        buf_valid = 1'b0;

        // ---- F1: fifo ready threshold and wraparound ordering ----
        do_reset();
        // fill: two pairs -> count 4
        src_pc[0] = 64'h000; src_data[0] = {32'h11, 32'h10};
        src_pc[1] = 64'h008; src_data[1] = {32'h21, 32'h20};
        src_pc[2] = 64'h010; src_data[2] = {32'h31, 32'h30};
        src_pc[3] = 64'h018; src_data[3] = {32'h41, 32'h40};
        src_n = 4;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F1: ready at count 2", {63'b0, push_ready}, 64'd1);
        @(posedge clk); #1;
        check("F1: not ready at count 4 (full)", {63'b0, push_ready}, 64'd0);
        repeat (3) @(posedge clk);
        #1;
        check("F1: still full, source stalled", 64'(src_i), 64'd2);
        // drain everything at one per cycle; source refills behind it,
        // exercising pointer wraparound
        pop_en = 1'b1;
        repeat (20) @(posedge clk);
        #1;
        check("F1: all 8 instructions out", 64'(log_n), 64'd8);
        for (k = 0; k < 8; k++) begin
            check($sformatf("F1: order %0d pc", k), log_pc[k], 64'(4 * k));
            check($sformatf("F1: order %0d raw", k), {32'b0, log_raw[k]},
                  64'((k / 2 + 1) * 16 + (k % 2)));
        end

        // ---- F2: flush empties the queue ----
        do_reset();
        src_pc[0] = 64'h200; src_data[0] = {32'h2, 32'h1};
        src_n = 1;
        src_en = 1'b1;
        @(posedge clk); #1;
        check("F2: non-empty before flush", {63'b0, head_valid}, 64'd1);
        src_en = 1'b0;
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        check("F2: empty after flush", {63'b0, head_valid}, 64'd0);
        check("F2: ready after flush", {63'b0, push_ready}, 64'd1);

        // ---- F3: a pop while empty is ignored, not an underflow ----
        do_reset();
        force_pop = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        force_pop = 1'b0;
        check("F3: still empty after popping an empty queue", {63'b0, head_valid}, 64'd0);
        check("F3: still ready after popping an empty queue", {63'b0, push_ready}, 64'd1);
        src_pc[0] = 64'h300; src_data[0] = {32'h3B, 32'h3A};
        src_n = 1;
        src_en = 1'b1;
        pop_en = 1'b1;
        repeat (6) @(posedge clk);
        #1;
        check("F3: exactly the 2 pushed entries come out", 64'(log_n), 64'd2);
        check("F3: first entry", {32'b0, log_raw[0]}, 64'h3A);
        check("F3: second entry", {32'b0, log_raw[1]}, 64'h3B);
        check("F3: empty again", {63'b0, head_valid}, 64'd0);

        // ---- S1: a stream with a high-half-only dword mid-stream ----
        do_reset();
        src_pc[0] = 64'h400; src_data[0] = {32'hA1, 32'hA0};
        src_pc[1] = 64'h408; src_data[1] = {32'hB1, 32'hB0};
        src_pc[2] = 64'h514; src_data[2] = {32'hC1, 32'hC0};   // redirect-style target, pc[2]=1
        src_pc[3] = 64'h518; src_data[3] = {32'hD1, 32'hD0};
        src_n = 4;
        expect_n = 7;
        exp_pc[0] = 64'h400; exp_raw[0] = 32'hA0;
        exp_pc[1] = 64'h404; exp_raw[1] = 32'hA1;
        exp_pc[2] = 64'h408; exp_raw[2] = 32'hB0;
        exp_pc[3] = 64'h40C; exp_raw[3] = 32'hB1;
        exp_pc[4] = 64'h514; exp_raw[4] = 32'hC1;
        exp_pc[5] = 64'h518; exp_raw[5] = 32'hD0;
        exp_pc[6] = 64'h51C; exp_raw[6] = 32'hD1;
        src_en = 1'b1;
        // pop on alternate cycles so the queue genuinely backs up
        for (k = 0; k < 30; k++) begin
            pop_en = k[0];
            @(posedge clk);
        end
        #1;
        pop_en = 1'b0;
        check("S1: all 7 instructions out", 64'(log_n), 64'(expect_n));
        for (k = 0; k < expect_n; k++) begin
            check($sformatf("S1: order %0d pc", k), log_pc[k], exp_pc[k]);
            check($sformatf("S1: order %0d raw", k), {32'b0, log_raw[k]}, {32'b0, exp_raw[k]});
        end

        $display("");
        $display("qv_align_fifo_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_align_fifo_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: qv_align_fifo_tb");
        $finish;
    end
endmodule
