// SPDX-License-Identifier: MIT

/*
 * qv_lsq_tb -- design/pipe/qv_lsq.sv against a model engine and a model commit.
 *
 * The engine takes one op when it is free, completes it after 0 to 3 cycles in its WAIT_HEAD/BUS states (o_wb for
 * one cycle, o_res registered at that edge, then free again), and on a flush drops the op it holds, or drains it for
 * a few cycles with no writeback. Commit retires the oldest dispatched op once it has been complete for a cycle, at a
 * random later cycle, and pops ROB entries that are not memory ops in between (their tags never match the queue's).
 *
 * Directed: a dispatch into an empty queue reaches the engine in the same cycle; the queue fills to DEPTH and frees a
 * slot only when an op retires; the result is read in the cycle after completion (from the engine) and later (from
 * the queue's copy); a pop whose tag is not the oldest entry's does nothing; a flush empties it.
 * Random: 4000 cycles of dispatches, completions, retirements and flushes, checking that the engine sees the ops in
 * dispatch order, that every retirement reads its own op's result, and that o_free is "fewer than DEPTH in the queue".
 */
module qv_lsq_tb #(
    parameter int DEPTH = 4
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    logic flush = 1'b0;

    fu_req_t                 req;
    logic                    free;
    fu_req_t                 eng_req;
    logic                    eng_free;
    wb_t                     eng_wb;
    lsu_res_t                eng_res;
    logic                    pop = 1'b0;
    logic [QV_ROB_TAG_W-1:0] pop_tag = '0;
    lsu_res_t                head_res;
    logic                    bar_alloc = 1'b0;
    logic [QV_ROB_TAG_W-1:0] bar_tag = '0;
    logic                    early, match;
    logic [31:3]             match_addr = '0;

    logic                    e_take;             // the model engine takes eng_req (below)
    qv_lsq #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .o_eng_req(eng_req), .i_eng_take(e_take), .i_eng_wb(eng_wb), .i_eng_res(eng_res),
        .i_pop(pop), .i_pop_tag(pop_tag), .o_head_res(head_res),
        .i_bar_alloc(bar_alloc), .i_bar_tag(bar_tag), .o_early(early), .i_match_addr(match_addr), .o_match(match)
    );

    // ---------------- the model engine ----------------
    // a result that names its op: tval = the tag and a sequence number of the dispatch
    function automatic lsu_res_t res_of(input logic [QV_ROB_TAG_W-1:0] t, input logic [63:0] a);
        lsu_res_t r;
        r = '0;
        r.tval     = {a[59:0], 4'(t)};
        r.mem_addr = a ^ 64'hFFFF_0000_0000_0000;      // the dword (bits 31:3) is the request's own
        r.posted   = a[63];                            // the test marks a posted store by the top bit of a
        return r;
    endfunction

    // the fields the checks compare (Icarus cannot select a field of a function's result)
    function automatic logic [63:0] exp_tval(input logic [QV_ROB_TAG_W-1:0] t, input logic [63:0] a);
        lsu_res_t r; r = res_of(t, a); return r.tval;
    endfunction
    function automatic logic [63:0] exp_maddr(input logic [QV_ROB_TAG_W-1:0] t, input logic [63:0] a);
        lsu_res_t r; r = res_of(t, a); return r.mem_addr;
    endfunction

    logic                    e_busy = 1'b0, e_drain = 1'b0;
    logic [QV_ROB_TAG_W-1:0] e_tag;
    logic [63:0]             e_a;
    int                      e_cnt = 0;
    int                      e_lat = 0;          // the latency of the next op the engine takes (set by the test)
    assign eng_free = !e_busy && !e_drain;
    assign e_take = eng_free && eng_req.valid && !flush;
    wire e_done = e_busy && (e_cnt == 0) && !flush;
    always_comb begin
        eng_wb       = '0;
        eng_wb.valid = e_done;
        eng_wb.tag   = e_tag;
    end
    int seen_tags [$];                           // what the engine took, in order
    always @(posedge clk) begin
        if (rst) begin
            e_busy <= 1'b0; e_drain <= 1'b0;
        end else begin
            if (e_take) begin
                e_busy <= 1'b1; e_tag <= eng_req.tag; e_a <= eng_req.a; e_cnt <= e_lat;
                seen_tags.push_back(int'(eng_req.tag));
            end else if (e_busy && flush) begin
                e_busy <= 1'b0;
                if ($urandom_range(0, 1)) begin e_drain <= 1'b1; e_cnt <= $urandom_range(1, 3); end
            end else if (e_done) begin
                e_busy <= 1'b0;
                eng_res <= res_of(e_tag, e_a);
            end else if (e_busy) begin
                e_cnt <= e_cnt - 1;
            end
            if (e_drain) begin
                if (e_cnt == 0) e_drain <= 1'b0;
                else            e_cnt <= e_cnt - 1;
            end
        end
    end

    // ---------------- helpers ----------------
    logic [QV_ROB_TAG_W-1:0] next_tag = '0;
    logic [63:0]             next_a   = 64'h100;

    task automatic present(output logic [QV_ROB_TAG_W-1:0] t, output logic [63:0] a);
        req = '0; req.valid = 1'b1; req.tag = next_tag; req.a = next_a; req.op = 5'b00011;
        t = next_tag; a = next_a;
        next_tag = next_tag + 1'b1; next_a = next_a + 64'h40;
    endtask
    task automatic idle(); req = '0; endtask
    task automatic tick(); @(posedge clk); #1; endtask

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- random run state ----------------
    // dispatched and not retired, oldest first: tag, request a, the cycle it completed (-1: not yet)
    logic [QV_ROB_TAG_W-1:0] q_tag [$];
    logic [63:0]             q_a [$];
    int                      q_done [$];
    int  cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        logic [QV_ROB_TAG_W-1:0] t0, t1, t2;
        logic [63:0]             a0, a1, a2;
        lsu_res_t                r0;
        idle();
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // ---- an empty queue passes the dispatch to a free engine in the same cycle ----
        e_lat = 1;
        present(t0, a0);
        #1;
        check("empty queue: the engine sees the dispatch at once", b(eng_req.valid), 64'd1);
        check("... its tag", 64'(eng_req.tag), 64'(t0));
        check("... and it is free to dispatch", b(free), 64'd1);
        tick(); idle();
        check("one op in the engine: room left", b(free), 64'd1);
        check("... the engine is busy", b(eng_free), 64'd0);
        // it completes (latency 1: one cycle held, then done)
        tick();
        check("completion cycle: writeback", b(eng_wb.valid), 64'd1);
        tick();
        check("the cycle after: the head's result is the engine's", head_res.tval, exp_tval(t0, a0));
        tick();
        check("later: the head's result is the queue's copy", head_res.tval, exp_tval(t0, a0));
        check("... the whole record", head_res.mem_addr, exp_maddr(t0, a0));
        // a pop of another tag (a ROB entry that is not a memory op) leaves it
        pop = 1'b1; pop_tag = t0 + 4'd7;
        tick(); pop = 1'b0;
        check("a pop of another tag: the op is still the head", head_res.tval, exp_tval(t0, a0));
        pop = 1'b1; pop_tag = t0;
        tick(); pop = 1'b0;

        // ---- fill it: while the engine holds one, the others queue; room comes back only at a retirement ----
        e_lat = 2;
        present(t0, a0); tick();
        present(t1, a1); #1;
        check("engine busy: a dispatch queues (the engine is not offered it as new)", 64'(eng_req.tag), 64'(t1));
        check("... and the engine does not take it", b(eng_free), 64'd0);
        tick();
        for (int i = 2; i < DEPTH; i++) begin present(t2, a2); tick(); end
        idle();
        check("DEPTH ops dispatched: no room", b(free), 64'd0);
        // wait for all of them to complete (each 2 cycles held + one lost cycle between ops)
        repeat (4 * DEPTH + 4) tick();
        check("all done, none retired: still no room", b(free), 64'd0);
        check("the head's result is the first op's", head_res.tval, exp_tval(t0, a0));
        pop = 1'b1; pop_tag = t0; #1;
        check("retiring the head (combinational result)", head_res.tval, exp_tval(t0, a0));
        tick(); pop = 1'b0;
        check("one retired: room again", b(free), 64'd1);
        check("the next head's result", head_res.tval, exp_tval(t1, a1));

        // ---- a flush empties it ----
        flush = 1'b1; tick(); flush = 1'b0;
        check("after a flush: room", b(free), 64'd1);
        check("after a flush: nothing offered to the engine", b(eng_req.valid), 64'd0);
        repeat (4) tick();

        // ---- barriers: an op dispatched while a barrier is unretired may not go early until it retires ----
        flush = 1'b1; tick(); flush = 1'b0;
        e_lat = 6;
        present(t0, a0); #1;                             // no barrier yet
        tick(); idle();
        check("no barrier: the op in the engine may go early", b(early), 64'd1);
        repeat (8) tick();
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        // a barrier is allocated (its own tag, the next one)
        bar_alloc = 1'b1; bar_tag = next_tag; t2 = next_tag; next_tag = next_tag + 1'b1;
        tick(); bar_alloc = 1'b0;
        present(t0, a0); tick(); idle();
        check("barrier older: the op in the engine may not go early", b(early), 64'd0);
        present(t1, a1); tick(); idle();
        // a second barrier, then a third op
        bar_alloc = 1'b1; bar_tag = next_tag; next_tag = next_tag + 1'b1;
        tick(); bar_alloc = 1'b0;
        check("still the first op in the engine: may not", b(early), 64'd0);
        // the first barrier retires: the first op may go
        pop = 1'b1; pop_tag = t2; tick(); pop = 1'b0;
        check("its barrier retired: the first op may go early", b(early), 64'd1);
        repeat (8) tick();
        check("the second op (behind the same barrier) is in the engine now and may go", b(early), 64'd1);
        // the second op's barrier is the first one too (it was dispatched before the second barrier)
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        repeat (8) tick();                               // the second op completes
        pop = 1'b1; pop_tag = t1; tick(); pop = 1'b0;
        // an op dispatched now is behind the second barrier
        present(t0, a0); tick(); idle();
        check("behind the second barrier: may not", b(early), 64'd0);
        pop = 1'b1; pop_tag = next_tag - 4'd2; tick(); pop = 1'b0;      // the second barrier's tag
        check("the second barrier retired: may go", b(early), 64'd1);
        repeat (8) tick();
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        // a barrier that retires in the very cycle an op is dispatched does not hold it
        bar_alloc = 1'b1; bar_tag = next_tag; t2 = next_tag; next_tag = next_tag + 1'b1;
        tick(); bar_alloc = 1'b0;
        present(t0, a0); pop = 1'b1; pop_tag = t2; tick(); pop = 1'b0; idle();
        check("barrier retiring as the op is dispatched: the op may go", b(early), 64'd1);
        repeat (8) tick();
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        // a flush forgets the barrier
        bar_alloc = 1'b1; bar_tag = next_tag; next_tag = next_tag + 1'b1;
        tick(); bar_alloc = 1'b0;
        flush = 1'b1; tick(); flush = 1'b0;
        repeat (4) tick();
        present(t0, a0); tick(); idle();
        check("after a flush: no barrier", b(early), 64'd1);
        repeat (8) tick();
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;

        // ---- the match: a posted store that is done and not retired, on the dword asked about ----
        e_lat = 1;
        next_a = 64'h8000_0000_0000_0200;                // posted (top bit) at 0x200
        present(t0, a0); tick(); idle();
        next_a = 64'h0000_0000_0000_0208;                // a plain op at 0x208, behind it
        repeat (2) tick();                               // the store completes
        match_addr = 29'(64'h200 >> 3); #1;
        check("done posted store, copy pending: matches its dword", b(match), 64'd1);
        tick();
        check("... and once copied", b(match), 64'd1);
        match_addr = 29'(64'h208 >> 3); #1;
        check("... not another dword", b(match), 64'd0);
        present(t1, a1); tick(); idle();
        repeat (3) tick();
        match_addr = 29'(64'h208 >> 3); #1;
        check("a done entry that is not posted does not match", b(match), 64'd0);
        match_addr = 29'(64'h200 >> 3);
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        check("the posted store retired (into the buffer): no longer the queue's to match", b(match), 64'd0);
        pop = 1'b1; pop_tag = t1; tick(); pop = 1'b0;
        // a posted store still in the engine (not done) does not match
        e_lat = 5;
        next_a = 64'h8000_0000_0000_0300;
        present(t0, a0); tick(); idle();
        match_addr = 29'(64'h300 >> 3); #1;
        check("a posted store not done yet does not match", b(match), 64'd0);
        repeat (8) tick();
        check("... and does once done", b(match), 64'd1);
        pop = 1'b1; pop_tag = t0; tick(); pop = 1'b0;
        next_a = 64'h100;
        match_addr = '0;

        // ---- random ----
        seen_tags.delete();
        begin
            int n_pops, n_flush;
            n_pops = 0; n_flush = 0;
            for (int k = 0; k < 4000; k++) begin
                // drive this cycle's inputs
                idle(); pop = 1'b0; flush = 1'b0;
                e_lat = $urandom_range(0, 3);
                if (free && $urandom_range(0, 2) != 0) begin
                    present(t0, a0);
                    q_tag.push_back(t0); q_a.push_back(a0); q_done.push_back(-1);
                end
                if (q_tag.size() > 0 && q_done[0] >= 0 && cyc > q_done[0] && $urandom_range(0, 2) != 0) begin
                    pop = 1'b1; pop_tag = q_tag[0];
                end else if ($urandom_range(0, 9) == 0) begin
                    pop = 1'b1; pop_tag = next_tag + 4'd8;        // a ROB entry that is not a memory op
                end
                if ($urandom_range(0, 199) == 0) flush = 1'b1;
                #1;
                // checks on this cycle's combinational outputs
                check("random: o_free is fewer than DEPTH in the queue", b(free),
                      b(q_tag.size() - (req.valid ? 1 : 0) < DEPTH));
                if (pop && q_tag.size() > 0 && pop_tag == q_tag[0] && !flush) begin
                    check("random: a retirement reads its own op's result", head_res.tval, exp_tval(q_tag[0], q_a[0]));
                    check("random: ... all of it", head_res.mem_addr, exp_maddr(q_tag[0], q_a[0]));
                    n_pops++;
                end
                @(posedge clk);
                // what that edge did, to the model
                if (flush) begin
                    q_tag.delete(); q_a.delete(); q_done.delete(); n_flush++;
                end else begin
                    if (eng_wb.valid) begin
                        for (int i = 0; i < q_tag.size(); i++)
                            if (q_tag[i] == eng_wb.tag && q_done[i] < 0) begin q_done[i] = cyc; break; end
                    end
                    if (pop && q_tag.size() > 0 && pop_tag == q_tag[0]) begin
                        void'(q_tag.pop_front()); void'(q_a.pop_front()); void'(q_done.pop_front());
                    end
                end
                #1;
            end
            idle(); pop = 1'b0; flush = 1'b0;
            $display("qv_lsq_tb: random: %0d retirements checked, %0d flushes, %0d ops taken by the engine",
                     n_pops, n_flush, seen_tags.size());
            check("random: retirements happened", b(n_pops > 500), 64'd1);
            check("random: flushes happened", b(n_flush > 5), 64'd1);
        end

        $display("");
        $display("qv_lsq_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsq_tb: FAILURES PRESENT");
        $finish;
    end

    // the engine sees the ops in dispatch order: every op it takes is the oldest dispatched one not yet taken
    // (checked against the queue's own record of what it pushed, tags in the order of the pushes)
    int pushed [$];
    always @(posedge clk) if (!rst) begin
        if (flush) pushed.delete();
        else begin
            if (req.valid) pushed.push_back(int'(req.tag));
            if (e_take) begin
                if (pushed.size() == 0) begin
                    fail_count++; $display("FAIL: the engine took an op nothing dispatched");
                end else begin
                    if (pushed[0] != int'(eng_req.tag)) begin
                        fail_count++; $display("FAIL: the engine took tag %0d, the oldest not taken is %0d", eng_req.tag, pushed[0]);
                    end
                    void'(pushed.pop_front());
                end
            end
        end
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
