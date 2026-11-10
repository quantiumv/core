// SPDX-License-Identifier: MIT

`include "defaults/alu_ops.sv"

/*
 * qv_dispatch2_tb -- two dispatches a cycle (O4c). Issue at DISPATCH_W 2 + ROB (two allocations) + one ALU + commit
 * (COMMIT_W 1 or 2) + regfile0 (read ports C/D for slot 1), driven with uops directly, two at a time (slot 0 is the
 * next uop of the script, slot 1 the one behind it), checked against a sequential golden model at every retirement
 * (both RVFI channels) and on the final register file.
 *
 * Covers what an end-to-end comparison can't observe directly:
 *   - the pair rules, as a combinational probe: three more issue instances held in reset (empty producer tables,
 *     empty station) whose o_issue/o_issue2 and unit requests are read for chosen uop pairs: which pairs dispatch
 *     together, which uop dispatches alone (in either slot), one memory op and one FP-touching uop per pair, where
 *     slot 1 goes (its own unit, the station, the queue), a slot-1 source that is slot 0's destination (never ready,
 *     slot 0's tag, never late; only in the table of that source), the ROB, the Program Buffer and SERIALIZE;
 *   - an intra-pair dependence: the pair dispatches in one cycle, slot 1 waits in the station and reaches the ALU the
 *     cycle after slot 0 (with bypass; two without);
 *   - a register both slots write, then a reader (slot 1's claim is the one that stays), across bubble lengths;
 *   - a stale `late` bit (a CSR read wrote the register earlier): the intra-pair operand is never late;
 *   - a long random dense-hazard stream with random bubbles (CSR reads among it with CSR_LATE).
 *
 * One ALU port: two ALU uops pair only through the station (RS_DEPTH > 0); with RS_DEPTH 0 the clocked part runs
 * one-wide and must say so (no pair), while the probes still check the rules.
 *
 * Run once per configuration via -P overrides (BYPASS_EN, ROB_DEPTH, RS_DEPTH, CSR_LATE, COMMIT_W, SEED).
 */
module qv_dispatch2_tb #(
    parameter bit BYPASS_EN = 1'b1,
    parameter int ROB_DEPTH = 8,
    parameter int RS_DEPTH  = 4,
    parameter bit CSR_LATE  = 1'b0,
    parameter int COMMIT_W  = 1,
    parameter int SEED      = 1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    localparam logic [63:0] CSR_VAL = 64'hC5C5_0000_1234_ABCD;

    // ---------------- DUT backend ----------------
    logic                    uop_valid, uop1_valid, issue, issue2;
    uop_t                    uop, uop1;
    logic [4:0]              rs1_sel, rs2_sel, rs1b_sel, rs2b_sel;
    logic [63:0]             rs1_data, rs2_data, rs1b_data, rs2b_data;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic                    alloc2_valid, alloc2_rd_wen, alloc_ready2;
    logic [63:0]             alloc_pc, alloc_next_pc, alloc2_pc, alloc2_next_pc;
    logic [31:0]             alloc_raw, alloc2_raw;
    logic [4:0]              alloc_rd, alloc2_rd;
    rob_ctrl_t               alloc_ctrl, alloc2_ctrl, head_ctrl, head1_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, alloc_tag1, l1_tag, l2_tag, l4_tag, l5_tag, head_tag, head1_tag, c_tag, c2_tag;
    logic                    l1_complete, l2_complete, l4_complete, l5_complete;
    logic [63:0]             l1_value, l2_value, l4_value, l5_value;
    wb_t                     wb;
    fu_req_t                 fu_req;
    logic                    head_valid, head1_valid, commit_pop, commit_pop2;
    rob_entry_t              head_entry, head1_entry;
    logic                    rf_we, rf2_we, c_valid, c_rd_wen, c2_valid, c2_rd_wen, c2_rd_fp, commit_now;
    logic [4:0]              rf_sel, rf2_sel, c_rd, c2_rd;
    logic [63:0]             rf_data, rf2_data, arch_pc, next_pc;
    logic [63:0]             r_order, r_rd_wdata, r_pc_rdata, r_pc_wdata;
    logic [31:0]             r_insn;
    logic                    r_intr;
    logic [4:0]              r_rs1_addr, r_rs2_addr, r_rd_addr;
    logic [63:0]             r1_order, r1_rd_wdata, r1_pc_rdata, r1_pc_wdata;
    logic [31:0]             r1_insn;
    logic [4:0]              r1_rs1_addr, r1_rs2_addr, r1_rd_addr;

    wb_t c_bus;                           // commit's regfile write and tag: wakes the station's late operands
    always_comb begin
        c_bus       = '0;
        c_bus.valid = rf_we;
        c_bus.tag   = c_tag;
        c_bus.value = rf_data;
    end

    qv_issue #(.BYPASS_EN(BYPASS_EN), .CSR_LATE(CSR_LATE), .RS_DEPTH(RS_DEPTH), .DISPATCH_W(2)) issue0 (
        .clk(clk), .rst(rst), .i_flush(1'b0),
        .i_uop_valid(uop_valid), .i_uop(uop), .o_issue(issue),
        .o_rs1_sel(rs1_sel), .o_rs2_sel(rs2_sel), .i_rs1_data(rs1_data), .i_rs2_data(rs2_data),
        .o_alloc_valid(alloc_valid), .o_alloc_pc(alloc_pc), .o_alloc_raw(alloc_raw),
        .o_alloc_rd(alloc_rd), .o_alloc_rd_wen(alloc_rd_wen), .o_alloc_next_pc(alloc_next_pc),
        .o_alloc_ctrl(alloc_ctrl),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(alloc_ready),
        .i_rob_empty(rob_empty),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l1_complete), .i_lookup1_value(l1_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l2_complete), .i_lookup2_value(l2_value),
        .o_lookup3_tag(), .o_frs1_sel(), .o_frs2_sel(), .o_frs3_sel(), .o_fpu_req(),
        .i_wb(wb), .o_alu_req(fu_req), .o_bru_req(), .o_lsu_req(), .o_lsu_opa(), .o_lsu_opb(), .i_lsu_free(1'b1),
        .o_div_req(), .i_div_free(1'b1),
        .i_commit_valid(c_valid), .i_commit_rd(c_rd), .i_commit_rd_wen(c_rd_wen), .i_commit_tag(c_tag),
        .i_commit2_valid(c2_valid), .i_commit2_rd(c2_rd), .i_commit2_rd_wen(c2_rd_wen), .i_commit2_rd_fp(c2_rd_fp),
        .i_commit2_tag(c2_tag),
        .i_wbc(c_bus),
        .i_uop1_valid(uop1_valid), .i_uop1(uop1), .o_issue2(issue2),
        .o_rs1b_sel(rs1b_sel), .o_rs2b_sel(rs2b_sel), .i_rs1b_data(rs1b_data), .i_rs2b_data(rs2b_data),
        .o_lookup4_tag(l4_tag), .i_lookup4_complete(l4_complete), .i_lookup4_value(l4_value),
        .o_lookup5_tag(l5_tag), .i_lookup5_complete(l5_complete), .i_lookup5_value(l5_value),
        .o_alloc2_valid(alloc2_valid), .o_alloc2_pc(alloc2_pc), .o_alloc2_raw(alloc2_raw), .o_alloc2_rd(alloc2_rd),
        .o_alloc2_rd_wen(alloc2_rd_wen), .o_alloc2_next_pc(alloc2_next_pc), .o_alloc2_ctrl(alloc2_ctrl),
        .i_alloc_tag1(alloc_tag1), .i_alloc_ready2(alloc_ready2),
        .o_src0_a(), .o_src0_b(), .o_src1_a(), .o_src1_b()
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
        .i_lookup4_tag(l4_tag), .o_lookup4_complete(l4_complete), .o_lookup4_value(l4_value),
        .i_lookup5_tag(l5_tag), .o_lookup5_complete(l5_complete), .o_lookup5_value(l5_value),
        .o_head_valid(head_valid), .o_head_entry(head_entry), .o_head_tag(head_tag),
        .o_head_ctrl(head_ctrl), .i_commit_pop(commit_pop),
        .o_head1_valid(head1_valid), .o_head1_entry(head1_entry), .o_head1_tag(head1_tag),
        .o_head1_ctrl(head1_ctrl), .i_commit_pop2(commit_pop2)
    );

    qv_exu_alu exu0 (.clk(clk), .rst(rst), .i_flush(1'b0), .i_req(fu_req), .o_wb(wb));

    qv_commit #(.COMMIT_W(COMMIT_W)) commit0 (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(head_entry), .i_head_tag(head_tag),
        .i_head_ctrl(head_ctrl), .i_lsu_res('0), .o_commit_pop(commit_pop),
        .i_head1_valid(head1_valid), .i_head1_entry(head1_entry), .i_head1_tag(head1_tag),
        .i_head1_ctrl(head1_ctrl), .o_commit_pop2(commit_pop2),
        // no trap or mret ever reaches commit here; a CSR op (CSR_LATE only, read-only, not serializing) reads CSR_VAL
        .i_csr_rdata(CSR_VAL), .i_mtvec(64'b0), .i_mepc(64'b0), .i_fetch_idle(1'b1),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_regfile2_we(rf2_we), .o_regfile2_sel(rf2_sel), .o_regfile2_data(rf2_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_commit2_valid(c2_valid), .o_commit2_rd(c2_rd), .o_commit2_rd_wen(c2_rd_wen), .o_commit2_rd_fp(c2_rd_fp),
        .o_commit2_tag(c2_tag),
        .o_commit_now(commit_now), .o_pc(arch_pc), .o_next_pc(next_pc),
        .o_rvfi_order(r_order), .o_rvfi_insn(r_insn), .o_rvfi_intr(r_intr),
        .o_rvfi_rs1_addr(r_rs1_addr), .o_rvfi_rs2_addr(r_rs2_addr),
        .o_rvfi_rd_addr(r_rd_addr), .o_rvfi_rd_wdata(r_rd_wdata),
        .o_rvfi_pc_rdata(r_pc_rdata), .o_rvfi_pc_wdata(r_pc_wdata),
        .o_rvfi1_order(r1_order), .o_rvfi1_insn(r1_insn),
        .o_rvfi1_rs1_addr(r1_rs1_addr), .o_rvfi1_rs2_addr(r1_rs2_addr),
        .o_rvfi1_rd_addr(r1_rd_addr), .o_rvfi1_rd_wdata(r1_rd_wdata),
        .o_rvfi1_pc_rdata(r1_pc_rdata), .o_rvfi1_pc_wdata(r1_pc_wdata)
    );

    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(rs1_sel), .o_read_gpr_A_data(rs1_data),
        .i_read_gpr_B_sel(rs2_sel), .o_read_gpr_B_data(rs2_data),
        .i_read_gpr_C_sel(rs1b_sel), .o_read_gpr_C_data(rs1b_data),
        .i_read_gpr_D_sel(rs2b_sel), .o_read_gpr_D_data(rs2b_data),
        .i_load_gpr(rf_we), .i_load_gpr_sel(rf_sel), .i_load_gpr_data(rf_data),
        .i_load2_gpr(rf2_we), .i_load2_gpr_sel(rf2_sel), .i_load2_gpr_data(rf2_data)
    );

    // ---------------- golden model ----------------
    function automatic logic [63:0] golden_alu(input logic [4:0] op, input logic [63:0] a, input logic [63:0] b);
        case (op)
            `ADD:  return a + b;
            `SUB:  return a - b;
            `SLT:  return 64'($signed(a) < $signed(b));
            `SLTU: return 64'(a < b);
            `XOR:  return a ^ b;
            `OR:   return a | b;
            `AND:  return a & b;
            `SLL:  return a << b[5:0];
            `SRL:  return a >> b[5:0];
            `SRA:  return 64'($signed(a) >>> b[5:0]);
            default: return 64'hBAD;
        endcase
    endfunction

    localparam int MAXN = 2048;
    uop_t        script     [0:MAXN];
    int          bubble     [0:MAXN];     // idle cycles before presenting this uop (as slot 0; >0 also keeps it out of slot 1)
    logic [63:0] exp_wdata  [0:MAXN-1];
    logic [4:0]  exp_rs1    [0:MAXN-1];   // RVFI's source registers (0 when unused) and their values in program order
    logic [4:0]  exp_rs2    [0:MAXN-1];
    logic [63:0] exp_rs1_v  [0:MAXN-1];
    logic [63:0] exp_rs2_v  [0:MAXN-1];
    logic [63:0] issue_cyc  [0:MAXN-1];   // dispatch (ROB allocation)
    logic [63:0] exec_cyc   [0:MAXN-1];   // the request to the ALU
    logic [63:0] G [0:31];                // golden regfile
    int n_uops;

    // raw: the uop's index above an OP opcode (never FENCE, never atomic, no control kind)
    function automatic logic [31:0] raw_of(input int n);
        return {n[24:0], 7'b0110011};
    endfunction

    function automatic uop_t mk(input logic [4:0] op, input logic [4:0] rd,
                                input logic [4:0] rs1, input logic rs1_used, input logic [63:0] imm1,
                                input logic [4:0] rs2, input logic rs2_used, input logic [63:0] imm2);
        uop_t u;
        u          = '0;
        u.fu       = QV_FU_ALU;
        u.alu_op   = op;
        u.rd       = rd;
        u.rd_wen   = 1'b1;
        u.rs1      = rs1_used ? rs1 : 5'd0;
        u.rs1_used = rs1_used && rs1 != 5'd0;
        u.imm1     = (rs1_used && rs1 != 5'd0) ? 64'd0 : imm1;
        u.rs2      = rs2_used ? rs2 : 5'd0;
        u.rs2_used = rs2_used && rs2 != 5'd0;
        u.imm2     = (rs2_used && rs2 != 5'd0) ? 64'd0 : imm2;
        return u;
    endfunction

    // a CSR read (csrrs rd, csr, x0) that does not serialize: through the ALU as its source + 0, rd made at commit
    function automatic uop_t mk_csrr(input logic [4:0] rd);
        uop_t u;
        u          = '0;
        u.fu       = QV_FU_CSR;
        u.alu_op   = `ADD;
        u.rd       = rd;
        u.rd_wen   = 1'b1;
        u.csr_op   = QV_CSR_RS;
        u.csr_addr = 12'h340;
        u.csr_wsup = 1'b1;
        return u;
    endfunction

    task automatic push(input uop_t u_in, input int bub);
        uop_t u;
        logic [63:0] a, b, y;
        u     = u_in;
        u.pc  = 64'(4 * n_uops);
        u.raw = raw_of(n_uops);
        a = u.rs1_used ? G[u.rs1] : u.imm1;
        b = u.rs2_used ? G[u.rs2] : u.imm2;
        y = golden_alu(u.alu_op, a, b);
        if (u.is_word) y = {{32{y[31]}}, y[31:0]};
        if (u.fu == QV_FU_CSR) y = CSR_VAL;                 // a read: rd is the CSR's value
        exp_rs1[n_uops]   = u.rs1;
        exp_rs2[n_uops]   = u.rs2;
        exp_rs1_v[n_uops] = u.rs1_used ? G[u.rs1] : 64'd0;
        exp_rs2_v[n_uops] = u.rs2_used ? G[u.rs2] : 64'd0;
        if (u.rd_wen && u.rd != 0) G[u.rd] = y;
        exp_wdata[n_uops] = (u.rd_wen && u.rd != 0) ? y : 64'd0;
        script[n_uops]    = u;
        bubble[n_uops]    = bub;
        n_uops++;
        script[n_uops]    = '0;
        bubble[n_uops]    = 1;
    endtask

    // ---------------- driver: slot 0 = script[k], slot 1 = script[k + 1] ----------------
    int  k, bub_left, n_pairs, n_cpairs;
    logic run_en = 1'b0;
    always_comb begin
        uop        = script[k];
        uop_valid  = run_en && (k < n_uops) && (bub_left == 0);
        uop1       = script[k + 1];
        uop1_valid = uop_valid && (k + 1 < n_uops) && (bubble[k + 1] == 0);
    end
    always @(posedge clk) begin
        if (rst || !run_en) begin
        end else if (uop_valid && issue) begin
            issue_cyc[k] <= cyc;
            if (issue2) begin
                issue_cyc[k + 1] <= cyc;
                k        <= k + 2;
                bub_left <= (k + 2 < n_uops) ? bubble[k + 2] : 0;
                n_pairs  <= n_pairs + 1;
            end else begin
                k        <= k + 1;
                bub_left <= (k + 1 < n_uops) ? bubble[k + 1] : 0;
            end
        end else if (bub_left > 0) begin
            bub_left <= bub_left - 1;
        end
    end

    // the rules the clocked instance must keep, every cycle
    int rule_errs;
    always @(posedge clk) begin
        if (!rst && run_en) begin
            if (issue2 && !(uop_valid && issue && uop1_valid)) begin
                rule_errs++;
                $display("RULE: o_issue2 without slot 0 dispatching and a valid slot 1 (cyc %0d)", cyc);
            end
            if (issue2 && (uop.fu == QV_FU_CSR || uop1.fu == QV_FU_CSR)) begin
                rule_errs++;
                $display("RULE: a CSR op dispatched in a pair (cyc %0d)", cyc);
            end
            if (alloc2_valid != issue2) begin
                rule_errs++;
                $display("RULE: the second allocation is not o_issue2 (cyc %0d)", cyc);
            end
            if (issue2 && !alloc_ready2) begin
                rule_errs++;
                $display("RULE: a pair dispatched without ROB room for two (cyc %0d)", cyc);
            end
        end
    end

    // where each uop reaches the ALU: its ROB tag (taken at dispatch) names it
    int idx_of_tag [0:(1 << QV_ROB_TAG_W) - 1];
    always @(posedge clk) begin
        if (!rst && run_en) begin
            if (uop_valid && issue) idx_of_tag[alloc_tag] <= k;
            if (uop_valid && issue && issue2) idx_of_tag[alloc_tag1] <= k + 1;
            if (fu_req.valid)                                   // (sent straight on: dispatched this very cycle)
                exec_cyc[(uop_valid && issue && fu_req.tag == alloc_tag) ? k
                         : (uop_valid && issue && issue2 && fu_req.tag == alloc_tag1) ? k + 1
                         : idx_of_tag[fu_req.tag]] <= cyc;
        end
    end

    // ---------------- retirement checker (both channels) ----------------
    // The source values a retirement saw: regfile0 at its source registers in the commit cycle (before the edge
    // writes this cycle's results), and for channel 1 also channel 0's write (it is older).
    function automatic logic [63:0] rf_val(input logic [4:0] a);
        return (a == 5'd0) ? 64'd0 : regfile0.gp_registers[a];
    endfunction
    function automatic logic [63:0] rf_val1(input logic [4:0] a);
        return (a != 5'd0 && rf_we && rf_sel == a) ? rf_data : rf_val(a);
    endfunction
    int n_ret, ret_errs;
    always @(posedge clk) begin
        if (!rst && run_en) begin
            if (commit_pop2 && !commit_now) begin
                ret_errs++;
                $display("RETIRE: a second retirement without the first (cyc %0d)", cyc);
            end
            if (commit_now) begin
                if (r_order != 64'(n_ret) || r_pc_rdata != 64'(4 * n_ret) || r_insn != raw_of(n_ret)
                        || r_rd_wdata != exp_wdata[n_ret] || r_pc_wdata != 64'(4 * n_ret + 4)
                        || r_rs1_addr != exp_rs1[n_ret] || r_rs2_addr != exp_rs2[n_ret]
                        || rf_val(r_rs1_addr) != exp_rs1_v[n_ret] || rf_val(r_rs2_addr) != exp_rs2_v[n_ret]) begin
                    ret_errs++;
                    if (ret_errs <= 5)
                        $display("RETIRE MISMATCH ch0 #%0d: order=%0d pc=%h insn=%h rd_wdata=%h (exp %h) rs1 x%0d=%h (exp x%0d=%h) rs2 x%0d=%h (exp x%0d=%h)",
                                 n_ret, r_order, r_pc_rdata, r_insn, r_rd_wdata, exp_wdata[n_ret],
                                 r_rs1_addr, rf_val(r_rs1_addr), exp_rs1[n_ret], exp_rs1_v[n_ret],
                                 r_rs2_addr, rf_val(r_rs2_addr), exp_rs2[n_ret], exp_rs2_v[n_ret]);
                end
                if (commit_pop2) begin
                    if (r1_order != 64'(n_ret + 1) || r1_pc_rdata != 64'(4 * (n_ret + 1)) || r1_insn != raw_of(n_ret + 1)
                            || r1_rd_wdata != exp_wdata[n_ret + 1] || r1_pc_wdata != 64'(4 * (n_ret + 1) + 4)
                            || r1_rs1_addr != exp_rs1[n_ret + 1] || r1_rs2_addr != exp_rs2[n_ret + 1]
                            || rf_val1(r1_rs1_addr) != exp_rs1_v[n_ret + 1]
                            || rf_val1(r1_rs2_addr) != exp_rs2_v[n_ret + 1]) begin
                        ret_errs++;
                        if (ret_errs <= 5)
                            $display("RETIRE MISMATCH ch1 #%0d: order=%0d pc=%h insn=%h rd_wdata=%h (exp %h)",
                                     n_ret + 1, r1_order, r1_pc_rdata, r1_insn, r1_rd_wdata, exp_wdata[n_ret + 1]);
                    end
                    n_ret    <= n_ret + 2;
                    n_cpairs <= n_cpairs + 1;
                end else
                    n_ret <= n_ret + 1;
            end
        end
    end

    task automatic begin_script();
        n_uops = 0;
        script[0] = '0;
        bubble[0] = 1;
        for (int r = 0; r < 32; r++) G[r] = 64'd0;
    endtask

    task automatic run_script(input string tag, input int max_cycles);
        int c;
        run_en = 1'b0;
        rst    = 1'b1;
        @(posedge clk); @(posedge clk);
        #1;
        // register_file.sv has no reset of its own; start every script
        // from the same all-zero architectural state the golden model does
        for (int r = 0; r < 32; r++) regfile0.gp_registers[r] = 64'd0;
        k         = 0;
        bub_left  = (n_uops > 0) ? bubble[0] : 0;
        n_ret     = 0;
        ret_errs  = 0;
        rule_errs = 0;
        n_pairs   = 0;
        n_cpairs  = 0;
        rst       = 1'b0;
        run_en    = 1'b1;
        c = 0;
        while (n_ret < n_uops && c < max_cycles) begin
            @(posedge clk);
            c++;
        end
        repeat (3) @(posedge clk);
        #1;
        check({tag, ": all uops retired"}, 64'(n_ret), 64'(n_uops));
        check({tag, ": no extra retirements"}, 64'(n_ret == n_uops), 64'd1);
        check({tag, ": every retirement matched"}, 64'(ret_errs), 64'd0);
        check({tag, ": the pair rules held every cycle"}, 64'(rule_errs), 64'd0);
        for (int r = 1; r < 32; r++)
            check($sformatf("%s: final x%0d", tag, r), regfile0.gp_registers[r], G[r]);
        check({tag, ": ROB drained"}, {63'b0, rob_empty}, 64'd1);
        for (int r = 0; r < 32; r++)
            check($sformatf("%s: no claim left on x%0d", tag, r), {63'b0, issue0.prod_busy_q[r]}, 64'd0);
        if (COMMIT_W == 1)
            check({tag, ": one-wide commit never retires two"}, 64'(n_cpairs), 64'd0);
        run_en = 1'b0;
    endtask

    // ---------------- the pair-rule probes ----------------
    // Held in reset: empty producer tables and an empty station, so every source is ready from the register file
    // and nothing is in the way but the rules. pr: a station of 4 and the queue's waiting (LSQ_WAIT); pr0: neither;
    // prs: a SERIALIZE build.
    uop_t    p_u0, p_u1;
    logic    p_v1, p_ready, p_ready2, p_pb, p_lsu_free;
    logic    pr_issue, pr_issue2, pr0_issue, pr0_issue2, prs_issue, prs_issue2;
    fu_req_t pr_alu, pr_bru, pr_lsu, pr_div, pr0_alu, pr0_bru, pr0_lsu;
    fpu_req_t pr_fpu, pr0_fpu;
    rs_opnd_t pr_lsu_opa, pr_lsu_opb;
    logic [4:0] pr_frs1;

    qv_issue #(.BYPASS_EN(1'b1), .RS_DEPTH(4), .LSQ_WAIT(1'b1), .DISPATCH_W(2)) pr (
        .clk(clk), .rst(1'b1), .i_flush(1'b0),
        .i_uop_valid(1'b1), .i_uop(p_u0), .o_issue(pr_issue),
        .o_rs1_sel(), .o_rs2_sel(), .i_rs1_data(64'd0), .i_rs2_data(64'd0),
        .o_alloc_valid(), .o_alloc_pc(), .o_alloc_raw(), .o_alloc_rd(), .o_alloc_rd_wen(), .o_alloc_next_pc(),
        .o_alloc_ctrl(), .i_alloc_tag(QV_ROB_TAG_W'(1)), .i_alloc_ready(p_ready), .i_rob_empty(1'b1),
        .o_lookup1_tag(), .i_lookup1_complete(1'b0), .i_lookup1_value(64'd0),
        .o_lookup2_tag(), .i_lookup2_complete(1'b0), .i_lookup2_value(64'd0),
        .o_lookup3_tag(), .o_frs1_sel(pr_frs1), .o_frs2_sel(), .o_frs3_sel(), .o_fpu_req(pr_fpu),
        .i_wb('0), .o_alu_req(pr_alu), .o_bru_req(pr_bru), .o_lsu_req(pr_lsu), .o_lsu_opa(pr_lsu_opa),
        .o_lsu_opb(pr_lsu_opb), .i_lsu_free(p_lsu_free), .o_div_req(pr_div), .i_div_free(1'b1),
        .i_commit_valid(1'b0), .i_commit_rd(5'd0), .i_commit_rd_wen(1'b0), .i_commit_tag('0),
        .i_uop1_valid(p_v1), .i_uop1(p_u1), .i_pb_active(p_pb), .o_issue2(pr_issue2),
        .o_rs1b_sel(), .o_rs2b_sel(), .o_lookup4_tag(), .o_lookup5_tag(),
        .o_alloc2_valid(), .o_alloc2_pc(), .o_alloc2_raw(), .o_alloc2_rd(), .o_alloc2_rd_wen(), .o_alloc2_next_pc(),
        .o_alloc2_ctrl(), .i_alloc_tag1(QV_ROB_TAG_W'(2)), .i_alloc_ready2(p_ready2),
        .o_src0_a(), .o_src0_b(), .o_src1_a(), .o_src1_b()
    );
    qv_issue #(.BYPASS_EN(1'b1), .RS_DEPTH(0), .LSQ_WAIT(1'b0), .DISPATCH_W(2)) pr0 (
        .clk(clk), .rst(1'b1), .i_flush(1'b0),
        .i_uop_valid(1'b1), .i_uop(p_u0), .o_issue(pr0_issue),
        .o_rs1_sel(), .o_rs2_sel(), .i_rs1_data(64'd0), .i_rs2_data(64'd0),
        .o_alloc_valid(), .o_alloc_pc(), .o_alloc_raw(), .o_alloc_rd(), .o_alloc_rd_wen(), .o_alloc_next_pc(),
        .o_alloc_ctrl(), .i_alloc_tag(QV_ROB_TAG_W'(1)), .i_alloc_ready(p_ready), .i_rob_empty(1'b1),
        .o_lookup1_tag(), .i_lookup1_complete(1'b0), .i_lookup1_value(64'd0),
        .o_lookup2_tag(), .i_lookup2_complete(1'b0), .i_lookup2_value(64'd0),
        .o_lookup3_tag(), .o_frs1_sel(), .o_frs2_sel(), .o_frs3_sel(), .o_fpu_req(pr0_fpu),
        .i_wb('0), .o_alu_req(pr0_alu), .o_bru_req(pr0_bru), .o_lsu_req(pr0_lsu), .o_lsu_opa(), .o_lsu_opb(),
        .i_lsu_free(p_lsu_free), .o_div_req(), .i_div_free(1'b1),
        .i_commit_valid(1'b0), .i_commit_rd(5'd0), .i_commit_rd_wen(1'b0), .i_commit_tag('0),
        .i_uop1_valid(p_v1), .i_uop1(p_u1), .i_pb_active(p_pb), .o_issue2(pr0_issue2),
        .o_rs1b_sel(), .o_rs2b_sel(), .o_lookup4_tag(), .o_lookup5_tag(),
        .o_alloc2_valid(), .o_alloc2_pc(), .o_alloc2_raw(), .o_alloc2_rd(), .o_alloc2_rd_wen(), .o_alloc2_next_pc(),
        .o_alloc2_ctrl(), .i_alloc_tag1(QV_ROB_TAG_W'(2)), .i_alloc_ready2(p_ready2),
        .o_src0_a(), .o_src0_b(), .o_src1_a(), .o_src1_b()
    );
    qv_issue #(.SERIALIZE(1'b1), .BYPASS_EN(1'b1), .RS_DEPTH(4), .DISPATCH_W(2)) prs (
        .clk(clk), .rst(1'b1), .i_flush(1'b0),
        .i_uop_valid(1'b1), .i_uop(p_u0), .o_issue(prs_issue),
        .o_rs1_sel(), .o_rs2_sel(), .i_rs1_data(64'd0), .i_rs2_data(64'd0),
        .o_alloc_valid(), .o_alloc_pc(), .o_alloc_raw(), .o_alloc_rd(), .o_alloc_rd_wen(), .o_alloc_next_pc(),
        .o_alloc_ctrl(), .i_alloc_tag(QV_ROB_TAG_W'(1)), .i_alloc_ready(p_ready), .i_rob_empty(1'b1),
        .o_lookup1_tag(), .i_lookup1_complete(1'b0), .i_lookup1_value(64'd0),
        .o_lookup2_tag(), .i_lookup2_complete(1'b0), .i_lookup2_value(64'd0),
        .o_lookup3_tag(), .o_frs1_sel(), .o_frs2_sel(), .o_frs3_sel(), .o_fpu_req(),
        .i_wb('0), .o_alu_req(), .o_bru_req(), .o_lsu_req(), .o_lsu_opa(), .o_lsu_opb(),
        .i_lsu_free(p_lsu_free), .o_div_req(), .i_div_free(1'b1),
        .i_commit_valid(1'b0), .i_commit_rd(5'd0), .i_commit_rd_wen(1'b0), .i_commit_tag('0),
        .i_uop1_valid(p_v1), .i_uop1(p_u1), .i_pb_active(p_pb), .o_issue2(prs_issue2),
        .o_rs1b_sel(), .o_rs2b_sel(), .o_lookup4_tag(), .o_lookup5_tag(),
        .o_alloc2_valid(), .o_alloc2_pc(), .o_alloc2_raw(), .o_alloc2_rd(), .o_alloc2_rd_wen(), .o_alloc2_next_pc(),
        .o_alloc2_ctrl(), .i_alloc_tag1(QV_ROB_TAG_W'(2)), .i_alloc_ready2(p_ready2),
        .o_src0_a(), .o_src0_b(), .o_src1_a(), .o_src1_b()
    );

    // probe uops (registers x/f 1..9; the tables are empty, so every source is ready)
    function automatic uop_t p_alu(input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
        return mk(`ADD, rd, rs1, 1'b1, 64'd0, rs2, 1'b1, 64'd0);
    endfunction
    function automatic uop_t p_bru(input logic [4:0] rs1, input logic [4:0] rs2);
        uop_t u;
        u = mk(`ADD, 5'd0, rs1, 1'b1, 64'd0, rs2, 1'b1, 64'd0);
        u.fu     = QV_FU_BRU;
        u.rd_wen = 1'b0;
        return u;
    endfunction
    function automatic uop_t p_ld(input logic [4:0] rd, input logic [4:0] rs1, input logic fp);
        uop_t u;
        u = mk(`ADD, rd, rs1, 1'b1, 64'd0, 5'd0, 1'b0, 64'd8);
        u.fu       = QV_FU_LSU;
        u.is_load  = 1'b1;
        u.mem_size = 2'd3;
        u.rd_fp    = fp;
        return u;
    endfunction
    function automatic uop_t p_st(input logic [4:0] rs1, input logic [4:0] rs2, input logic fp);
        uop_t u;
        u = mk(`ADD, 5'd0, rs1, 1'b1, 64'd0, rs2, 1'b1, 64'd0);
        u.fu       = QV_FU_LSU;
        u.is_store = 1'b1;
        u.mem_size = 2'd3;
        u.rd_wen   = 1'b0;
        u.rs2_fp   = fp;
        return u;
    endfunction
    function automatic uop_t p_fpu(input qv_fp_op_e op, input logic [4:0] rd, input logic [4:0] rs1,
                                   input logic [4:0] rs2);
        uop_t u;
        u = mk(`ADD, rd, rs1, 1'b1, 64'd0, rs2, 1'b1, 64'd0);
        u.fu     = QV_FU_FPU;
        u.fp_op  = 5'(op);
        u.rs1_fp = 1'b1;
        u.rs2_fp = 1'b1;
        u.rd_fp  = 1'b1;
        u.fp_fmt = 1'b1;
        return u;
    endfunction
    function automatic uop_t p_fmv_dx(input logic [4:0] rd, input logic [4:0] rs1);   // FMV.D.X: an integer source
        uop_t u;
        u = mk(`ADD, rd, rs1, 1'b1, 64'd0, 5'd0, 1'b0, 64'd0);
        u.fu     = QV_FU_FPU;
        u.fp_op  = 5'(QV_FP_MV_FX);
        u.rd_fp  = 1'b1;
        u.fp_fmt = 1'b1;
        return u;
    endfunction
    // the uops that dispatch alone (k: which), with ready sources x1/x2
    function automatic uop_t p_alone(input int k);
        uop_t u;
        u = p_alu(5'd3, 5'd1, 5'd2);
        case (k)
            0: u.fu = QV_FU_CSR;
            1: begin u.fu = QV_FU_SYS; u.rd_wen = 1'b0; end
            2: u.fu = QV_FU_DIV;
            3: begin u = p_ld(5'd3, 5'd1, 1'b0); u.is_load = 1'b0; u.is_atomic = 1'b1; u.amo_op = QV_AMO_ADD; end
            4: u.serialize = 1'b1;
            5: u.xcpt = 1'b1;
            6: u.trig_debug = 1'b1;
            7: u.trig_exc = 1'b1;
            8: begin u.raw = 32'h0ff0000f; u.rd_wen = 1'b0; end                          // FENCE
            9: u = p_fpu(QV_FP_DIV, 5'd3, 5'd1, 5'd2);
            default: u = p_fpu(QV_FP_SQRT, 5'd3, 5'd1, 5'd0);
        endcase
        return u;
    endfunction
    function automatic string alone_name(input int k);
        case (k)
            0: return "CSR"; 1: return "SYS"; 2: return "DIV"; 3: return "AMO"; 4: return "serializing";
            5: return "faulting"; 6: return "trig_debug"; 7: return "trig_exc"; 8: return "FENCE";
            9: return "FDIV"; default: return "FSQRT";
        endcase
    endfunction

    task automatic probe_set(input uop_t u0, input uop_t u1);
        p_u0 = u0; p_u1 = u1; p_v1 = 1'b1; p_ready = 1'b1; p_ready2 = 1'b1; p_pb = 1'b0; p_lsu_free = 1'b1;
        #1;
    endtask
    // pr's slot 1 went into its station
    function automatic logic pr_push2();
        return pr.g_rs.rs0.i_push2;
    endfunction

    task automatic run_probes();
        // independent ALU pair: slot 0 takes the ALU; with a station slot 1 waits there, without one the pair splits
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_alu(5'd4, 5'd1, 5'd2));
        check("P1: ALU+ALU: slot 0 dispatches", {63'b0, pr_issue}, 64'd1);
        check("P1: ALU+ALU pair (station)", {63'b0, pr_issue2}, 64'd1);
        check("P1: slot 0 to the ALU", {63'b0, pr_alu.valid && pr_alu.tag == QV_ROB_TAG_W'(1)}, 64'd1);
        check("P1: slot 1 into the station", {63'b0, pr_push2()}, 64'd1);
        check("P1: no station: no pair", {63'b0, pr0_issue2}, 64'd0);
        check("P1: no station: slot 0 still dispatches", {63'b0, pr0_issue}, 64'd1);
        // ALU + BRU share the port
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_bru(5'd1, 5'd2));
        check("P2: ALU+BRU pair", {63'b0, pr_issue2}, 64'd1);
        check("P2: the BRU (slot 1) waits for the shared port in the station",
              {63'b0, pr_push2() && !pr_bru.valid && pr.g_rs.rs0.i_push2_e.kind == QV_RS_BRU}, 64'd1);
        probe_set(p_bru(5'd1, 5'd2), p_alu(5'd3, 5'd1, 5'd2));
        check("P2b: BRU+ALU: slot 0 to the BRU, slot 1 into the station",
              {63'b0, pr_issue2 && pr_bru.valid && pr_bru.tag == QV_ROB_TAG_W'(1) && pr_push2() && !pr_alu.valid},
              64'd1);
        // a memory op beside an ALU op: each to its own unit, in either order, station or not
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_ld(5'd4, 5'd1, 1'b0));
        check("P3: ALU+LD pair", {63'b0, pr_issue2 && pr0_issue2}, 64'd1);
        check("P3: slot 1 straight to the LSU",
              {63'b0, pr_lsu.valid && pr_lsu.tag == QV_ROB_TAG_W'(2) && pr0_lsu.valid && pr0_lsu.tag == QV_ROB_TAG_W'(2)},
              64'd1);
        check("P3: slot 0 to the ALU", {63'b0, pr0_alu.valid && pr0_alu.tag == QV_ROB_TAG_W'(1)}, 64'd1);
        probe_set(p_st(5'd1, 5'd2, 1'b0), p_alu(5'd3, 5'd1, 5'd2));
        check("P3b: SD+ALU pair", {63'b0, pr_issue2 && pr0_issue2}, 64'd1);
        check("P3b: slot 0 to the LSU, slot 1 straight to the ALU",
              {63'b0, pr0_lsu.valid && pr0_lsu.tag == QV_ROB_TAG_W'(1) && pr0_alu.valid
                      && pr0_alu.tag == QV_ROB_TAG_W'(2) && pr_alu.valid && pr_alu.tag == QV_ROB_TAG_W'(2)}, 64'd1);
        // at most one memory op
        probe_set(p_ld(5'd3, 5'd1, 1'b0), p_ld(5'd4, 5'd2, 1'b0));
        check("P4: LD+LD: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        check("P4: LD+LD: slot 0 dispatches", {63'b0, pr_issue}, 64'd1);
        probe_set(p_ld(5'd3, 5'd1, 1'b0), p_st(5'd2, 5'd4, 1'b0));
        check("P4: LD+SD: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        // FP state: one FP-touching uop per pair; the FP read ports follow it
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_fpu(QV_FP_ADD, 5'd4, 5'd5, 5'd6));
        check("P5: ALU+FADD pair", {63'b0, pr_issue2 && pr0_issue2}, 64'd1);
        check("P5: slot 1 straight to the FPU",
              {63'b0, pr0_fpu.valid && pr0_fpu.tag == QV_ROB_TAG_W'(2)}, 64'd1);
        check("P5: the FP read ports serve slot 1", 64'(pr_frs1), 64'd5);
        probe_set(p_fpu(QV_FP_ADD, 5'd4, 5'd5, 5'd6), p_alu(5'd3, 5'd1, 5'd2));
        check("P5b: FADD+ALU pair: slot 0 to the FPU, slot 1 to the ALU",
              {63'b0, pr0_issue2 && pr0_fpu.valid && pr0_fpu.tag == QV_ROB_TAG_W'(1) && pr0_alu.valid
                      && pr0_alu.tag == QV_ROB_TAG_W'(2)}, 64'd1);
        check("P5b: the FP read ports serve slot 0", 64'(pr_frs1), 64'd5);
        probe_set(p_fpu(QV_FP_ADD, 5'd4, 5'd5, 5'd6), p_fpu(QV_FP_ADD, 5'd7, 5'd8, 5'd9));
        check("P6: FADD+FADD: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        check("P6: FADD+FADD: the FP read ports stay slot 0's", 64'(pr_frs1), 64'd5);
        probe_set(p_ld(5'd4, 5'd1, 1'b1), p_fpu(QV_FP_ADD, 5'd7, 5'd8, 5'd9));
        check("P6: FLD+FADD: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        probe_set(p_fpu(QV_FP_ADD, 5'd4, 5'd5, 5'd6), p_st(5'd1, 5'd7, 1'b1));
        check("P6: FADD+FSD: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_fmv_dx(5'd4, 5'd1));
        check("P6b: ALU+FMV.D.X pair", {63'b0, pr0_issue2}, 64'd1);
        probe_set(p_ld(5'd4, 5'd1, 1'b1), p_alu(5'd3, 5'd1, 5'd2));
        check("P6c: FLD+ALU pair", {63'b0, pr_issue2 && pr0_issue2}, 64'd1);
        // the uops that dispatch alone, in either slot
        for (int a = 0; a <= 10; a++) begin
            probe_set(p_alu(5'd4, 5'd1, 5'd2), p_alone(a));
            check($sformatf("P7: ALU+%s: no pair", alone_name(a)), {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
            probe_set(p_alone(a), p_alu(5'd4, 5'd1, 5'd2));
            check($sformatf("P7: %s dispatches", alone_name(a)), {63'b0, pr_issue}, 64'd1);
            check($sformatf("P7: %s+ALU: no pair", alone_name(a)), {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        end
        // slot 1 reads slot 0's destination: never ready now, slot 0's tag, never late; and only in the same table
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_alu(5'd6, 5'd5, 5'd2));
        check("P8: dependent pair (rs1): pair through the station", {63'b0, pr_issue2}, 64'd1);
        check("P8: rs1 waits for slot 0's tag, not late",
              {63'b0, pr_push2() && !pr.g_rs.rs0.i_push2_e.a.rdy && pr.g_rs.rs0.i_push2_e.a.tag == QV_ROB_TAG_W'(1)
                      && !pr.g_rs.rs0.i_push2_e.a.late && pr.g_rs.rs0.i_push2_e.b.rdy}, 64'd1);
        check("P8: no station: the dependent pair splits", {63'b0, pr0_issue2}, 64'd0);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_alu(5'd6, 5'd1, 5'd5));
        check("P8b: rs2 waits for slot 0's tag",
              {63'b0, pr_issue2 && pr_push2() && pr.g_rs.rs0.i_push2_e.a.rdy && !pr.g_rs.rs0.i_push2_e.b.rdy
                      && pr.g_rs.rs0.i_push2_e.b.tag == QV_ROB_TAG_W'(1) && !pr.g_rs.rs0.i_push2_e.b.late}, 64'd1);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_ld(5'd6, 5'd5, 1'b0));
        check("P8c: a load whose address is slot 0's: the pair, its address waits in the queue",
              {63'b0, pr_issue2 && pr_lsu.valid && pr_lsu.tag == QV_ROB_TAG_W'(2) && !pr_lsu_opa.rdy
                      && pr_lsu_opa.tag == QV_ROB_TAG_W'(1) && !pr_lsu_opa.late}, 64'd1);
        check("P8c: no queue waiting: that pair splits", {63'b0, pr0_issue2}, 64'd0);
        check("P8c: the memory op does not go into the station", {63'b0, pr_push2()}, 64'd0);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_st(5'd1, 5'd5, 1'b0));
        check("P8d: a store whose data is slot 0's: its data waits in the queue",
              {63'b0, pr_issue2 && pr_lsu_opa.rdy && !pr_lsu_opb.rdy && pr_lsu_opb.tag == QV_ROB_TAG_W'(1)}, 64'd1);
        probe_set(p_ld(5'd5, 5'd1, 1'b1), p_alu(5'd6, 5'd5, 5'd2));
        check("P8e: slot 0 writes f5, slot 1 reads x5: not a dependence (straight to the ALU)",
              {63'b0, pr_issue2 && pr_alu.valid && pr_alu.tag == QV_ROB_TAG_W'(2) && !pr_push2()}, 64'd1);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_fmv_dx(5'd6, 5'd5));
        check("P8f: FMV.D.X from slot 0's x5: waits in the station for slot 0's tag",
              {63'b0, pr_issue2 && pr_push2() && pr.g_rs.rs0.i_push2_e.kind == QV_RS_FPU
                      && !pr.g_rs.rs0.i_push2_e.a.rdy && pr.g_rs.rs0.i_push2_e.a.tag == QV_ROB_TAG_W'(1)
                      && !pr0_fpu.valid}, 64'd1);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_alu(5'd6, 5'd4, 5'd2));
        check("P8g: an unrelated register is ready", {63'b0, pr_issue2 && pr.g_rs.rs0.i_push2_e.a.rdy}, 64'd1);
        probe_set(p_alu(5'd5, 5'd1, 5'd2), p_st(5'd1, 5'd5, 1'b1));
        check("P8h: slot 0 writes x5, slot 1 stores f5: not a dependence (the data is ready)",
              {63'b0, pr0_issue2 && pr0_lsu.valid && pr0_lsu.tag == QV_ROB_TAG_W'(2) && pr_lsu_opb.rdy}, 64'd1);
        // the LSU (the queue) full: a memory op in slot 1 waits, and the pair splits
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_ld(5'd4, 5'd1, 1'b0));
        p_lsu_free = 1'b0; #1;
        check("P3c: the LSU busy: ALU+LD splits", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        check("P3c: the LSU busy: slot 0 still dispatches", {63'b0, pr_issue && pr0_issue}, 64'd1);
        p_lsu_free = 1'b1; #1;
        // the rest of the conditions
        probe_set(p_alu(5'd3, 5'd1, 5'd2), p_ld(5'd4, 5'd1, 1'b0));
        p_pb = 1'b1; #1;
        check("P9: a Program Buffer run: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        p_pb = 1'b0; p_ready2 = 1'b0; #1;
        check("P9: no ROB room for two: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        check("P9: no ROB room for two: slot 0 still dispatches", {63'b0, pr_issue}, 64'd1);
        p_ready2 = 1'b1; p_v1 = 1'b0; #1;
        check("P9: no slot 1: no pair", {63'b0, pr_issue2 || pr0_issue2}, 64'd0);
        p_v1 = 1'b1; p_ready = 1'b0; #1;
        check("P9: slot 0 cannot dispatch: neither does slot 1", {63'b0, pr_issue || pr_issue2 || pr0_issue2}, 64'd0);
        p_ready = 1'b1; #1;
        check("P9: back to a pair", {63'b0, pr_issue2 && pr0_issue2}, 64'd1);
        check("P9: a SERIALIZE build: one at a time", {63'b0, prs_issue && !prs_issue2}, 64'd1);
    endtask

    int i, gap, j0;
    int seed_v = SEED;
    logic [4:0] ops [0:9];

    initial begin
        ops[0] = `ADD; ops[1] = `SUB; ops[2] = `SLT; ops[3] = `SLTU; ops[4] = `XOR;
        ops[5] = `OR;  ops[6] = `AND; ops[7] = `SLL; ops[8] = `SRL;  ops[9] = `SRA;
        void'($urandom(seed_v));

        repeat (2) @(posedge clk);                          // the probes (held in reset) take their reset first
        #1;
        run_probes();

        // ---- T1: independent uops pair up (through the station: one ALU port) ----
        begin_script();
        for (i = 0; i < 8; i++) push(mk(`ADD, 5'(8 + i), 0, 0, 64'(i), 0, 0, 64'(100)), 0);
        run_script("T1", 200);
        if (RS_DEPTH > 0) begin
            check("T1: the first two dispatch in one cycle", issue_cyc[1] - issue_cyc[0], 64'd0);
            check("T1: pairs happened", 64'(n_pairs > 0), 64'd1);
        end else
            check("T1: no station: one dispatch a cycle", 64'(n_pairs), 64'd0);

        // ---- T2: an intra-pair dependence, through rs1 and through rs2 ----
        for (j0 = 0; j0 < 2; j0++) begin
            begin_script();
            push(mk(`ADD, 5, 0, 0, 64'd7, 0, 0, 64'd0), 0);                            // x5 = 7
            if (j0 == 0) push(mk(`ADD, 6, 5, 1, 0, 0, 0, 64'd3), 0);                  // x6 = x5 + 3
            else         push(mk(`SUB, 6, 0, 0, 64'd3, 5, 1, 0), 0);                  // x6 = 3 - x5
            run_script($sformatf("T2.%0d", j0), 200);
            if (RS_DEPTH > 0) begin
                check($sformatf("T2.%0d: the dependent pair dispatches in one cycle", j0),
                      issue_cyc[1] - issue_cyc[0], 64'd0);
                check($sformatf("T2.%0d: slot 1 reaches the ALU %s after slot 0", j0,
                                BYPASS_EN ? "the cycle" : "two cycles"),
                      exec_cyc[1] - exec_cyc[0], BYPASS_EN ? 64'd1 : 64'd2);
            end else
                check($sformatf("T2.%0d: no station: the pair splits", j0), 64'(issue_cyc[1] > issue_cyc[0]), 64'd1);
        end

        // ---- T3: both slots write x5, then a reader, across bubble lengths (slot 1's claim stays) ----
        for (gap = 0; gap <= 6; gap++) begin
            begin_script();
            push(mk(`ADD, 9, 0, 0, 64'd5, 0, 0, 64'd0), 0);   // something before, so the pair is not the first uop
            push(mk(`ADD, 5, 0, 0, 64'd1, 0, 0, 64'd0), 4);   // older writer:   x5 = 1   (a pair with the next; the
                                                              // bubble empties a 2-entry ROB, which pairs only empty)
            push(mk(`ADD, 5, 0, 0, 64'd2, 0, 0, 64'd0), 0);   // younger writer: x5 = 2
            push(mk(`ADD, 7, 5, 1, 0, 0, 0, 64'd0), gap);     // reader: x7 = x5 (must be 2)
            run_script($sformatf("T3 gap=%0d", gap), 200);
            if (RS_DEPTH > 0)
                check($sformatf("T3 gap=%0d: the two writers paired", gap), issue_cyc[2] - issue_cyc[1], 64'd0);
        end

        // ---- T4 (CSR_LATE): a stale late bit on the register a pair passes between its slots ----
        if (CSR_LATE) begin
            begin_script();
            push(mk_csrr(5), 0);                                  // x5 = the CSR: a late claim on x5
            push(mk(`ADD, 6, 5, 1, 0, 0, 0, 64'd1), 0);           // x6 = x5 + 1, waits for that commit
            push(mk(`ADD, 5, 0, 0, 64'd11, 0, 0, 64'd0), 12);     // long after: x5 = 11   (a pair with the next)
            push(mk(`ADD, 7, 5, 1, 0, 0, 0, 64'd2), 0);           // x7 = x5 + 2 = 13: slot 0's value, not late
            run_script("T4", 300);
            if (RS_DEPTH > 0) begin
                check("T4: the second pair dispatches in one cycle", issue_cyc[3] - issue_cyc[2], 64'd0);
                check("T4: its slot 1 is not late (no wait for slot 0's commit)",
                      exec_cyc[3] - exec_cyc[2], BYPASS_EN ? 64'd1 : 64'd2);
            end
        end

        // ---- R1: random dense-hazard stream with bubbles (and CSR reads with CSR_LATE) ----
        begin_script();
        for (i = 0; i < 1500; i++) begin
            logic [4:0] op, rd, rs1, rs2;
            logic       use1, use2;
            logic [63:0] im1, im2;
            uop_t       u;
            if (CSR_LATE && $urandom % 7 == 0) begin
                push(mk_csrr(5'($urandom % 8)), ($urandom % 6 == 0) ? int'($urandom % 3) : 0);
            end else begin
                op   = ops[$urandom % 10];
                rd   = 5'($urandom % 8);                     // x0..x7 only: lots of RAW/WAW, inside pairs too
                rs1  = 5'($urandom % 8);
                rs2  = 5'($urandom % 8);
                use1 = ($urandom % 4) != 0;
                use2 = ($urandom % 3) != 0;
                im1  = {$urandom, $urandom};
                im2  = ($urandom % 2) ? {$urandom, $urandom} : 64'($urandom % 70);
                u = mk(op, rd, rs1, use1, im1, rs2, use2, im2);
                u.is_word = ($urandom % 4) == 0;
                push(u, ($urandom % 6 == 0) ? int'($urandom % 4) : 0);
            end
        end
        run_script("R1", 30000);
        $display("qv_dispatch2_tb R1: %0d uops, %0d dispatched in pairs, %0d retired in pairs", n_uops, 2 * n_pairs,
                 2 * n_cpairs);
        if (RS_DEPTH > 0) check("R1: pairs dispatched", 64'(n_pairs > 10), 64'd1);
        else              check("R1: no station: no pair", 64'(n_pairs), 64'd0);
        // (with no station nothing backs up: every entry completes the cycle after the one ahead of it retires)
        if (COMMIT_W > 1 && RS_DEPTH > 0) check("R1: pairs retired", 64'(n_cpairs > 10), 64'd1);

        $display("");
        $display("qv_dispatch2_tb (BYPASS_EN=%0d ROB_DEPTH=%0d RS_DEPTH=%0d CSR_LATE=%0d COMMIT_W=%0d): %0d passed, %0d failed",
                 BYPASS_EN, ROB_DEPTH, RS_DEPTH, CSR_LATE, COMMIT_W, pass_count, fail_count);
        if (fail_count > 0) $display("qv_dispatch2_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #4000000;
        $display("TIMEOUT: qv_dispatch2_tb");
        $finish;
    end
endmodule
