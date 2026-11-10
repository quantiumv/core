// SPDX-License-Identifier: MIT

/*
 * qv_rs -- the reservation station (O1): uops that issue has dispatched (ROB entry allocated, destination claimed in
 * the producer table) but could not send to their unit in that cycle wait here, in age order, until their operands
 * exist and their unit is free. Each issue port then takes its oldest entry that can go, so a uop no longer waits
 * behind an older one that waits for a load or a divide. Memory ops never come here (the load/store queue holds them).
 *
 * Entries are kept oldest first at index 0 and compacted as they leave; a pushed entry goes at the end. Ports:
 *   ALU/BRU  the oldest ready ALU or BRU entry; at most one of the two per cycle (they share the writeback bus)
 *   DIV      the oldest divide only, once it is ready and the divider is free: a younger divide never passes an older
 *            one, so the divider's work stays in program order
 *   FPU      the oldest of: a ready pipelined FPU op, and the oldest divide/square root (FDS) if it is ready and the
 *            FPU's divide/square-root unit is free (FDS entries keep program order among themselves, as DIV does)
 * The select outputs (o_sel_*) are exactly these conditions: issue sends its dispatching uop straight to a unit only
 * when the station does not take that unit's port, so a port never gets two requests in one cycle. Nothing is
 * selected in a flush cycle, and a flush empties the station.
 *
 * Wakeup. An operand waits for its producer's ROB tag. Every writeback bus wakes it (ALU/BRU, LSU, divider, FPU) and so
 * does the commit bus, except that a late operand (a CSR op's rd, made only at commit) wakes on the commit bus alone:
 * its unit's writeback carries only the ALU's pass of the CSR op's source. The entry pushed in a cycle takes in every
 * bus active in that same cycle, whatever BYPASS_EN and LSU_BYPASS say: a bus that issue does not bypass from at
 * dispatch (the divider's, the commit bus, the others with the knobs off) would otherwise be missed for good, since
 * the producer writes back exactly once. Tags are unique among the uops in flight and a producer writes back before
 * it commits, so an operand that has not woken still names a producer in flight, and at most one bus carries its tag.
 *
 * Select may also take an operand off a bus in the cycle it appears, as issue's own bypass does and under the same
 * knobs: the ALU/BRU and FPU writebacks with BYPASS_EN, the LSU's with LSU_BYPASS as well. The divider's writeback and
 * the commit bus make an entry ready from the next cycle (as the ROB lookup does for issue).
 *
 * o_room is registered (the last slot is free), so nothing selected in a cycle reaches issue's dispatch decision
 * through it.
 */
module qv_rs #(
    parameter int DEPTH      = 4,               // >= 1
    parameter bit BYPASS_EN  = 1'b1,
    parameter bit LSU_BYPASS = 1'b0
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // issue
    input  logic                             i_push,           // only with o_room
    input  qv_pkg::rs_entry_t                i_push_e,
    output logic                             o_room,
    // O4: a second push in the same cycle (the younger dispatching uop, behind i_push_e), only with o_room2: two free
    input  logic                             i_push2 = 1'b0,
    input  qv_pkg::rs_entry_t                i_push2_e = '0,
    output logic                             o_room2,
    output logic                             o_has_div,        // an entry is a divide: a dispatching one may not pass it
    output logic                             o_has_fds,        // an entry is an FP divide/square root: likewise

    // wakeup (only valid, tag and value are read)
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb,             // ALU/BRU
    input  qv_pkg::wb_t                      i_wbl,            // LSU
    input  qv_pkg::wb_t                      i_wbd,            // divider
    input  qv_pkg::wb_fp_t                   i_wbf,            // FPU
    input  qv_pkg::wb_t                      i_wbc,            // commit: an integer rd written to regfile0
    /* verilator lint_on UNUSEDSIGNAL */

    // units
    input  logic                             i_div_free,
    input  logic                             i_fpu_ds_free,
    output logic                             o_sel_ab,         // the ALU/BRU port is taken by an entry this cycle
    output logic                             o_sel_div,
    output logic                             o_sel_fpu,
    output qv_pkg::fu_req_t                  o_alu_req,
    output qv_pkg::fu_req_t                  o_bru_req,
    output qv_pkg::fu_req_t                  o_div_req,
    output qv_pkg::fpu_req_t                 o_fpu_req
);
    import qv_pkg::*;

    rs_entry_t e_q [0:DEPTH-1];
    logic      v_q [0:DEPTH-1];               // valid; the valid entries are always 0 .. n-1

    // (Elements of e_q are copied into a temporary before their fields are read or written: Icarus crashes
    // elaborating `array[i].field` on an array of structs.)

    // An operand's next state: a waiting one takes the first bus that carries its producer's tag (a late one only
    // the commit bus).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic rs_opnd_t wake(input rs_opnd_t o, input wb_t wb, input wb_t wbl, input wb_t wbd,
                                      input wb_fp_t wbf, input wb_t wbc);
        rs_opnd_t n;
        n = o;
        if (!o.rdy) begin
            if (wbc.valid && wbc.tag == o.tag) begin
                n.rdy = 1'b1; n.value = wbc.value;
            end else if (!o.late) begin
                if (wb.valid && wb.tag == o.tag)        begin n.rdy = 1'b1; n.value = wb.value;  end
                else if (wbl.valid && wbl.tag == o.tag) begin n.rdy = 1'b1; n.value = wbl.value; end
                else if (wbd.valid && wbd.tag == o.tag) begin n.rdy = 1'b1; n.value = wbd.value; end
                else if (wbf.valid && wbf.tag == o.tag) begin n.rdy = 1'b1; n.value = wbf.value; end
            end
        end
        return n;
    endfunction

    // An operand that is not ready may still be taken in this cycle off a same-cycle bypass source.
    function automatic logic byp_hit(input rs_opnd_t o, input wb_t wb, input wb_t wbl, input wb_fp_t wbf);
        return !o.late && BYPASS_EN && ((wb.valid && wb.tag == o.tag) || (wbf.valid && wbf.tag == o.tag)
                                        || (LSU_BYPASS && wbl.valid && wbl.tag == o.tag));
    endfunction

    function automatic logic [63:0] now_val(input rs_opnd_t o, input wb_t wb, input wb_t wbl, input wb_fp_t wbf);
        if (o.rdy)                         return o.value;
        if (wb.valid && wb.tag == o.tag)   return wb.value;
        if (wbf.valid && wbf.tag == o.tag) return wbf.value;
        return wbl.value;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- select ----------------
    qv_rs_kind_e kind    [0:DEPTH-1];
    logic        ready   [0:DEPTH-1];         // valid, and every operand exists now
    logic [63:0] va      [0:DEPTH-1];
    logic [63:0] vb      [0:DEPTH-1];
    logic [63:0] vc      [0:DEPTH-1];
    logic        issued  [0:DEPTH-1];
    int          ab_i, div_i, fds_i, fpu_i;    // the chosen ALU/BRU entry, the oldest DIV and FDS, the chosen FPU one
    logic        ab_f, div_f, fds_f, fpu_f;    // ... exists

    always_comb begin
        /* verilator lint_off UNUSEDSIGNAL */
        rs_entry_t x;          // (the request fields are read by the request block)
        /* verilator lint_on UNUSEDSIGNAL */
        for (int i = 0; i < DEPTH; i++) begin
            x        = e_q[i];
            kind[i]  = x.kind;
            ready[i] = v_q[i] && (x.a.rdy || byp_hit(x.a, i_wb, i_wbl, i_wbf))
                              && (x.b.rdy || byp_hit(x.b, i_wb, i_wbl, i_wbf))
                              && (x.c.rdy || byp_hit(x.c, i_wb, i_wbl, i_wbf));
            va[i]    = now_val(x.a, i_wb, i_wbl, i_wbf);
            vb[i]    = now_val(x.b, i_wb, i_wbl, i_wbf);
            vc[i]    = now_val(x.c, i_wb, i_wbl, i_wbf);
        end
        ab_f = 1'b0; ab_i = 0; div_f = 1'b0; div_i = 0; fds_f = 1'b0; fds_i = 0;
        for (int i = DEPTH - 1; i >= 0; i--) begin             // the last hit is the oldest
            if (ready[i] && (kind[i] == QV_RS_ALU || kind[i] == QV_RS_BRU)) begin ab_f = 1'b1; ab_i = i; end
            if (v_q[i] && kind[i] == QV_RS_DIV) begin div_f = 1'b1; div_i = i; end
            if (v_q[i] && kind[i] == QV_RS_FDS) begin fds_f = 1'b1; fds_i = i; end
        end
        fpu_f = 1'b0; fpu_i = 0;
        for (int i = DEPTH - 1; i >= 0; i--)
            if (ready[i] && (kind[i] == QV_RS_FPU || (kind[i] == QV_RS_FDS && i == fds_i && i_fpu_ds_free))) begin
                fpu_f = 1'b1; fpu_i = i;
            end
        o_sel_ab  = !i_flush && ab_f;
        o_sel_div = !i_flush && div_f && ready[div_i] && i_div_free;
        o_sel_fpu = !i_flush && fpu_f;
        for (int i = 0; i < DEPTH; i++)
            issued[i] = (o_sel_ab && i == ab_i) || (o_sel_div && i == div_i) || (o_sel_fpu && i == fpu_i);
        o_has_div = div_f;
        o_has_fds = fds_f;
    end
    assign o_room = !v_q[DEPTH-1];
    assign o_room2 = (DEPTH > 1) && !v_q[(DEPTH > 1) ? DEPTH - 2 : 0];

    // ---------------- requests ----------------
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic fu_req_t mk_req(input rs_entry_t e, input logic [63:0] a, input logic [63:0] b);
        fu_req_t r;
        r           = '0;
        r.tag       = e.tag;
        r.op        = e.op;
        r.is_word   = e.is_word;
        r.a         = a;
        r.b         = b;
        r.pc        = e.pc;
        r.imm       = e.imm;
        r.rvc       = e.rvc;
        r.pred_next = e.pred_next;
        return r;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        rs_entry_t x;
        o_alu_req = '0;
        o_bru_req = '0;
        o_div_req = '0;
        o_fpu_req = '0;
        for (int i = 0; i < DEPTH; i++) begin
            x = e_q[i];
            if (i == ab_i) begin
                o_alu_req       = mk_req(x, va[i], vb[i]);
                o_alu_req.valid = o_sel_ab && x.kind == QV_RS_ALU;
                o_bru_req       = mk_req(x, va[i], vb[i]);
                o_bru_req.valid = o_sel_ab && x.kind == QV_RS_BRU;
            end
            if (i == div_i) begin
                o_div_req       = mk_req(x, va[i], vb[i]);
                o_div_req.valid = o_sel_div;
            end
            if (i == fpu_i) begin
                o_fpu_req.valid = o_sel_fpu;
                o_fpu_req.tag   = x.tag;
                o_fpu_req.op    = qv_fp_op_e'(x.op);
                o_fpu_req.fmt   = x.fmt;
                o_fpu_req.ityp  = x.ityp;
                o_fpu_req.rm    = x.rm;
                o_fpu_req.a     = va[i];
                o_fpu_req.b     = vb[i];
                o_fpu_req.c     = vc[i];
            end
        end
    end

    // ---------------- next state: leave, compact, wake, push ----------------
    rs_entry_t n_e [0:DEPTH-1];
    logic      n_v [0:DEPTH-1];

    always_comb begin
        rs_entry_t x, y;
        int        j, k;
        x = '0;
        y = '0;
        j = 0;
        k = 0;
        for (int i = 0; i < DEPTH; i++) begin
            n_e[i] = e_q[i];
            n_v[i] = 1'b0;
        end
        for (int i = 0; i < DEPTH; i++) begin
            if (v_q[i] && !issued[i]) begin
                x      = e_q[i];
                x.a    = wake(x.a, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
                x.b    = wake(x.b, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
                x.c    = wake(x.c, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
                n_e[j] = x;
                n_v[j] = 1'b1;
                j++;
            end
        end
        if (i_push && j < DEPTH) begin                          // the dispatch-cycle capture: this cycle's buses too
            x      = i_push_e;
            x.a    = wake(x.a, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            x.b    = wake(x.b, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            x.c    = wake(x.c, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            n_e[j] = x;
            n_v[j] = 1'b1;
        end
        // (O4) the second dispatching uop goes behind the first, with the same capture
        if (i_push2) begin
            k   = j + (i_push ? 1 : 0);
            y   = i_push2_e;
            y.a = wake(y.a, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            y.b = wake(y.b, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            y.c = wake(y.c, i_wb, i_wbl, i_wbd, i_wbf, i_wbc);
            if (k < DEPTH) begin
                n_e[k] = y;
                n_v[k] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < DEPTH; i++) begin
            e_q[i] <= n_e[i];
            v_q[i] <= (rst || i_flush) ? 1'b0 : n_v[i];
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && !i_flush && i_push && !o_room)
            $error("qv_rs: push with no room");
        if (!rst && !i_flush && i_push && i_push2 && !o_room2)
            $error("qv_rs: two pushes with room for one");
        if (!rst && !i_flush && i_push2 && !i_push && !o_room)
            $error("qv_rs: a second push with no room");
        if (!rst && o_alu_req.valid && o_bru_req.valid)
            $error("qv_rs: ALU and BRU selected together");
    end
`endif
endmodule
