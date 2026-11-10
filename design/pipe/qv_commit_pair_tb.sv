// SPDX-License-Identifier: MIT

/*
 * qv_commit_pair_tb -- O4b: qv_commit with COMMIT_W 2, retiring the ROB head and the entry behind it in one cycle.
 *
 * A pair retires only when neither has anything the one-wide rules order around a retirement: every term of the
 * rule gets a case of its own here, the head's (a trap, a CSR or system op, a serializing, FENCE, atomic or
 * mispredicted op, a Program Buffer run, a single step) and the second's (not complete, a fault marker, a trigger
 * mark, a memory fault or no memory result, a CSR, system, serializing, FENCE or atomic op), and the pair's (two
 * posted stores, a posted store without room, two branches, two FP-state writes). Where it may, the second's
 * effects are checked: its register write on port 2, its claim clear, minstret, the order counter (+2), the
 * architectural pc and the redirect (a mispredicted second), the LR/SC reservation (a store second clears it), the
 * FP register write and fflags (from the second), predictor training (from the second), the store-buffer push
 * (the second's), and RVFI channel 1. An instance with COMMIT_W 1 never retires a second.
 */
module qv_commit_pair_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    hv = 1'b0, hv1 = 1'b0;
    rob_entry_t              e = '0, e1 = '0;
    rob_ctrl_t               c = '0, c1 = '0;
    logic [QV_ROB_TAG_W-1:0] tag = '0, tag1 = '0;
    lsu_res_t                lres = '0, lres1 = '0;
    logic                    lres1_ok = 1'b1;
    logic                    sb_ready = 1'b1;
    logic                    pb_act = 1'b0, dbg_step = 1'b0;

    logic                    pop, pop2, rf_we, rf2_we, c2_valid, c2_rd_wen, c2_rd_fp, ret, ret2, sb_push, sb_push1;
    logic [4:0]              rf_sel, rf2_sel, c2_rd;
    logic [63:0]             rf_data, rf2_data;
    logic [QV_ROB_TAG_W-1:0] c2_tag;
    logic                    redirect, res_valid, fprf_we, btb_valid, ras_push;
    logic [63:0]             redirect_pc, arch_pc, res_addr, fprf_data, btb_pc;
    logic [4:0]              fprf_sel, fp_accrue;
    logic [63:0]             r_order, r1_order, r1_pc_rdata, r1_pc_wdata, r1_rd_wdata, r1_mem_addr;
    logic [4:0]              r1_rd_addr;
    logic                    pop2_w1, r_intr;

    qv_commit #(.RESET_PC(64'h1000), .COMMIT_W(2)) dut (
        .clk(clk), .rst(rst),
        .i_head_valid(hv), .i_head_entry(e), .i_head_tag(tag), .i_head_ctrl(c), .i_lsu_res(lres), .o_commit_pop(pop),
        .i_head1_valid(hv1), .i_head1_entry(e1), .i_head1_tag(tag1), .i_head1_ctrl(c1), .i_lsu_res1(lres1),
        .i_lsu_res1_ok(lres1_ok), .o_commit_pop2(pop2),
        .o_res_valid(res_valid), .o_res_addr(res_addr),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_regfile2_we(rf2_we), .o_regfile2_sel(rf2_sel), .o_regfile2_data(rf2_data),
        .o_commit_valid(), .o_commit_rd(), .o_commit_rd_wen(), .o_commit_rd_fp(), .o_commit_tag(),
        .o_commit2_valid(c2_valid), .o_commit2_rd(c2_rd), .o_commit2_rd_wen(c2_rd_wen), .o_commit2_rd_fp(c2_rd_fp),
        .o_commit2_tag(c2_tag),
        .o_fprf_we(fprf_we), .o_fprf_sel(fprf_sel), .o_fprf_data(fprf_data), .o_fp_accrue(fp_accrue),
        .o_csr_addr(), .i_csr_rdata(64'b0), .o_csr_we(), .o_csr_wdata(),
        .o_instr_retired(ret), .o_instr_retired2(ret2), .o_trap_taken(), .o_trap_cause(), .o_trap_val(),
        .o_mret_taken(), .i_mtvec(64'h8000), .i_mepc(64'b0), .o_sret_taken(), .o_trap_to_s(), .o_priv(),
        .i_stvec(64'b0), .i_sepc(64'b0), .i_medeleg(64'b0), .i_mstatus_mpp(2'b11), .i_mstatus_spp(1'b0),
        .o_irq_taken(),
        .i_dbg_stepping(dbg_step),
        .o_dbg_entry(), .o_dbg_cause(), .o_dbg_halt_entry(), .o_dbg_ebreak_entry(), .o_dbg_trigger_entry(),
        .i_pb_active(pb_act), .o_pb_commit(), .o_pb_done(), .o_pb_abort(),
        .o_fetch_hold(), .i_fetch_idle(1'b1), .o_icache_flush(), .o_sfence(),
        .i_sb_ready(sb_ready), .i_sb_empty(1'b1), .o_sb_push(sb_push), .o_sb_push1(sb_push1),
        .o_btb_upd_valid(btb_valid), .o_btb_upd_pc(btb_pc), .o_btb_upd_taken(), .o_btb_upd_cross(),
        .o_bht_upd_valid(), .o_bht_upd_taken(), .o_ras_push(ras_push), .o_ras_addr(), .o_ras_pop(),
        .o_btb_upd_tgt(),
        .o_commit_now(), .o_pc(arch_pc), .o_next_pc(),
        .o_redirect_valid(redirect), .o_redirect_pc(redirect_pc), .o_redirect_ctx(),
        .o_rvfi_order(r_order), .o_rvfi_insn(), .o_rvfi_trap(), .o_rvfi_intr(r_intr), .o_rvfi_rs1_addr(), .o_rvfi_rs2_addr(),
        .o_rvfi_rd_addr(), .o_rvfi_rd_wdata(), .o_rvfi_pc_rdata(), .o_rvfi_pc_wdata(), .o_rvfi_mem_addr(),
        .o_rvfi_mem_rmask(), .o_rvfi_mem_wmask(), .o_rvfi_mem_rdata(), .o_rvfi_mem_wdata(),
        .o_rvfi_frd_wvalid(), .o_rvfi_frd_addr(), .o_rvfi_frd_wdata(),
        .o_rvfi1_order(r1_order), .o_rvfi1_insn(), .o_rvfi1_rs1_addr(), .o_rvfi1_rs2_addr(),
        .o_rvfi1_rd_addr(r1_rd_addr), .o_rvfi1_rd_wdata(r1_rd_wdata), .o_rvfi1_pc_rdata(r1_pc_rdata),
        .o_rvfi1_pc_wdata(r1_pc_wdata), .o_rvfi1_mem_addr(r1_mem_addr), .o_rvfi1_mem_rmask(), .o_rvfi1_mem_wmask(),
        .o_rvfi1_mem_rdata(), .o_rvfi1_mem_wdata(), .o_rvfi1_frd_wvalid(), .o_rvfi1_frd_addr(), .o_rvfi1_frd_wdata()
    );

    // the same pair, offered to a core that retires one a cycle
    qv_commit #(.RESET_PC(64'h1000)) dut1 (
        .clk(clk), .rst(rst),
        .i_head_valid(hv), .i_head_entry(e), .i_head_tag(tag), .i_head_ctrl(c), .i_lsu_res(lres), .o_commit_pop(),
        .i_head1_valid(hv1), .i_head1_entry(e1), .i_head1_tag(tag1), .i_head1_ctrl(c1), .i_lsu_res1(lres1),
        .i_lsu_res1_ok(lres1_ok), .o_commit_pop2(pop2_w1),
        .o_res_valid(), .o_res_addr(), .o_regfile_we(), .o_regfile_sel(), .o_regfile_data(),
        .o_regfile2_we(), .o_regfile2_sel(), .o_regfile2_data(),
        .o_commit_valid(), .o_commit_rd(), .o_commit_rd_wen(), .o_commit_rd_fp(), .o_commit_tag(),
        .o_commit2_valid(), .o_commit2_rd(), .o_commit2_rd_wen(), .o_commit2_rd_fp(), .o_commit2_tag(),
        .o_fprf_we(), .o_fprf_sel(), .o_fprf_data(), .o_fp_accrue(),
        .o_csr_addr(), .i_csr_rdata(64'b0), .o_csr_we(), .o_csr_wdata(),
        .o_instr_retired(), .o_instr_retired2(), .o_trap_taken(), .o_trap_cause(), .o_trap_val(),
        .o_mret_taken(), .i_mtvec(64'h8000), .i_mepc(64'b0), .o_sret_taken(), .o_trap_to_s(), .o_priv(),
        .i_stvec(64'b0), .i_sepc(64'b0), .i_medeleg(64'b0), .i_mstatus_mpp(2'b11), .i_mstatus_spp(1'b0),
        .o_irq_taken(), .o_dbg_entry(), .o_dbg_cause(), .o_dbg_halt_entry(), .o_dbg_ebreak_entry(),
        .o_dbg_trigger_entry(), .o_pb_commit(), .o_pb_done(), .o_pb_abort(),
        .o_fetch_hold(), .i_fetch_idle(1'b1), .o_icache_flush(), .o_sfence(),
        .o_sb_push(), .o_sb_push1(),
        .o_btb_upd_valid(), .o_btb_upd_pc(), .o_btb_upd_taken(), .o_btb_upd_cross(),
        .o_bht_upd_valid(), .o_bht_upd_taken(), .o_ras_push(), .o_ras_addr(), .o_ras_pop(), .o_btb_upd_tgt(),
        .o_commit_now(), .o_pc(), .o_next_pc(), .o_redirect_valid(), .o_redirect_pc(), .o_redirect_ctx(),
        .o_rvfi_order(), .o_rvfi_insn(), .o_rvfi_trap(), .o_rvfi_intr(), .o_rvfi_rs1_addr(), .o_rvfi_rs2_addr(),
        .o_rvfi_rd_addr(), .o_rvfi_rd_wdata(), .o_rvfi_pc_rdata(), .o_rvfi_pc_wdata(), .o_rvfi_mem_addr(),
        .o_rvfi_mem_rmask(), .o_rvfi_mem_wmask(), .o_rvfi_mem_rdata(), .o_rvfi_mem_wdata(),
        .o_rvfi_frd_wvalid(), .o_rvfi_frd_addr(), .o_rvfi_frd_wdata(),
        .o_rvfi1_order(), .o_rvfi1_insn(), .o_rvfi1_rs1_addr(), .o_rvfi1_rs2_addr(), .o_rvfi1_rd_addr(),
        .o_rvfi1_rd_wdata(), .o_rvfi1_pc_rdata(), .o_rvfi1_pc_wdata(), .o_rvfi1_mem_addr(), .o_rvfi1_mem_rmask(),
        .o_rvfi1_mem_wmask(), .o_rvfi1_mem_rdata(), .o_rvfi1_mem_wdata(), .o_rvfi1_frd_wvalid(),
        .o_rvfi1_frd_addr(), .o_rvfi1_frd_wdata()
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    localparam logic [31:0] ADDI = 32'h0010_0093;   // addi x1, x0, 1
    localparam logic [31:0] BEQ  = 32'h0000_0463;   // beq x0, x0, +8
    localparam logic [31:0] SD   = 32'h0010_3023;   // sd x1, 0(x0)
    localparam logic [31:0] FENCE = 32'h0ff0_000f;
    localparam logic [31:0] AMO  = 32'h0020_b0af;   // amoadd.d x1, x2, (x1)

    // a plain pair: the head at pc (rd 5 <- vh), the second at pc+4 (rd 6 <- v1), both ALU ops falling through
    task automatic pair(input logic [63:0] pc, input logic [63:0] vh, input logic [63:0] v1);
        e = '0; e.valid = 1'b1; e.complete = 1'b1; e.pc = pc; e.raw = ADDI; e.rd = 5'd5; e.rd_wen = 1'b1;
        e.value = vh; e.next_pc = pc + 64'd4;
        c = '0; c.cls = QV_FU_ALU;
        e1 = '0; e1.valid = 1'b1; e1.complete = 1'b1; e1.pc = pc + 64'd4; e1.raw = ADDI; e1.rd = 5'd6; e1.rd_wen = 1'b1;
        e1.value = v1; e1.next_pc = pc + 64'd8;
        c1 = '0; c1.cls = QV_FU_ALU;
        tag = 4'd2; tag1 = 4'd3;
        lres = '0; lres1 = '0; lres1_ok = 1'b1; sb_ready = 1'b1;
        hv = 1'b1; hv1 = 1'b1;
    endtask

    // retire what is presented and present nothing for a cycle (so the next case starts outside a sample point)
    task automatic step();
        @(posedge clk); #1;
        hv = 1'b0; hv1 = 1'b0;
        @(posedge clk); #1;
    endtask

    // the case's pair must not retire as one: the head still does, the second waits
    task automatic expect_no_pair(input string name);
        #1;
        check({name, ": the head retires"}, b(pop), 64'd1);
        check({name, ": the second does not"}, b(pop2), 64'd0);
        step();
    endtask

    logic [63:0] o0;

    initial begin
        repeat (3) @(posedge clk);
        #1; rst = 1'b0;
        @(posedge clk); #1;

        // ---- a plain pair, and everything it does ----
        pair(64'h1000, 64'h11, 64'h22);
        #1;
        check("pair: the head retires", b(pop), 64'd1);
        check("pair: the second too", b(pop2), 64'd1);
        check("pair: port 1 writes the head's rd", {58'b0, rf_we, rf_sel}, {58'b0, 1'b1, 5'd5});
        check("pair: port 1 data", rf_data, 64'h11);
        check("pair: port 2 writes the second's rd", {58'b0, rf2_we, rf2_sel}, {58'b0, 1'b1, 5'd6});
        check("pair: port 2 data", rf2_data, 64'h22);
        check("pair: the second's claim is cleared", {57'b0, c2_valid, c2_rd_wen, c2_rd}, {57'b0, 1'b1, 1'b1, 5'd6});
        check("pair: ... by its own tag", {60'b0, c2_tag}, 64'd3);
        check("pair: minstret counts both", {62'b0, ret, ret2}, 64'd3);
        check("pair: no redirect", b(redirect), 64'd0);
        check("pair: channel 1 is the next order", r1_order, r_order + 64'd1);
        check("pair: channel 1 pc", r1_pc_rdata, 64'h1004);
        check("pair: channel 1 next pc", r1_pc_wdata, 64'h1008);
        check("pair: channel 1 rd", {59'b0, r1_rd_addr}, 64'd6);
        check("pair: channel 1 rd value", r1_rd_wdata, 64'h22);
        check("pair: one a cycle never pairs", b(pop2_w1), 64'd0);
        o0 = r_order;
        @(posedge clk); #1;
        check("pair: the order counter moves by two", r_order, o0 + 64'd2);
        check("pair: the architectural pc is past the second", arch_pc, 64'h1008);
        // the next retirement follows the second: it is not an interrupt's first
        pair(64'h1008, 64'h33, 64'h44); hv1 = 1'b0;
        #1;
        check("pair: the retirement after it is no interrupt entry", b(r_intr), 64'd0);
        step();

        // ---- the head's terms ----
        pair(64'h2000, 1, 2); c.xcpt = 1'b1; c.cause = 4'd2;
        #1;
        check("head trap: the second does not retire", b(pop2), 64'd0);
        step();
        pair(64'h2000, 1, 2); c.cls = QV_FU_CSR;                       expect_no_pair("head CSR op");
        pair(64'h2000, 1, 2); c.cls = QV_FU_SYS; c.sys_op = QV_SYS_WFI; expect_no_pair("head system op");
        pair(64'h2000, 1, 2); c.serialize = 1'b1;                      expect_no_pair("head serializes");
        pair(64'h2000, 1, 2); e.raw = FENCE;                           expect_no_pair("head FENCE");
        pair(64'h2000, 1, 2); e.raw = AMO; c.cls = QV_FU_LSU;          expect_no_pair("head atomic");
        pair(64'h2000, 1, 2); e.mispredict = 1'b1; e.next_pc = 64'h3000;
        #1;
        check("head mispredicted: the second does not retire", b(pop2), 64'd0);
        check("head mispredicted: it redirects", b(redirect), 64'd1);
        step();
        pair(64'h2000, 1, 2); pb_act = 1'b1;                           expect_no_pair("a Program Buffer run");
        pb_act = 1'b0;
        pair(64'h2000, 1, 2); dbg_step = 1'b1;                         expect_no_pair("a single step");
        dbg_step = 1'b0;

        // ---- the second's terms ----
        pair(64'h2000, 1, 2); e1.complete = 1'b0;                      expect_no_pair("second not complete");
        pair(64'h2000, 1, 2); hv1 = 1'b0;                              expect_no_pair("no second");
        pair(64'h2000, 1, 2); c1.xcpt = 1'b1; c1.cause = 4'd2;         expect_no_pair("second fault marker");
        pair(64'h2000, 1, 2); c1.trig_exc = 1'b1;                      expect_no_pair("second action-0 trigger");
        pair(64'h2000, 1, 2); c1.trig_debug = 1'b1;                    expect_no_pair("second action-1 trigger");
        pair(64'h2000, 1, 2); c1.cls = QV_FU_CSR;                      expect_no_pair("second CSR op");
        pair(64'h2000, 1, 2); c1.cls = QV_FU_SYS; c1.sys_op = QV_SYS_ECALL; expect_no_pair("second system op");
        pair(64'h2000, 1, 2); c1.serialize = 1'b1;                     expect_no_pair("second serializes");
        pair(64'h2000, 1, 2); e1.raw = FENCE;                          expect_no_pair("second FENCE");
        pair(64'h2000, 1, 2); e1.raw = AMO; c1.cls = QV_FU_LSU;        expect_no_pair("second atomic");
        pair(64'h2000, 1, 2); c1.cls = QV_FU_LSU; lres1_ok = 1'b0;     expect_no_pair("second memory op, no result");
        pair(64'h2000, 1, 2); c1.cls = QV_FU_LSU; lres1.xcpt = 1'b1;   expect_no_pair("second memory fault");

        // ---- the pair's terms ----
        pair(64'h2000, 1, 2); e.raw = SD; c.cls = QV_FU_LSU; lres.posted = 1'b1;
        e1.raw = SD; c1.cls = QV_FU_LSU; lres1.posted = 1'b1;          expect_no_pair("two posted stores");
        pair(64'h2000, 1, 2); e1.raw = SD; c1.cls = QV_FU_LSU; lres1.posted = 1'b1; sb_ready = 1'b0;
        #1;
        check("second posts, no room: the second waits", b(pop2), 64'd0);
        step();
        pair(64'h2000, 1, 2); e.raw = BEQ; c.cls = QV_FU_BRU; e.next_pc = 64'h2008;
        e1.raw = BEQ; c1.cls = QV_FU_BRU; e1.pc = 64'h2008; e1.next_pc = 64'h2010;
        expect_no_pair("two branches");
        pair(64'h2000, 1, 2); c.rd_fp = 1'b1; c1.cls = QV_FU_FPU;       expect_no_pair("two FP-state writes");

        // ---- what a second may do ----
        // a store second clears the LR/SC reservation; an LR alone sets it first
        pair(64'h4000, 1, 2); c.cls = QV_FU_LSU; c.is_lr = 1'b1; e.raw = 32'h1000_b0af; hv1 = 1'b0;
        lres.vaddr = 64'h5550;
        @(posedge clk); #1;
        hv = 1'b0;
        check("an LR sets the reservation", b(res_valid), 64'd1);
        @(posedge clk); #1;
        pair(64'h4004, 1, 2); e1.raw = SD; c1.cls = QV_FU_LSU; c1.is_store_class = 1'b1; e1.rd_wen = 1'b0;
        lres1.posted = 1'b1; lres1.mem_addr = 64'h7770;
        #1;
        check("store second: it retires in the pair", b(pop2), 64'd1);
        check("store second: it is the store pushed", {62'b0, sb_push, sb_push1}, 64'd3);
        check("store second: channel 1 shows its access", r1_mem_addr, 64'h7770);
        @(posedge clk); #1;
        hv = 1'b0; hv1 = 1'b0;
        check("store second: it clears the reservation", b(res_valid), 64'd0);
        @(posedge clk); #1;

        // a mispredicted second redirects to its resolved target
        pair(64'h6000, 1, 2); e1.raw = BEQ; c1.cls = QV_FU_BRU; e1.mispredict = 1'b1; e1.next_pc = 64'h6100;
        e1.rd_wen = 1'b0;
        #1;
        check("mispredicted second: it retires in the pair", b(pop2), 64'd1);
        check("mispredicted second: a redirect", b(redirect), 64'd1);
        check("mispredicted second: to its target", redirect_pc, 64'h6100);
        check("mispredicted second: it trains the predictors", {63'b0, btb_valid}, 64'd1);
        check("mispredicted second: ... at its pc", btb_pc, 64'h6004);
        @(posedge clk); #1;
        hv = 1'b0; hv1 = 1'b0;
        check("mispredicted second: the architectural pc is its target", arch_pc, 64'h6100);
        @(posedge clk); #1;

        // a call second pushes the return address stack (jal x1)
        pair(64'h6200, 1, 2); e1.raw = 32'h0080_00ef; c1.cls = QV_FU_BRU; e1.rd = 5'd1;
        #1;
        check("call second: it retires in the pair", b(pop2), 64'd1);
        check("call second: it pushes the return address", b(ras_push), 64'd1);
        step();

        // an FP second writes its FP register and its flags
        pair(64'h7000, 1, 2); c1.cls = QV_FU_FPU; c1.rd_fp = 1'b1; e1.rd = 5'd9; e1.value = 64'h3ff0; e1.fflags = 5'b00001;
        #1;
        check("FP second: it retires in the pair", b(pop2), 64'd1);
        check("FP second: the FP register write is its", {58'b0, fprf_we, fprf_sel}, {58'b0, 1'b1, 5'd9});
        check("FP second: ... with its value", fprf_data, 64'h3ff0);
        check("FP second: its flags accrue", {59'b0, fp_accrue}, 64'd1);
        check("FP second: no integer write on port 2", b(rf2_we), 64'd0);
        check("FP second: its claim is an FP one", b(c2_rd_fp), 64'd1);
        step();

        // a load second (its memory result at hand)
        pair(64'h7100, 1, 2); c1.cls = QV_FU_LSU; e1.raw = 32'h0000_b303; lres1.mem_addr = 64'h9990;
        #1;
        check("load second: it retires in the pair", b(pop2), 64'd1);
        check("load second: channel 1 shows its access", r1_mem_addr, 64'h9990);
        step();

        $display("");
        $display("qv_commit_pair_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_commit_pair_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: qv_commit_pair_tb");
        $finish;
    end
endmodule
