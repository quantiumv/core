// SPDX-License-Identifier: MIT

/*
 * qv_commit -- retires the ROB head, one instruction per cycle, and owns
 * every architectural side effect: the regfile0 write, csr_file0's side
 * channels (CSR read/write, trap, mret, retirement count), the
 * producer-table release back to issue, the architectural PC, redirects,
 * and RVFI.
 *
 * What the head does when it retires, in priority order:
 *   trap    a fault marked at fetch/decode (cause 1 or 2), one a memory op
 *           hit while executing (4-7, from the LSU's result), ECALL (11,
 *           M mode only so far) or EBREAK (3): nothing is written,
 *           csr_file0 takes the trap, fetch restarts at mtvec's base
 *           (direct mode)
 *   MRET    csr_file0 restores mstatus, fetch restarts at mepc
 *   CSR     the old value goes to rd, the new one (RW: src, RS: old | src,
 *           RC: old & ~src, src being the ALU pass value) to the CSR
 *           unless write-suppressed; then a serializing refetch
 *   FENCE.I once fetch has nothing outstanding (fetch is held meanwhile):
 *           icache flush, then a serializing refetch
 *   other   result to rd; redirect on a mispredict or serialize
 * mtval follows core.sv's trap_val: the instruction bits for an illegal
 * instruction, the pc for a fetch fault, the access address for a
 * misaligned or faulting load/store, 0 otherwise. A trapped
 * instruction isn't a retirement as far as minstret goes.
 *
 * Every redirect kills everything younger: the same pulse flushes all
 * stages.
 *
 * RVFI follows core.sv's own conventions field for field: rd_addr is 0
 * unless the instruction writes rd, rd_wdata is 0 unless it writes a
 * nonzero rd, pc_wdata is the real next pc (trap vector, mepc, or the
 * entry's own), intr flags a retirement whose pc doesn't follow the
 * previous one's pc_wdata, mode and ixl are fixed (M, 64-bit). Source
 * operands come from the values issue captured (rvfi_shadow_t), since
 * regfile0's read ports aren't free to re-read them here; memory fields
 * come from the LSU's result for a memory op and are 0 otherwise.
 *
 * Not yet: interrupts, U/S modes.
 */
module qv_commit #(
    parameter logic [63:0] RESET_PC = 64'h0
) (
    input  logic                             clk,
    input  logic                             rst,

    input  logic                             i_head_valid,
    // the entry's own .valid duplicates i_head_valid
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::rob_entry_t               i_head_entry,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_head_tag,
    input  qv_pkg::rvfi_shadow_t             i_head_shadow,
    input  qv_pkg::rob_ctrl_t                i_head_ctrl,
    input  qv_pkg::lsu_res_t                 i_lsu_res,     // the head's, when it's a memory op
    output logic                             o_commit_pop,

    output logic                             o_regfile_we,
    output logic [4:0]                       o_regfile_sel,
    output logic [63:0]                      o_regfile_data,

    output logic                             o_commit_valid,
    output logic [4:0]                       o_commit_rd,
    output logic                             o_commit_rd_wen,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_commit_tag,

    // csr_file0
    output logic [11:0]                      o_csr_addr,
    input  logic [63:0]                      i_csr_rdata,
    output logic                             o_csr_we,
    output logic [63:0]                      o_csr_wdata,
    output logic                             o_instr_retired,
    output logic                             o_trap_taken,
    output logic [63:0]                      o_trap_cause,
    output logic [63:0]                      o_trap_val,
    output logic                             o_mret_taken,
    // MODE bits [1:0] ignored: direct mode only, as in core.sv
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_mtvec,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]                      i_mepc,

    // FENCE.I: fetch is held while it is the head; it retires only once
    // fetch has nothing outstanding, flushing the icache in that cycle
    output logic                             o_fetch_hold,
    input  logic                             i_fetch_idle,
    output logic                             o_icache_flush,

    output logic                             o_commit_now,
    output logic [63:0]                      o_pc,
    output logic [63:0]                      o_next_pc,

    output logic                             o_redirect_valid,
    output logic [63:0]                      o_redirect_pc,

    output logic [63:0]                      o_rvfi_order,
    output logic [31:0]                      o_rvfi_insn,
    output logic                             o_rvfi_trap,
    output logic                             o_rvfi_intr,
    output logic [4:0]                       o_rvfi_rs1_addr,
    output logic [4:0]                       o_rvfi_rs2_addr,
    output logic [63:0]                      o_rvfi_rs1_rdata,
    output logic [63:0]                      o_rvfi_rs2_rdata,
    output logic [4:0]                       o_rvfi_rd_addr,
    output logic [63:0]                      o_rvfi_rd_wdata,
    output logic [63:0]                      o_rvfi_pc_rdata,
    output logic [63:0]                      o_rvfi_pc_wdata,
    output logic [63:0]                      o_rvfi_mem_addr,
    output logic [7:0]                       o_rvfi_mem_rmask,
    output logic [7:0]                       o_rvfi_mem_wmask,
    output logic [63:0]                      o_rvfi_mem_rdata,
    output logic [63:0]                      o_rvfi_mem_wdata
);
    import qv_pkg::*;

    // ---------------- classify the head ----------------
    // a marked fault overrides whatever the entry would otherwise do, as
    // core.sv's instr_faulted gating does
    wire is_sys  = (i_head_ctrl.cls == QV_FU_SYS) && !i_head_ctrl.xcpt;
    wire is_fence_i = is_sys && (i_head_ctrl.sys_op == QV_SYS_FENCE_I);

    // FENCE.I waits for fetch to drain: an icache fill finishing in the
    // flush cycle would revalidate its line (icache.sv), and anything
    // fetched before the flush is refetched by the serializing redirect
    wire commit = i_head_valid && i_head_entry.complete && (!is_fence_i || i_fetch_idle);

    assign o_fetch_hold   = i_head_valid && is_fence_i;
    assign o_icache_flush = commit && is_fence_i;
    wire is_lsu  = (i_head_ctrl.cls == QV_FU_LSU) && !i_head_ctrl.xcpt;
    wire mem_xcpt = is_lsu && i_lsu_res.xcpt;          // found while executing, not at decode
    wire is_trap = i_head_ctrl.xcpt || mem_xcpt
                || (is_sys && (i_head_ctrl.sys_op == QV_SYS_ECALL || i_head_ctrl.sys_op == QV_SYS_EBREAK));
    wire is_mret = is_sys && (i_head_ctrl.sys_op == QV_SYS_MRET);
    wire is_csr  = (i_head_ctrl.cls == QV_FU_CSR) && !i_head_ctrl.xcpt;

    logic [3:0] cause;
    always_comb begin
        if (i_head_ctrl.xcpt)                          cause = i_head_ctrl.cause;
        else if (mem_xcpt)                             cause = i_lsu_res.cause;
        else if (i_head_ctrl.sys_op == QV_SYS_EBREAK)  cause = 4'd3;
        else                                           cause = 4'd11;
    end

    logic [63:0] tval;
    always_comb begin
        if (i_head_ctrl.xcpt && i_head_ctrl.cause == 4'd2)
            tval = {32'b0, i_head_entry.raw};      // raw is already {16'b0, hw} for RVC
        else if (i_head_ctrl.xcpt && i_head_ctrl.cause == 4'd1)
            tval = i_head_entry.pc;
        else if (mem_xcpt)
            tval = i_lsu_res.tval;
        else
            tval = 64'b0;
    end

    // ---------------- CSR read-modify-write ----------------
    wire [63:0] csr_src = i_head_entry.value;
    always_comb begin
        case (i_head_ctrl.csr_op)
            QV_CSR_RS: o_csr_wdata = i_csr_rdata | csr_src;
            QV_CSR_RC: o_csr_wdata = i_csr_rdata & ~csr_src;
            default:   o_csr_wdata = csr_src;
        endcase
    end
    assign o_csr_addr = i_head_ctrl.csr_addr;
    assign o_csr_we   = commit && is_csr && !i_head_ctrl.csr_wsup;

    assign o_trap_taken    = commit && is_trap;
    assign o_trap_cause    = {60'b0, cause};
    assign o_trap_val      = tval;
    assign o_mret_taken    = commit && is_mret;
    assign o_instr_retired = commit && !is_trap;

    // ---------------- retirement ----------------
    wire [63:0] rd_value = is_csr ? i_csr_rdata : i_head_entry.value;

    assign o_commit_pop = commit;
    assign o_commit_now = commit;

    // a memory op that faults while executing still has rd_wen set
    wire writes_rd = i_head_entry.rd_wen && !is_trap;
    assign o_regfile_we   = commit && writes_rd;
    assign o_regfile_sel  = i_head_entry.rd;
    assign o_regfile_data = rd_value;

    assign o_commit_valid  = commit;
    assign o_commit_rd     = i_head_entry.rd;
    assign o_commit_rd_wen = i_head_entry.rd_wen;
    assign o_commit_tag    = i_head_tag;

    // ---------------- next pc / redirect ----------------
    logic [63:0] actual_next_pc;
    always_comb begin
        if (is_trap)      actual_next_pc = {i_mtvec[63:2], 2'b00};
        else if (is_mret) actual_next_pc = i_mepc;
        else              actual_next_pc = i_head_entry.next_pc;
    end

    assign o_redirect_valid = commit && (is_trap || is_mret || i_head_entry.mispredict
                                         || i_head_ctrl.serialize);
    assign o_redirect_pc    = actual_next_pc;

    // architectural PC: the next instruction to retire
    logic [63:0] arch_pc_q;
    always_ff @(posedge clk) begin
        if (rst)         arch_pc_q <= RESET_PC;
        else if (commit) arch_pc_q <= actual_next_pc;
    end
    assign o_pc      = arch_pc_q;
    assign o_next_pc = actual_next_pc;

    // ---------------- RVFI ----------------
    logic [63:0] order_q, prev_pc_wdata_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            order_q         <= 64'b0;
            prev_pc_wdata_q <= RESET_PC;
        end else if (commit) begin
            order_q         <= order_q + 64'd1;
            prev_pc_wdata_q <= actual_next_pc;
        end
    end

    assign o_rvfi_order     = order_q;
    assign o_rvfi_insn      = i_head_entry.raw;
    assign o_rvfi_trap      = commit && is_trap;
    assign o_rvfi_intr      = commit && (i_head_entry.pc != prev_pc_wdata_q);
    assign o_rvfi_rs1_addr  = i_head_shadow.rs1_addr;
    assign o_rvfi_rs2_addr  = i_head_shadow.rs2_addr;
    assign o_rvfi_rs1_rdata = i_head_shadow.rs1_rdata;
    assign o_rvfi_rs2_rdata = i_head_shadow.rs2_rdata;
    assign o_rvfi_rd_addr   = writes_rd ? i_head_entry.rd : 5'b0;
    assign o_rvfi_rd_wdata  = (writes_rd && i_head_entry.rd != 5'b0) ? rd_value : 64'b0;
    assign o_rvfi_pc_rdata  = i_head_entry.pc;
    assign o_rvfi_pc_wdata  = actual_next_pc;
    // a trapping access still reports its would-be fields, as core.sv does
    assign o_rvfi_mem_addr  = is_lsu ? i_lsu_res.mem_addr  : 64'b0;
    assign o_rvfi_mem_rmask = is_lsu ? i_lsu_res.mem_rmask : 8'b0;
    assign o_rvfi_mem_wmask = is_lsu ? i_lsu_res.mem_wmask : 8'b0;
    assign o_rvfi_mem_rdata = is_lsu ? i_lsu_res.mem_rdata : 64'b0;
    assign o_rvfi_mem_wdata = is_lsu ? i_lsu_res.mem_wdata : 64'b0;
endmodule
