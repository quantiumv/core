// SPDX-License-Identifier: MIT

/*
 * qv_rob_tb -- standalone test for design/pipe/qv_rob.sv.
 *
 * Drives what the end-to-end pipeline can't reach yet (every ALU uop has
 * the same one-cycle latency and commits immediately, so a completed-
 * but-uncommitted entry is always the head): filling the ROB, completing
 * entries out of order, looking up non-head entries by tag, tag
 * wraparound -- including reusing an index whose previous occupant
 * completed -- the mispredict next-pc override, and flush. Run at
 * ROB_DEPTH=8, 4 and 2.
 */
module qv_rob_tb #(
    parameter int ROB_DEPTH = 8
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    flush = 1'b0;
    logic                    alloc_valid = 1'b0;
    logic [63:0]             alloc_pc, alloc_next_pc;
    logic [31:0]             alloc_raw;
    logic [4:0]              alloc_rd;
    logic                    alloc_rd_wen;
    rvfi_shadow_t            alloc_shadow, head_shadow;
    rob_ctrl_t               alloc_ctrl, head_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, head_tag;
    logic                    alloc_ready, empty;
    wb_t                     wb = '0;
    logic [QV_ROB_TAG_W-1:0] l1_tag = '0, l2_tag = '0;
    logic                    l1_complete, l2_complete;
    logic [63:0]             l1_value, l2_value;
    logic                    head_valid;
    rob_entry_t              head;
    logic                    pop = 1'b0;

    qv_rob #(.ROB_DEPTH(ROB_DEPTH)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_alloc_valid(alloc_valid), .i_alloc_pc(alloc_pc), .i_alloc_raw(alloc_raw),
        .i_alloc_rd(alloc_rd), .i_alloc_rd_wen(alloc_rd_wen), .i_alloc_next_pc(alloc_next_pc),
        .i_alloc_shadow(alloc_shadow), .i_alloc_ctrl(alloc_ctrl),
        .o_alloc_tag(alloc_tag), .o_alloc_ready(alloc_ready),
        .o_empty(empty), .i_wb(wb),
        .i_lookup1_tag(l1_tag), .o_lookup1_complete(l1_complete), .o_lookup1_value(l1_value),
        .i_lookup2_tag(l2_tag), .o_lookup2_complete(l2_complete), .o_lookup2_value(l2_value),
        .o_head_valid(head_valid), .o_head_entry(head), .o_head_tag(head_tag),
        .o_head_shadow(head_shadow), .o_head_ctrl(head_ctrl), .i_commit_pop(pop)
    );

    // Entry n's fields are a pure function of n, so any slot can be
    // checked later without bookkeeping.
    function automatic logic [63:0] val_of(input int n); return 64'hA000_0000_0000_0000 + 64'(n * 17); endfunction

    int seq = 0;   // allocation sequence number
    logic [QV_ROB_TAG_W-1:0] tag_of [0:255];

    task automatic do_alloc();
        @(negedge clk);
        alloc_valid  = 1'b1;
        alloc_pc     = 64'h1000 + 64'(4 * seq);
        alloc_next_pc= 64'h1004 + 64'(4 * seq);
        alloc_raw    = 32'h5000_0000 + 32'(seq);
        alloc_rd     = 5'(seq % 31 + 1);
        alloc_rd_wen = seq[0];
        alloc_shadow = '0;
        alloc_shadow.rs1_addr  = 5'(seq % 7);
        alloc_shadow.rs1_rdata = 64'(seq) << 8;
        alloc_ctrl = '0;
        alloc_ctrl.csr_addr  = 12'(seq * 37);
        alloc_ctrl.serialize = seq[1];
        alloc_ctrl.cause     = 4'(seq);
        #1;
        tag_of[seq] = alloc_tag;
        @(posedge clk);
        #1;
        alloc_valid = 1'b0;
        seq++;
    endtask

    task automatic do_complete(input int n);
        @(negedge clk);
        wb       = '0;
        wb.valid = 1'b1;
        wb.tag   = tag_of[n];
        wb.value = val_of(n);
        @(posedge clk);
        #1;
        wb = '0;
    endtask

    task automatic check_lookup(input string tag, input int n, input logic exp_complete);
        l1_tag = tag_of[n];
        l2_tag = tag_of[n];
        #1;
        check($sformatf("%s: entry %0d complete (port 1)", tag, n), {63'b0, l1_complete}, {63'b0, exp_complete});
        check($sformatf("%s: entry %0d complete (port 2)", tag, n), {63'b0, l2_complete}, {63'b0, exp_complete});
        if (exp_complete) begin
            check($sformatf("%s: entry %0d value (port 1)", tag, n), l1_value, val_of(n));
            check($sformatf("%s: entry %0d value (port 2)", tag, n), l2_value, val_of(n));
        end
    endtask

    task automatic pop_and_check(input string tag, input int n);
        #1;
        check($sformatf("%s: head %0d valid", tag, n), {63'b0, head_valid}, 64'd1);
        check($sformatf("%s: head %0d complete", tag, n), {63'b0, head.complete}, 64'd1);
        check($sformatf("%s: head %0d tag", tag, n), {60'b0, head_tag}, {60'b0, tag_of[n]});
        check($sformatf("%s: head %0d pc", tag, n), head.pc, 64'h1000 + 64'(4 * n));
        check($sformatf("%s: head %0d next_pc", tag, n), head.next_pc, 64'h1004 + 64'(4 * n));
        check($sformatf("%s: head %0d raw", tag, n), {32'b0, head.raw}, 64'h5000_0000 + 64'(n));
        check($sformatf("%s: head %0d rd", tag, n), {59'b0, head.rd}, 64'(n % 31 + 1));
        check($sformatf("%s: head %0d rd_wen", tag, n), {63'b0, head.rd_wen}, 64'(n % 2));
        check($sformatf("%s: head %0d value", tag, n), head.value, val_of(n));
        check($sformatf("%s: head %0d shadow rs1_addr", tag, n), {59'b0, head_shadow.rs1_addr}, 64'(n % 7));
        check($sformatf("%s: head %0d shadow rs1_rdata", tag, n), head_shadow.rs1_rdata, 64'(n) << 8);
        check($sformatf("%s: head %0d ctrl csr_addr", tag, n), {52'b0, head_ctrl.csr_addr}, 64'(12'(n * 37)));
        check($sformatf("%s: head %0d ctrl serialize", tag, n), {63'b0, head_ctrl.serialize}, 64'((n >> 1) & 1));
        check($sformatf("%s: head %0d ctrl cause", tag, n), {60'b0, head_ctrl.cause}, 64'(n % 16));
        @(negedge clk);
        pop = 1'b1;
        @(posedge clk);
        #1;
        pop = 1'b0;
    endtask

    int i, base;

    initial begin
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: empty", {63'b0, empty}, 64'd1);
        check("reset: ready", {63'b0, alloc_ready}, 64'd1);
        check("reset: no head", {63'b0, head_valid}, 64'd0);

        // a pop while empty is ignored, not an underflow
        @(negedge clk);
        pop = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        pop = 1'b0;
        check("empty pop: still empty", {63'b0, empty}, 64'd1);
        check("empty pop: still ready", {63'b0, alloc_ready}, 64'd1);
        check("empty pop: next tag still 0", {60'b0, alloc_tag}, 64'd0);

        // ---- fill to full, nothing completed ----
        for (i = 0; i < ROB_DEPTH; i++) begin
            #1;
            check($sformatf("fill: ready before entry %0d", i), {63'b0, alloc_ready}, 64'd1);
            do_alloc();
        end
        check("fill: not ready when full", {63'b0, alloc_ready}, 64'd0);
        check("fill: not empty", {63'b0, empty}, 64'd0);
        for (i = 0; i < ROB_DEPTH; i++)
            check($sformatf("fill: tag %0d", i), {60'b0, tag_of[i]}, 64'(i));
        // an allocation attempt while full is refused
        @(negedge clk);
        alloc_valid = 1'b1;
        @(posedge clk); #1;
        alloc_valid = 1'b0;
        check("full: refused allocation didn't move the tail", {60'b0, alloc_tag}, 64'(ROB_DEPTH));

        // ---- complete out of order (youngest first) ----
        for (i = ROB_DEPTH - 1; i >= 0; i--) begin
            do_complete(i);
            check_lookup($sformatf("ooo after %0d", i), i, 1'b1);
            if (i > 0) check_lookup($sformatf("ooo after %0d", i), i - 1, 1'b0);
            #1;
            check($sformatf("ooo: head not complete until entry 0 is (after %0d)", i),
                  {63'b0, head.complete}, 64'(i == 0));
        end
        // every non-head entry readable by tag
        for (i = 0; i < ROB_DEPTH; i++) check_lookup("all complete", i, 1'b1);

        // ---- commit in order ----
        for (i = 0; i < ROB_DEPTH / 2; i++) pop_and_check("commit", i);
        #1;
        check("partial drain: ready again", {63'b0, alloc_ready}, 64'd1);
        // remaining (older-index) entries still readable after the head moved
        for (i = ROB_DEPTH / 2; i < ROB_DEPTH; i++) check_lookup("after partial drain", i, 1'b1);

        // ---- wraparound: reuse indices whose previous occupant completed ----
        base = seq;
        for (i = 0; i < ROB_DEPTH / 2; i++) begin
            do_alloc();
            check_lookup("wrap: fresh entry not complete", base + i, 1'b0);
        end
        check("wrap: full again", {63'b0, alloc_ready}, 64'd0);
        for (i = 0; i < ROB_DEPTH / 2; i++)
            check($sformatf("wrap: tag %0d carries the wrap bit", base + i), {60'b0, tag_of[base + i]},
                  64'(ROB_DEPTH + i));
        // complete the wrapped entries in reverse, drain everything in order
        for (i = ROB_DEPTH / 2 - 1; i >= 0; i--) do_complete(base + i);
        for (i = ROB_DEPTH / 2; i < seq; i++) pop_and_check("drain", i);
        #1;
        check("drain: empty", {63'b0, empty}, 64'd1);

        // ---- mispredict: resolved next pc replaces the prediction ----
        base = seq;
        do_alloc();                                      // base: will mispredict
        do_alloc();                                      // base+1: completes normally
        @(negedge clk);
        wb = '0; wb.valid = 1'b1; wb.tag = tag_of[base]; wb.value = val_of(base);
        wb.mispredict = 1'b1; wb.next_pc = 64'hDEAD_BEE0;
        @(posedge clk); #1;
        wb = '0;
        @(negedge clk);
        wb = '0; wb.valid = 1'b1; wb.tag = tag_of[base + 1]; wb.value = val_of(base + 1);
        wb.next_pc = 64'hBAD0;                           // ignored without mispredict
        @(posedge clk); #1;
        wb = '0;
        check("mispredict: head flagged", {63'b0, head.mispredict}, 64'd1);
        check("mispredict: head next_pc resolved", head.next_pc, 64'hDEAD_BEE0);
        check("mispredict: value still written", head.value, val_of(base));
        @(negedge clk); pop = 1'b1; @(posedge clk); #1; pop = 1'b0;
        check("normal: head not flagged", {63'b0, head.mispredict}, 64'd0);
        check("normal: predicted next_pc kept", head.next_pc, 64'h1004 + 64'(4 * (base + 1)));
        @(negedge clk); pop = 1'b1; @(posedge clk); #1; pop = 1'b0;
        // every slot, including the one that mispredicted, comes back clean
        for (i = 0; i < ROB_DEPTH; i++) begin
            do_alloc();
            do_complete(seq - 1);
            #1;
            check($sformatf("reuse %0d: not flagged", i), {63'b0, head.mispredict}, 64'd0);
            check($sformatf("reuse %0d: predicted next_pc", i), head.next_pc, 64'h1004 + 64'(4 * (seq - 1)));
            @(negedge clk); pop = 1'b1; @(posedge clk); #1; pop = 1'b0;
        end

        // ---- flush with the head popping the same cycle ----
        base = seq;
        for (i = 0; i < 3; i++) do_alloc();
        do_complete(base);
        @(negedge clk);
        flush = 1'b1;
        pop   = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        pop   = 1'b0;
        check("flush: empty", {63'b0, empty}, 64'd1);
        check("flush: ready", {63'b0, alloc_ready}, 64'd1);
        // tags wrap modulo 2*ROB_DEPTH (index + wrap bit), not modulo 2^QV_ROB_TAG_W
        check("flush: next tag follows the popped head", {60'b0, alloc_tag},
              64'((int'(tag_of[base]) + 1) % (2 * ROB_DEPTH)));
        // allocation after a flush lands as a fresh, incomplete entry at the head
        do_alloc();
        #1;
        check("post-flush: head valid", {63'b0, head_valid}, 64'd1);
        check("post-flush: head not complete", {63'b0, head.complete}, 64'd0);
        check("post-flush: head is the new entry", head.pc, 64'h1000 + 64'(4 * (seq - 1)));

        $display("");
        $display("qv_rob_tb (ROB_DEPTH=%0d): %0d passed, %0d failed", ROB_DEPTH, pass_count, fail_count);
        if (fail_count > 0) $display("qv_rob_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT: qv_rob_tb");
        $finish;
    end
endmodule
