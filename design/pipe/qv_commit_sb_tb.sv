// SPDX-License-Identifier: MIT

/*
 * qv_commit_sb_tb -- the store-buffer side of design/pipe/qv_commit.sv, on its own so qv_commit_tb keeps
 * testing commit without it.
 *
 * A store the LSU posted (lsu_res.posted) retires only while the buffer has room, and is pushed in the very
 * cycle it retires -- never when an interrupt or a halt takes the slot, never when it does not retire. Any
 * other memory op retires whatever the buffer says. FENCE.I and an EBREAK that traps wait for an empty buffer
 * (FENCE.I also for fetch to be idle, and its fetch hold is up meanwhile); an EBREAK that enters Debug Mode is
 * not a retirement and does not wait; every other head ignores both signals.
 */
module qv_commit_sb_tb;
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
    logic                    dbg_halt = 1'b0, dbg_step = 1'b0, dbg_in = 1'b0, dbg_resume = 1'b0;
    logic [63:0]             dpc = '0, dcsr = '0;
    logic                    dbg_entry, dbg_halt_entry, dbg_ebreak_entry, dbg_trigger_entry;
    logic                    pb_act = 1'b0, pb_commit, pb_done, pb_abort;
    logic [2:0]              dbg_cause;
    logic                    sfence, redirect_ctx;
    logic                    sb_ready = 1'b1, sb_empty = 1'b1, sb_push;

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
        .i_dbg_halt_req(dbg_halt), .i_dbg_stepping(dbg_step), .i_dbg_in_debug(dbg_in), .i_dbg_resume(dbg_resume),
        .i_dpc(dpc), .i_dcsr(dcsr), .o_dbg_entry(dbg_entry), .o_dbg_cause(dbg_cause), .o_dbg_halt_entry(dbg_halt_entry),
        .o_dbg_ebreak_entry(dbg_ebreak_entry), .o_dbg_trigger_entry(dbg_trigger_entry),
        .i_pb_active(pb_act), .o_pb_commit(pb_commit), .o_pb_done(pb_done), .o_pb_abort(pb_abort),
        .o_sfence(sfence),
        .i_sb_ready(sb_ready), .i_sb_empty(sb_empty), .o_sb_push(sb_push),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_csr_addr(csr_addr), .i_csr_rdata(csr_rdata), .o_csr_we(csr_we), .o_csr_wdata(csr_wdata),
        .o_instr_retired(instr_retired), .o_trap_taken(trap_taken), .o_trap_cause(trap_cause),
        .o_trap_val(trap_val), .o_mret_taken(mret_taken), .i_mtvec(mtvec), .i_mepc(mepc),
        .o_fetch_hold(fetch_hold), .i_fetch_idle(fetch_idle), .o_icache_flush(icache_flush),
        .o_commit_now(commit_now), .o_pc(arch_pc), .o_next_pc(next_pc),
        .o_redirect_valid(redirect), .o_redirect_pc(redirect_pc), .o_redirect_ctx(redirect_ctx),
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

    // a complete posted store at pc, with the bus fields the LSU would report
    task automatic posted_store(input logic [63:0] pc);
        set_entry(pc, 32'h0000_3023, 0, 1'b0, 64'd0);
        c.cls = QV_FU_LSU; c.is_store_class = 1'b1;
        lres = '0;
        lres.posted = 1'b1;
        lres.mem_addr = 64'h1238; lres.mem_wmask = 8'hF0; lres.mem_wdata = 64'hAABB_CCDD_0000_0000;
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        mip = '0; mie = '0;

        // ---- a posted store with room: retires and is pushed in the same cycle ----
        posted_store(arch_pc);
        #1;
        check("posted store, room: retires", b(commit_now), 64'd1);
        check("posted store, room: popped", b(pop), 64'd1);
        check("posted store, room: pushed", b(sb_push), 64'd1);
        check("posted store, room: counted as a retirement", b(instr_retired), 64'd1);
        check("posted store, room: no trap", b(trap_taken), 64'd0);
        check("posted store, room: rvfi wmask", {56'b0, r_mem_wmask}, 64'hF0);
        check("posted store, room: rvfi wdata", r_mem_wdata, 64'hAABB_CCDD_0000_0000);
        check("posted store, room: rvfi addr", r_mem_addr, 64'h1238);
        retire();

        // ---- no room: it does not retire, is not popped and is not pushed; with room again it goes ----
        sb_ready = 1'b0;
        posted_store(arch_pc);
        #1;
        check("posted store, buffer full: does not retire", b(commit_now), 64'd0);
        check("posted store, buffer full: not popped", b(pop), 64'd0);
        check("posted store, buffer full: not pushed", b(sb_push), 64'd0);
        check("posted store, buffer full: no redirect", b(redirect), 64'd0);
        check("posted store, buffer full: no retirement counted", b(instr_retired), 64'd0);
        @(posedge clk); #1;
        check("posted store, still full a cycle later: still waiting", b(commit_now), 64'd0);
        sb_ready = 1'b1;
        #1;
        check("posted store, room again: retires", b(commit_now), 64'd1);
        check("posted store, room again: pushed", b(sb_push), 64'd1);
        retire();

        // ---- anything else retires with a full buffer ----
        sb_ready = 1'b0;
        posted_store(arch_pc);
        lres.posted = 1'b0;                          // an ordinary store (it reached the bus at the head)
        #1;
        check("store that was not posted, buffer full: retires", b(commit_now), 64'd1);
        check("store that was not posted: no push", b(sb_push), 64'd0);
        retire();
        set_entry(arch_pc, 32'h13, 5, 1'b1, 64'd3);
        #1;
        check("ALU op, buffer full: retires", b(commit_now), 64'd1);
        check("ALU op: no push", b(sb_push), 64'd0);
        retire();
        // a faulting store (the LSU found an exception): never posted, retires as a trap
        set_entry(arch_pc, 32'h0000_3023, 0, 1'b0, 64'd0);
        c.cls = QV_FU_LSU; c.is_store_class = 1'b1;
        lres = '0; lres.xcpt = 1'b1; lres.cause = 4'd7; lres.tval = 64'h40;
        #1;
        check("faulting store, buffer full: retires (as a trap)", b(commit_now), 64'd1);
        check("faulting store: no push", b(sb_push), 64'd0);
        retire();
        lres = '0;
        sb_ready = 1'b1;

        // ---- a posted store taken by an interrupt or a halt is neither retired nor pushed ----
        // (the cycle after the ALU op below is a sample cycle)
        set_entry(arch_pc, 32'h13, 5, 1'b1, 64'd1);
        retire();
        mip = 64'h80; mie = 64'h80; mstatus_mie = 1'b1;    // machine timer interrupt pending and enabled
        posted_store(arch_pc);
        #1;
        check("posted store in a sample cycle with an interrupt: the interrupt is taken", b(irq_taken), 64'd1);
        check("... the store does not retire", b(commit_now), 64'd0);
        check("... and is not pushed", b(sb_push), 64'd0);
        retire();
        mip = '0; mie = '0; mstatus_mie = 1'b0;
        set_entry(arch_pc, 32'h13, 5, 1'b1, 64'd1);       // a retirement, so that the next cycle samples
        retire();
        dbg_halt = 1'b1;
        posted_store(arch_pc);
        #1;
        check("posted store in a sample cycle with a halt request: the halt is taken", b(dbg_halt_entry), 64'd1);
        check("... the store does not retire", b(commit_now), 64'd0);
        check("... and is not pushed", b(sb_push), 64'd0);
        retire();
        dbg_halt = 1'b0;
        dbg_in = 1'b0;

        // ---- FENCE.I waits for fetch and for the buffer ----
        sb_empty = 1'b0; fetch_idle = 1'b1;
        set_entry(arch_pc, 32'h0000_100F, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_FENCE_I; c.serialize = 1'b1;
        #1;
        check("FENCE.I, buffer not empty: fetch is held", b(fetch_hold), 64'd1);
        check("FENCE.I, buffer not empty: does not retire", b(commit_now), 64'd0);
        check("FENCE.I, buffer not empty: no icache flush", b(icache_flush), 64'd0);
        sb_empty = 1'b1; fetch_idle = 1'b0;
        #1;
        check("FENCE.I, buffer empty but fetch busy: does not retire", b(commit_now), 64'd0);
        fetch_idle = 1'b1;
        #1;
        check("FENCE.I, both ready: retires", b(commit_now), 64'd1);
        check("FENCE.I, both ready: flushes the icache", b(icache_flush), 64'd1);
        retire();

        // ---- an EBREAK that traps waits for an empty buffer ----
        dcsr = '0;                                   // no ebreak bit: a plain breakpoint trap
        sb_empty = 1'b0;
        set_entry(arch_pc, 32'h0010_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_EBREAK;
        #1;
        check("EBREAK trap, buffer not empty: does not retire", b(commit_now), 64'd0);
        check("EBREAK trap, buffer not empty: no trap channel pulse", b(trap_taken), 64'd0);
        check("EBREAK trap, buffer not empty: no redirect", b(redirect), 64'd0);
        sb_empty = 1'b1;
        #1;
        check("EBREAK trap, buffer empty: retires as a trap", b(commit_now), 64'd1);
        check("EBREAK trap, buffer empty: trap taken", b(trap_taken), 64'd1);
        check("EBREAK trap, buffer empty: cause 3", trap_cause, 64'd3);
        retire();

        // an EBREAK that enters Debug Mode is not a retirement and does not wait for the buffer
        dcsr = 64'h8000;                             // ebreakm
        sb_empty = 1'b0;
        set_entry(arch_pc, 32'h0010_0073, 0, 1'b0, 64'd0);
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_EBREAK;
        #1;
        check("EBREAK into Debug Mode, buffer not empty: enters at once", b(dbg_ebreak_entry), 64'd1);
        check("... as a debug entry, not a retirement", b(commit_now), 64'd0);
        retire();
        dcsr = '0;
        sb_empty = 1'b1;

        // ---- everything else ignores both signals ----
        sb_empty = 1'b0; sb_ready = 1'b0;
        set_entry(arch_pc, 32'h13, 6, 1'b1, 64'd5);
        #1;
        check("ALU op with a full, non-empty buffer: retires", b(commit_now), 64'd1);
        retire();
        set_entry(arch_pc, 32'h3050_0073, 0, 1'b0, 64'd0);   // ECALL: a trap, but not one that waits
        c.cls = QV_FU_SYS; c.sys_op = QV_SYS_ECALL;
        #1;
        check("ECALL with a non-empty buffer: retires", b(commit_now), 64'd1);
        retire();
        sb_empty = 1'b1; sb_ready = 1'b1;

        $display("");
        $display("qv_commit_sb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_commit_sb_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
