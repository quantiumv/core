// SPDX-License-Identifier: MIT

`include "defaults/alu_ops.sv"

/*
 * qv_rebuild_tb -- (O3) issue's producer tables against their definition, through kills. Issue (two dispatches a
 * cycle, two ALU ports) + the ROB, with no units: the testbench completes entries, retires them (one or two a cycle,
 * from a complete head, as commit does) and kills (a recovery at execute: the branch is a random entry from this
 * cycle's last retirement up to the youngest; nothing dispatches in that cycle, and nothing killed is written back).
 *
 * After every edge both tables must equal their definition, computed from the ROB: a register is busy when an entry
 * in the ROB writes it, with the youngest such entry's tag, and (CSR_LATE) late when that entry is a CSR op. That
 * holds by the claims and the tag-matched clears in a cycle with no kill, and by the rebuild in a kill cycle.
 * Uops have no sources (they dispatch at once, one or two a cycle), random destinations among x0-x5 and f0-f5, and
 * some are CSR reads (which dispatch alone).
 *
 * Coverage (checked at the end): kills that drop a claim; kills that bring back an older producer of a register a
 * killed entry also wrote; kills in cycles with one and with two retirements; kills whose branch retires in that
 * cycle; kills that drop nothing; pairs dispatched.
 *
 * Run once per configuration via -P overrides (ROB_DEPTH, CSR_LATE, SEED, CYCLES).
 */
module qv_rebuild_tb #(
    parameter int ROB_DEPTH = 8,
    parameter bit CSR_LATE  = 1'b1,
    parameter int SEED      = 1,
    parameter int CYCLES    = 20000
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int IDX_W = $clog2(ROB_DEPTH);
    localparam int PTR_W = IDX_W + 1;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---------------- DUT: issue + ROB ----------------
    logic                    uop_valid = 1'b0, uop1_valid = 1'b0, issue, issue2;
    uop_t                    uop = '0, uop1 = '0;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic                    alloc2_valid, alloc2_rd_wen, alloc_ready2;
    logic [63:0]             alloc_pc, alloc_next_pc, alloc2_pc, alloc2_next_pc;
    logic [31:0]             alloc_raw, alloc2_raw;
    logic [4:0]              alloc_rd, alloc2_rd;
    rob_ctrl_t               alloc_ctrl, alloc2_ctrl, head_ctrl, head1_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, alloc_tag1, l1_tag, l2_tag, l3_tag, l4_tag, l5_tag, head_tag, head1_tag;
    logic                    l1_complete, l2_complete, l3_complete, l4_complete, l5_complete;
    logic [63:0]             l1_value, l2_value, l3_value, l4_value, l5_value;
    wb_t                     wb = '0;
    logic                    head_valid, head1_valid;
    rob_entry_t              head_entry, head1_entry;
    logic                    pop = 1'b0, pop2 = 1'b0;
    logic                    kill = 1'b0;
    logic [QV_ROB_TAG_W-1:0] kill_tag = '0;
    logic [(1<<QV_ROB_TAG_W)-1:0] kill_vec;
    logic [QV_ROB_DEPTH-1:0]                   surv_live, surv_int, surv_fp, surv_csr;
    logic [QV_ROB_DEPTH-1:0][QV_ROB_TAG_W-1:0] surv_tag;
    logic [QV_ROB_DEPTH-1:0][4:0]              surv_rd;

    qv_issue #(.CSR_LATE(CSR_LATE), .RS_DEPTH(0), .DISPATCH_W(2), .ALU_PORTS(2)) issue0 (
        .clk(clk), .rst(rst), .i_flush(1'b0), .i_kill_vec(kill_vec),
        .i_kill(kill), .i_surv_live(surv_live), .i_surv_tag(surv_tag), .i_surv_rd(surv_rd),
        .i_surv_int(surv_int), .i_surv_fp(surv_fp), .i_surv_csr(surv_csr),
        .i_uop_valid(uop_valid), .i_uop(uop), .o_issue(issue),
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
        .i_uop1_valid(uop1_valid), .i_uop1(uop1), .o_issue2(issue2),
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
        .o_surv_int(surv_int), .o_surv_fp(surv_fp), .o_surv_csr(surv_csr)
    );

    // ---------------- stimulus ----------------
    function automatic uop_t rnd_uop(input int n, input logic may_csr);
        uop_t u;
        u        = '0;
        u.fu     = QV_FU_ALU;
        u.alu_op = `ADD;
        u.raw    = {n[24:0], 7'b0110011};
        u.rd     = 5'($urandom_range(0, 5));
        u.rd_wen = $urandom_range(0, 9) != 0;
        u.rd_fp  = $urandom_range(0, 3) == 0;
        if (may_csr && !u.rd_fp && $urandom_range(0, 5) == 0) begin   // a CSR read: dispatches alone
            u.fu       = QV_FU_CSR;
            u.csr_op   = QV_CSR_RS;
            u.csr_addr = 12'h340;
            u.csr_wsup = 1'b1;
            u.raw      = {n[19:0], 5'd0, 7'b1110011};
        end
        return u;
    endfunction

    // what an entry (by its offset from the head) writes, read from the ROB
    function automatic logic [PTR_W-1:0] ptr_at(input int off);
        return rob0.head_q + PTR_W'(off);
    endfunction
    function automatic logic entry_complete(input int off);
        logic [PTR_W-1:0] p;
        p = ptr_at(off);
        return rob0.complete_q[p[IDX_W-1:0]];
    endfunction
    function automatic logic writes(input int off, input logic fp, input logic [4:0] r);
        logic [PTR_W-1:0] p;
        rob_ctrl_t c;
        p = ptr_at(off);
        c = rob0.ctrl_q[p[IDX_W-1:0]];
        return rob0.rd_wen_q[p[IDX_W-1:0]] && (rob0.rd_q[p[IDX_W-1:0]] == r) && (c.rd_fp == fp) && (fp || r != 5'd0);
    endfunction

    int n_kill = 0, n_kill_drop = 0, n_kill_restore = 0, n_kill_pop1 = 0, n_kill_pop2 = 0, n_kill_head = 0;
    int n_kill_none = 0, n_pair = 0, n_mism = 0, n_csr_late = 0;
    int n_uop = 0;
    int seed_v = SEED;

    initial begin
        void'($urandom(seed_v));
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        for (int cy = 0; cy < CYCLES; cy++) begin
            int count, npop, b_off, lo_off, c_hi;
            int cand [$];
            @(negedge clk);
            count = int'(PTR_W'(rob0.tail_q - rob0.head_q));
            // retirements: from a complete head, one or two
            npop = 0;
            if (count >= 1 && entry_complete(0) && $urandom_range(0, 2) != 0) begin
                npop = 1;
                if (count >= 2 && entry_complete(1) && $urandom_range(0, 1) != 0) npop = 2;
            end
            // a kill, some of the time: the branch from this cycle's last retirement up to the youngest entry
            kill = 1'b0;
            b_off = -1;
            if (count >= 1 && $urandom_range(0, 7) == 0) begin
                lo_off = (npop == 2) ? 1 : 0;
                b_off  = $urandom_range(lo_off, count - 1);
                if (b_off == 0 && npop == 2) npop = 1;      // a mispredicted head retires alone
                kill     = 1'b1;
                kill_tag = QV_ROB_TAG_W'(ptr_at(b_off));
            end
            pop  = (npop >= 1);
            pop2 = (npop == 2);
            // a completion of an entry that is not complete (in a kill cycle, one the kill leaves)
            c_hi = kill ? b_off : count - 1;
            cand.delete();
            for (int o = 0; o <= c_hi; o++) if (!entry_complete(o)) cand.push_back(o);
            wb = '0;
            if (cand.size() > 0 && $urandom_range(0, 3) != 0) begin
                wb.valid = 1'b1;
                wb.tag   = QV_ROB_TAG_W'(ptr_at(cand[$urandom_range(0, cand.size() - 1)]));
                wb.value = 64'(cy);
            end
            // dispatch, never in a kill cycle
            uop_valid  = !kill && $urandom_range(0, 3) != 0;
            uop1_valid = uop_valid && $urandom_range(0, 2) != 0;
            uop  = rnd_uop(n_uop, 1'b1);
            uop1 = rnd_uop(n_uop + 1, 1'b0);
            n_uop += 2;
            // coverage, from the ROB as it is before the edge
            if (kill) begin
                logic dropped, restored;
                n_kill++;
                if (npop == 1) n_kill_pop1++;
                if (npop == 2) n_kill_pop2++;
                if (b_off < npop) n_kill_head++;
                if (b_off == count - 1) n_kill_none++;
                dropped = 1'b0; restored = 1'b0;
                for (int f = 0; f < 2; f++)
                    for (int r = 0; r < 6; r++) begin
                        logic killed_w, surv_w;
                        killed_w = 1'b0; surv_w = 1'b0;
                        for (int o = b_off + 1; o < count; o++) if (writes(o, f[0], 5'(r))) killed_w = 1'b1;
                        for (int o = npop; o <= b_off; o++)     if (writes(o, f[0], 5'(r))) surv_w = 1'b1;
                        if (killed_w) dropped = 1'b1;
                        if (killed_w && surv_w) restored = 1'b1;
                    end
                if (dropped)  n_kill_drop++;
                if (restored) n_kill_restore++;
            end
            #1;
            if (issue2) n_pair++;
            if (kill && (issue || issue2)) begin
                $display("cycle %0d: a dispatch in a kill cycle", cy);
                n_mism++;
            end
        end
        @(negedge clk);
        kill = 1'b0; uop_valid = 1'b0; uop1_valid = 1'b0; pop = 1'b0; pop2 = 1'b0; wb = '0;
        repeat (2) @(posedge clk);

        check("the tables equal their definition after every edge", 64'(n_mism), 64'd0);
        $display("qv_rebuild_tb: %0d kills (%0d drop a claim, %0d bring back an older producer, %0d with one and %0d with two retirements, %0d whose branch retires, %0d drop nothing), %0d pairs, %0d late claims seen",
                 n_kill, n_kill_drop, n_kill_restore, n_kill_pop1, n_kill_pop2, n_kill_head, n_kill_none, n_pair,
                 n_csr_late);
        check("coverage: kills that drop a claim", 64'(n_kill_drop > CYCLES / 200), 64'd1);
        // (a ROB of 2 holds such an older producer only when the branch is the head and nothing retires)
        check("coverage: kills that bring back an older producer",
              64'(n_kill_restore > ((ROB_DEPTH > 2) ? CYCLES / 400 : CYCLES / 2000)), 64'd1);
        check("coverage: kills with one retirement", 64'(n_kill_pop1 > CYCLES / 400), 64'd1);
        check("coverage: kills with two retirements", 64'(n_kill_pop2 > CYCLES / 1000), 64'd1);
        check("coverage: kills whose branch retires", 64'(n_kill_head > CYCLES / 1000), 64'd1);
        check("coverage: kills that drop nothing", 64'(n_kill_none > CYCLES / 1000), 64'd1);
        check("coverage: pairs", 64'(n_pair > CYCLES / 20), 64'd1);
        if (CSR_LATE) check("coverage: late claims", 64'(n_csr_late > CYCLES / 200), 64'd1);
        $display("");
        $display("qv_rebuild_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_rebuild_tb: FAILURES PRESENT");
        $finish;
    end

    // ---------------- the check: after every edge, the tables against their definition ----------------
    always @(posedge clk) if (!rst) begin
        logic             eb [0:31], fb [0:31], el [0:31];
        logic [QV_ROB_TAG_W-1:0] et [0:31], ft [0:31];
        int count;
        #2;
        for (int r = 0; r < 32; r++) begin eb[r] = 1'b0; fb[r] = 1'b0; el[r] = 1'b0; et[r] = '0; ft[r] = '0; end
        count = int'(PTR_W'(rob0.tail_q - rob0.head_q));
        for (int o = 0; o < count; o++) begin
            logic [PTR_W-1:0] p;
            rob_ctrl_t c;
            logic [4:0] rd;
            p  = ptr_at(o);
            c  = rob0.ctrl_q[p[IDX_W-1:0]];
            rd = rob0.rd_q[p[IDX_W-1:0]];
            if (rob0.rd_wen_q[p[IDX_W-1:0]] && !c.rd_fp && rd != 5'd0) begin
                eb[rd] = 1'b1; et[rd] = QV_ROB_TAG_W'(p); el[rd] = CSR_LATE && (c.cls == QV_FU_CSR);
            end
            if (rob0.rd_wen_q[p[IDX_W-1:0]] && c.rd_fp) begin
                fb[rd] = 1'b1; ft[rd] = QV_ROB_TAG_W'(p);
            end
        end
        for (int r = 0; r < 32; r++) begin
            logic bad;
            bad = (issue0.prod_busy_q[r] !== eb[r]) || (fb[r] !== issue0.fprod_busy_q[r])
                  || (eb[r] && ((issue0.prod_tag_q[r] !== et[r]) || (issue0.prod_late_q[r] !== el[r])))
                  || (fb[r] && (issue0.fprod_tag_q[r] !== ft[r]));
            if (eb[r] && el[r]) n_csr_late++;
            if (bad) begin
                if (n_mism < 10)
                    $display("%0t: r%0d: table int %b/%0d/%b fp %b/%0d, definition int %b/%0d/%b fp %b/%0d", $time, r,
                             issue0.prod_busy_q[r], issue0.prod_tag_q[r], issue0.prod_late_q[r],
                             issue0.fprod_busy_q[r], issue0.fprod_tag_q[r], eb[r], et[r], el[r], fb[r], ft[r]);
                n_mism++;
            end
        end
    end

    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
