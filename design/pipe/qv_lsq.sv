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
 */
module qv_lsq #(
    parameter int DEPTH  = 4,                   // a power of 2, >= 2
    parameter bit PRE_XL = 1'b0                 // the oldest queued op's translation is looked up early (O2c)
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // issue
    input  qv_pkg::fu_req_t                  i_req,
    output logic                             o_free,           // room for one more

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

    // the oldest queued op, or, with none, issue's own request
    fu_req_t send_e;
    assign send_e = req_q[send_i];
    always_comb begin
        o_eng_req       = has_q ? send_e : i_req;
        o_eng_req.valid = has_q || i_req.valid;
    end
    wire send = i_eng_take && !i_flush;                        // the engine takes it

    wire cmpl = i_eng_wb.valid && !i_flush;

    wire pop  = i_pop && !empty && (i_pop_tag == tag_q[head_i]) && !i_flush;

    assign o_head_res = (copy_q && copy_idx_q == head_i) ? i_eng_res : res_q[head_i];

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
    wire [63:0] p_va     = p_atomic ? send_e.a : send_e.a + (p_store ? send_e.imm : send_e.b);
    wire        p_mis    = (p_size == 2'd1) ? p_va[0] : (p_size == 2'd2) ? (p_va[1:0] != 2'd0)
                         : (p_size == 2'd3) ? (p_va[2:0] != 3'd0) : 1'b0;
    assign o_xl_req  = PRE_XL && i_xl_active && has_q && !xl_q[send_i] && !p_sc && !p_mis && !i_flush;
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
            if (push) begin
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
            if (pop)  head_q <= head_q + 1'b1;
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
    end
`endif
endmodule: qv_lsq
