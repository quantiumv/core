// SPDX-License-Identifier: MIT

/*
 * kill_props -- SymbiYosys properties for design/pipe/qv_issue.sv's producer tables and design/pipe/qv_rob.sv's kill
 * (O3: recovery at execute), together: issue (two dispatches a cycle, two ALU ports, no station, CSR_LATE) and a ROB
 * of ROB_DEPTH entries. Free under the core's contract:
 *   - two uops a cycle (no sources, so they dispatch when the ROB has room; ALU, branch or CSR ops, any destination
 *     in either register file);
 *   - a writeback of a live entry that is not complete (one producer per tag);
 *   - retirements: the head when it is complete, the entry behind it too when that is complete;
 *   - a kill: a live entry is the branch, no older than this cycle's last retirement (commit pairs nothing behind a
 *     mispredicted head, so a branch that retires now is the only one retiring), nothing dispatches in that cycle,
 *     and no writeback of a killed entry comes in it.
 * Then, after every edge, both tables equal their definition: register r is busy exactly when an entry in the ROB
 * writes it (x0 never), with the youngest such entry's tag, and (CSR_LATE) late exactly when that entry is a CSR op.
 * That is what the claims and the tag-matched clears keep, and what the rebuild restores in a kill cycle. Also: the
 * kill vector marks exactly the entries younger than the branch, and after a kill the tail is the entry after it.
 * Covers: a kill that brings back an older producer of a register a killed entry wrote, one in a cycle with two
 * retirements, one whose branch retires in its cycle.
 */
module kill_props (
    input logic                             clk,
    input logic                             rst,
    input logic                             uop_valid,
    input qv_pkg::uop_t                     uop_in,
    input logic                             uop1_valid,
    input qv_pkg::uop_t                     uop1_in,
    input qv_pkg::wb_t                      wb_in,
    input logic                             pop_in,
    input logic                             pop2_in,
    input logic                             kill_in,
    input logic [qv_pkg::QV_ROB_TAG_W-1:0]  kill_tag
);
    // (O7) this proof is sized for the 4-bit tags of an 8-entry package: every build of it pins QV_ROB_MAX at 8
    if (qv_pkg::QV_ROB_DEPTH != 8) begin : g_rob_pin
        $error("%m: built with qv_pkg::QV_ROB_DEPTH %0d: pin -D QV_ROB_MAX=8", qv_pkg::QV_ROB_DEPTH);
    end
    import qv_pkg::*;
    localparam int ROB_DEPTH = 4;
    localparam int IDX_W = $clog2(ROB_DEPTH);
    localparam int PTR_W = IDX_W + 1;

    // the uops: no sources, a few kinds
    function automatic uop_t shape(input uop_t u, input logic slot1);
        uop_t x;
        x = '0;
        x.fu       = (u.fu == QV_FU_BRU) ? QV_FU_BRU : (!slot1 && u.fu == QV_FU_CSR) ? QV_FU_CSR : QV_FU_ALU;
        x.raw      = 32'h0000_0033;
        x.rd       = {3'b0, u.rd[1:0]};          // x0-x3 / f0-f3: every register is rebuilt alike, these collide often
        x.rd_wen   = u.rd_wen;
        x.rd_fp    = u.rd_fp && (x.fu == QV_FU_ALU);
        x.csr_wsup = 1'b1;
        return x;
    endfunction
    wire uop_t uop  = shape(uop_in, 1'b0);
    wire uop_t uop1 = shape(uop1_in, 1'b1);

    // ---- the DUT ----
    logic                    issue, issue2;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic                    alloc2_valid, alloc2_rd_wen, alloc_ready2;
    logic [63:0]             alloc_pc, alloc_next_pc, alloc2_pc, alloc2_next_pc;
    logic [31:0]             alloc_raw, alloc2_raw;
    logic [4:0]              alloc_rd, alloc2_rd;
    rob_ctrl_t               alloc_ctrl, alloc2_ctrl, head_ctrl, head1_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, alloc_tag1, l1_tag, l2_tag, l3_tag, l4_tag, l5_tag, head_tag, head1_tag;
    logic                    l1_complete, l2_complete, l3_complete, l4_complete, l5_complete;
    logic [63:0]             l1_value, l2_value, l3_value, l4_value, l5_value;
    logic                    head_valid, head1_valid;
    rob_entry_t              head_entry, head1_entry;
    logic [(1<<QV_ROB_TAG_W)-1:0] kill_vec;
    logic [QV_ROB_DEPTH-1:0]                   surv_live, surv_int, surv_fp, surv_csr;
    logic [QV_ROB_DEPTH-1:0][QV_ROB_TAG_W-1:0] surv_tag;
    logic [QV_ROB_DEPTH-1:0][4:0]              surv_rd;
    ras_snap_t               kill_snap;

    wire kill = kill_in && !rst;
    wire pop  = pop_in && !rst;
    wire pop2 = pop && pop2_in;
    wb_t wb;                                     // a completion only: no value (the tables do not depend on one)
    always_comb begin
        wb       = '0;
        wb.valid = wb_in.valid;
        wb.tag   = wb_in.tag;
    end

    qv_issue #(.CSR_LATE(1'b1), .RS_DEPTH(0), .DISPATCH_W(2), .ALU_PORTS(2)) issue0 (
        .clk(clk), .rst(rst), .i_flush(1'b0), .i_kill_vec(kill_vec),
        .i_kill(kill), .i_surv_live(surv_live), .i_surv_tag(surv_tag), .i_surv_rd(surv_rd),
        .i_surv_int(surv_int), .i_surv_fp(surv_fp), .i_surv_csr(surv_csr),
        .i_uop_valid(uop_valid && !kill), .i_uop(uop), .o_issue(issue),
        .o_rs1_sel(), .o_rs2_sel(), .i_rs1_data(64'b0), .i_rs2_data(64'b0),
        .o_alloc_valid(alloc_valid), .o_alloc_pc(alloc_pc), .o_alloc_raw(alloc_raw),
        .o_alloc_rd(alloc_rd), .o_alloc_rd_wen(alloc_rd_wen), .o_alloc_next_pc(alloc_next_pc),
        .o_alloc_ctrl(alloc_ctrl),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(alloc_ready),
        .i_rob_empty(rob_empty),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l1_complete), .i_lookup1_value(l1_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l2_complete), .i_lookup2_value(l2_value),
        .o_lookup3_tag(l3_tag), .i_lookup3_complete(l3_complete), .i_lookup3_value(l3_value),
        .o_frs1_sel(), .o_frs2_sel(), .o_frs3_sel(), .o_fpu_req(),
        .i_wb(wb), .o_alu_req(), .o_bru_req(), .o_lsu_req(), .o_lsu_opa(), .o_lsu_opb(), .i_lsu_free(1'b1),
        .o_div_req(), .i_div_free(1'b1),
        .i_commit_valid(pop), .i_commit_rd(head_entry.rd), .i_commit_rd_wen(head_entry.rd_wen),
        .i_commit_rd_fp(head_ctrl.rd_fp), .i_commit_tag(head_tag),
        .i_commit2_valid(pop2), .i_commit2_rd(head1_entry.rd), .i_commit2_rd_wen(head1_entry.rd_wen),
        .i_commit2_rd_fp(head1_ctrl.rd_fp), .i_commit2_tag(head1_tag),
        .i_uop1_valid(uop1_valid && !kill), .i_uop1(uop1), .o_issue2(issue2),
        .o_rs1b_sel(), .o_rs2b_sel(), .i_rs1b_data(64'b0), .i_rs2b_data(64'b0),
        .o_lookup4_tag(l4_tag), .i_lookup4_complete(l4_complete), .i_lookup4_value(l4_value),
        .o_lookup5_tag(l5_tag), .i_lookup5_complete(l5_complete), .i_lookup5_value(l5_value),
        .o_alloc2_valid(alloc2_valid), .o_alloc2_pc(alloc2_pc), .o_alloc2_raw(alloc2_raw), .o_alloc2_rd(alloc2_rd),
        .o_alloc2_rd_wen(alloc2_rd_wen), .o_alloc2_next_pc(alloc2_next_pc), .o_alloc2_ctrl(alloc2_ctrl),
        .i_alloc_tag1(alloc_tag1), .i_alloc_ready2(alloc_ready2),
        .o_src0_a(), .o_src0_b(), .o_src1_a(), .o_src1_b(),
        .o_alu1_req(), .i_wbp('0)
    );

    qv_rob #(.ROB_DEPTH(ROB_DEPTH)) rob0 (
        .clk(clk), .rst(rst), .i_flush(1'b0),
        .i_alloc_valid(alloc_valid), .i_alloc_pc(alloc_pc), .i_alloc_raw(alloc_raw),
        .i_alloc_rd(alloc_rd), .i_alloc_rd_wen(alloc_rd_wen), .i_alloc_next_pc(alloc_next_pc),
        .i_alloc_ctrl(alloc_ctrl),
        .o_alloc_tag(alloc_tag), .o_alloc_ready(alloc_ready),
        .o_empty(rob_empty),
        .i_alloc2_valid(alloc2_valid), .i_alloc2_pc(alloc2_pc), .i_alloc2_raw(alloc2_raw), .i_alloc2_rd(alloc2_rd),
        .i_alloc2_rd_wen(alloc2_rd_wen), .i_alloc2_next_pc(alloc2_next_pc), .i_alloc2_ctrl(alloc2_ctrl),
        .o_alloc_tag1(alloc_tag1), .o_alloc_ready2(alloc_ready2),
        .i_wb(wb), .i_wb2('0), .i_wb3('0),
        .i_lookup1_tag(l1_tag), .o_lookup1_complete(l1_complete), .o_lookup1_value(l1_value),
        .i_lookup2_tag(l2_tag), .o_lookup2_complete(l2_complete), .o_lookup2_value(l2_value),
        .i_lookup3_tag(l3_tag), .o_lookup3_complete(l3_complete), .o_lookup3_value(l3_value),
        .i_lookup4_tag(l4_tag), .o_lookup4_complete(l4_complete), .o_lookup4_value(l4_value),
        .i_lookup5_tag(l5_tag), .o_lookup5_complete(l5_complete), .o_lookup5_value(l5_value),
        .o_head_valid(head_valid), .o_head_entry(head_entry), .o_head_tag(head_tag),
        .o_head_ctrl(head_ctrl), .i_commit_pop(pop),
        .o_head1_valid(head1_valid), .o_head1_entry(head1_entry), .o_head1_tag(head1_tag),
        .o_head1_ctrl(head1_ctrl), .i_commit_pop2(pop2),
        .i_kill(kill), .i_kill_tag(kill_tag), .o_kill_vec(kill_vec),
        .o_surv_live(surv_live), .o_surv_tag(surv_tag), .o_surv_rd(surv_rd),
        .o_surv_int(surv_int), .o_surv_fp(surv_fp), .o_surv_csr(surv_csr),
        .o_kill_snap(kill_snap)
    );

    // ---- the contract ----
    wire [PTR_W-1:0] h = rob0.head_q;
    wire [PTR_W-1:0] t = rob0.tail_q;
    wire [PTR_W-1:0] count = t - h;
    function automatic logic live(input logic [QV_ROB_TAG_W-1:0] g);
        logic [PTR_W-1:0] p;
        p = g[PTR_W-1:0];
        return ((g >> PTR_W) == '0) && (PTR_W'(p - h) < count);
    endfunction
    wire [PTR_W-1:0] koff = PTR_W'(kill_tag[PTR_W-1:0] - h);        // the branch's distance from the head
    wire [1:0]       npop = {1'b0, pop} + {1'b0, pop2};
    always @* if (!rst) begin
        if (pop)  assume (head_valid && head_entry.complete);
        if (pop2) assume (head1_valid && head1_entry.complete);
        if (wb.valid) begin
            assume (live(wb.tag) && !rob0.complete_q[wb.tag[IDX_W-1:0]] && !wb.mispredict);
            if (kill) assume (!kill_vec[wb.tag]);
        end
        if (kill) begin
            assume (live(kill_tag));
            assume ({1'b0, koff} + 3'd1 >= {1'b0, npop});            // never below this cycle's last retirement
            if (pop2) assume (koff != '0);                            // a mispredicted head retires alone
        end
    end

    // ---- the properties: after every edge, the tables against the ROB ----
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @* if (init) assume (rst);

    logic                    d_busy  [0:31];
    logic [QV_ROB_TAG_W-1:0] d_tag   [0:31];
    logic                    d_late  [0:31];
    logic                    d_fbusy [0:31];
    logic [QV_ROB_TAG_W-1:0] d_ftag  [0:31];
    always @* begin
        for (int r = 0; r < 32; r++) begin
            d_busy[r] = 1'b0; d_tag[r] = '0; d_late[r] = 1'b0; d_fbusy[r] = 1'b0; d_ftag[r] = '0;
        end
        for (int o = 0; o < ROB_DEPTH; o++) begin
            logic [PTR_W-1:0] p;
            logic [IDX_W-1:0] x;
            rob_ctrl_t c;
            p = h + PTR_W'(o);
            x = p[IDX_W-1:0];
            c = rob0.ctrl_q[x];
            if (PTR_W'(o) < count) begin
                if (rob0.rd_wen_q[x] && !c.rd_fp && rob0.rd_q[x] != 5'd0) begin
                    d_busy[rob0.rd_q[x]] = 1'b1; d_tag[rob0.rd_q[x]] = QV_ROB_TAG_W'(p);
                    d_late[rob0.rd_q[x]] = (c.cls == QV_FU_CSR);
                end
                if (rob0.rd_wen_q[x] && c.rd_fp) begin
                    d_fbusy[rob0.rd_q[x]] = 1'b1; d_ftag[rob0.rd_q[x]] = QV_ROB_TAG_W'(p);
                end
            end
        end
    end
    always @* if (!rst && !init) begin
        for (int r = 0; r < 32; r++) begin
            assert (issue0.prod_busy_q[r] == d_busy[r]);
            if (d_busy[r]) assert (issue0.prod_tag_q[r] == d_tag[r] && issue0.prod_late_q[r] == d_late[r]);
            assert (issue0.fprod_busy_q[r] == d_fbusy[r]);
            if (d_fbusy[r]) assert (issue0.fprod_tag_q[r] == d_ftag[r]);
        end
    end

    // the ROB never holds more than its entries (an invariant of its own, stated for the induction)
    always @* if (!rst) assert (count <= PTR_W'(ROB_DEPTH));

    // the kill vector and the tail
    always @* if (!rst && kill)
        for (int g = 0; g < (1 << QV_ROB_TAG_W); g++)
            assert (kill_vec[g] == (live(QV_ROB_TAG_W'(g)) && (PTR_W'(PTR_W'(g) - h) > koff)));
    reg past_kill = 1'b0;
    reg [PTR_W-1:0] past_from = '0;
    always @(posedge clk) begin
        past_kill <= kill;
        past_from <= kill_tag[PTR_W-1:0] + PTR_W'(1);
    end
    always @* if (!rst && !init && past_kill) assert (t == past_from);

    // ---- covers ----
    always @* if (!rst) begin
        cover (kill && pop2);
        cover (kill && pop && koff == '0);
        cover (kill && kill_vec != '0 && count == 3'd4);
    end
endmodule
