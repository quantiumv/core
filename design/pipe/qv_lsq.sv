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
 *               cycle, if the engine is free (the timing of the core without the queue)
 *   completion  the engine's writeback (o_wb, valid only for the op it holds) makes that entry done; the engine's
 *               o_res is copied into the entry in the next cycle, and until then o_head_res reads it directly
 *   retirement  when commit pops the ROB head and the head's tag is the oldest entry's, that entry leaves
 *   flush       empties the queue (the engine drops or drains its own op)
 *
 * o_free is registered (the pointers only), so nothing that commit does in a cycle reaches issue in that cycle.
 */
module qv_lsq #(
    parameter int DEPTH = 4                     // a power of 2, >= 2
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // issue
    input  qv_pkg::fu_req_t                  i_req,
    output logic                             o_free,           // room for one more

    // the engine (qv_lsu)
    output qv_pkg::fu_req_t                  o_eng_req,        // its i_req
    input  logic                             i_eng_free,       // its o_free
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_eng_wb,         // its o_wb (valid and tag: value goes to the ROB)
    /* verilator lint_on UNUSEDSIGNAL */
    input  qv_pkg::lsu_res_t                 i_eng_res,        // its o_res

    // commit
    input  logic                             i_pop,            // the ROB head retires ...
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_pop_tag,        // ... with this tag
    output qv_pkg::lsu_res_t                 o_head_res        // the oldest entry's result
);
    import qv_pkg::*;

    localparam int IW = $clog2(DEPTH);

    logic [IW:0]             head_q, cmpl_q, send_q, tail_q;
    fu_req_t                 req_q [DEPTH];
    logic [QV_ROB_TAG_W-1:0] tag_q [DEPTH];
    lsu_res_t                res_q [DEPTH];
    logic                    copy_q;                 // the engine completed an entry last cycle ...
    logic [IW-1:0]           copy_idx_q;             // ... this one: its o_res still holds the result

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
    wire send = i_eng_free && o_eng_req.valid && !i_flush;    // the engine takes it (qv_lsu's accept)

    wire cmpl = i_eng_wb.valid && !i_flush;

    wire pop  = i_pop && !empty && (i_pop_tag == tag_q[head_i]) && !i_flush;

    assign o_head_res = (copy_q && copy_idx_q == head_i) ? i_eng_res : res_q[head_i];

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            head_q <= '0;
            cmpl_q <= '0;
            send_q <= '0;
            tail_q <= '0;
            copy_q <= 1'b0;
        end else begin
            if (push) begin
                req_q[tail_i] <= i_req;
                tag_q[tail_i] <= i_req.tag;
                tail_q        <= tail_q + 1'b1;
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
