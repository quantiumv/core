// SPDX-License-Identifier: MIT

/*
 * align2_props -- SymbiYosys properties for design/pipe/qv_align2.sv (O8b, the aligner over two fetch-buffer
 * entries), checked at its ports against a model fetch buffer.
 *
 * The model buffer (FBD entries) is filled at free times, one entry a cycle, the way qv_fetch fills it: the first
 * entry after a reset, a flush or an aligner redirect is at that redirect's pc, every later one at the dword after
 * the one before it or, behind an entry with a BTB hint, at the hint's target. An entry's data is a fixed function of
 * its dword address (two free, constant dwords, alternating; a faulted entry's data is free junk), its fault flag and its hint are free (a hint names a halfword at or
 * after the entry's first, as qv_fetch promises), and so are the IQ's room, the branch history table, the RAS and
 * the flushes. The aligner pops one or two entries; a redirect or a flush empties the buffer.
 *
 * Properties:
 *   - the instructions that go out are the program in order from the latest flush: each starts where the one before
 *     it led (its successor, or its predicted target when it is predicted taken), its bits and its size are the
 *     memory's at that pc. Nothing is skipped, duplicated or taken from the wrong entry; a fault marker carries the
 *     pc it stands for (after it nothing is checked until the next flush: it traps);
 *   - a redirect for a predicted-taken instruction goes to the target the stream continues at; the redirect for a
 *     hint nothing confirmed goes to the dword after the window that was used up (the stream itself continues there
 *     or, with a crossing first half kept, two bytes before it);
 *   - the head is never held: every cycle the aligner can go, it sends out an instruction or pops the head (a head
 *     with no successor in the buffer is not kept waiting for one: fetch reads a page-table entry outside RAM for that
 *     successor only once the buffer is empty, qv_ptw's f_nonspec);
 *   - a kept crossing first half is always the last halfword of its dword; both entries are used up in one cycle only
 *     by a confirmed hint in the second (two instructions from halfword 3 or before end by 7); two entries are popped only when there
 *     are two.
 */
`ifndef FBD
`define FBD 2
`endif
module align2_props (
    input logic        clk,
    input logic        rst,
    input logic        flush,
    input logic [6:0]  flush_pc7,
    input logic        fill,
    input logic        fill_err,
    input logic [63:0] fill_junk,
    input logic        fill_hint,
    input logic [1:0]  fill_hoff,
    input logic        fill_hx,
    input logic [6:0]  fill_htgt7,
    input logic        push_ready,
    input logic        push_ready1,
    input logic [3:0]  bk, bt, bk1, bt1,
    input logic        pk, pt,
    input logic [6:0]  ras_top7,
    input logic        ras_has1
);
    // (O7) this proof is sized for the 4-bit tags of an 8-entry package: every build of it pins QV_ROB_MAX at 8
    if (qv_pkg::QV_ROB_DEPTH != 8) begin : g_rob_pin
        $error("%m: built with qv_pkg::QV_ROB_DEPTH %0d: pin -D QV_ROB_MAX=8", qv_pkg::QV_ROB_DEPTH);
    end
    import qv_pkg::*;
    localparam int FBD = `FBD;
    localparam int PW  = $clog2(FBD);

    // the redirect, hint and return targets are in the first 128 bytes (even): the aligner's arithmetic is the same at
    // any address, and narrow targets keep the solver fast
    wire [63:0] flush_pc  = {57'b0, flush_pc7[6:1], 1'b0};
    wire [63:0] fill_htgt = {57'b0, fill_htgt7[6:1], 1'b0};
    wire [63:0] ras_top   = {57'b0, ras_top7[6:1], 1'b0};

    // the memory: two free dwords, alternating, the same for the whole run (registers with no initial value that keep
    // it): neighbouring dwords differ
    reg [63:0] mem0, mem1;
    always @(posedge clk) {mem0, mem1} <= {mem0, mem1};
    function automatic logic [63:0] M(input logic [63:0] a);
        return a[3] ? mem1 : mem0;
    endfunction
    function automatic logic [15:0] HW(input logic [63:0] a);
        logic [63:0] d;
        d = M(a);
        case (a[2:1])
            2'd0:    HW = d[15:0];
            2'd1:    HW = d[31:16];
            2'd2:    HW = d[47:32];
            default: HW = d[63:48];
        endcase
    endfunction
    function automatic logic [31:0] insn_at(input logic [63:0] a);
        return (HW(a)[1:0] == 2'b11) ? {HW(a + 64'd2), HW(a)} : {16'b0, HW(a)};
    endfunction
    function automatic logic [63:0] after_ins(input fe_instr_t i);
        return i.pred_taken ? i.pred_tgt : i.pc + (i.rvc ? 64'd2 : 64'd4);
    endfunction

    // ---------------- the model fetch buffer ----------------
    reg [63:0]   f_pc   [0:FBD-1];
    reg          f_err  [0:FBD-1];
    reg [63:0]   f_junk [0:FBD-1];
    reg          f_hint [0:FBD-1];
    reg [1:0]    f_hoff [0:FBD-1];
    reg          f_hx   [0:FBD-1];
    reg [63:0]   f_htgt [0:FBD-1];
    reg [PW-1:0] rd = '0;
    reg [PW:0]   cnt = '0;
    reg [63:0]   npc = 64'b0;      // where the next fill comes from
    wire [PW-1:0] rd1 = rd + PW'(1);

    logic        pop, pop2, push0, push1, redir;
    logic [63:0] redir_pc;
    fe_instr_t   d0, d1;

    qv_align2 #(.ONE_OK(1'b1)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(cnt != '0), .i_buf_pc(f_pc[rd]), .i_buf_data(f_err[rd] ? f_junk[rd] : M(f_pc[rd])), .i_buf_err(f_err[rd]),
        .i_buf_hint(f_hint[rd]), .i_buf_hoff(f_hoff[rd]), .i_buf_hx(f_hx[rd]), .i_buf_htgt(f_htgt[rd]),
        .o_buf_pop(pop),
        .i_buf1_valid(cnt >= (PW+1)'(2)), .i_buf1_pc(f_pc[rd1]), .i_buf1_data(f_err[rd1] ? f_junk[rd1] : M(f_pc[rd1])), .i_buf1_err(f_err[rd1]),
        .i_buf1_hint(f_hint[rd1]), .i_buf1_hoff(f_hoff[rd1]), .i_buf1_hx(f_hx[rd1]), .i_buf1_htgt(f_htgt[rd1]),
        .o_buf_pop2(pop2),
        .i_ras_top(ras_top), .i_ras_has1(ras_has1),
        .o_bht_base(), .o_bht_base1(), .o_bht_ppc(),
        .i_bht_known(bk), .i_bht_taken(bt), .i_bht_known1(bk1), .i_bht_taken1(bt1),
        .i_bht_pknown(pk), .i_bht_ptaken(pt),
        .o_ras_op0(), .o_ras_addr0(), .o_ras_op1(), .o_ras_addr1(),
        .o_push0_valid(push0), .o_push0_data(d0), .o_push1_valid(push1), .o_push1_data(d1),
        .i_push_ready(push_ready), .i_push_ready1(push_ready1),
        .o_redirect_valid(redir), .o_redirect_pc(redir_pc)
    );

    // the model buffer's next cycle
    wire          take = fill && !flush && !redir && (cnt - (PW+1)'(pop) - (PW+1)'(pop2) < (PW+1)'(FBD));
    wire [PW:0]   cnt_pop = cnt - (PW+1)'(pop) - (PW+1)'(pop2);
    wire [PW-1:0] wr = rd + PW'(cnt);
    always @(posedge clk) begin
        if (rst) begin
            cnt <= '0;
            rd  <= '0;
            npc <= 64'b0;
        end else if (flush || redir) begin
            cnt <= '0;
            rd  <= '0;
            npc <= flush ? flush_pc : redir_pc;
        end else begin
            rd  <= rd + PW'(pop) + PW'(pop2);
            cnt <= cnt_pop + (PW+1)'(take);
            if (take) begin
                f_pc[wr]   <= npc;
                f_err[wr]  <= fill_err;
                f_junk[wr] <= fill_junk;
                f_hint[wr] <= fill_hint;
                f_hoff[wr] <= fill_hoff;
                f_hx[wr]   <= fill_hx;
                f_htgt[wr] <= fill_htgt;
                npc        <= fill_hint ? fill_htgt : {npc[63:3], 3'b000} + 64'd8;
            end
        end
    end

    // ---------------- the stream ghost ----------------
    reg        init = 1'b1;
    reg        alive = 1'b1;          // no fault marker went out since the last flush
    reg [63:0] exp_pc = 64'b0;        // where the program continues
    wire [63:0] e1 = after_ins(d0);
    always @(posedge clk) begin
        init <= 1'b0;
        if (rst) begin
            alive  <= 1'b1;
            exp_pc <= 64'b0;
        end else if (flush) begin
            alive  <= 1'b1;
            exp_pc <= flush_pc;
        end else if (push0) begin
            if (d0.xcpt)    alive  <= 1'b0;
            else if (push1) exp_pc <= after_ins(d1);
            else            exp_pc <= e1;
        end
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        // the BTB's promise: its branch is at or after the first halfword of the entry it steers
        if (fill_hint) assume (fill_hoff >= npc[2:1]);
        // room for two is room for one
        if (push_ready) assume (push_ready1);
    end

    // ---------------- properties ----------------
    wire go = (cnt != '0) && (push_ready || push_ready1) && !flush;
    always @* begin
        if (!rst && !init) begin
            if (alive && push0) begin
                assert (d0.pc == exp_pc);
                if (!d0.xcpt) begin
                    assert (d0.raw == insn_at(exp_pc));
                    assert (d0.rvc == (HW(exp_pc)[1:0] != 2'b11));
                end
            end
            if (alive && push0 && push1) begin
                assert (!d0.xcpt && !d1.xcpt);
                assert (!d0.pred_taken);              // a predicted-taken instruction is the last of its cycle
                assert (d1.pc == e1);
                assert (d1.raw == insn_at(e1));
                assert (d1.rvc == (HW(e1)[1:0] != 2'b11));
            end
            if (push1) assert (push0);
            // a predicted-taken redirect goes where the stream continues
            if (alive && redir && !dut.hint_redir) begin
                assert (push0);
                assert (redir_pc == (push1 ? after_ins(d1) : e1));
            end
            // never held (a redirect empties the buffer: a stashed first half with a hint nothing confirmed)
            if (go) assert (push0 || pop || redir);
            if (pop2) assert (pop && cnt >= (PW+1)'(2));
            if (dut.pend_q) assert (dut.pend_pc_q[2:0] == 3'd6);
            // two instructions that start at halfword 3 or before end by halfword 7: the window is used up (cur 8) only
            // by a confirmed hint in its second entry, so qv_align2 never has to send fetch back for an unconfirmed
            // hint there with both entries used up (that hint is dealt with once its entry is the head)
            if (go && dut.cur == 4'd8) assert (dut.conf0_1 || dut.conf1_1);
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst && !init && alive) begin
            cover (push0 && push1 && d0.pc[63:3] != d1.pc[63:3]);                 // a pair across two entries
            cover (push0 && !d0.rvc && d0.pc[2:1] == 2'd3 && !dut.pend_q);       // a crossing one, no stash
            cover (push0 && !d0.rvc && dut.pend_q);                               // a crossing one from a stash
            cover (pop2);                                                         // both entries used up
            cover (redir && dut.hint_redir && dut.pend_q == 1'b0 && cnt >= (PW+1)'(2));   // the next entry's hint
            cover (push0 && d0.pred_taken && !redir && cnt >= (PW+1)'(2));        // a confirmed hint
            cover (push0 && push1 && d1.pred_taken);                              // the second one taken
        end
    end

    // ---------------- induction lemmas ----------------
    // The model buffer is a chain from the head (each entry where the one before it led, the last one leading to
    // npc), and the aligner's own state says where in it the program continues: at the kept first half (the head is
    // the dword after it), at its position in the head, or at the head's first halfword (npc when the buffer is empty).
    function automatic logic [63:0] nxt(input logic [PW-1:0] j);
        return f_hint[j] ? f_htgt[j] : {f_pc[j][63:3], 3'b000} + 64'd8;
    endfunction
    always @* begin
        if (!init && !rst) begin
            assert (cnt <= (PW+1)'(FBD));
            assert (!npc[0] && !exp_pc[0]);
            for (int j = 0; j < FBD; j++) begin
                if (j < int'(cnt)) begin
                    assert (!f_pc[rd + PW'(j)][0] && !f_htgt[rd + PW'(j)][0]);
                    if (f_hint[rd + PW'(j)]) assert (f_hoff[rd + PW'(j)] >= f_pc[rd + PW'(j)][2:1]);
                    if (j + 1 < int'(cnt)) assert (f_pc[rd + PW'(j + 1)] == nxt(rd + PW'(j)));
                    if (j + 1 == int'(cnt)) assert (npc == nxt(rd + PW'(j)));
                end
            end
            if (dut.pend_q) begin
                assert (!dut.mid_q);
                assert (dut.pend_hw_q == HW(dut.pend_pc_q));
                assert (dut.pend_hw_q[1:0] == 2'b11);
            end
            if (dut.mid_q) assert (cnt != '0);
            if (alive) begin
                if (dut.pend_q) begin
                    assert (dut.pend_pc_q == exp_pc);
                    if (cnt == '0) assert (npc == exp_pc + 64'd2);
                    else           assert (f_pc[rd] == exp_pc + 64'd2);
                end else if (dut.mid_q) begin
                    assert (exp_pc == {f_pc[rd][63:3], dut.off_q, 1'b0});
                end else if (cnt == '0) begin
                    assert (exp_pc == npc);
                end else begin
                    assert (exp_pc == f_pc[rd]);
                end
            end
        end
    end
endmodule
