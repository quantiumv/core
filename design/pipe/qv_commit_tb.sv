// SPDX-License-Identifier: MIT

/*
 * qv_commit_tb -- standalone test for design/pipe/qv_commit.sv.
 *
 * Drives the ROB head directly, one entry at a time, and checks every
 * side effect of retiring it: regfile write, csr_file0 side channels
 * (CSR read-modify-write, trap cause/tval, mret, retirement count),
 * redirect, the architectural pc and RVFI. Covers what the end-to-end
 * RVFI diff can't reach yet: fetch faults (mtval = pc), an exception on
 * an entry that would otherwise be a system op, and mtvec's MODE bits.
 */
module qv_commit_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    head_valid = 1'b0;
    rob_entry_t              e = '0;
    rvfi_shadow_t            sh = '0;
    rob_ctrl_t               c = '0;
    logic [QV_ROB_TAG_W-1:0] tag = '0;
    logic [63:0]             csr_rdata = '0, mtvec = '0, mepc = '0;

    logic                    pop, rf_we, c_valid, c_rd_wen, csr_we, instr_retired, trap_taken, mret_taken;
    logic                    commit_now, redirect, r_trap, r_intr;
    logic [4:0]              rf_sel, c_rd, r_rs1_addr, r_rs2_addr, r_rd_addr;
    logic [QV_ROB_TAG_W-1:0] c_tag;
    logic [11:0]             csr_addr;
    logic [63:0]             rf_data, csr_wdata, trap_cause, trap_val, arch_pc, next_pc, redirect_pc;
    logic [63:0]             r_order, r_rs1_rdata, r_rs2_rdata, r_rd_wdata, r_pc_rdata, r_pc_wdata;
    logic [31:0]             r_insn;
    lsu_res_t                lres = '0;
    logic [63:0]             r_mem_addr, r_mem_rdata, r_mem_wdata;
    logic [7:0]              r_mem_rmask, r_mem_wmask;

    qv_commit #(.RESET_PC(64'h1000)) dut (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(e), .i_head_tag(tag),
        .i_head_shadow(sh), .i_head_ctrl(c), .i_lsu_res(lres), .o_commit_pop(pop),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_csr_addr(csr_addr), .i_csr_rdata(csr_rdata), .o_csr_we(csr_we), .o_csr_wdata(csr_wdata),
        .o_instr_retired(instr_retired), .o_trap_taken(trap_taken), .o_trap_cause(trap_cause),
        .o_trap_val(trap_val), .o_mret_taken(mret_taken), .i_mtvec(mtvec), .i_mepc(mepc),
        .o_commit_now(commit_now), .o_pc(arch_pc), .o_next_pc(next_pc),
        .o_redirect_valid(redirect), .o_redirect_pc(redirect_pc),
        .o_rvfi_order(r_order), .o_rvfi_insn(r_insn), .o_rvfi_trap(r_trap), .o_rvfi_intr(r_intr),
        .o_rvfi_rs1_addr(r_rs1_addr), .o_rvfi_rs2_addr(r_rs2_addr),
        .o_rvfi_rs1_rdata(r_rs1_rdata), .o_rvfi_rs2_rdata(r_rs2_rdata),
        .o_rvfi_rd_addr(r_rd_addr), .o_rvfi_rd_wdata(r_rd_wdata),
        .o_rvfi_pc_rdata(r_pc_rdata), .o_rvfi_pc_wdata(r_pc_wdata),
        .o_rvfi_mem_addr(r_mem_addr), .o_rvfi_mem_rmask(r_mem_rmask), .o_rvfi_mem_wmask(r_mem_wmask),
        .o_rvfi_mem_rdata(r_mem_rdata), .o_rvfi_mem_wdata(r_mem_wdata)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // a complete ALU-style entry at pc, falling through to pc+4
    task automatic set_entry(input logic [63:0] pc, input logic [31:0] raw, input logic [4:0] rd,
                             input logic rd_wen, input logic [63:0] value);
        e            = '0;
        e.valid      = 1'b1;
        e.complete   = 1'b1;
        e.pc         = pc;
        e.raw        = raw;
        e.rd         = rd;
        e.rd_wen     = rd_wen;
        e.value      = value;
        e.next_pc    = pc + 64'd4;
        c            = '0;
        c.cls        = QV_FU_ALU;
        head_valid   = 1'b1;
    endtask

    // check the combinational outputs for the presented entry, then retire it
    task automatic retire();
        @(posedge clk); #1;
        head_valid = 1'b0;
        e = '0; c = '0;
    endtask

    task automatic expect_trap(input string name, input logic [63:0] cause, input logic [63:0] tval);
        #1;
        check({name, ": trap_taken"}, b(trap_taken), 64'd1);
        check({name, ": rvfi_trap"}, b(r_trap), 64'd1);
        check({name, ": cause"}, trap_cause, cause);
        check({name, ": tval"}, trap_val, tval);
        check({name, ": not a retirement for minstret"}, b(instr_retired), 64'd0);
        check({name, ": no CSR write"}, b(csr_we), 64'd0);
        check({name, ": no mret"}, b(mret_taken), 64'd0);
        check({name, ": no rd write"}, b(rf_we), 64'd0);
        check({name, ": redirect"}, b(redirect), 64'd1);
        check({name, ": redirect to mtvec base"}, redirect_pc, {mtvec[63:2], 2'b00});
        check({name, ": rvfi pc_wdata = vector"}, r_pc_wdata, {mtvec[63:2], 2'b00});
        check({name, ": still a commit (rvfi_valid)"}, b(commit_now), 64'd1);
    endtask

    task automatic expect_plain(input string name, input logic exp_redirect);
        #1;
        check({name, ": no trap"}, b(trap_taken), 64'd0);
        check({name, ": rvfi_trap 0"}, b(r_trap), 64'd0);
        check({name, ": retirement counted"}, b(instr_retired), 64'd1);
        check({name, ": redirect"}, b(redirect), b(exp_redirect));
        check({name, ": next pc"}, next_pc, e.next_pc);
        if (exp_redirect) check({name, ": redirect pc"}, redirect_pc, e.next_pc);
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        mtvec = 64'h0000_0000_0000_8001;            // MODE bits must be masked off
        mepc  = 64'h0000_0000_0000_4444;
        #1;
        check("reset: arch pc", arch_pc, 64'h1000);
        check("idle: no commit", b(commit_now), 64'd0);
        check("idle: no redirect", b(redirect), 64'd0);

        // ---- plain ALU result ----
        set_entry(64'h1000, 32'h0050_0293, 5, 1'b1, 64'hABCD);
        sh.rs1_addr = 7; sh.rs1_rdata = 64'h77;
        expect_plain("alu", 1'b0);
        check("alu: rd write", b(rf_we), 64'd1);
        check("alu: rd sel", {59'b0, rf_sel}, 64'd5);
        check("alu: rd data", rf_data, 64'hABCD);
        check("alu: rvfi rd", r_rd_wdata, 64'hABCD);
        check("alu: rvfi rs1", r_rs1_rdata, 64'h77);
        check("alu: order 0", r_order, 64'd0);
        check("alu: not intr", b(r_intr), 64'd0);
        retire();
        check("alu: arch pc advanced", arch_pc, 64'h1004);

        // ---- incomplete head never commits ----
        set_entry(64'h1004, 32'h13, 1, 1'b1, 64'd1);
        e.complete = 1'b0;
        #1;
        check("incomplete: no commit", b(commit_now), 64'd0);
        check("incomplete: no rd write", b(rf_we), 64'd0);
        check("incomplete: no retirement count", b(instr_retired), 64'd0);
        retire();
        check("incomplete: arch pc unchanged", arch_pc, 64'h1004);

        // ---- mispredict and serialize redirect to the entry's next pc ----
        set_entry(64'h1004, 32'h0080_006F, 1, 1'b1, 64'h1008);
        e.next_pc = 64'h2000; e.mispredict = 1'b1;
        expect_plain("mispredict", 1'b1);
        check("mispredict: link written", rf_data, 64'h1008);
        retire();
        check("mispredict: arch pc = target", arch_pc, 64'h2000);
        set_entry(64'h2000, 32'h13, 0, 1'b0, 64'd0);
        c.serialize = 1'b1;
        expect_plain("serialize", 1'b1);
        retire();

        // ---- traps ----
        set_entry(64'h2004, 32'h0000_0000, 0, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd2;
        expect_trap("illegal (zero word)", 64'd2, 64'd0);
        retire();
        check("illegal: arch pc = vector", arch_pc, 64'h8000);
        check("illegal: order counts every commit, trapped or not", r_order, 64'd4);

        set_entry(64'h8000, 32'hF147_9873, 16, 1'b0, 64'd0);   // csrrw x16, mhartid, x15
        c.xcpt = 1'b1; c.cause = 4'd2; c.cls = QV_FU_ALU;
        expect_trap("illegal: tval = instruction bits", 64'd2, 64'hF147_9873);
        retire();

        set_entry(64'h3000, 32'h0000_0013, 1, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("fetch fault: tval = pc", 64'd1, 64'h3000);
        check("fetch fault: intr (pc != previous pc_wdata)", b(r_intr), 64'd1);
        retire();

        set_entry(64'h8000, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        expect_trap("ecall", 64'd11, 64'd0);
        retire();

        set_entry(64'h8000, 32'h0010_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_EBREAK;
        expect_trap("ebreak", 64'd3, 64'd0);
        retire();

        // a marked fault wins over the system op it would otherwise be
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("fault beats mret", 64'd1, 64'h8000);
        check("fault beats mret: no mret", b(mret_taken), 64'd0);
        retire();
        set_entry(64'h8000, 32'h3403_12F3, 5, 1'b0, 64'd7);
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RW; c.csr_addr = 12'h340; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("fault beats csr", 64'd1, 64'h8000);
        retire();

        // ---- MRET ----
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        #1;
        check("mret: mret_taken", b(mret_taken), 64'd1);
        check("mret: no trap", b(trap_taken), 64'd0);
        check("mret: counted", b(instr_retired), 64'd1);
        check("mret: redirect", b(redirect), 64'd1);
        check("mret: to mepc", redirect_pc, 64'h4444);
        check("mret: rvfi pc_wdata", r_pc_wdata, 64'h4444);
        retire();
        check("mret: arch pc = mepc", arch_pc, 64'h4444);

        // ---- WFI: a plain retirement ----
        set_entry(64'h4444, 32'h1050_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_WFI;
        expect_plain("wfi", 1'b0);
        check("wfi: no mret", b(mret_taken), 64'd0);
        retire();

        // ---- CSR read-modify-write ----
        csr_rdata = 64'hF0F0_0000_0000_FF00;
        set_entry(64'h4448, 32'h3400_92F3, 5, 1'b1, 64'h0000_0000_0000_0F0F);   // src = 0x0F0F
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RW; c.csr_addr = 12'h340; c.serialize = 1'b1;
        expect_plain("csrrw", 1'b1);
        check("csrrw: addr", {52'b0, csr_addr}, 64'h340);
        check("csrrw: we", b(csr_we), 64'd1);
        check("csrrw: wdata = src", csr_wdata, 64'h0F0F);
        check("csrrw: rd = old", rf_data, csr_rdata);
        check("csrrw: rvfi rd = old", r_rd_wdata, csr_rdata);
        retire();
        set_entry(64'h444C, 32'h3400_A2F3, 5, 1'b1, 64'h0000_0000_0000_0F0F);
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RS; c.csr_addr = 12'h340;
        #1;
        check("csrrs: wdata = old | src", csr_wdata, 64'hF0F0_0000_0000_FF0F);
        retire();
        set_entry(64'h4450, 32'h3400_B2F3, 5, 1'b1, 64'h0000_0000_0000_0F0F);
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RC; c.csr_addr = 12'h340;
        #1;
        check("csrrc: wdata = old & ~src", csr_wdata, 64'hF0F0_0000_0000_F000);
        retire();
        // write-suppressed: still reads into rd, never writes
        set_entry(64'h4454, 32'h3400_22F3, 5, 1'b1, 64'd0);
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RS; c.csr_addr = 12'h340; c.csr_wsup = 1'b1;
        #1;
        check("csrr (suppressed): no we", b(csr_we), 64'd0);
        check("csrr (suppressed): rd = old", rf_data, csr_rdata);
        retire();
        // an ALU entry never touches the CSR file, whatever its csr fields say
        set_entry(64'h4458, 32'h13, 5, 1'b1, 64'd9);
        c.csr_addr = 12'h340;
        #1;
        check("alu with csr fields: no we", b(csr_we), 64'd0);
        check("alu with csr fields: rd = value", rf_data, 64'd9);
        retire();

        // ---- memory ops: the LSU's result decides trap vs retire ----
        // a clean load: rd gets the value, RVFI memory fields come from the LSU
        lres = '0;
        lres.mem_addr = 64'h1_0010; lres.mem_rmask = 8'hF0; lres.mem_rdata = 64'hAAAA_BBBB_CCCC_DDDD;
        lres.mem_wdata = 64'h1234;
        set_entry(64'h445C, 32'h0108_3283, 5, 1'b1, 64'hFFFF_FFFF_AAAA_BBBB);   // lw x5, 16(x16)
        c.cls = QV_FU_LSU;
        expect_plain("load", 1'b0);
        check("load: rd write", b(rf_we), 64'd1);
        check("load: rd value", rf_data, 64'hFFFF_FFFF_AAAA_BBBB);
        check("load: rvfi rd", r_rd_wdata, 64'hFFFF_FFFF_AAAA_BBBB);
        check("load: rvfi mem addr", r_mem_addr, 64'h1_0010);
        check("load: rvfi rmask", {56'b0, r_mem_rmask}, 64'hF0);
        check("load: rvfi wmask", {56'b0, r_mem_wmask}, 64'h0);
        check("load: rvfi rdata (raw)", r_mem_rdata, 64'hAAAA_BBBB_CCCC_DDDD);
        retire();
        // a misaligned load: traps with the LSU's cause and tval, and even
        // though rd_wen is set (decode can't know) nothing is written
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd4; lres.tval = 64'h1_0003;
        lres.mem_addr = 64'h1_0000; lres.mem_rmask = 8'h78;
        set_entry(64'h4460, 32'h0038_3283, 5, 1'b1, 64'h55);
        c.cls = QV_FU_LSU;
        expect_trap("misaligned load", 64'd4, 64'h1_0003);
        check("misaligned load: no rvfi rd", {59'b0, r_rd_addr}, 64'd0);
        check("misaligned load: rvfi rd data 0", r_rd_wdata, 64'd0);
        check("misaligned load: would-be addr still reported", r_mem_addr, 64'h1_0000);
        check("misaligned load: would-be rmask still reported", {56'b0, r_mem_rmask}, 64'h78);
        retire();
        // a store that hits a bus error
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd7; lres.tval = 64'h20_0008;
        lres.mem_addr = 64'h20_0008; lres.mem_wmask = 8'hFF; lres.mem_wdata = 64'h77;
        set_entry(64'h8000, 32'h0062_3423, 0, 1'b0, 64'd0);   // sd x6, 8(x4)
        c.cls = QV_FU_LSU;
        expect_trap("store access fault", 64'd7, 64'h20_0008);
        check("store access fault: wmask reported", {56'b0, r_mem_wmask}, 64'hFF);
        retire();
        // a load access fault
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd5; lres.tval = 64'h20_0000;
        set_entry(64'h8000, 32'h0002_3283, 5, 1'b1, 64'd1);
        c.cls = QV_FU_LSU;
        expect_trap("load access fault", 64'd5, 64'h20_0000);
        retire();
        // a misaligned store
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd6; lres.tval = 64'h1_0001;
        set_entry(64'h8000, 32'h0062_10A3, 0, 1'b0, 64'd0);
        c.cls = QV_FU_LSU;
        expect_trap("misaligned store", 64'd6, 64'h1_0001);
        retire();
        // a fault marked at fetch wins over whatever the LSU result says
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd5; lres.tval = 64'hBAD;
        set_entry(64'h9000, 32'h0, 5, 1'b0, 64'd0);
        c.cls = QV_FU_ALU; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("fetch fault beats a stale LSU result", 64'd1, 64'h9000);
        retire();
        // a non-memory entry ignores the LSU result entirely
        lres = '0;
        lres.xcpt = 1'b1; lres.cause = 4'd5; lres.mem_addr = 64'h1234; lres.mem_rmask = 8'hFF;
        set_entry(64'h9000, 32'h13, 5, 1'b1, 64'd3);
        expect_plain("alu with a stale LSU result", 1'b0);
        check("alu with a stale LSU result: rd written", b(rf_we), 64'd1);
        check("alu with a stale LSU result: mem addr 0", r_mem_addr, 64'd0);
        check("alu with a stale LSU result: rmask 0", {56'b0, r_mem_rmask}, 64'd0);
        retire();
        lres = '0;

        $display("");
        $display("qv_commit_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_commit_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: qv_commit_tb");
        $finish;
    end
endmodule
