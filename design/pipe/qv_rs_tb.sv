// SPDX-License-Identifier: MIT

/*
 * qv_rs_tb -- the reservation station (qv_rs) against an exact golden model, one random run per configuration
 * (DEPTH, BYPASS_EN, LSU_BYPASS via -P).
 *
 * The bench plays the rest of the core. Each cycle it may push an entry of a random kind (ALU, BRU, DIV, FPU, FDS),
 * each operand either ready with its value or waiting for a producer; producers deliver their value once, on a
 * random bus (ALU/BRU, LSU, divider, FPU) at a random later cycle, possibly the very cycle the dependent is pushed (the
 * dispatch-cycle capture). A late producer (a CSR op) delivers on the commit bus only, after a writeback on the
 * ALU/BRU bus that carries a wrong value, which a late operand must ignore. Flushes come at random.
 *
 * The model knows, for every entry and cycle, whether each operand exists (delivered in an earlier cycle, or on a
 * bus the station may take in the same cycle under the knobs), so it predicts every port exactly: the ALU/BRU port
 * takes the oldest ready ALU or BRU entry; the divider the oldest divide, once ready and the divider is free; the
 * FPU the oldest of the ready pipelined ops and the oldest divide/square root (if ready and its unit is free);
 * nothing in a flush cycle. Each selected request is checked field by field, operand values included, so a lost or
 * wrong wakeup, an operand taken from the wrong bus or too early, an entry issued twice or skipped, an age mistake, a
 * divide passing an older one or a select in a flush cycle all fail. Tags are reused as in the ROB: a producer's tag
 * is free again once it has delivered, so a missed wakeup would be woken later by another producer's value.
 */
module qv_rs_tb #(
    parameter int DEPTH      = 4,
    parameter bit BYPASS_EN  = 1'b1,
    parameter bit LSU_BYPASS = 1'b1,
    parameter int CYCLES     = 40000,
    parameter int SEED       = 1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int TW   = QV_ROB_TAG_W;
    localparam int NTAG = 1 << TW;
    localparam int NP   = 32;               // producer slots
    localparam int RING = 256;              // schedule ring (events are at most 64 cycles ahead)

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic      flush = 1'b0, push = 1'b0;
    rs_entry_t push_e = '0;
    logic      room, has_div, has_fds;
    wb_t       wb = '0, wbl = '0, wbd = '0, wbc = '0;
    wb_fp_t    wbf = '0;
    logic      div_free = 1'b1, ds_free = 1'b1;
    logic      sel_ab, sel_div, sel_fpu;
    fu_req_t   alu_req, bru_req, div_req;
    fpu_req_t  fpu_req;

    qv_rs #(.DEPTH(DEPTH), .BYPASS_EN(BYPASS_EN), .LSU_BYPASS(LSU_BYPASS)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push(push), .i_push_e(push_e), .o_room(room), .o_has_div(has_div), .o_has_fds(has_fds),
        .i_wb(wb), .i_wbl(wbl), .i_wbd(wbd), .i_wbf(wbf), .i_wbc(wbc),
        .i_div_free(div_free), .i_fpu_ds_free(ds_free),
        .o_sel_ab(sel_ab), .o_sel_div(sel_div), .o_sel_fpu(sel_fpu),
        .o_alu_req(alu_req), .o_bru_req(bru_req), .o_div_req(div_req), .o_fpu_req(fpu_req)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- tags ----------------
    logic tag_used [0:NTAG-1];
    function automatic int free_tags();
        int n;
        n = 0;
        for (int i = 0; i < NTAG; i++) if (!tag_used[i]) n++;
        return n;
    endfunction
    function automatic int alloc_tag();
        int k, n;
        n = free_tags();
        k = $urandom % n;
        for (int i = 0; i < NTAG; i++)
            if (!tag_used[i]) begin
                if (k == 0) begin tag_used[i] = 1'b1; return i; end
                k--;
            end
        return -1;
    endfunction

    // ---------------- producers and the bus schedule ----------------
    // bus 0 ALU/BRU, 1 LSU, 2 divider, 3 FPU, 4 commit
    logic        p_live [0:NP-1];
    int          p_tag  [0:NP-1];
    logic [63:0] p_val  [0:NP-1];
    logic        p_late [0:NP-1];
    int          p_bus  [0:NP-1];
    int          p_w    [0:NP-1];           // the cycle the value is delivered (a late one: its commit)
    int          s_p    [0:4][0:RING-1];    // the producer whose event is on that bus in that cycle, or -1
    logic        s_garb [0:4][0:RING-1];    // ... and the event is a late producer's wrong-value writeback

    function automatic int n_live();
        int n;
        n = 0;
        for (int i = 0; i < NP; i++) if (p_live[i]) n++;
        return n;
    endfunction

    // the first cycle >= c with no event on bus bb, within 48 cycles (-1: none)
    function automatic int free_slot(input int bb, input int c);
        for (int k = c; k < c + 48; k++) if (s_p[bb][k % RING] < 0) return k;
        return -1;
    endfunction

    function automatic logic same_ok(input int bus, input logic late);   // the station may use it in its cycle
        return !late && BYPASS_EN && (bus == 0 || bus == 3 || (bus == 1 && LSU_BYPASS));
    endfunction

    // A new producer, made after cycle t's buses are driven, so delivering from cycle t + 1 on: its index, or -1 (no tag or
    // slot left). (A dependent pushed in the cycle an older producer delivers is the dispatch-cycle capture.)
    function automatic int new_prod(input int t);
        int s, w, g, bus;
        logic late;
        if (free_tags() <= DEPTH + 1) return -1;          // keep tags for the entries
        s = -1;
        for (int i = 0; i < NP; i++) if (!p_live[i] && s < 0) s = i;
        if (s < 0) return -1;
        late = ($urandom % 5) == 0;
        bus  = late ? 4 : int'($urandom % 4);
        w    = free_slot(bus, t + 1 + int'($urandom % 16));
        if (w < 0) return -1;
        p_live[s] = 1'b1;
        p_tag[s]  = alloc_tag();
        p_val[s]  = {$urandom, $urandom};
        p_late[s] = late;
        p_bus[s]  = bus;
        p_w[s]    = w;
        s_p[bus][w % RING]    = s;
        s_garb[bus][w % RING] = 1'b0;
        if (late && w > t + 1) begin                        // its unit's writeback, earlier, with a wrong value
            g = free_slot(0, t + 1 + int'($urandom % (w - t - 1)));
            if (g >= 0 && g < w) begin
                s_p[0][g % RING]    = s;
                s_garb[0][g % RING] = 1'b1;
            end
        end
        return s;
    endfunction

    // ---------------- golden station ----------------
    int          gn;                                    // entries, oldest first
    int          g_kind [0:DEPTH-1];
    int          g_tag  [0:DEPTH-1];
    rs_entry_t   g_e    [0:DEPTH-1];                    // the pushed entry (fields; operand values as expected)
    logic        g_hasp [0:3*DEPTH-1];                  // operand k of entry i at [3*i + k]
    int          g_w    [0:3*DEPTH-1];
    int          g_bus  [0:3*DEPTH-1];
    logic        g_late [0:3*DEPTH-1];
    logic [63:0] g_val  [0:3*DEPTH-1];

    function automatic logic avail(input int i, input int k, input int t);
        int x;
        x = 3 * i + k;
        if (!g_hasp[x]) return 1'b1;
        if (t >= g_w[x] + 1) return 1'b1;
        return t == g_w[x] && same_ok(g_bus[x], g_late[x]);
    endfunction

    function automatic logic g_ready(input int i, input int t);
        return avail(i, 0, t) && avail(i, 1, t) && avail(i, 2, t);
    endfunction

    task automatic g_remove(input int i);
        for (int j = i; j < gn - 1; j++) begin
            g_kind[j] = g_kind[j + 1]; g_tag[j] = g_tag[j + 1]; g_e[j] = g_e[j + 1];
            for (int k = 0; k < 3; k++) begin
                g_hasp[3*j + k] = g_hasp[3*(j+1) + k]; g_w[3*j + k] = g_w[3*(j+1) + k];
                g_bus[3*j + k]  = g_bus[3*(j+1) + k];  g_late[3*j + k] = g_late[3*(j+1) + k];
                g_val[3*j + k]  = g_val[3*(j+1) + k];
            end
        end
        gn--;
    endtask

    task automatic g_move(input int from, input int to);
        if (from == to) return;
        g_kind[to] = g_kind[from]; g_tag[to] = g_tag[from]; g_e[to] = g_e[from];
        for (int k = 0; k < 3; k++) begin
            g_hasp[3*to + k] = g_hasp[3*from + k]; g_w[3*to + k] = g_w[3*from + k];
            g_bus[3*to + k]  = g_bus[3*from + k];  g_late[3*to + k] = g_late[3*from + k];
            g_val[3*to + k]  = g_val[3*from + k];
        end
    endtask

    // ---------------- coverage ----------------
    int n_push, n_ab, n_alu, n_bru, n_div, n_fpu, n_fds, n_flush, n_capture, n_same, n_late, n_ooo, n_div_hold,
        n_fds_hold, n_full;

    // ---------------- the run ----------------
    int  t, e_ab, e_div, e_fds, e_fpu, div_busy_until, ds_busy_until, old_gn;
    logic f_ab, f_div, f_fds, f_fpu, x_div, x_fpu, pushed_now;
    rs_entry_t gf;
    int        seed_v;

    task automatic chk_req(input string what, input fu_req_t r, input int i);
        rs_entry_t ge;
        ge = g_e[i];
        check({what, " tag"}, 64'(r.tag), 64'(g_tag[i]));
        check({what, " op"}, 64'(r.op), 64'(ge.op));
        check({what, " is_word"}, b(r.is_word), b(ge.is_word));
        check({what, " a"}, r.a, g_val[3*i]);
        check({what, " b"}, r.b, g_val[3*i + 1]);
        check({what, " pc"}, r.pc, ge.pc);
        check({what, " imm"}, r.imm, ge.imm);
        check({what, " rvc"}, b(r.rvc), b(ge.rvc));
        check({what, " pred_next"}, r.pred_next, ge.pred_next);
    endtask

    initial begin
        seed_v = SEED;
        void'($urandom(seed_v));
        for (int i = 0; i < NTAG; i++) tag_used[i] = 1'b0;
        for (int i = 0; i < NP; i++) p_live[i] = 1'b0;
        for (int bb = 0; bb < 5; bb++) for (int k = 0; k < RING; k++) begin s_p[bb][k] = -1; s_garb[bb][k] = 1'b0; end
        gn = 0;
        n_push = 0; n_ab = 0; n_alu = 0; n_bru = 0; n_div = 0; n_fpu = 0; n_fds = 0; n_flush = 0; n_capture = 0;
        n_same = 0; n_late = 0; n_ooo = 0; n_div_hold = 0; n_fds_hold = 0; n_full = 0;
        div_busy_until = -1; ds_busy_until = -1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (t = 0; t < CYCLES; t++) begin
            // ---- inputs for cycle t ----
            flush = ($urandom % 400) == 0;
            wb = '0; wbl = '0; wbd = '0; wbf = '0; wbc = '0;
            for (int bb = 0; bb < 5; bb++) begin
                int s;
                s = s_p[bb][t % RING];
                if (s >= 0) begin
                    logic [63:0] v;
                    v = s_garb[bb][t % RING] ? ~p_val[s] : p_val[s];
                    case (bb)
                        0: begin wb.valid  = 1'b1; wb.tag  = TW'(p_tag[s]); wb.value  = v; end
                        1: begin wbl.valid = 1'b1; wbl.tag = TW'(p_tag[s]); wbl.value = v; end
                        2: begin wbd.valid = 1'b1; wbd.tag = TW'(p_tag[s]); wbd.value = v; end
                        3: begin wbf.valid = 1'b1; wbf.tag = TW'(p_tag[s]); wbf.value = v; end
                        default: begin wbc.valid = 1'b1; wbc.tag = TW'(p_tag[s]); wbc.value = v; end
                    endcase
                end
            end
            div_free = (t > div_busy_until) && ($urandom % 6 != 0);
            ds_free  = (t > ds_busy_until) && ($urandom % 6 != 0);

            // ---- push ----
            push = 1'b0;
            if (!flush && gn < DEPTH && ($urandom % 100) < 55 && free_tags() > 0) begin
                int kind, tg;
                rs_entry_t e;
                kind = $urandom % 100;
                kind = kind < 35 ? 0 : kind < 50 ? 1 : kind < 65 ? 2 : kind < 85 ? 3 : 4;
                tg   = alloc_tag();
                e           = '0;
                e.kind      = qv_rs_kind_e'(kind);
                e.tag       = TW'(tg);
                e.op        = 5'($urandom);
                e.is_word   = 1'($urandom);
                e.pc        = {$urandom, $urandom};
                e.imm       = {$urandom, $urandom};
                e.rvc       = 1'($urandom);
                e.pred_next = {$urandom, $urandom};
                e.fmt       = 1'($urandom);
                e.ityp      = 2'($urandom);
                e.rm        = 3'($urandom);
                g_kind[gn] = kind;
                g_tag[gn]  = tg;
                for (int k = 0; k < 3; k++) begin
                    rs_opnd_t o;
                    int s, x;
                    x = 3 * gn + k;
                    s = -1;
                    if (k < 2 || kind == 3) begin              // c is used by the pipelined FPU ops only
                        if (($urandom % 100) < 55) begin
                            // an existing producer that has not delivered yet (delivering now: the dispatch-cycle
                            // capture), or a new one
                            if (($urandom % 2) == 0) begin
                                int m, c;
                                m = 0;
                                for (int q = 0; q < NP; q++) if (p_live[q] && p_w[q] >= t) m++;
                                if (m > 0) begin
                                    c = $urandom % m;
                                    for (int q = 0; q < NP; q++)
                                        if (p_live[q] && p_w[q] >= t) begin
                                            if (c == 0) s = q;
                                            c--;
                                        end
                                end
                            end
                            if (s < 0) s = new_prod(t);
                        end
                    end
                    o = '0;
                    if (s >= 0) begin
                        o.rdy   = 1'b0;
                        o.late  = p_late[s];
                        o.tag   = TW'(p_tag[s]);
                        o.value = {$urandom, $urandom};      // meaningless until the producer delivers
                        g_hasp[x] = 1'b1; g_w[x] = p_w[s]; g_bus[x] = p_bus[s]; g_late[x] = p_late[s];
                        g_val[x]  = p_val[s];
                        if (p_w[s] == t) n_capture++;
                    end else begin
                        o.rdy   = 1'b1;
                        o.value = (k == 2 && kind != 3) ? 64'b0 : {$urandom, $urandom};
                        g_hasp[x] = 1'b0; g_w[x] = 0; g_bus[x] = 0; g_late[x] = 1'b0;
                        g_val[x]  = o.value;
                    end
                    if (k == 0) e.a = o; else if (k == 1) e.b = o; else e.c = o;
                end
                g_e[gn] = e;
                push_e  = e;
                push    = 1'b1;
                n_push++;
            end
            #1;

            // ---- expected selection for cycle t (from the entries as they stand: the push joins at the edge) ----
            f_ab = 1'b0; e_ab = 0; f_div = 1'b0; e_div = 0; f_fds = 1'b0; e_fds = 0; f_fpu = 1'b0; e_fpu = 0;
            for (int i = gn - 1; i >= 0; i--) begin
                if (g_ready(i, t) && (g_kind[i] == 0 || g_kind[i] == 1)) begin f_ab = 1'b1; e_ab = i; end
                if (g_kind[i] == 2) begin f_div = 1'b1; e_div = i; end
                if (g_kind[i] == 4) begin f_fds = 1'b1; e_fds = i; end
            end
            for (int i = gn - 1; i >= 0; i--)
                if (g_ready(i, t) && (g_kind[i] == 3 || (g_kind[i] == 4 && i == e_fds && ds_free))) begin
                    f_fpu = 1'b1; e_fpu = i;
                end
            x_div = f_div && g_ready(e_div, t) && div_free;
            if (flush) begin f_ab = 1'b0; x_div = 1'b0; f_fpu = 1'b0; end
            x_fpu = f_fpu;

            check($sformatf("t=%0d room", t), b(room), b(gn < DEPTH));
            check($sformatf("t=%0d has_div", t), b(has_div), b(f_div));
            check($sformatf("t=%0d has_fds", t), b(has_fds), b(f_fds));
            check($sformatf("t=%0d ALU/BRU port taken", t), b(sel_ab), b(f_ab));
            check($sformatf("t=%0d ALU request", t), b(alu_req.valid), b(f_ab && g_kind[e_ab] == 0));
            check($sformatf("t=%0d BRU request", t), b(bru_req.valid), b(f_ab && g_kind[e_ab] == 1));
            check($sformatf("t=%0d divider request", t), b(div_req.valid), b(x_div));
            check($sformatf("t=%0d divider port taken", t), b(sel_div), b(x_div));
            check($sformatf("t=%0d FPU request", t), b(fpu_req.valid), b(x_fpu));
            check($sformatf("t=%0d FPU port taken", t), b(sel_fpu), b(x_fpu));
            if (f_ab) chk_req($sformatf("t=%0d %s", t, g_kind[e_ab] == 0 ? "ALU" : "BRU"),
                              g_kind[e_ab] == 0 ? alu_req : bru_req, e_ab);
            if (x_div) chk_req($sformatf("t=%0d DIV", t), div_req, e_div);
            if (x_fpu) begin
                gf = g_e[e_fpu];
                check($sformatf("t=%0d FPU tag", t), 64'(fpu_req.tag), 64'(g_tag[e_fpu]));
                check($sformatf("t=%0d FPU op", t), 64'(fpu_req.op), 64'(gf.op));
                check($sformatf("t=%0d FPU fmt", t), b(fpu_req.fmt), b(gf.fmt));
                check($sformatf("t=%0d FPU ityp", t), 64'(fpu_req.ityp), 64'(gf.ityp));
                check($sformatf("t=%0d FPU rm", t), 64'(fpu_req.rm), 64'(gf.rm));
                check($sformatf("t=%0d FPU a", t), fpu_req.a, g_val[3*e_fpu]);
                check($sformatf("t=%0d FPU b", t), fpu_req.b, g_val[3*e_fpu + 1]);
                check($sformatf("t=%0d FPU c", t), fpu_req.c, g_val[3*e_fpu + 2]);
            end
            if (fail_count > 20) begin
                $display("qv_rs_tb: stopping at t=%0d", t);
                break;
            end

            // ---- coverage of the interesting cases ----
            if (gn == DEPTH) n_full++;
            if (f_ab) begin
                n_ab++;
                if (g_kind[e_ab] == 0) n_alu++; else n_bru++;
                for (int i = 0; i < e_ab; i++) if (g_kind[i] == 0 || g_kind[i] == 1) n_ooo++;
            end
            if (x_div) n_div++;
            if (x_fpu) begin if (g_kind[e_fpu] == 3) n_fpu++; else n_fds++; end
            for (int i = 0; i < gn; i++) begin
                if (g_kind[i] == 2 && f_div && i > e_div && g_ready(i, t) && !g_ready(e_div, t)) n_div_hold++;
                if (g_kind[i] == 4 && f_fds && i > e_fds && g_ready(i, t) && !g_ready(e_fds, t)) n_fds_hold++;
            end
            for (int k = 0; k < 3; k++) begin
                if (f_ab && g_hasp[3*e_ab + k] && g_w[3*e_ab + k] == t) n_same++;
                if (f_ab && g_hasp[3*e_ab + k] && g_late[3*e_ab + k]) n_late++;
            end

            // ---- the edge: the model follows ----
            pushed_now = push;
            old_gn     = gn;
            @(posedge clk);
            #1;
            push = 1'b0;
            if (f_ab)  begin tag_used[g_tag[e_ab]] = 1'b0; end
            if (x_div) begin tag_used[g_tag[e_div]] = 1'b0; div_busy_until = t + 1 + int'($urandom % 10); end
            if (x_fpu) begin
                gf = g_e[e_fpu];
                tag_used[g_tag[e_fpu]] = 1'b0;
                if (g_kind[e_fpu] == 4) ds_busy_until = t + 1 + int'($urandom % 12);
            end
            // remove the issued ones, youngest index first so the others do not move (the pushed entry, at index
            // old_gn, is not touched), then append the pushed one
            for (int i = DEPTH - 1; i >= 0; i--)
                if (i < gn && ((f_ab && i == e_ab) || (x_div && i == e_div) || (x_fpu && i == e_fpu))) g_remove(i);
            if (pushed_now) begin
                g_move(old_gn, gn);
                gn++;
            end
            // producers that delivered in cycle t leave (their tags are free for reuse)
            for (int bb = 0; bb < 5; bb++) begin
                s_p[bb][t % RING] = -1;
                s_garb[bb][t % RING] = 1'b0;
            end
            for (int q = 0; q < NP; q++)
                if (p_live[q] && p_w[q] <= t) begin p_live[q] = 1'b0; tag_used[p_tag[q]] = 1'b0; end
            if (flush) begin
                n_flush++;
                for (int i = 0; i < gn; i++) tag_used[g_tag[i]] = 1'b0;
                gn = 0;
                for (int q = 0; q < NP; q++) if (p_live[q]) begin p_live[q] = 1'b0; tag_used[p_tag[q]] = 1'b0; end
                for (int bb = 0; bb < 5; bb++) for (int k = 0; k < RING; k++) begin s_p[bb][k] = -1; s_garb[bb][k] = 1'b0; end
            end
            @(negedge clk);
        end

        $display("qv_rs_tb (DEPTH %0d, BYPASS_EN %0d, LSU_BYPASS %0d): %0d pushes; ALU/BRU %0d (ALU %0d, BRU %0d, %0d past an older waiting one), DIV %0d, FPU %0d, FDS %0d; %0d dispatch-cycle captures, %0d same-cycle bypass operands, %0d late operands, %0d divide holds, %0d FDS holds, %0d full cycles, %0d flushes",
                 DEPTH, BYPASS_EN, LSU_BYPASS, n_push, n_ab, n_alu, n_bru, n_ooo, n_div, n_fpu, n_fds, n_capture,
                 n_same, n_late, n_div_hold, n_fds_hold, n_full, n_flush);
        check("coverage: ALU issued", b(n_alu > 100), 1);
        check("coverage: BRU issued", b(n_bru > 50), 1);
        if (DEPTH > 1) begin                                  // (one entry: none of these can happen)
            check("coverage: issued past an older waiting entry", b(n_ooo > 50), 1);
            check("coverage: dispatch-cycle captures", b(n_capture > 50), 1);
            check("coverage: a younger divide waited for an older one", b(n_div_hold > 5), 1);
            check("coverage: a younger FDS waited for an older one", b(n_fds_hold > 5), 1);
        end
        check("coverage: divides issued", b(n_div > 50), 1);
        check("coverage: FPU issued", b(n_fpu > 50), 1);
        check("coverage: FDS issued", b(n_fds > 50), 1);
        check("coverage: late operands", b(n_late > 20), 1);
        check("coverage: the station was full", b(n_full > 50), 1);
        check("coverage: flushes", b(n_flush > 20), 1);
        if (BYPASS_EN) check("coverage: same-cycle bypass operands", b(n_same > 50), 1);
        $display("");
        $display("qv_rs_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_rs_tb: FAILURES PRESENT");
        $finish;
    end
endmodule
