// SPDX-License-Identifier: MIT

/*
 * qv_lsq_opw_tb -- design/pipe/qv_lsq.sv with waiting operands (OPW, O1c) against an exact golden model, one random run
 * per configuration (DEPTH, BYPASS_EN, LSU_BYPASS via -P).
 *
 * The bench dispatches memory ops whose two operands are ready, or wait for a producer: an outside one that delivers
 * once on the ALU/BRU, divider, FPU or commit bus (a late one on the commit bus only, after a writeback with a wrong
 * value on the ALU/BRU bus), or an older memory op in the queue, whose value is what the model engine writes back
 * when it completes it (a pointer chase). The engine takes one op when free, or in the cycle it completes the last
 * (the handoff), completes it 0 to 3 cycles later, and drops it on a flush; commit retires the oldest done op.
 *
 * Every cycle the model says whether the queue must offer an op to the engine and which: the oldest one not taken, once
 * both its operands exist (delivered in an earlier cycle, or on a same-cycle source now: the ALU/BRU and FPU buses with
 * BYPASS_EN, the engine's own writeback with LSU_BYPASS as well), never a younger one; with nothing queued, the op
 * being dispatched, only if its operands are ready. Its tag and operand values are checked, so an op taken out of
 * order or too early, a missed or wrong wakeup, a late operand woken by a unit, and a chase that loses a cycle (with
 * both knobs on, the next load must be offered in its producer's completion cycle) all fail.
 */
module qv_lsq_opw_tb #(
    parameter int DEPTH      = 4,
    parameter bit BYPASS_EN  = 1'b1,
    parameter bit LSU_BYPASS = 1'b1,
    parameter int CYCLES     = 30000,
    parameter int SEED       = 1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int TW   = QV_ROB_TAG_W;
    localparam int NTAG = 1 << TW;
    localparam int NOUT = 6;                 // outside producers at most

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic     flush = 1'b0;
    fu_req_t  req = '0;
    rs_opnd_t opa = '0, opb = '0;
    wb_t      wb = '0, wbd = '0, wbc = '0, eng_wb = '0;
    wb_fp_t   wbf = '0;
    logic     free, e_take = 1'b0, pop = 1'b0;
    logic [TW-1:0] pop_tag = '0;
    fu_req_t  eng_req;
    lsu_res_t head_res;
    /* verilator lint_off PINCONNECTEMPTY */
    qv_lsq #(.DEPTH(DEPTH), .OPW(1'b1), .BYPASS_EN(BYPASS_EN), .LSU_BYPASS(LSU_BYPASS)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free), .i_opa(opa), .i_opb(opb),
        .i_wb(wb), .i_wbd(wbd), .i_wbf(wbf), .i_wbc(wbc),
        .o_eng_req(eng_req), .i_eng_take(e_take), .i_eng_wb(eng_wb), .i_eng_res('0),
        .i_pop(pop), .i_pop_tag(pop_tag), .o_head_res(head_res),
        .o_early(), .o_match(),
        .o_xl_req(), .o_xl_va(), .o_xl_wr(), .o_eng_xl(), .o_eng_ppn()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- tags ----------------
    logic tag_used [0:NTAG-1];
    function automatic int nfree();
        int n; n = 0;
        for (int i = 0; i < NTAG; i++) if (!tag_used[i]) n++;
        return n;
    endfunction
    function automatic int alloc_tag();
        int k;
        k = $urandom % nfree();
        for (int i = 0; i < NTAG; i++)
            if (!tag_used[i]) begin
                if (k == 0) begin tag_used[i] = 1'b1; return i; end
                k--;
            end
        return -1;
    endfunction

    // ---------------- outside producers ----------------
    // bus 0 ALU/BRU, 2 divider, 3 FPU, 4 commit (a late one; its bus-0 writeback carries a wrong value)
    logic        o_live [0:NOUT-1];
    int          o_tag  [0:NOUT-1];
    logic [63:0] o_val  [0:NOUT-1];
    int          o_bus  [0:NOUT-1];
    int          o_w    [0:NOUT-1];          // the delivery cycle
    int          o_g    [0:NOUT-1];          // (late) the wrong-value writeback's cycle, or -1

    // nothing else is on bus bb in cycle c (a late producer's wrong-value writeback counts on bus 0)
    function automatic logic bus_free(input int bb, input int c);
        for (int u = 0; u < NOUT; u++)
            if (o_live[u] && ((o_bus[u] == bb && o_w[u] == c) || (bb == 0 && o_g[u] == c))) return 1'b0;
        return 1'b1;
    endfunction

    // ---------------- memory ops ----------------
    // every op dispatched and not retired, in order: q_* (index 0 the oldest). taken: the engine has it; done: completed
    localparam int NQ = DEPTH;
    int          nq;
    int          q_tag   [0:NQ-1];
    logic        q_taken [0:NQ-1];
    logic        q_done  [0:NQ-1];
    logic [63:0] q_res   [0:NQ-1];           // the value the engine writes back for it (a producer for younger ops)
    // its two operands: ready at dispatch (rdy), or the producer's tag; avail: the first cycle it may be used without a
    // same-cycle source (-1: not delivered yet), same: the bus it was delivered on, when; val: the value
    logic        q_rdy   [0:2*NQ-1];
    logic        q_late  [0:2*NQ-1];
    int          q_ptag  [0:2*NQ-1];
    int          q_avail [0:2*NQ-1];
    logic [63:0] q_val   [0:2*NQ-1];

    task automatic q_remove0();
        for (int j = 0; j < nq - 1; j++) begin
            q_tag[j] = q_tag[j+1]; q_taken[j] = q_taken[j+1]; q_done[j] = q_done[j+1]; q_res[j] = q_res[j+1];
            for (int k = 0; k < 2; k++) begin
                q_rdy[2*j+k] = q_rdy[2*(j+1)+k]; q_late[2*j+k] = q_late[2*(j+1)+k]; q_ptag[2*j+k] = q_ptag[2*(j+1)+k];
                q_avail[2*j+k] = q_avail[2*(j+1)+k]; q_val[2*j+k] = q_val[2*(j+1)+k];
            end
        end
        nq--;
    endtask

    // ---------------- the engine model ----------------
    logic        e_busy = 1'b0;
    int          e_left;                     // cycles to its completion
    int          e_idx;                      // its op: the first op taken and not done (always the oldest such)

    // ---------------- coverage ----------------
    int n_disp, n_take, n_pass, n_chase_same, n_late, n_hold, n_flush, n_capture;

    // the operand x (2*i + k) of op i is usable in cycle t, given this cycle's buses
    function automatic logic usable(input int x, input int t);
        if (q_rdy[x]) return 1'b1;
        if (q_avail[x] >= 0 && t >= q_avail[x]) return 1'b1;
        if (q_late[x] || !BYPASS_EN) return 1'b0;
        if (wb.valid && int'(wb.tag) == q_ptag[x]) return 1'b1;
        if (wbf.valid && int'(wbf.tag) == q_ptag[x]) return 1'b1;
        if (LSU_BYPASS && eng_wb.valid && int'(eng_wb.tag) == q_ptag[x]) return 1'b1;
        return 1'b0;
    endfunction
    function automatic logic [63:0] value_now(input int x);
        if (q_rdy[x] || q_avail[x] >= 0) return q_val[x];
        if (wb.valid && int'(wb.tag) == q_ptag[x]) return wb.value;
        if (wbf.valid && int'(wbf.tag) == q_ptag[x]) return wbf.value;
        return eng_wb.value;
    endfunction
    // this cycle's buses deliver to operand x (capture or wakeup), and with what
    function automatic logic delivers(input int x);
        if (q_rdy[x] || q_avail[x] >= 0) return 1'b0;
        if (wbc.valid && int'(wbc.tag) == q_ptag[x]) return 1'b1;
        if (q_late[x]) return 1'b0;
        return (wb.valid && int'(wb.tag) == q_ptag[x]) || (eng_wb.valid && int'(eng_wb.tag) == q_ptag[x])
               || (wbd.valid && int'(wbd.tag) == q_ptag[x]) || (wbf.valid && int'(wbf.tag) == q_ptag[x]);
    endfunction
    function automatic logic [63:0] delivered(input int x);
        if (wbc.valid && int'(wbc.tag) == q_ptag[x])       return wbc.value;
        if (wb.valid && int'(wb.tag) == q_ptag[x])         return wb.value;
        if (eng_wb.valid && int'(eng_wb.tag) == q_ptag[x]) return eng_wb.value;
        if (wbd.valid && int'(wbd.tag) == q_ptag[x])       return wbd.value;
        return wbf.value;
    endfunction

    int  t, first, seed_v;
    logic offer, e_done_now;
    logic [63:0] ea, eb;

    initial begin
        seed_v = SEED;
        void'($urandom(seed_v));
        for (int i = 0; i < NTAG; i++) tag_used[i] = 1'b0;
        for (int i = 0; i < NOUT; i++) o_live[i] = 1'b0;
        nq = 0;
        n_disp = 0; n_take = 0; n_pass = 0; n_chase_same = 0; n_late = 0; n_hold = 0; n_flush = 0; n_capture = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (t = 0; t < CYCLES; t++) begin
            // ---- this cycle's buses: outside producers, the engine's completion ----
            flush = ($urandom % 500) == 0;
            wb = '0; wbd = '0; wbf = '0; wbc = '0; eng_wb = '0;
            for (int s = 0; s < NOUT; s++) if (o_live[s]) begin
                if (o_g[s] == t) begin wb.valid = 1'b1; wb.tag = TW'(o_tag[s]); wb.value = ~o_val[s]; end
                if (o_w[s] == t)
                    case (o_bus[s])
                        0: begin wb.valid = 1'b1;  wb.tag = TW'(o_tag[s]);  wb.value = o_val[s];  end
                        2: begin wbd.valid = 1'b1; wbd.tag = TW'(o_tag[s]); wbd.value = o_val[s]; end
                        3: begin wbf.valid = 1'b1; wbf.tag = TW'(o_tag[s]); wbf.value = o_val[s]; end
                        default: begin wbc.valid = 1'b1; wbc.tag = TW'(o_tag[s]); wbc.value = o_val[s]; end
                    endcase
            end
            e_done_now = e_busy && e_left == 0 && !flush;
            if (e_done_now) begin
                eng_wb.valid = 1'b1; eng_wb.tag = TW'(q_tag[e_idx]); eng_wb.value = q_res[e_idx];
            end

            // ---- a dispatch: operands ready, or waiting for an outside producer or an older op ----
            req = '0; opa = '0; opb = '0;
            if (!flush && free && nq < NQ && ($urandom % 100) < 60 && nfree() > NOUT + 1) begin
                int tg;
                tg = alloc_tag();
                req.valid = 1'b1; req.tag = TW'(tg); req.op = 5'b00011;
                req.imm = {$urandom, $urandom}; req.pc = {$urandom, $urandom};
                q_tag[nq] = tg; q_taken[nq] = 1'b0; q_done[nq] = 1'b0; q_res[nq] = {$urandom, $urandom};
                for (int k = 0; k < 2; k++) begin
                    rs_opnd_t o;
                    int x, r, s;
                    x = 2 * nq + k;
                    o = '0;
                    r = $urandom % 100;
                    s = -1;
                    q_rdy[x] = 1'b0; q_late[x] = 1'b0; q_avail[x] = -1; q_ptag[x] = 0; q_val[x] = '0;
                    if (r < 35 && nq > 0) begin                       // an older op not yet completed (a chase)
                        int m, c;
                        m = 0;
                        for (int j = 0; j < nq; j++) if (!q_done[j]) m++;
                        if (m > 0) begin
                            c = $urandom % m;
                            for (int j = 0; j < nq; j++) if (!q_done[j]) begin
                                if (c == 0) s = j;
                                c--;
                            end
                        end
                        if (s >= 0) begin
                            q_ptag[x] = q_tag[s]; q_val[x] = q_res[s];
                        end
                    end else if (r < 70) begin                        // an outside producer delivering from t on
                        for (int u = 0; u < NOUT && s < 0; u++) if (!o_live[u]) s = u;
                        if (s >= 0) begin
                            int bb, w, g;
                            bb = $urandom % 5;
                            if (bb == 1) bb = 0;                          // (bus 1 is the engine's own)
                            w = t + 1 + int'($urandom % 12);
                            while (!bus_free(bb, w)) w++;
                            g = -1;
                            if (bb == 4 && w > t + 1) begin
                                g = t + 1 + int'($urandom % (w - t - 1));
                                if (!bus_free(0, g)) g = -1;
                            end
                            o_live[s] = 1'b1; o_tag[s] = alloc_tag(); o_val[s] = {$urandom, $urandom};
                            o_bus[s] = bb; o_w[s] = w; o_g[s] = g;
                            q_ptag[x] = o_tag[s]; q_val[x] = o_val[s]; q_late[x] = (bb == 4);
                            s = 100 + s;                                  // (mark: outside)
                        end
                    end else if (r < 80) begin                        // an outside producer delivering in this very cycle
                        for (int u = 0; u < NOUT && s < 0; u++)
                            if (o_live[u] && o_w[u] == t) s = u;
                        if (s >= 0) begin
                            q_ptag[x] = o_tag[s]; q_val[x] = o_val[s]; q_late[x] = (o_bus[s] == 4);
                            n_capture++;
                            s = 100 + s;
                        end
                    end
                    if (s < 0) begin                                  // ready
                        q_rdy[x] = 1'b1; q_val[x] = {$urandom, $urandom};
                        o.rdy = 1'b1; o.value = q_val[x];
                    end else begin
                        o.rdy = 1'b0; o.late = q_late[x]; o.tag = TW'(q_ptag[x]); o.value = ~q_val[x];
                        if (q_late[x]) n_late++;
                    end
                    if (k == 0) begin opa = o; req.a = o.value; end else begin opb = o; req.b = o.value; end
                end
                nq++;
                n_disp++;
            end

            // ---- what the queue must offer now ----
            first = -1;
            for (int j = 0; j < nq && first < 0; j++) if (!q_taken[j]) first = j;
            offer = 1'b0;
            if (first >= 0 && !flush) begin
                if (req.valid && first == nq - 1)                     // nothing queued: the dispatch, if ready
                    offer = q_rdy[2*first] && q_rdy[2*first+1];
                else
                    offer = usable(2*first, t) && usable(2*first+1, t);
            end
            #1;
            if (!flush) begin
                check($sformatf("t=%0d offer", t), b(eng_req.valid), b(offer));
                if (offer) begin
                    ea = (req.valid && first == nq - 1) ? q_val[2*first] : value_now(2*first);
                    eb = (req.valid && first == nq - 1) ? q_val[2*first+1] : value_now(2*first+1);
                    check($sformatf("t=%0d offered tag", t), 64'(eng_req.tag), 64'(q_tag[first]));
                    check($sformatf("t=%0d offered a", t), eng_req.a, ea);
                    check($sformatf("t=%0d offered b", t), eng_req.b, eb);
                end
                if (first >= 0 && !offer && first + 1 < nq) n_hold++;
            end
            if (fail_count > 20) begin
                $display("qv_lsq_opw_tb: stopping at t=%0d", t);
                break;
            end

            // ---- the engine takes it (when free, or in its completion cycle: the handoff) ----
            e_take = offer && !flush && (!e_busy || e_done_now) && ($urandom % 100) < 85;
            if (e_take && e_done_now && first >= 0) begin
                for (int k = 0; k < 2; k++)
                    if (!q_rdy[2*first+k] && q_avail[2*first+k] < 0 && eng_wb.valid
                        && int'(eng_wb.tag) == q_ptag[2*first+k]) n_chase_same++;
            end
            if (e_take && req.valid && first == nq - 1) n_pass++;
            // commit: the oldest done op, now and then
            pop = !flush && nq > 0 && q_done[0] && ($urandom % 100) < 50;
            pop_tag = pop ? TW'(q_tag[0]) : '0;

            // ---- the edge ----
            @(posedge clk);
            #1;
            if (flush) begin
                n_flush++;
                for (int j = 0; j < nq; j++) tag_used[q_tag[j]] = 1'b0;
                nq = 0;
                for (int u = 0; u < NOUT; u++) if (o_live[u]) begin o_live[u] = 1'b0; tag_used[o_tag[u]] = 1'b0; end
                e_busy = 1'b0;
            end else begin
                // operands delivered this cycle (by the buses as they were: the edge has not changed them)
                for (int j = 0; j < nq; j++)
                    for (int k = 0; k < 2; k++)
                        if (delivers(2*j+k)) begin q_avail[2*j+k] = t + 1; q_val[2*j+k] = delivered(2*j+k); end
                if (e_done_now) begin q_done[e_idx] = 1'b1; e_busy = 1'b0; end
                if (e_take) begin
                    q_taken[first] = 1'b1; e_busy = 1'b1; e_idx = first; e_left = $urandom % 4;
                    n_take++;
                end else if (e_busy) e_left--;
                for (int u = 0; u < NOUT; u++)
                    if (o_live[u] && o_w[u] <= t) begin o_live[u] = 1'b0; tag_used[o_tag[u]] = 1'b0; end
                if (pop) begin
                    tag_used[q_tag[0]] = 1'b0;
                    q_remove0();
                    if (e_busy) e_idx--;
                end
            end
            e_take = 1'b0; pop = 1'b0; req = '0;
            @(negedge clk);
        end

        $display("qv_lsq_opw_tb (DEPTH %0d, BYPASS_EN %0d, LSU_BYPASS %0d): %0d dispatches, %0d taken (%0d passed straight through), %0d chases taken in the producer's completion cycle, %0d late operands, %0d dispatch-cycle captures, %0d cycles an older op held younger ones, %0d flushes",
                 DEPTH, BYPASS_EN, LSU_BYPASS, n_disp, n_take, n_pass, n_chase_same, n_late, n_capture, n_hold, n_flush);
        check("coverage: ops taken", b(n_take > 1000), 1);
        check("coverage: passed straight through", b(n_pass > 0), 1);       // (a deep queue is seldom empty)
        check("coverage: late operands", b(n_late > 50), 1);
        check("coverage: dispatch-cycle captures", b(n_capture > 20), 1);
        check("coverage: an older op held younger ones", b(n_hold > 100), 1);
        check("coverage: flushes", b(n_flush > 20), 1);
        if (BYPASS_EN && LSU_BYPASS) check("coverage: chases with no lost cycle", b(n_chase_same > 50), 1);
        else check("coverage: no chase in the producer's completion cycle", b(n_chase_same == 0), 1);
        $display("");
        $display("qv_lsq_opw_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsq_opw_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
