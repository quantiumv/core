// SPDX-License-Identifier: MIT

`include "defaults/alu_ops.sv"

/*
 * qv_backend_tb -- issue + ROB + ALU + commit + regfile0, driven with
 * uops directly (no fetch/decode), checked against a sequential golden
 * model at every retirement and on the final register file.
 *
 * Covers what an end-to-end RVFI comparison can't observe directly:
 *   - exact issue timing of a back-to-back dependence (0 extra cycles
 *     with bypass, 1 without, a fully serialized gap with SERIALIZE);
 *   - the producer table's tag-compared release: a WAW pair followed by
 *     a reader, swept across every bubble length so the reader lands in
 *     the window between the older writer's commit and the younger's;
 *   - a long random stream over few registers (dense hazards) with
 *     random bubbles.
 *
 * Run once per configuration via -P overrides (BYPASS_EN, SERIALIZE,
 * ROB_DEPTH).
 */
module qv_backend_tb #(
    parameter bit BYPASS_EN = 1'b1,
    parameter bit SERIALIZE = 1'b0,
    parameter int ROB_DEPTH = 8
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

    // ---------------- DUT backend ----------------
    logic                    uop_valid;
    uop_t                    uop;
    logic                    issue;
    logic [4:0]              rs1_sel, rs2_sel;
    logic [63:0]             rs1_data, rs2_data;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic [63:0]             alloc_pc, alloc_next_pc;
    logic [31:0]             alloc_raw;
    logic [4:0]              alloc_rd;
    rvfi_shadow_t            alloc_shadow, head_shadow;
    rob_ctrl_t               alloc_ctrl, head_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, l1_tag, l2_tag, head_tag, c_tag;
    logic                    l1_complete, l2_complete;
    logic [63:0]             l1_value, l2_value;
    wb_t                     wb;
    fu_req_t                 fu_req;
    logic                    head_valid, commit_pop;
    rob_entry_t              head_entry;
    logic                    rf_we, c_valid, c_rd_wen, commit_now;
    logic [4:0]              rf_sel, c_rd;
    logic [63:0]             rf_data, arch_pc, next_pc;
    logic [63:0]             r_order, r_rs1_rdata, r_rs2_rdata, r_rd_wdata, r_pc_rdata, r_pc_wdata;
    logic [31:0]             r_insn;
    logic                    r_intr;
    logic [4:0]              r_rs1_addr, r_rs2_addr, r_rd_addr;

    qv_issue #(.SERIALIZE(SERIALIZE), .BYPASS_EN(BYPASS_EN)) issue0 (
        .clk(clk), .rst(rst), .i_flush(1'b0),
        .i_uop_valid(uop_valid), .i_uop(uop), .o_issue(issue),
        .o_rs1_sel(rs1_sel), .o_rs2_sel(rs2_sel), .i_rs1_data(rs1_data), .i_rs2_data(rs2_data),
        .o_alloc_valid(alloc_valid), .o_alloc_pc(alloc_pc), .o_alloc_raw(alloc_raw),
        .o_alloc_rd(alloc_rd), .o_alloc_rd_wen(alloc_rd_wen), .o_alloc_next_pc(alloc_next_pc),
        .o_alloc_shadow(alloc_shadow), .o_alloc_ctrl(alloc_ctrl),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(alloc_ready),
        .i_rob_empty(rob_empty),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l1_complete), .i_lookup1_value(l1_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l2_complete), .i_lookup2_value(l2_value),
        .i_wb(wb), .o_alu_req(fu_req), .o_bru_req(), .o_lsu_req(), .i_lsu_free(1'b1),
        .i_commit_valid(c_valid), .i_commit_rd(c_rd), .i_commit_rd_wen(c_rd_wen), .i_commit_tag(c_tag)
    );

    qv_rob #(.ROB_DEPTH(ROB_DEPTH)) rob0 (
        .clk(clk), .rst(rst), .i_flush(1'b0),
        .i_alloc_valid(alloc_valid), .i_alloc_pc(alloc_pc), .i_alloc_raw(alloc_raw),
        .i_alloc_rd(alloc_rd), .i_alloc_rd_wen(alloc_rd_wen), .i_alloc_next_pc(alloc_next_pc),
        .i_alloc_shadow(alloc_shadow), .i_alloc_ctrl(alloc_ctrl),
        .o_alloc_tag(alloc_tag), .o_alloc_ready(alloc_ready),
        .o_empty(rob_empty), .i_wb(wb), .i_wb2('0),
        .i_lookup1_tag(l1_tag), .o_lookup1_complete(l1_complete), .o_lookup1_value(l1_value),
        .i_lookup2_tag(l2_tag), .o_lookup2_complete(l2_complete), .o_lookup2_value(l2_value),
        .o_head_valid(head_valid), .o_head_entry(head_entry), .o_head_tag(head_tag),
        .o_head_shadow(head_shadow), .o_head_ctrl(head_ctrl), .i_commit_pop(commit_pop)
    );

    qv_exu_alu exu0 (.clk(clk), .rst(rst), .i_flush(1'b0), .i_req(fu_req), .o_wb(wb));

    qv_commit commit0 (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(head_entry), .i_head_tag(head_tag),
        .i_head_shadow(head_shadow), .i_head_ctrl(head_ctrl), .i_lsu_res('0), .o_commit_pop(commit_pop),
        // ALU-only uops: no CSR, trap or mret ever reaches commit here
        .i_csr_rdata(64'b0), .i_mtvec(64'b0), .i_mepc(64'b0), .i_fetch_idle(1'b1),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_commit_now(commit_now), .o_pc(arch_pc), .o_next_pc(next_pc),
        .o_rvfi_order(r_order), .o_rvfi_insn(r_insn), .o_rvfi_intr(r_intr),
        .o_rvfi_rs1_addr(r_rs1_addr), .o_rvfi_rs2_addr(r_rs2_addr),
        .o_rvfi_rs1_rdata(r_rs1_rdata), .o_rvfi_rs2_rdata(r_rs2_rdata),
        .o_rvfi_rd_addr(r_rd_addr), .o_rvfi_rd_wdata(r_rd_wdata),
        .o_rvfi_pc_rdata(r_pc_rdata), .o_rvfi_pc_wdata(r_pc_wdata)
    );

    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(rs1_sel), .o_read_gpr_A_data(rs1_data),
        .i_read_gpr_B_sel(rs2_sel), .o_read_gpr_B_data(rs2_data),
        .i_load_gpr(rf_we), .i_load_gpr_sel(rf_sel), .i_load_gpr_data(rf_data)
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
    uop_t        script     [0:MAXN-1];
    int          bubble     [0:MAXN-1];   // idle cycles before presenting this uop
    logic [63:0] exp_wdata  [0:MAXN-1];
    logic [63:0] issue_cyc  [0:MAXN-1];
    logic [63:0] G [0:31];                // golden regfile
    int n_uops;

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

    // Append a uop: assign its pc/raw, compute its golden result.
    task automatic push(input uop_t u_in, input int bub);
        uop_t u;
        logic [63:0] a, b, y;
        u     = u_in;
        u.pc  = 64'(4 * n_uops);
        u.raw = 32'(n_uops);
        a = u.rs1_used ? G[u.rs1] : u.imm1;
        b = u.rs2_used ? G[u.rs2] : u.imm2;
        y = golden_alu(u.alu_op, a, b);
        if (u.is_word) y = {{32{y[31]}}, y[31:0]};
        if (u.rd_wen && u.rd != 0) G[u.rd] = y;
        exp_wdata[n_uops] = (u.rd_wen && u.rd != 0) ? y : 64'd0;
        script[n_uops]    = u;
        bubble[n_uops]    = bub;
        n_uops++;
    endtask

    // ---------------- driver ----------------
    int  k, bub_left;
    logic run_en = 1'b0;
    uop_t cur;
    always_comb begin
        cur       = script[k];
        uop_valid = run_en && (k < n_uops) && (bub_left == 0);
        uop       = cur;
    end
    always @(posedge clk) begin
        if (rst || !run_en) begin
        end else if (uop_valid && issue) begin
            issue_cyc[k] <= cyc;
            k        <= k + 1;
            bub_left <= (k + 1 < n_uops) ? bubble[k + 1] : 0;
        end else if (bub_left > 0) begin
            bub_left <= bub_left - 1;
        end
    end

    // ---------------- retirement checker ----------------
    int n_ret, ret_errs;
    always @(posedge clk) begin
        if (!rst && run_en && commit_now) begin
            if (r_order != 64'(n_ret) || r_pc_rdata != 64'(4 * n_ret) || r_insn != 32'(n_ret)
                    || r_rd_wdata != exp_wdata[n_ret] || r_pc_wdata != 64'(4 * n_ret + 4)) begin
                ret_errs++;
                if (ret_errs <= 5)
                    $display("RETIRE MISMATCH #%0d: order=%0d pc=%h insn=%h rd_wdata=%h (exp %h)",
                             n_ret, r_order, r_pc_rdata, r_insn, r_rd_wdata, exp_wdata[n_ret]);
            end
            n_ret <= n_ret + 1;
        end
    end

    task automatic begin_script();
        n_uops = 0;
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
        k        = 0;
        bub_left = (n_uops > 0) ? bubble[0] : 0;
        n_ret    = 0;
        ret_errs = 0;
        rst      = 1'b0;
        run_en   = 1'b1;
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
        for (int r = 1; r < 32; r++)
            check($sformatf("%s: final x%0d", tag, r), regfile0.gp_registers[r], G[r]);
        check({tag, ": ROB drained"}, {63'b0, rob_empty}, 64'd1);
        for (int r = 0; r < 32; r++)
            check($sformatf("%s: no claim left on x%0d", tag, r), {63'b0, issue0.prod_busy_q[r]}, 64'd0);
        run_en = 1'b0;
    endtask

    int i, gap;
    int seed = 12345;
    logic [4:0] ops [0:9];

    initial begin
        ops[0] = `ADD; ops[1] = `SUB; ops[2] = `SLT; ops[3] = `SLTU; ops[4] = `XOR;
        ops[5] = `OR;  ops[6] = `AND; ops[7] = `SLL; ops[8] = `SRL;  ops[9] = `SRA;

        // ---- D1: back-to-back dependences -- issue timing ----
        // Each operand position separately, so a broken bypass on one
        // side can't hide behind the other side still stalling.
        begin_script();
        push(mk(`ADD, 5, 0, 0, 64'd7, 0, 0, 64'd0), 0);      // x5 = 7
        push(mk(`ADD, 6, 5, 1, 0, 5, 1, 0), 0);               // x6 = x5 + x5   (both operands)
        push(mk(`ADD, 7, 6, 1, 0, 0, 0, 64'd1), 0);           // x7 = x6 + 1    (rs1 only)
        push(mk(`SUB, 8, 0, 0, 64'd3, 7, 1, 0), 0);           // x8 = 3 - x7    (rs2 only)
        run_script("D1", 200);
        for (i = 1; i <= 3; i++) begin
            if (SERIALIZE)
                check($sformatf("D1.%0d: serialized -- issues only after the producer retires", i),
                      64'(issue_cyc[i] - issue_cyc[i-1] >= 3), 64'd1);
            else if (BYPASS_EN)
                check($sformatf("D1.%0d: bypass -- dependent issues the very next cycle", i),
                      issue_cyc[i] - issue_cyc[i-1], 64'd1);
            else
                check($sformatf("D1.%0d: no bypass -- dependent stalls exactly one cycle", i),
                      issue_cyc[i] - issue_cyc[i-1], 64'd2);
        end

        // ---- D2: independent back-to-back -- never stalls ----
        begin_script();
        for (i = 0; i < 8; i++) push(mk(`ADD, 5'(8 + i), 0, 0, 64'(i), 0, 0, 64'(100)), 0);
        run_script("D2", 200);
        if (!SERIALIZE)
            check("D2: 8 independent uops issue on 8 consecutive cycles", issue_cyc[7] - issue_cyc[0], 64'd7);

        // ---- D3: WAW then a reader, swept across bubble lengths ----
        for (gap = 0; gap <= 6; gap++) begin
            begin_script();
            push(mk(`ADD, 5, 0, 0, 64'd1, 0, 0, 64'd0), 0);   // older writer:   x5 = 1
            push(mk(`ADD, 5, 0, 0, 64'd2, 0, 0, 64'd0), 0);   // younger writer: x5 = 2
            push(mk(`ADD, 7, 5, 1, 0, 0, 0, 64'd0), gap);     // reader: x7 = x5 (must be 2)
            run_script($sformatf("D3 gap=%0d", gap), 200);
        end

        // ---- D4: x0 as a destination never claims x0 ----
        begin_script();
        push(mk(`ADD, 0, 0, 0, 64'd9, 0, 0, 64'd0), 0);       // writes x0: no-op
        push(mk(`ADD, 6, 0, 1, 0, 0, 0, 64'd3), 0);           // x6 = x0 + 3 = 3
        run_script("D4", 200);

        // ---- R1: random dense-hazard stream ----
        begin_script();
        void'($urandom(seed));
        for (i = 0; i < 1500; i++) begin
            logic [4:0] op, rd, rs1, rs2;
            logic       use1, use2;
            logic [63:0] im1, im2;
            uop_t       u;
            op   = ops[$urandom % 10];
            rd   = 5'($urandom % 8);                     // x0..x7 only: lots of RAW/WAW
            rs1  = 5'($urandom % 8);
            rs2  = 5'($urandom % 8);
            use1 = ($urandom % 4) != 0;
            use2 = ($urandom % 3) != 0;
            im1  = {$urandom, $urandom};
            im2  = ($urandom % 2) ? {$urandom, $urandom} : 64'($urandom % 70);
            u = mk(op, rd, rs1, use1, im1, rs2, use2, im2);
            u.is_word = ($urandom % 4) == 0;                 // truncated results through bypass/ROB too
            push(u, ($urandom % 5 == 0) ? int'($urandom % 4) : 0);
        end
        run_script("R1", 20000);

        $display("");
        $display("qv_backend_tb (BYPASS_EN=%0d SERIALIZE=%0d ROB_DEPTH=%0d): %0d passed, %0d failed",
                 BYPASS_EN, SERIALIZE, ROB_DEPTH, pass_count, fail_count);
        if (fail_count > 0) $display("qv_backend_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT: qv_backend_tb");
        $finish;
    end
endmodule
