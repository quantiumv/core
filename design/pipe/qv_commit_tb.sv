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
 *
 * The LR/SC reservation it keeps: set only by an LR that retires cleanly
 * (to the address the LSU reports), cleared by retiring any store-class
 * op -- a store, an SC either way, an AMO -- whether or not it faulted,
 * and left alone by everything else, traps and returns included.
 *
 * Privilege: it starts in M and changes only as core.sv's current_priv does
 * -- a trap goes to S when the instruction ran below M and medeleg has its
 * cause's bit (to M otherwise, and always from M), MRET loads MPP raw (2'b10
 * included, where ECALL gets cause 0), SRET loads SPP (S or U) -- with the
 * ECALL cause following the privilege, the trap vector coming from stvec or
 * mtvec, and SRET returning to sepc.
 *
 * Interrupts: sampled only in the cycle after a retirement, from that
 * cycle's live mip/mie/mideleg/MIE/SIE/privilege; one that is taken replaces
 * the head's commit (nothing retires, the pipe is flushed), goes out on the
 * trap channel with the interrupt bit, no tval and its own delegation,
 * updates privilege and the architectural pc, and leaves the order counter
 * alone so the handler's first retirement reports rvfi_intr.
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
    logic                    fetch_idle = 1'b1;
    logic                    fetch_hold, icache_flush;
    logic                    res_valid;
    logic [63:0]             res_addr;
    logic [63:0]             stvec = '0, sepc = '0, medeleg = '0;
    logic [63:0]             mip = '0, mie = '0, mideleg = '0;
    logic                    mstatus_mie = 1'b0, mstatus_sie = 1'b0, irq_taken;
    logic [1:0]              mpp = 2'b11;
    logic                    spp = 1'b0;
    logic                    sret_taken, trap_to_s;
    logic [1:0]              priv;

    qv_commit #(.RESET_PC(64'h1000)) dut (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(e), .i_head_tag(tag),
        .i_head_shadow(sh), .i_head_ctrl(c), .i_lsu_res(lres), .o_commit_pop(pop),
        .o_res_valid(res_valid), .o_res_addr(res_addr),
        .o_sret_taken(sret_taken), .o_trap_to_s(trap_to_s), .o_priv(priv),
        .i_stvec(stvec), .i_sepc(sepc), .i_medeleg(medeleg),
        .i_mstatus_mpp(mpp), .i_mstatus_spp(spp),
        .i_mip(mip), .i_mie(mie), .i_mideleg(mideleg),
        .i_mstatus_mie(mstatus_mie), .i_mstatus_sie(mstatus_sie), .o_irq_taken(irq_taken),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_csr_addr(csr_addr), .i_csr_rdata(csr_rdata), .o_csr_we(csr_we), .o_csr_wdata(csr_wdata),
        .o_instr_retired(instr_retired), .o_trap_taken(trap_taken), .o_trap_cause(trap_cause),
        .o_trap_val(trap_val), .o_mret_taken(mret_taken), .i_mtvec(mtvec), .i_mepc(mepc),
        .o_fetch_hold(fetch_hold), .i_fetch_idle(fetch_idle), .o_icache_flush(icache_flush),
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

    // a trap that is delegated to S: same checks as expect_trap, but to stvec's base
    task automatic expect_plain_trap_to_s(input string name, input logic [63:0] cause, input logic [63:0] tval,
                                          input logic [63:0] vec);
        #1;
        check({name, ": trap_taken"}, b(trap_taken), 64'd1);
        check({name, ": rvfi_trap"}, b(r_trap), 64'd1);
        check({name, ": cause"}, trap_cause, cause);
        check({name, ": tval"}, trap_val, tval);
        check({name, ": trap_to_s"}, b(trap_to_s), 64'd1);
        check({name, ": not a retirement for minstret"}, b(instr_retired), 64'd0);
        check({name, ": no rd write"}, b(rf_we), 64'd0);
        check({name, ": redirect"}, b(redirect), 64'd1);
        check({name, ": redirect to stvec's base"}, redirect_pc, vec);
        check({name, ": rvfi pc_wdata = vector"}, r_pc_wdata, vec);
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

    // retire one plain ALU entry at the architectural pc, with no interrupt pending while it
    // commits: the next cycle is a sample cycle, with mip as the caller had it
    task automatic plain_retire();
        logic [63:0] save;
        save = mip; mip = '0;
        set_entry(arch_pc, 32'h13, 1, 1'b1, 64'd7);
        retire();
        mip = save;
    endtask

    // move to privilege p by retiring an MRET with MPP = p, with no interrupt pending
    // while it commits; the cycle after it is a sample cycle with mip as the caller had it
    task automatic go_priv(input logic [1:0] p);
        logic [63:0] save;
        save = mip; mip = '0;
        mpp = p;
        set_entry(arch_pc, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        retire();
        mip = save;
    endtask

    // a sample cycle with a complete ALU head presented: the interrupt replaces its commit
    task automatic expect_irq(input string name, input logic [3:0] icause, input logic to_s, input logic [63:0] vec);
        logic [63:0] pc0, ord0;
        pc0 = arch_pc; ord0 = r_order;
        set_entry(arch_pc, 32'h13, 2, 1'b1, 64'd9);
        #1;
        check({name, ": interrupt taken"}, b(irq_taken), 64'd1);
        check({name, ": trap channel"}, b(trap_taken), 64'd1);
        check({name, ": cause = interrupt bit + code"}, trap_cause, {1'b1, 59'b0, icause});
        check({name, ": tval 0"}, trap_val, 64'd0);
        check({name, ": trap_to_s"}, b(trap_to_s), b(to_s));
        check({name, ": head does not commit"}, b(commit_now), 64'd0);
        check({name, ": head not popped"}, b(pop), 64'd0);
        check({name, ": no rd write"}, b(rf_we), 64'd0);
        check({name, ": no retirement counted"}, b(instr_retired), 64'd0);
        check({name, ": no rvfi trap flag"}, b(r_trap), 64'd0);
        check({name, ": redirect"}, b(redirect), 64'd1);
        check({name, ": redirect to the vector"}, redirect_pc, vec);
        check({name, ": arch pc is still the next instruction (becomes mepc)"}, arch_pc, pc0);
        retire();
        check({name, ": arch pc is the vector"}, arch_pc, vec);
        check({name, ": privilege"}, {62'b0, priv}, to_s ? 64'd1 : 64'd3);
        check({name, ": order not advanced"}, r_order, ord0);
    endtask

    // a sample cycle (or not) in which nothing is taken: the head just commits
    task automatic expect_no_irq(input string name);
        set_entry(arch_pc, 32'h13, 2, 1'b1, 64'd9);
        #1;
        check({name, ": no interrupt"}, b(irq_taken), 64'd0);
        check({name, ": head commits"}, b(commit_now), 64'd1);
        check({name, ": no trap"}, b(trap_taken), 64'd0);
        check({name, ": retirement counted"}, b(instr_retired), 64'd1);
        retire();
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        mtvec = 64'h0000_0000_0000_8001;            // MODE bits must be masked off
        mepc  = 64'h0000_0000_0000_4444;
        stvec = 64'h0000_0000_0000_9003;
        sepc  = 64'h0000_0000_0000_5554;
        #1;
        check("reset: arch pc", arch_pc, 64'h1000);
        check("reset: privilege M", {62'b0, priv}, 64'd3);
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

        // ---- the LR/SC reservation ----
        lres = '0;
        check("reservation: none after reset", b(res_valid), 64'd0);
        // a clean LR sets it, to the LSU's exact address
        lres.vaddr = 64'h0000_0001_0000_4008;                  // bits above the bus width count
        set_entry(64'h6000, 32'h1002_B2AF, 5, 1'b1, 64'h77);   // lr.d x5, (x5)
        c.cls = QV_FU_LSU; c.is_lr = 1'b1;
        expect_plain("lr", 1'b0);
        check("lr: not yet set before it retires", b(res_valid), 64'd0);
        retire();
        check("lr: reservation set", b(res_valid), 64'd1);
        check("lr: at its address", res_addr, 64'h0000_0001_0000_4008);
        // an incomplete head changes nothing
        lres = '0; lres.vaddr = 64'h111;
        set_entry(64'h6004, 32'h1002_B2AF, 5, 1'b1, 64'h77);
        c.cls = QV_FU_LSU; c.is_lr = 1'b1; e.complete = 1'b0;
        retire();
        check("incomplete lr: reservation unchanged", res_addr, 64'h0000_0001_0000_4008);
        // a later LR supersedes it
        lres = '0; lres.vaddr = 64'h2468;
        set_entry(64'h6004, 32'h1002_B2AF, 5, 1'b1, 64'h77);
        c.cls = QV_FU_LSU; c.is_lr = 1'b1;
        retire();
        check("second lr: still valid", b(res_valid), 64'd1);
        check("second lr: new address", res_addr, 64'h2468);
        // things that must leave it alone
        lres = '0;
        set_entry(64'h6008, 32'h13, 5, 1'b1, 64'd1);                       // ALU
        retire();
        set_entry(64'h600C, 32'h0108_3283, 5, 1'b1, 64'd1);                // load
        c.cls = QV_FU_LSU;
        retire();
        set_entry(64'h6010, 32'h0000_0073, 0, 1'b0, 64'd0);                // ecall: a trap
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        retire();
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);                // mret
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        retire();
        set_entry(64'h6014, 32'h3400_92F3, 5, 1'b1, 64'd0);                // a CSR write
        c.cls = QV_FU_CSR; c.csr_op = QV_CSR_RW; c.csr_addr = 12'h340; c.serialize = 1'b1;
        retire();
        set_entry(64'h6018, 32'h0000_100F, 0, 1'b0, 64'd0);                // fence.i
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_FENCE_I; c.serialize = 1'b1;
        retire();
        set_entry(64'h601C, 32'h0080_006F, 1, 1'b1, 64'h6020);             // a mispredicted jump
        e.next_pc = 64'h7000; e.mispredict = 1'b1;
        retire();
        check("alu/load/trap/mret/csr/fence.i/jump leave it", b(res_valid), 64'd1);
        check("... and its address", res_addr, 64'h2468);
        // an LR that faults never sets it, and does not disturb a standing one
        lres = '0; lres.xcpt = 1'b1; lres.cause = 4'd6; lres.tval = 64'h3001; lres.vaddr = 64'h3001;
        set_entry(64'h7000, 32'h1002_B2AF, 5, 1'b1, 64'd0);
        c.cls = QV_FU_LSU; c.is_lr = 1'b1;
        expect_trap("faulting lr", 64'd6, 64'h3001);
        retire();
        check("faulting lr: standing reservation untouched", res_addr, 64'h2468);
        check("faulting lr: still valid", b(res_valid), 64'd1);
        // store-class ops clear it, at any address, faulting or not
        for (int k = 0; k < 6; k++) begin
            lres = '0; lres.vaddr = 64'h5000 + 64'(k);
            set_entry(64'h7004, 32'h1002_B2AF, 5, 1'b1, 64'd0);
            c.cls = QV_FU_LSU; c.is_lr = 1'b1;
            retire();
            check($sformatf("setup %0d: reservation held", k), b(res_valid), 64'd1);
            lres = '0;
            set_entry(64'h7008, 32'h0062_3423, 0, 1'b0, 64'd0);
            c.cls = QV_FU_LSU; c.is_store_class = 1'b1;
            case (k)
                0: ;                                                      // a plain store
                1: begin lres.xcpt = 1'b1; lres.cause = 4'd7; end        // a store that faults
                2: begin lres.xcpt = 1'b1; lres.cause = 4'd6; end        // a misaligned store
                3: begin e.rd_wen = 1'b1; e.rd = 5; e.value = 64'd1; end // an SC that failed: rd = 1, no access
                4: begin e.rd_wen = 1'b1; e.rd = 5; end                  // an SC that succeeded
                5: begin e.rd_wen = 1'b1; e.rd = 5; e.value = 64'h99; end// an AMO
            endcase
            retire();
            check($sformatf("store-class variant %0d: reservation cleared", k), b(res_valid), 64'd0);
        end
        // a uop faulted at decode carries no flags, so it leaves the reservation alone
        lres = '0; lres.vaddr = 64'h7777;
        set_entry(64'h7004, 32'h1002_B2AF, 5, 1'b1, 64'd0);
        c.cls = QV_FU_LSU; c.is_lr = 1'b1;
        retire();
        check("setup: held again", b(res_valid), 64'd1);
        lres = '0;
        set_entry(64'h7008, 32'h0000_0000, 0, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd2;
        retire();
        check("a decode fault leaves it", b(res_valid), 64'd1);
        // the store-class flag on an incomplete head does nothing yet
        set_entry(64'h700C, 32'h0062_3423, 0, 1'b0, 64'd0);
        c.cls = QV_FU_LSU; c.is_store_class = 1'b1; e.complete = 1'b0;
        retire();
        check("incomplete store: reservation unchanged", b(res_valid), 64'd1);
        lres = '0;

        // ---- privilege ----
        check("priv: M after reset", {62'b0, priv}, 64'd3);
        // MRET with MPP = S drops to S, to mepc
        mpp = 2'b01;
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        #1;
        check("mret to S: redirect to mepc", redirect_pc, 64'h4444);
        check("mret to S: still M while it retires", {62'b0, priv}, 64'd3);
        retire();
        check("mret to S: now S", {62'b0, priv}, 64'd1);

        // an ECALL in S: cause 9, not delegated -> mtvec, back to M
        medeleg = '0;
        set_entry(64'h4444, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        expect_trap("ecall from S", 64'd9, 64'd0);
        check("ecall from S: to M", b(trap_to_s), 64'd0);
        retire();
        check("ecall from S: priv M", {62'b0, priv}, 64'd3);

        // an ECALL in S with medeleg[9]: delegated to S -> stvec, stays S
        mpp = 2'b01;
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        retire();
        medeleg = 64'h200;
        set_entry(64'h4444, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        #1;
        check("delegated ecall from S: cause 9", trap_cause, 64'd9);
        check("delegated ecall from S: trap_to_s", b(trap_to_s), 64'd1);
        check("delegated ecall from S: to stvec's base", redirect_pc, 64'h9000);
        check("delegated ecall from S: rvfi pc_wdata", r_pc_wdata, 64'h9000);
        check("delegated ecall from S: still a trap", b(trap_taken), 64'd1);
        retire();
        check("delegated ecall from S: priv S", {62'b0, priv}, 64'd1);
        check("delegated ecall from S: arch pc", arch_pc, 64'h9000);

        // SRET with SPP = 0 -> U, to sepc; with SPP = 1 -> S
        spp = 1'b0;
        set_entry(64'h9000, 32'h1020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_SRET;
        #1;
        check("sret: sret_taken", b(sret_taken), 64'd1);
        check("sret: no mret", b(mret_taken), 64'd0);
        check("sret: no trap", b(trap_taken), 64'd0);
        check("sret: counted", b(instr_retired), 64'd1);
        check("sret: redirect", b(redirect), 64'd1);
        check("sret: to sepc", redirect_pc, 64'h5554);
        check("sret: rvfi pc_wdata", r_pc_wdata, 64'h5554);
        check("sret: no rd", b(rf_we), 64'd0);
        retire();
        check("sret: SPP=0 -> U", {62'b0, priv}, 64'd0);
        check("sret: arch pc = sepc", arch_pc, 64'h5554);

        // an ECALL in U: cause 8; medeleg[8] set -> S
        medeleg = 64'h100;
        set_entry(64'h5554, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        expect_plain_trap_to_s("ecall from U (delegated)", 64'd8, 64'd0, 64'h9000);
        retire();
        check("ecall from U delegated: priv S", {62'b0, priv}, 64'd1);
        spp = 1'b1;
        set_entry(64'h9000, 32'h1020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_SRET;
        retire();
        check("sret: SPP=1 -> S", {62'b0, priv}, 64'd1);

        // a fault marked at fetch from S, delegated or not
        medeleg = 64'h2;
        set_entry(64'h6000, 32'h13, 0, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd1;
        expect_plain_trap_to_s("fetch fault from S (delegated)", 64'd1, 64'h6000, 64'h9000);
        retire();
        check("fetch fault delegated: priv S", {62'b0, priv}, 64'd1);
        medeleg = 64'h4;                                  // illegal-instruction delegated, access fault not
        set_entry(64'h6000, 32'h13, 0, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("fetch fault from S (not delegated)", 64'd1, 64'h6000);
        check("fetch fault not delegated: to M", b(trap_to_s), 64'd0);
        retire();
        check("fetch fault not delegated: priv M", {62'b0, priv}, 64'd3);

        // from M a trap is never delegated, whatever medeleg says
        medeleg = '1;
        set_entry(64'h6000, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        expect_trap("ecall from M, medeleg all ones", 64'd11, 64'd0);
        check("ecall from M: to M", b(trap_to_s), 64'd0);
        retire();
        check("ecall from M: stays M", {62'b0, priv}, 64'd3);

        // memory faults delegate by their cause bit too
        mpp = 2'b01;
        set_entry(64'h8000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        retire();
        medeleg = 64'h20;                                 // load access fault (5)
        lres = '0; lres.xcpt = 1'b1; lres.cause = 4'd5; lres.tval = 64'h20_0000;
        set_entry(64'h4444, 32'h0002_3283, 5, 1'b1, 64'd1);
        c.cls = QV_FU_LSU;
        expect_plain_trap_to_s("load access fault from S (delegated)", 64'd5, 64'h20_0000, 64'h9000);
        retire();
        check("load access fault delegated: S", {62'b0, priv}, 64'd1);
        lres = '0;
        medeleg = '0;

        // MPP is loaded raw: 2'b10 is a privilege of its own
        mpp = 2'b10;
        set_entry(64'h9000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        retire();
        check("mret with MPP = 2'b10 loads 2'b10", {62'b0, priv}, 64'd2);
        set_entry(64'h4444, 32'h0000_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        expect_trap("ecall at privilege 2: cause 0", 64'd0, 64'd0);
        check("ecall at privilege 2, no medeleg[0]: to M", b(trap_to_s), 64'd0);
        medeleg = 64'h1;
        #1;
        check("ecall at privilege 2, medeleg[0]: delegated (it is below M)", b(trap_to_s), 64'd1);
        check("ecall at privilege 2, delegated: stvec", redirect_pc, 64'h9000);
        retire();
        check("ecall at privilege 2, delegated: S", {62'b0, priv}, 64'd1);
        medeleg = '0;
        // back to M for the rest
        mpp = 2'b11;
        set_entry(64'h9000, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET;
        #1;
        check("mret from S is just executed (decode guards legality)", b(mret_taken), 64'd1);
        retire();
        check("mret with MPP = M", {62'b0, priv}, 64'd3);

        // a trap wins over an xRET on the same entry: privilege follows the trap
        mpp = 2'b00; spp = 1'b0;
        set_entry(64'h4444, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("faulted mret", 64'd1, 64'h4444);
        check("faulted mret: no mret", b(mret_taken), 64'd0);
        retire();
        check("faulted mret: priv from the trap (M), not MPP", {62'b0, priv}, 64'd3);
        set_entry(64'h4444, 32'h1020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_SRET; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("faulted sret", 64'd1, 64'h4444);
        check("faulted sret: no sret", b(sret_taken), 64'd0);
        retire();
        check("faulted sret: priv M", {62'b0, priv}, 64'd3);

        // an incomplete head changes nothing, and neither do ordinary retirements
        mpp = 2'b00;
        set_entry(64'h4444, 32'h3020_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_MRET; e.complete = 1'b0;
        retire();
        check("incomplete mret: priv unchanged", {62'b0, priv}, 64'd3);
        set_entry(64'h4444, 32'h13, 5, 1'b1, 64'd1);
        retire();
        set_entry(64'h4448, 32'h1050_0073, 0, 1'b0, 64'd0);      // wfi
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_WFI;
        retire();
        set_entry(64'h444C, 32'h1200_0073, 0, 1'b0, 64'd0);      // sfence.vma: a serializing no-op
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_SFENCE_VMA; c.serialize = 1'b1;
        expect_plain("sfence.vma", 1'b1);
        check("sfence.vma: no trap, no xRET", b(trap_taken | mret_taken | sret_taken), 64'd0);
        retire();
        check("wfi/alu/sfence.vma: priv unchanged", {62'b0, priv}, 64'd3);
        mpp = 2'b11; spp = 1'b0; medeleg = '0;

        // ---- FENCE.I: fetch held until idle, then flush + serializing refetch ----
        check("no fence.i head: no hold", b(fetch_hold), 64'd0);
        fetch_idle = 1'b0;
        set_entry(64'h5000, 32'h0000_100F, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_FENCE_I; c.serialize = 1'b1;
        e.complete = 1'b0;
        #1;
        check("fence.i incomplete: fetch already held", b(fetch_hold), 64'd1);
        e.complete = 1'b1;
        repeat (2) begin
            #1;
            check("fence.i, fetch busy: held", b(fetch_hold), 64'd1);
            check("fence.i, fetch busy: no commit", b(commit_now), 64'd0);
            check("fence.i, fetch busy: no pop", b(pop), 64'd0);
            check("fence.i, fetch busy: no flush", b(icache_flush), 64'd0);
            check("fence.i, fetch busy: no redirect", b(redirect), 64'd0);
            check("fence.i, fetch busy: not counted", b(instr_retired), 64'd0);
            @(posedge clk);
        end
        fetch_idle = 1'b1;
        expect_plain("fence.i, fetch idle", 1'b1);
        check("fence.i: flush pulse", b(icache_flush), 64'd1);
        check("fence.i: fetch still held in its commit cycle", b(fetch_hold), 64'd1);
        check("fence.i: no rd write", b(rf_we), 64'd0);
        check("fence.i: rvfi rd 0", {59'b0, r_rd_addr}, 64'd0);
        retire();
        #1;
        check("after fence.i: no flush", b(icache_flush), 64'd0);
        check("after fence.i: hold released", b(fetch_hold), 64'd0);

        // a FENCE.I marked with a fetch fault just traps, fetch busy or not
        fetch_idle = 1'b0;
        set_entry(64'h5004, 32'h0000_100F, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_FENCE_I; c.xcpt = 1'b1; c.cause = 4'd1;
        expect_trap("faulted fence.i", 64'd1, 64'h5004);
        check("faulted fence.i: no flush", b(icache_flush), 64'd0);
        check("faulted fence.i: no hold", b(fetch_hold), 64'd0);
        retire();

        // other heads ignore fetch_idle
        set_entry(64'h8000, 32'h13, 1, 1'b1, 64'd3);
        expect_plain("alu, fetch busy", 1'b0);
        check("alu, fetch busy: no hold", b(fetch_hold), 64'd0);
        retire();
        fetch_idle = 1'b1;

        // ---- interrupts ----
        mip = '0; mie = '0; mideleg = '0; medeleg = '0; mstatus_mie = 1'b0; mstatus_sie = 1'b0;
        mpp = 2'b11; spp = 1'b0;
        go_priv(2'b11);
        check("interrupts: start in M", {62'b0, priv}, 64'd3);
        plain_retire();
        expect_no_irq("nothing pending");

        // MTI in M with MIE set: taken to M through mtvec
        mie = 64'h80; mip = 64'h80; mstatus_mie = 1'b1;
        plain_retire();
        expect_irq("MTI in M", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        // the cycle after the entry is not a sample point: the handler's first
        // instruction retires, flagged as an interrupt entry
        set_entry(arch_pc, 32'h13, 3, 1'b1, 64'd5);
        #1;
        check("after entry: no second interrupt", b(irq_taken), 64'd0);
        check("after entry: handler instruction commits", b(commit_now), 64'd1);
        check("after entry: rvfi_intr on it", b(r_intr), 64'd1);
        retire();
        // still pending and enabled: taken again at the next sample point
        expect_irq("MTI again after one handler retirement", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = '0;

        // not enabled: MIE clear in M, the source's own enable clear, other mip bits
        mstatus_mie = 1'b0; mie = 64'h80; mip = 64'h80;
        plain_retire();
        expect_no_irq("MTI pending, MIE=0 in M");
        mstatus_mie = 1'b1; mie = '0;
        plain_retire();
        expect_no_irq("MTI pending, MTIE clear");
        mie = 64'hFFFF; mip = 64'h002A;               // SSIP, MSIP, STIP: no source here
        plain_retire();
        expect_no_irq("SSIP/MSIP/STIP pending are not sources");

        // sampled only in the cycle after a retirement: enabling it in a later cycle
        // does not take it until the next retirement has happened
        mie = '0; mip = 64'h80;
        plain_retire();                                // sample cycle follows, nothing enabled
        @(posedge clk); #1;                            // an idle cycle: no retirement, not a sample cycle
        mie = 64'h80;
        expect_no_irq("MTI enabled outside a sample cycle");
        expect_irq("MTI at the next sample point", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = '0;

        // an empty ROB does not matter: the interrupt comes with no head at all
        mie = 64'h80; mip = '0;
        plain_retire();
        mip = 64'h80;
        #1;
        check("empty ROB: interrupt taken", b(irq_taken), 64'd1);
        check("empty ROB: redirect", b(redirect), 64'd1);
        retire();
        mip = '0;
        go_priv(2'b11);

        // below M a non-delegated interrupt is enabled whatever MIE says
        mstatus_mie = 1'b0; mie = 64'h80; mideleg = '0;
        mip = 64'h80; go_priv(2'b01);
        expect_irq("MTI in S, MIE=0", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = 64'h80; go_priv(2'b00);
        expect_irq("MTI in U, MIE=0", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        // privilege 2'b10 is not M either (MPP is loaded raw)
        mip = 64'h80; go_priv(2'b10);
        check("MPP = 2'b10 reached", {62'b0, priv}, 64'd2);
        expect_irq("MTI at privilege 2", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = '0;

        // delegated: enabled in U, in S with SIE, never in M
        mideleg = 64'h80; mie = 64'h80; mstatus_mie = 1'b1; mstatus_sie = 1'b0;
        mip = 64'h80; go_priv(2'b01);
        expect_no_irq("delegated MTI in S, SIE=0");
        mstatus_sie = 1'b1;
        plain_retire();
        expect_irq("delegated MTI in S, SIE=1", 4'd7, 1'b1, {stvec[63:2], 2'b00});
        mstatus_sie = 1'b0;
        mip = 64'h80; go_priv(2'b00);
        expect_irq("delegated MTI in U, SIE=0", 4'd7, 1'b1, {stvec[63:2], 2'b00});
        mip = 64'h80; go_priv(2'b11);
        expect_no_irq("delegated MTI in M, MIE=1");
        mip = 64'h80; go_priv(2'b10);
        expect_no_irq("delegated MTI at privilege 2");
        mip = '0; mideleg = '0;

        // priority MEI > MTI > SEI, and the route follows the one taken
        mstatus_mie = 1'b1; mstatus_sie = 1'b1; go_priv(2'b11);
        mie = 64'hA80; mip = 64'hA80;
        plain_retire();
        expect_irq("MEI beats MTI and SEI", 4'd11, 1'b0, {mtvec[63:2], 2'b00});
        mie = 64'hA80; mip = 64'hA80; go_priv(2'b11);
        mie = 64'h280;
        plain_retire();
        expect_irq("MTI beats SEI", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mie = 64'h280; mip = 64'hA80; go_priv(2'b11);
        mie = 64'h200;
        plain_retire();
        expect_irq("SEI alone", 4'd9, 1'b0, {mtvec[63:2], 2'b00});
        mideleg = 64'h200; mie = 64'h200; mip = 64'h200; go_priv(2'b00);
        expect_irq("delegated SEI in U", 4'd9, 1'b1, {stvec[63:2], 2'b00});
        // MEI undelegated outranks a delegated MTI: M route
        mideleg = 64'h080; mie = 64'hA80; mip = 64'hA80; go_priv(2'b00);
        expect_irq("MEI (M) beats delegated MTI", 4'd11, 1'b0, {mtvec[63:2], 2'b00});
        // MEI delegated outranks MTI: S route
        mideleg = 64'h800; mie = 64'hA80; mip = 64'hA80; go_priv(2'b00);
        expect_irq("delegated MEI beats MTI", 4'd11, 1'b1, {stvec[63:2], 2'b00});
        // MEI masked: the route belongs to the MTI that is taken instead
        mideleg = 64'h800; mie = 64'h280; mip = 64'hA80; go_priv(2'b00);
        expect_irq("MTI taken while MEI is masked: its own (M) route", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = '0; mideleg = '0;

        // every source has its own enables below M and when delegated
        mideleg = '0; mie = 64'hA80; mstatus_mie = 1'b0; mstatus_sie = 1'b0;
        mie = 64'h800; mip = 64'h800; go_priv(2'b01);
        expect_irq("MEI in S, MIE=0", 4'd11, 1'b0, {mtvec[63:2], 2'b00});
        mie = 64'h200; mip = 64'h200; go_priv(2'b00);
        expect_irq("SEI in U, MIE=0", 4'd9, 1'b0, {mtvec[63:2], 2'b00});
        mideleg = 64'h200; mie = 64'h200; mip = 64'h200; mstatus_sie = 1'b0; go_priv(2'b01);
        expect_no_irq("delegated SEI in S, SIE=0");
        mstatus_sie = 1'b1;
        plain_retire();
        expect_irq("delegated SEI in S, SIE=1", 4'd9, 1'b1, {stvec[63:2], 2'b00});
        mideleg = 64'h800; mie = 64'h800; mip = 64'h800; mstatus_sie = 1'b0; go_priv(2'b01);
        expect_no_irq("delegated MEI in S, SIE=0");
        mstatus_sie = 1'b1;
        plain_retire();
        expect_irq("delegated MEI in S, SIE=1", 4'd11, 1'b1, {stvec[63:2], 2'b00});
        mip = '0; mideleg = '0; mstatus_sie = 1'b0;

        // a faulted head in the sample cycle: the interrupt carries no tval of its own
        mie = 64'h80; mip = '0; mstatus_mie = 1'b1; go_priv(2'b11);
        plain_retire();
        mip = 64'h80;
        set_entry(arch_pc, 32'h0000_0000, 0, 1'b0, 64'd0);
        c.xcpt = 1'b1; c.cause = 4'd1;                          // a fetch fault: its tval would be the pc
        #1;
        check("faulted head vs interrupt: interrupt", b(irq_taken), 64'd1);
        check("faulted head vs interrupt: cause", trap_cause, {1'b1, 59'b0, 4'd7});
        check("faulted head vs interrupt: tval 0", trap_val, 64'd0);
        retire();
        mip = '0;

        // right after a trap: the architectural pc is the handler's vector
        mie = 64'h80; mstatus_mie = 1'b1; go_priv(2'b11);
        set_entry(arch_pc, 32'h0000_0073, 0, 1'b0, 64'd0);       // ecall, no interrupt yet
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        retire();
        check("after a trap: arch pc is the vector", arch_pc, {mtvec[63:2], 2'b00});
        mip = 64'h80;
        expect_irq("interrupt right after a trap", 4'd7, 1'b0, {mtvec[63:2], 2'b00});
        mip = '0;

        // FENCE.I at the head of a sample cycle: the interrupt wins, no flush
        go_priv(2'b11);
        plain_retire();
        mip = 64'h80;
        set_entry(arch_pc, 32'h0000_100F, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_FENCE_I; c.serialize = 1'b1;
        #1;
        check("fence.i vs interrupt: interrupt", b(irq_taken), 64'd1);
        check("fence.i vs interrupt: no flush", b(icache_flush), 64'd0);
        check("fence.i vs interrupt: no commit", b(commit_now), 64'd0);
        retire();
        mip = '0; mie = '0; mstatus_mie = 1'b0; mideleg = '0;
        go_priv(2'b11);

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
