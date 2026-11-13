// SPDX-License-Identifier: MIT

/*
 * rs_props -- SymbiYosys properties for design/pipe/qv_rs.sv, the reservation station (DEPTH 2 here, the formal
 * small configuration; BYPASS_EN and LSU_BYPASS on, so every bus is a same-cycle source but the divider's and the
 * commit bus). Pushes, the five buses, the units' free signals and flush are free, under the core's contract: a
 * push only with room and never in a flush cycle, the pushed tag held by no entry (ROB tags of uops in flight are
 * unique), and no two buses with the same tag in one cycle (one producer per tag).
 *
 * The spec is a ghost written per tag, not per slot: the set of tags in the station, the kind each was pushed with,
 * and, for one symbolic tag T (any constant), the entry pushed with it, the tags older than it, and each of its
 * operands' value as its producer first delivers it (from the cycle it is pushed on; a late operand only off the
 * commit bus). An operand is available now if it was ready when pushed or delivered in an earlier cycle, or if a
 * same-cycle source (ALU/BRU, FPU, LSU writeback) carries it now. Then:
 *   - exactly once: every request's tag is in the station, the ports never send one tag twice in a cycle, and a
 *     request leaves the set, so a tag is sent once per push; nothing at all is sent in a flush cycle, and a flush
 *     empties the station;
 *   - the entry with tag T goes to its kind's port, with its own fields and, for every operand, the value its
 *     producer delivered (so never before it exists: no early issue, no value off the wrong bus or a late operand's
 *     unit writeback);
 *   - no lost wakeup, oldest first: once T can go (its operands available, and for a divide or a divide/square root
 *     no older one of its kind, the unit free, and no flush), its port is taken, by T or by an entry older than T;
 *     a divide or a divide/square root never goes while an older one of its kind waits;
 *   - ALU and BRU are never sent together; o_room, o_has_div and o_has_fds follow the set.
 * (O3) A kill (a recovery at execute) drops the tags of i_kill_vec, under the core's contract: nothing is pushed in a
 * kill cycle, a flush never comes with one, and the killed tags are the youngest (one older than T killed means T is
 * too). Nothing killed is sent in the kill cycle, the set loses the killed tags, and T's obligations end if it is
 * killed.
 */
module rs_props (
    input logic                             clk,
    input logic                             rst,
    input logic                             flush,
    input logic                             push,
    input qv_pkg::rs_entry_t                push_e,
    input qv_pkg::wb_t                      wb,
    input qv_pkg::wb_t                      wbl,
    input qv_pkg::wb_t                      wbd,
    input qv_pkg::wb_fp_t                   wbf,
    input qv_pkg::wb_t                      wbc,
    input logic                             div_free,
    input logic                             ds_free,
    input logic [qv_pkg::QV_ROB_TAG_W-1:0]  T,
    input logic [(1<<qv_pkg::QV_ROB_TAG_W)-1:0] kv
);
    import qv_pkg::*;
    localparam int DEPTH = 2;
    localparam int TW    = QV_ROB_TAG_W;
    localparam int NT    = 1 << TW;

    logic     room, has_div, has_fds, sel_ab, sel_div, sel_fpu;
    fu_req_t  alu_req, bru_req, div_req;
    fpu_req_t fpu_req;

    qv_rs #(.DEPTH(DEPTH), .BYPASS_EN(1'b1), .LSU_BYPASS(1'b1)) dut (
        .clk(clk), .rst(rst), .i_flush(flush), .i_kill_vec(kv),
        .i_push(push), .i_push_e(push_e), .o_room(room), .o_has_div(has_div), .o_has_fds(has_fds),
        .i_wb(wb), .i_wbl(wbl), .i_wbd(wbd), .i_wbf(wbf), .i_wbc(wbc),
        .i_div_free(div_free), .i_fpu_ds_free(ds_free),
        .o_sel_ab(sel_ab), .o_sel_div(sel_div), .o_sel_fpu(sel_fpu),
        .o_alu_req(alu_req), .o_bru_req(bru_req), .o_div_req(div_req), .o_fpu_req(fpu_req)
    );

    // ---- the ghost ----
    reg            init = 1'b1;
    reg  [NT-1:0]  inset = '0;                   // tags held by the station
    reg  [2:0]     kind_of [0:NT-1];             // ... and the kind each was pushed with
    reg  [NT-1:0]  older = '0;                   // the tags older than T (while T is held)
    reg            tr_v = 1'b0;                  // T is held
    rs_entry_t     tr_e;                         // ... as pushed
    reg  [2:0]     dl = '0;                      // operand a/b/c of T: delivered in an earlier cycle
    reg  [63:0]    dv [0:2];                     // ... with this value

    wire issue_ab  = alu_req.valid || bru_req.valid;
    wire [TW-1:0] ab_tag = alu_req.valid ? alu_req.tag : bru_req.tag;
    wire [NT-1:0] gone = (issue_ab ? (NT'(1) << ab_tag) : '0) | (div_req.valid ? (NT'(1) << div_req.tag) : '0)
                       | (fpu_req.valid ? (NT'(1) << fpu_req.tag) : '0);

    // the operand's producer delivers now on a bus the station must take (late: only the commit bus)
    function automatic logic deliv(input rs_opnd_t o, input wb_t a, input wb_t l, input wb_t d, input wb_fp_t f,
                                   input wb_t c);
        if (c.valid && c.tag == o.tag) return 1'b1;
        if (o.late) return 1'b0;
        return (a.valid && a.tag == o.tag) || (l.valid && l.tag == o.tag) || (d.valid && d.tag == o.tag)
               || (f.valid && f.tag == o.tag);
    endfunction
    function automatic logic [63:0] deliv_v(input rs_opnd_t o, input wb_t a, input wb_t l, input wb_t d,
                                            input wb_fp_t f, input wb_t c);
        if (c.valid && c.tag == o.tag) return c.value;
        if (a.valid && a.tag == o.tag) return a.value;
        if (l.valid && l.tag == o.tag) return l.value;
        if (d.valid && d.tag == o.tag) return d.value;
        return f.value;
    endfunction
    // ... on a same-cycle source the station may take it from in this very cycle
    function automatic logic same(input rs_opnd_t o, input wb_t a, input wb_t l, input wb_fp_t f);
        return !o.late && ((a.valid && a.tag == o.tag) || (f.valid && f.tag == o.tag) || (l.valid && l.tag == o.tag));
    endfunction
    function automatic logic [63:0] same_v(input rs_opnd_t o, input wb_t a, input wb_t l, input wb_fp_t f);
        if (a.valid && a.tag == o.tag) return a.value;
        if (f.valid && f.tag == o.tag) return f.value;
        return l.value;
    endfunction

    // T's operands now
    rs_opnd_t op [0:2];
    logic     av [0:2];
    logic [63:0] vn [0:2];
    always_comb begin
        op[0] = tr_e.a; op[1] = tr_e.b; op[2] = tr_e.c;
        for (int k = 0; k < 3; k++) begin
            av[k] = op[k].rdy || dl[k] || same(op[k], wb, wbl, wbf);
            vn[k] = op[k].rdy ? op[k].value : dl[k] ? dv[k] : same_v(op[k], wb, wbl, wbf);
        end
    end
    wire tr_ready = tr_v && av[0] && av[1] && av[2];

    logic older_div, older_fds;
    int   n_in;
    always_comb begin
        older_div = 1'b0; older_fds = 1'b0; n_in = 0;
        for (int t = 0; t < NT; t++) begin
            if (older[t] && kind_of[t] == 3'(QV_RS_DIV)) older_div = 1'b1;
            if (older[t] && kind_of[t] == 3'(QV_RS_FDS)) older_fds = 1'b1;
            if (inset[t]) n_in++;
        end
    end
    logic any_div, any_fds;
    always_comb begin
        any_div = 1'b0; any_fds = 1'b0;
        for (int t = 0; t < NT; t++) begin
            if (inset[t] && kind_of[t] == 3'(QV_RS_DIV)) any_div = 1'b1;
            if (inset[t] && kind_of[t] == 3'(QV_RS_FDS)) any_fds = 1'b1;
        end
    end

    rs_opnd_t pa, pb, pc;
    assign pa = push_e.a;
    assign pb = push_e.b;
    assign pc = push_e.c;

    always @(posedge clk) begin
        init <= 1'b0;
        if (rst || flush) begin
            inset <= '0; older <= '0; tr_v <= 1'b0;
        end else begin
            inset <= (inset & ~gone & ~kv) | (push ? (NT'(1) << push_e.tag) : '0);
            older <= older & ~gone & ~kv;
            if (tr_v && (gone[T] || kv[T])) tr_v <= 1'b0;
            if (push) kind_of[push_e.tag] <= 3'(push_e.kind);
            // T's operands take their first delivery
            if (tr_v) begin
                for (int k = 0; k < 3; k++)
                    if (!op[k].rdy && !dl[k] && deliv(op[k], wb, wbl, wbd, wbf, wbc)) begin
                        dl[k] <= 1'b1; dv[k] <= deliv_v(op[k], wb, wbl, wbd, wbf, wbc);
                    end
            end
            if (push && push_e.tag == T) begin
                tr_v  <= 1'b1;
                tr_e  <= push_e;
                older <= inset & ~gone;
                dl[0] <= !pa.rdy && deliv(pa, wb, wbl, wbd, wbf, wbc); dv[0] <= deliv_v(pa, wb, wbl, wbd, wbf, wbc);
                dl[1] <= !pb.rdy && deliv(pb, wb, wbl, wbd, wbf, wbc); dv[1] <= deliv_v(pb, wb, wbl, wbd, wbf, wbc);
                dl[2] <= !pc.rdy && deliv(pc, wb, wbl, wbd, wbf, wbc); dv[2] <= deliv_v(pc, wb, wbl, wbd, wbf, wbc);
            end
        end
    end

    // ---- assumptions: the core's contract ----
    reg [TW-1:0] T_prev;
    always @(posedge clk) begin
        T_prev <= T;
        if (init) assume (rst);
        else assume (T == T_prev);                                   // T is a constant
        if (push) begin
            assume (room);
            assume (!flush);
            assume (!inset[push_e.tag]);                             // ROB tags in flight are unique
            assume (push_e.kind <= QV_RS_FDS);
        end
        // one producer per tag: no two buses carry one tag in a cycle
        if (wb.valid && wbl.valid)  assume (wb.tag != wbl.tag);
        if (wb.valid && wbd.valid)  assume (wb.tag != wbd.tag);
        if (wb.valid && wbf.valid)  assume (wb.tag != wbf.tag);
        if (wb.valid && wbc.valid)  assume (wb.tag != wbc.tag);
        if (wbl.valid && wbd.valid) assume (wbl.tag != wbd.tag);
        if (wbl.valid && wbf.valid) assume (wbl.tag != wbf.tag);
        if (wbl.valid && wbc.valid) assume (wbl.tag != wbc.tag);
        if (wbd.valid && wbf.valid) assume (wbd.tag != wbf.tag);
        if (wbd.valid && wbc.valid) assume (wbd.tag != wbc.tag);
        if (wbf.valid && wbc.valid) assume (wbf.tag != wbc.tag);
        // (O3) a kill: no push and no flush in its cycle, and the killed are the youngest
        if (kv != '0) assume (!push && !flush);
        if (tr_v && (kv & older) != '0) assume (kv[T]);
    end

    // ---- properties ----
    always @(posedge clk) begin
        if (!rst && !init) begin
            // the ports
            assert (!(alu_req.valid && bru_req.valid));
            assert (sel_ab == issue_ab);
            assert (sel_div == div_req.valid);
            assert (sel_fpu == fpu_req.valid);
            if (flush) assert (!sel_ab && !sel_div && !sel_fpu);
            // (O3) nothing killed is sent
            assert (!(issue_ab && kv[ab_tag]) && !(div_req.valid && kv[div_req.tag]) && !(fpu_req.valid && kv[fpu_req.tag]));
            // exactly once: a request is an entry the station holds, and one tag goes to one port
            if (issue_ab)      assert (inset[ab_tag]);
            if (div_req.valid) assert (inset[div_req.tag]);
            if (fpu_req.valid) assert (inset[fpu_req.tag]);
            if (issue_ab && div_req.valid)      assert (ab_tag != div_req.tag);
            if (issue_ab && fpu_req.valid)      assert (ab_tag != fpu_req.tag);
            if (div_req.valid && fpu_req.valid) assert (div_req.tag != fpu_req.tag);
            // the set: room and the kinds held
            assert (room == (n_in < DEPTH));
            assert (has_div == any_div);
            assert (has_fds == any_fds);
            // T goes to its own port with its own fields and its operands' delivered values
            if (issue_ab && ab_tag == T) begin
                assert (tr_v);
                assert (alu_req.valid ? tr_e.kind == QV_RS_ALU : tr_e.kind == QV_RS_BRU);
                assert (av[0] && av[1] && av[2]);
                if (alu_req.valid) begin
                    assert (alu_req.op == tr_e.op && alu_req.is_word == tr_e.is_word);
                    assert (alu_req.a == vn[0] && alu_req.b == vn[1]);
                end else begin
                    assert (bru_req.op == tr_e.op && bru_req.pc == tr_e.pc && bru_req.imm == tr_e.imm);
                    assert (bru_req.rvc == tr_e.rvc && bru_req.pred_next == tr_e.pred_next);
                    assert (bru_req.a == vn[0] && bru_req.b == vn[1]);
                end
            end
            if (div_req.valid && div_req.tag == T) begin
                assert (tr_v && tr_e.kind == QV_RS_DIV);
                assert (av[0] && av[1] && av[2]);
                assert (div_free && !older_div);
                assert (div_req.op == tr_e.op && div_req.is_word == tr_e.is_word);
                assert (div_req.a == vn[0] && div_req.b == vn[1]);
            end
            if (fpu_req.valid && fpu_req.tag == T) begin
                assert (tr_v && (tr_e.kind == QV_RS_FPU || tr_e.kind == QV_RS_FDS));
                assert (av[0] && av[1] && av[2]);
                if (tr_e.kind == QV_RS_FDS) assert (ds_free && !older_fds);
                assert (5'(fpu_req.op) == tr_e.op && fpu_req.fmt == tr_e.fmt && fpu_req.ityp == tr_e.ityp);
                assert (fpu_req.rm == tr_e.rm);
                assert (fpu_req.a == vn[0] && fpu_req.b == vn[1] && fpu_req.c == vn[2]);
            end
            // no lost wakeup, oldest first: once T can go, its port is taken by T or by an older entry
            if (tr_ready && !flush && !kv[T]) begin
                if (tr_e.kind == QV_RS_ALU || tr_e.kind == QV_RS_BRU)
                    assert (issue_ab && (ab_tag == T || older[ab_tag]));
                if (tr_e.kind == QV_RS_DIV && !older_div && div_free)
                    assert (div_req.valid && div_req.tag == T);
                if (tr_e.kind == QV_RS_FPU)
                    assert (fpu_req.valid && (fpu_req.tag == T || older[fpu_req.tag]));
                if (tr_e.kind == QV_RS_FDS && !older_fds && ds_free)
                    assert (fpu_req.valid && (fpu_req.tag == T || older[fpu_req.tag]));
            end
        end
    end

    // ---- lemmas for the induction: the ghost and the station's slots agree ----
    rs_entry_t se [0:DEPTH-1];
    logic      sv [0:DEPTH-1];
    always_comb
        for (int i = 0; i < DEPTH; i++) begin se[i] = dut.e_q[i]; sv[i] = dut.v_q[i]; end
    rs_opnd_t so;
    rs_opnd_t to;
    always @(posedge clk) begin
        if (!rst && !init) begin
            for (int i = 0; i < DEPTH; i++) begin
                if (i > 0 && sv[i]) assert (sv[i-1]);                           // the valid slots are 0 .. n-1
                if (sv[i]) begin
                    assert (inset[se[i].tag]);
                    assert (kind_of[se[i].tag] == 3'(se[i].kind));
                    assert (se[i].kind <= QV_RS_FDS);
                    for (int j = i + 1; j < DEPTH; j++) if (sv[j]) assert (se[i].tag != se[j].tag);
                end
            end
            begin : cnt
                int n;
                n = 0;
                for (int i = 0; i < DEPTH; i++) if (sv[i]) n++;
                assert (n == n_in);
            end
            assert ((older & ~inset) == '0);
            assert (!older[T] || !tr_v);
            begin : tr
                logic hit;
                int   it;
                hit = 1'b0; it = 0;
                for (int i = 0; i < DEPTH; i++) if (sv[i] && se[i].tag == T) begin hit = 1'b1; it = i; end
                assert (hit == tr_v);
                if (tr_v) begin
                    assert (se[it].kind == tr_e.kind && se[it].op == tr_e.op && se[it].is_word == tr_e.is_word);
                    assert (se[it].pc == tr_e.pc && se[it].imm == tr_e.imm && se[it].rvc == tr_e.rvc);
                    assert (se[it].pred_next == tr_e.pred_next && se[it].fmt == tr_e.fmt);
                    assert (se[it].ityp == tr_e.ityp && se[it].rm == tr_e.rm);
                    for (int k = 0; k < 3; k++) begin
                        so = (k == 0) ? se[it].a : (k == 1) ? se[it].b : se[it].c;
                        to = op[k];
                        assert (so.tag == to.tag && so.late == to.late);
                        assert (so.rdy == (to.rdy || dl[k]));
                        if (so.rdy) assert (so.value == (to.rdy ? to.value : dv[k]));
                    end
                    // older: exactly the slots before T's
                    for (int j = 0; j < DEPTH; j++)
                        if (sv[j] && j != it) assert (older[se[j].tag] == (j < it));
                end
            end
        end
    end

    // non-vacuity
    always @(posedge clk) begin
        if (!rst && !init) begin
            cover (issue_ab && ab_tag == T && older != '0);                       // T goes with an older one waiting
            cover (tr_v && !op[0].rdy && op[0].late && dl[0]);                    // a late operand woken
            cover (issue_ab && ab_tag == T && !op[0].rdy && !dl[0]);              // taken off a same-cycle bypass
            cover (div_req.valid && div_req.tag == T && !op[1].rdy);              // a divide woken (div_wb or the commit bus)
            cover (fpu_req.valid && fpu_req.tag == T && tr_e.kind == QV_RS_FDS && older != '0);
            cover (sel_ab && sel_fpu);                                            // two ports in one cycle (of two entries)
            cover (sel_div && sel_fpu);
            cover (!room && push == 1'b0 && sel_ab);
            cover (kv != '0 && tr_v && !kv[T] && older != '0);                   // a kill that T survives
            cover (tr_v && kv[T] && older != '0);                                 // T killed, an older one kept
        end
    end
endmodule
