// SPDX-License-Identifier: MIT

/*
 * qv_lsq -- the load/store queue (O2): the memory ops issue has dispatched, in program order, from dispatch until
 * they retire. It performs nothing and checks nothing itself: qv_lsu stays the one engine every op goes through, one
 * at a time and in order. What the queue adds is room: issue may dispatch DEPTH memory ops instead of one, the oldest
 * op not yet performed goes to the engine as soon as the engine is free, and each op's result (lsu_res_t) is kept
 * here until the op retires, so the engine can take the next op meanwhile.
 *
 * The entries, in age order, are always: done (D: performed, waiting to retire) ... at most one in the engine (E) ...
 * queued (Q). Four pointers, each with a wrap bit, cut them apart:
 *   head_q  the oldest entry (the next to retire)        cmpl_q  the next to complete (the one in the engine, if any)
 *   send_q  the next to go to the engine (the oldest Q)  tail_q  the next free slot
 *
 *   dispatch    issue's request goes in at the tail; while there is no Q entry it also goes to the engine in that same
 *               cycle, if the engine takes one (the timing of the core without the queue)
 *   completion  the engine's writeback (o_wb, valid only for the op it holds) makes that entry done; the engine's
 *               o_res is copied into the entry in the next cycle, and until then o_head_res reads it directly
 *   retirement  when commit pops the ROB head and the head's tag is the oldest entry's, that entry leaves
 *   flush       empties the queue (the engine drops or drains its own op)
 *
 * o_free is registered (the pointers only), so nothing that commit does in a cycle reaches issue in that cycle.
 *
 * For the engine's early accesses (qv_lsu EARLY):
 *   o_early  no barrier is older than the op in the engine. A barrier is a uop that may change what an access may do,
 *            or must be ordered before one: a FENCE, a serializing uop (a CSR write that is not to a trap CSR,
 *            FENCE.I, SFENCE.VMA), a system op (ECALL, EBREAK, xRET, WFI), and a uop that traps or has a trigger.
 *            Issue tells the queue of each one it allocates (i_bar_alloc); an op dispatched while one is unretired
 *            records the youngest one's tag and may not go early until that tag retires. Apart from FENCE and WFI,
 *            everything younger than a barrier is flushed when it retires, so the rule costs nothing else.
 *   o_match  a done entry holds a posted store (performed, not yet in the store buffer: it is pushed when it
 *            retires) to the dword the engine asks about (i_match_addr, qv_lsu's o_sb_addr). Every done entry is
 *            older than the op in the engine; with the buffer's own match it makes a load wait for the store.
 *
 * Pre-translation (O2c, PRE_XL): while the engine leaves the data TLB's port free (i_xl_free: it is on the bus, or
 * holds nothing), the oldest queued op's virtual address is looked up there (o_xl_req, a lookup only: the port's
 * owner sets nowalk), unless it is an SC (its reservation is the head's to judge) or misaligned (it faults before any
 * translation). A clean hit is kept in the entry, and the engine takes the op with its physical page (o_eng_xl,
 * o_eng_ppn), so it can start in its first cycle; a miss or a hit that faults leaves the op to the engine, which looks
 * up again (and at the head walks). The page stays right until the op is performed for the reason the engine's own
 * early lookup does (qv_lsu, PROBE): every change of the privilege, MPRV, SUM, MXR or satp and every SFENCE.VMA
 * flushes the queue, and a TLB entry, once found, may be used until an SFENCE.VMA.
 *
 * Waiting operands (O1c, OPW): issue may dispatch a memory op whose address or store data does not exist yet. Its
 * operands come as the reservation station's do (i_opa, i_opb: ready with the value, or the producer's tag, late for
 * a CSR op's rd), and each entry's operands are woken the same way: every writeback bus (the LSU's own is i_eng_wb)
 * and the commit bus, a late one only by the commit bus, and the entry pushed in a cycle takes in that cycle's buses.
 * The oldest queued op goes to the engine only once both operands exist -- which may be in the cycle a same-cycle
 * source carries one (the ALU/BRU and FPU writebacks with BYPASS_EN, the LSU's own with LSU_BYPASS as well), so a
 * load whose address is the load before it is taken in that load's completion cycle, as with the load bypass in
 * issue -- and never before: a younger op does not pass it, so the engine still takes the ops in program order.
 * Issue's request passes straight through only when its operands are ready; pre-translation waits for the address.
 */
module qv_lsq #(
    parameter int DEPTH  = 4,                   // a power of 2, >= 2
    parameter bit PRE_XL = 1'b0,                // the oldest queued op's translation is looked up early (O2c)
    parameter bit OPW        = 1'b0,            // operands may wait in the queue (O1c)
    parameter bit BYPASS_EN  = 1'b1,            // (OPW) the same-cycle sources, as issue's bypass
    parameter bit LSU_BYPASS = 1'b0
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // issue
    input  qv_pkg::fu_req_t                  i_req,
    output logic                             o_free,           // room for one more
    // (OPW) the dispatching op's operands (a: rs1, b: rs2 or the I-immediate), and the buses that wake them (only
    // valid, tag and value are read)
    input  qv_pkg::rs_opnd_t                 i_opa = '0,
    input  qv_pkg::rs_opnd_t                 i_opb = '0,
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb = '0,        // ALU/BRU
    input  qv_pkg::wb_t                      i_wbd = '0,       // divider
    input  qv_pkg::wb_fp_t                   i_wbf = '0,       // FPU
    input  qv_pkg::wb_t                      i_wbc = '0,       // commit: an integer rd written to regfile0
    /* verilator lint_on UNUSEDSIGNAL */

    // the engine (qv_lsu)
    output qv_pkg::fu_req_t                  o_eng_req,        // its i_req
    input  logic                             i_eng_take,       // its o_take: it takes o_eng_req in this cycle
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_eng_wb,         // its o_wb (valid and tag: value goes to the ROB)
    /* verilator lint_on UNUSEDSIGNAL */
    input  qv_pkg::lsu_res_t                 i_eng_res,        // its o_res

    // commit
    input  logic                             i_pop,            // the ROB head retires ...
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_pop_tag,        // ... with this tag
    output qv_pkg::lsu_res_t                 o_head_res,       // the oldest entry's result
    // O4: the entry behind the ROB head retires too (with i_pop), with this tag; and the second-oldest entry's result
    input  logic                             i_pop2 = 1'b0,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_pop2_tag = '0,
    output qv_pkg::lsu_res_t                 o_head1_res,

    // early accesses
    input  logic                             i_bar_alloc = 1'b0,   // issue allocates a barrier uop ...
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_bar_tag = '0,       // ... with this tag
    output logic                             o_early,              // no barrier is older than the engine's op
    input  logic [31:3]                      i_match_addr = '0,
    output logic                             o_match,

    // pre-translation
    output logic                             o_xl_req,
    output logic [63:0]                      o_xl_va,
    output logic                             o_xl_wr,              // a store, SC or AMO (needs W and D)
    input  logic                             i_xl_free = 1'b0,     // the engine asks nothing of the port
    input  logic                             i_xl_active = 1'b0,   // translation is on (the engine's context)
    input  logic                             i_xl_done = 1'b0,
    input  logic                             i_xl_pf = 1'b0,
    input  logic                             i_xl_af = 1'b0,
    input  logic [43:0]                      i_xl_ppn = '0,
    output logic                             o_eng_xl,             // o_eng_req comes translated ...
    output logic [43:0]                      o_eng_ppn             // ... to this physical page
);
    import qv_pkg::*;

    localparam int IW = $clog2(DEPTH);

    logic [IW:0]             head_q, cmpl_q, send_q, tail_q;
    fu_req_t                 req_q [DEPTH];
    logic [QV_ROB_TAG_W-1:0] tag_q [DEPTH];
    lsu_res_t                res_q [DEPTH];
    logic                    copy_q;                 // the engine completed an entry last cycle ...
    logic [IW-1:0]           copy_idx_q;             // ... this one: its o_res still holds the result
    logic                    bar_q     [DEPTH];      // an older barrier has not retired yet ...
    logic [QV_ROB_TAG_W-1:0] bar_tag_q [DEPTH];      // ... the youngest one at dispatch
    logic                    lbar_q;                 // the youngest barrier allocated has not retired ...
    logic [QV_ROB_TAG_W-1:0] lbar_tag_q;             // ... its tag
    logic                    xl_q      [DEPTH];      // (PRE_XL) the entry's translation is in ...
    logic [43:0]             ppn_q     [DEPTH];      // ... its physical page

    wire [IW-1:0] head_i = head_q[IW-1:0];
    wire [IW-1:0] cmpl_i = cmpl_q[IW-1:0];
    wire [IW-1:0] send_i = send_q[IW-1:0];
    wire [IW-1:0] tail_i = tail_q[IW-1:0];

    wire [IW:0] count  = tail_q - head_q;
    wire        empty  = (count == '0);
    wire        has_q  = (send_q != tail_q);           // a queued op waits for the engine
    assign o_free      = (count != (IW + 1)'(DEPTH));

    wire push = i_req.valid && !i_flush;

    // ---------------- (OPW) waiting operands ----------------
    // wake, byp_hit and now_val are the reservation station's rules (qv_rs.sv), the LSU's writeback being i_eng_wb
    rs_opnd_t opa_q [DEPTH];
    rs_opnd_t opb_q [DEPTH];

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

    rs_opnd_t sa, sb;                                   // the oldest queued op's operands
    assign sa = opa_q[send_i];
    assign sb = opb_q[send_i];
    wire s_ok  = !OPW || ((sa.rdy || byp_hit(sa, i_wb, i_eng_wb, i_wbf)) && (sb.rdy || byp_hit(sb, i_wb, i_eng_wb, i_wbf)));
    wire in_ok = !OPW || (i_opa.rdy && i_opb.rdy);      // issue's request has its operands

    // the oldest queued op, or, with none, issue's own request
    fu_req_t send_e;
    assign send_e = req_q[send_i];
    always_comb begin
        o_eng_req       = has_q ? send_e : i_req;
        if (OPW && has_q) begin
            o_eng_req.a = now_val(sa, i_wb, i_eng_wb, i_wbf);
            o_eng_req.b = now_val(sb, i_wb, i_eng_wb, i_wbf);
        end
        o_eng_req.valid = has_q ? s_ok : (i_req.valid && in_ok);
    end
    wire send = i_eng_take && !i_flush;                        // the engine takes it

    wire cmpl = i_eng_wb.valid && !i_flush;

    wire pop  = i_pop && !empty && (i_pop_tag == tag_q[head_i]) && !i_flush;
    // (O4) the second retirement leaves too when it is the next memory op: the oldest entry, or the one behind it
    // when the head was one
    wire [IW:0]   head1_q = head_q + 1'b1;
    wire [IW-1:0] head1_i = head1_q[IW-1:0];
    wire [IW-1:0] h2_i    = pop ? head1_i : head_i;
    wire pop2 = i_pop2 && !i_flush && (count > (pop ? (IW + 1)'(1) : (IW + 1)'(0))) && (i_pop2_tag == tag_q[h2_i]);

    assign o_head_res = (copy_q && copy_idx_q == head_i) ? i_eng_res : res_q[head_i];
    assign o_head1_res = (copy_q && copy_idx_q == head1_i) ? i_eng_res : res_q[head1_i];

    // ---------------- barriers ----------------
    wire bar_retire = i_pop && !i_flush;             // the ROB head retires: is it a barrier someone waits for?
    assign o_early  = (cmpl_q != send_q) && !bar_q[cmpl_i];

    // ---------------- the posted stores not retired yet ----------------
    logic [DEPTH-1:0] posted_hit;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            /* verilator lint_off UNUSEDSIGNAL */
            lsu_res_t      r;                        // only posted and the address matter here
            /* verilator lint_on UNUSEDSIGNAL */
            logic [IW-1:0] pos;                      // how far entry i is from the head
            r    = (copy_q && copy_idx_q == IW'(i)) ? i_eng_res : res_q[i];
            pos  = IW'(i) - head_i;
            posted_hit[i] = ({1'b0, pos} < (cmpl_q - head_q)) && r.posted && (r.mem_addr[31:3] == i_match_addr);
        end
    end
    assign o_match = |posted_hit;

    // ---------------- (PRE_XL) the oldest queued op's translation ----------------
    // its address and kind exactly as qv_lsu works them out at dispatch
    wire        p_atomic = send_e.op[4];
    wire        p_lr     = p_atomic && (qv_amo_op_e'(send_e.op[3:0]) == QV_AMO_LR);
    wire        p_sc     = p_atomic && (qv_amo_op_e'(send_e.op[3:0]) == QV_AMO_SC);
    wire        p_store  = !p_atomic && send_e.op[3];
    wire [1:0]  p_size   = p_atomic ? (send_e.is_word ? 2'd2 : 2'd3) : send_e.op[1:0];
    // (OPW) from the operands' registered values only: the address must exist already (no bus into the lookup)
    wire [63:0] p_a      = OPW ? sa.value : send_e.a;
    wire [63:0] p_b      = OPW ? sb.value : send_e.b;
    wire        p_va_ok  = !OPW || (sa.rdy && (p_atomic || p_store || sb.rdy));
    wire [63:0] p_va     = p_atomic ? p_a : p_a + (p_store ? send_e.imm : p_b);
    wire        p_mis    = (p_size == 2'd1) ? p_va[0] : (p_size == 2'd2) ? (p_va[1:0] != 2'd0)
                         : (p_size == 2'd3) ? (p_va[2:0] != 3'd0) : 1'b0;
    assign o_xl_req  = PRE_XL && i_xl_active && has_q && !xl_q[send_i] && !p_sc && !p_mis && !i_flush && p_va_ok;
    assign o_xl_va   = p_va;
    assign o_xl_wr   = p_atomic ? !p_lr : p_store;
    wire   pre_hit   = o_xl_req && i_xl_free && i_xl_done && !i_xl_pf && !i_xl_af;
    assign o_eng_xl  = PRE_XL && has_q && xl_q[send_i];
    assign o_eng_ppn = ppn_q[send_i];

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            head_q <= '0;
            cmpl_q <= '0;
            send_q <= '0;
            tail_q <= '0;
            copy_q <= 1'b0;
            lbar_q <= 1'b0;
        end else begin
            if (pre_hit) begin
                xl_q[send_i]  <= 1'b1;
                ppn_q[send_i] <= i_xl_ppn;
            end
            if (OPW)
                for (int i = 0; i < DEPTH; i++) begin
                    opa_q[i] <= wake(opa_q[i], i_wb, i_eng_wb, i_wbd, i_wbf, i_wbc);
                    opb_q[i] <= wake(opb_q[i], i_wb, i_eng_wb, i_wbd, i_wbf, i_wbc);
                end
            if (push) begin
                if (OPW) begin                               // the dispatch-cycle capture: this cycle's buses too
                    opa_q[tail_i] <= wake(i_opa, i_wb, i_eng_wb, i_wbd, i_wbf, i_wbc);
                    opb_q[tail_i] <= wake(i_opb, i_wb, i_eng_wb, i_wbd, i_wbf, i_wbc);
                end
                xl_q[tail_i]      <= 1'b0;
                req_q[tail_i]     <= i_req;
                tag_q[tail_i]     <= i_req.tag;
                bar_q[tail_i]     <= lbar_q && !(bar_retire && i_pop_tag == lbar_tag_q);
                bar_tag_q[tail_i] <= lbar_tag_q;
                tail_q            <= tail_q + 1'b1;
            end
            for (int i = 0; i < DEPTH; i++)
                if (bar_retire && i_pop_tag == bar_tag_q[i] && !(push && tail_i == IW'(i))) bar_q[i] <= 1'b0;
            if (i_bar_alloc) begin
                lbar_q     <= 1'b1;
                lbar_tag_q <= i_bar_tag;
            end else if (bar_retire && i_pop_tag == lbar_tag_q) begin
                lbar_q     <= 1'b0;
            end
            if (send) send_q <= send_q + 1'b1;
            if (cmpl) cmpl_q <= cmpl_q + 1'b1;
            if (pop || pop2) head_q <= head_q + (IW + 1)'(pop) + (IW + 1)'(pop2);
            if (copy_q) res_q[copy_idx_q] <= i_eng_res;
            copy_q     <= cmpl;
            copy_idx_q <= cmpl_i;
        end
    end

`ifndef SYNTHESIS
    // what the order of the entries promises: issue dispatches only into room, the engine completes only the op it
    // took (the oldest not done), and only a done entry retires
    always @(posedge clk) if (!rst && !i_flush) begin
        if (push && !o_free)
            $error("qv_lsq: a dispatch into a full queue");
        if (cmpl && (cmpl_q == send_q || i_eng_wb.tag != tag_q[cmpl_i]))
            $error("qv_lsq: the engine completed an op it does not hold");
        if (pop && head_q == cmpl_q)
            $error("qv_lsq: an op retires before it is done");
        if (pop2 && (pop ? head1_q : head_q) == cmpl_q)
            $error("qv_lsq: a second op retires before it is done");
    end
`endif
endmodule: qv_lsq
