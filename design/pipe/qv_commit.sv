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
 *           hit while executing (4-7, from the LSU's result), ECALL (8, 9 or
 *           11 by privilege) or EBREAK (3): nothing is written, csr_file0
 *           takes the trap, fetch restarts at the vector base of mtvec or,
 *           when the trap is delegated (medeleg, from below M), stvec (direct
 *           mode only)
 *   MRET    csr_file0 restores mstatus, privilege becomes MPP, fetch restarts
 *           at mepc
 *   SRET    likewise: privilege becomes SPP (S or U), fetch restarts at sepc
 *   CSR     the old value goes to rd, the new one (RW: src, RS: old | src,
 *           RC: old & ~src, src being the ALU pass value) to the CSR
 *           unless write-suppressed; then a serializing refetch
 *   FENCE.I once fetch has nothing outstanding (fetch is held meanwhile):
 *           icache flush, then a serializing refetch
 *   other   result to rd; redirect on a mispredict or serialize
 * mtval follows ref_core.sv's trap_val: the instruction bits for an illegal
 * instruction, the pc for a fetch fault, the access address for a
 * misaligned or faulting load/store, 0 otherwise. A trapped
 * instruction isn't a retirement as far as minstret goes.
 *
 * Every redirect kills everything younger: the same pulse flushes all
 * stages.
 *
 * RVFI follows ref_core.sv's own conventions field for field: rd_addr is 0
 * unless the instruction writes rd, rd_wdata is 0 unless it writes a
 * nonzero rd, pc_wdata is the real next pc (trap vector, mepc, or the
 * entry's own), intr flags a retirement whose pc doesn't follow the
 * previous one's pc_wdata, mode is the privilege the instruction ran at
 * and ixl is fixed (64-bit). Source
 * operands come from the values issue captured (rvfi_shadow_t), since
 * regfile0's read ports aren't free to re-read them here; memory fields
 * come from the LSU's result for a memory op and are 0 otherwise.
 *
 * Interrupts are sampled exactly as ref_core.sv does: only in the cycle after
 * a retirement (commit_q), from the live mip/mie/mideleg/mstatus/privilege
 * values of that cycle, and one that is sampled takes the place of whatever
 * would retire in the same cycle (nothing commits, everything younger is
 * flushed). mepc is then the architectural pc, the next instruction to
 * retire; the order counter and the previous-pc register are untouched, so
 * the handler's first retirement shows up with rvfi_intr set.
 *
 * A debug halt request, or an armed single step, is sampled at the very same
 * point and wins over both an interrupt and the head's commit: nothing
 * commits, everything is flushed, and csr_file0 records dpc (the
 * architectural pc: the next instruction to retire, or the trap vector if
 * the retirement that led here was a trap), the privilege and the cause
 * (4 for a step, 3 for a halt request). It is not a retirement. The hart is
 * then halted (qv_dbg's in_debug) until the Debug Module's resume, which
 * restarts the pipeline at the live dpc, since a debugger may have
 * rewritten it. Nothing is sampled again until one instruction has retired.
 *
 * The other two ways into Debug Mode happen at the ROB head, not at a sample
 * point, and are not retirements either: an EBREAK while the dcsr ebreak bit
 * of the current privilege is set (cause 1), and an action-1 execute trigger
 * that decode matched on the head's pc (cause 2); the EBREAK wins when both
 * apply. Nothing of the head takes effect (it was neutralised ahead of
 * issue), dpc is its pc, everything younger is flushed. An action-0 trigger
 * instead makes the head a breakpoint exception (cause 3, tval = the pc), for
 * which a store, SC or AMO still clears the LR/SC reservation. A halt
 * request or interrupt sampled in the same cycle goes first.
 *
 * A Program Buffer run (i_pb_active) retires its instructions like any
 * other, one at a time and in order, but nothing it does counts
 * architecturally beyond its own register and CSR writes: a trap is not
 * taken (an exception ends the run as an abort, an EBREAK ends it cleanly;
 * the Debug Module hears about either in the cycle the last instruction
 * retires, and an aborted one writes nothing and is not counted by
 * minstret), MRET and SRET have no effect, and instructions retired
 * while dcsr.stopcount is set are not counted.
 *
 * It also keeps the privilege level (updated exactly as ref_core.sv's
 * current_priv is: trap, MRET, SRET; MPP is loaded raw, so privilege 2'b10
 * can occur and then behaves as written) and the LR/SC reservation (see
 * below), since only a retirement may change either.
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

    // LR/SC reservation, read by the LSU when an SC becomes the head
    output logic                             o_res_valid,
    output logic [63:0]                      o_res_addr,

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
    // MODE bits [1:0] ignored: direct mode only, as in ref_core.sv
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_mtvec,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]                      i_mepc,
    output logic                             o_sret_taken,
    output logic                             o_trap_to_s,
    output logic [1:0]                       o_priv,
    // exported by csr_file0; stvec's MODE bits are ignored like mtvec's
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_stvec,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]                      i_sepc,
    input  logic [63:0]                      i_medeleg,
    input  logic [1:0]                       i_mstatus_mpp,
    input  logic                             i_mstatus_spp,

    // interrupt sampling; only MEI/MTI/SEI (bits 11, 7, 9) are looked at
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_mip = 64'b0,
    input  logic [63:0]                      i_mie = 64'b0,
    input  logic [63:0]                      i_mideleg = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                             i_mstatus_mie = 1'b0,
    input  logic                             i_mstatus_sie = 1'b0,
    output logic                             o_irq_taken,

    // Debug Mode (qv_dbg keeps its flags); the defaults are a hart that is never asked to halt
    input  logic                             i_dbg_halt_req = 1'b0,     // the Debug Module's level
    input  logic                             i_dbg_stepping = 1'b0,
    input  logic                             i_dbg_in_debug = 1'b0,
    input  logic                             i_dbg_resume   = 1'b0,     // an accepted resume
    input  logic [63:0]                      i_dpc          = 64'b0,    // csr_file0's live dpc
    // only the ebreakm/ebreaks/ebreaku bits (15, 13, 12) are looked at
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]                      i_dcsr         = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_dbg_entry,               // any entry this cycle
    output logic [2:0]                       o_dbg_cause,
    output logic                             o_dbg_halt_entry,          // ... a halt or step one
    output logic                             o_dbg_ebreak_entry,        // ... an EBREAK one
    output logic                             o_dbg_trigger_entry,       // ... an execute-trigger one

    // Program Buffer run
    input  logic                             i_pb_active = 1'b0,
    output logic                             o_pb_commit,               // a Program Buffer instruction retires
    output logic                             o_pb_done,                 // ... the run's last: an EBREAK
    output logic                             o_pb_abort,                // ... the run's last: an exception

    // FENCE.I: fetch is held while it is the head; it retires only once
    // fetch has nothing outstanding, flushing the icache in that cycle
    output logic                             o_fetch_hold,
    input  logic                             i_fetch_idle,
    output logic                             o_icache_flush,
    // SFENCE.VMA: the TLBs are emptied at the edge that ends the retiring cycle (no wait, unlike FENCE.I: it is a
    // serializing instruction, so its redirect refetches against the empty TLB). Not for one that traps (TVM)
    output logic                             o_sfence,

    output logic                             o_commit_now,
    output logic [63:0]                      o_pc,
    output logic [63:0]                      o_next_pc,

    output logic                             o_redirect_valid,
    output logic [63:0]                      o_redirect_pc,
    // This redirect changes what address translation of the fetch depends on -- the privilege (a trap, an xRET, an
    // interrupt), satp and the TLBs (a serializing instruction) -- at the edge that ends this cycle, so fetch must
    // not issue from the target in this very cycle
    output logic                             o_redirect_ctx,

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

    // ---------------- interrupts ----------------
    // current privilege: the one the head instruction runs at
    logic [1:0] priv_q;
    assign o_priv = priv_q;

    // ref_core.sv's enables, expression for expression: a delegated interrupt
    // is enabled in U, in S when SIE is set and never in M; an M one is
    // enabled below M and in M when MIE is set
    wire mei_pending = i_mie[11] & i_mip[11];
    wire mei_to_s    = i_mideleg[11];
    wire mei_enabled = mei_to_s
        ? ((priv_q == QV_PRIV_U) ? 1'b1 : (priv_q == QV_PRIV_S) ? i_mstatus_sie : 1'b0)
        : ((priv_q != QV_PRIV_M) ? 1'b1 : i_mstatus_mie);
    wire mti_pending = i_mie[7] & i_mip[7];
    wire mti_to_s    = i_mideleg[7];
    wire mti_enabled = mti_to_s
        ? ((priv_q == QV_PRIV_U) ? 1'b1 : (priv_q == QV_PRIV_S) ? i_mstatus_sie : 1'b0)
        : ((priv_q != QV_PRIV_M) ? 1'b1 : i_mstatus_mie);
    wire sei_pending = i_mie[9] & i_mip[9];
    wire sei_to_s    = i_mideleg[9];
    wire sei_enabled = sei_to_s
        ? ((priv_q == QV_PRIV_U) ? 1'b1 : (priv_q == QV_PRIV_S) ? i_mstatus_sie : 1'b0)
        : ((priv_q != QV_PRIV_M) ? 1'b1 : i_mstatus_mie);

    // priority MEI > MTI > SEI
    wire        mei_take = mei_pending && mei_enabled;
    wire        mti_take = mti_pending && mti_enabled;
    wire        sei_take = sei_pending && sei_enabled;
    wire [3:0]  int_cause = mei_take ? 4'd11 : mti_take ? 4'd7 : sei_take ? 4'd9 : 4'd0;
    wire        int_to_s  = mei_take ? mei_to_s : mti_take ? mti_to_s : sei_take ? sei_to_s : 1'b0;

    // The sample point for interrupts, halt requests and single steps: the cycle after a retirement,
    // outside Debug Mode. A halt request or an armed step is taken in preference to an interrupt
    // (ref_core.sv's debug_halt_req_entry / interrupt_taken pair), and to the head's commit.
    logic commit_q;
    wire  sample_pt  = commit_q && !i_dbg_in_debug;
    wire  halt_take  = sample_pt && (i_dbg_halt_req || i_dbg_stepping);
    wire  irq        = sample_pt && !(i_dbg_halt_req || i_dbg_stepping) && (mei_take || mti_take || sei_take);
    assign o_irq_taken      = irq;
    assign o_dbg_halt_entry = halt_take;

    // ---------------- classify the head ----------------
    // a marked fault overrides whatever the entry would otherwise do, as
    // ref_core.sv's instr_faulted gating does
    wire is_sys  = (i_head_ctrl.cls == QV_FU_SYS) && !i_head_ctrl.xcpt;
    wire is_fence_i = is_sys && (i_head_ctrl.sys_op == QV_SYS_FENCE_I);

    // FENCE.I waits for fetch to drain: an icache fill finishing in the
    // flush cycle would revalidate its line (icache.sv), and anything
    // fetched before the flush is refetched by the serializing redirect
    // the head's own routes into Debug Mode (an interrupt or a halt sampled in the same cycle goes first). The
    // dcsr bit follows the privilege exactly as ref_core.sv's ebreak_to_debug does: M, S, else (U and 2'b10) U.
    wire head_ready    = i_head_valid && i_head_entry.complete;
    wire ebreak_bit    = (priv_q == QV_PRIV_M) ? i_dcsr[15] : (priv_q == QV_PRIV_S) ? i_dcsr[13] : i_dcsr[12];
    wire ebreak_entry  = head_ready && is_sys && (i_head_ctrl.sys_op == QV_SYS_EBREAK) && ebreak_bit
                         && !i_dbg_in_debug && !irq && !halt_take;
    wire trigger_entry = head_ready && i_head_ctrl.trig_debug && !i_dbg_in_debug && !irq && !halt_take && !ebreak_entry;
    wire head_dbg_entry = ebreak_entry || trigger_entry;
    assign o_dbg_ebreak_entry  = ebreak_entry;
    assign o_dbg_trigger_entry = trigger_entry;
    assign o_dbg_entry         = halt_take || head_dbg_entry;
    assign o_dbg_cause         = ebreak_entry ? 3'd1 : trigger_entry ? 3'd2 : i_dbg_stepping ? 3'd4 : 3'd3;

    wire commit = head_ready && (!is_fence_i || i_fetch_idle) && !irq && !halt_take && !head_dbg_entry;
    always_ff @(posedge clk) begin
        if (rst) commit_q <= 1'b0;
        else     commit_q <= commit;
    end

    assign o_fetch_hold   = i_head_valid && is_fence_i;
    assign o_icache_flush = commit && is_fence_i;
    wire is_lsu  = (i_head_ctrl.cls == QV_FU_LSU) && !i_head_ctrl.xcpt;
    wire mem_xcpt = is_lsu && i_lsu_res.xcpt;          // found while executing, not at decode
    wire is_trap = i_head_ctrl.xcpt || mem_xcpt || i_head_ctrl.trig_exc
                || (is_sys && (i_head_ctrl.sys_op == QV_SYS_ECALL || i_head_ctrl.sys_op == QV_SYS_EBREAK));
    wire is_mret = is_sys && (i_head_ctrl.sys_op == QV_SYS_MRET);
    wire is_sret = is_sys && (i_head_ctrl.sys_op == QV_SYS_SRET);

    // In a Program Buffer run a trap is not taken and xRET has no effect; an EBREAK retires (the run is done)
    wire pb_ebreak = i_pb_active && is_sys && (i_head_ctrl.sys_op == QV_SYS_EBREAK);
    wire trap_fx   = is_trap && !i_pb_active;           // the trap path proper: csr_file0, privilege, vector
    wire mret_fx   = is_mret && !i_pb_active;
    wire sret_fx   = is_sret && !i_pb_active;
    wire faulted   = is_trap && !pb_ebreak;             // does not retire: no rd/CSR write, not counted
    assign o_pb_commit = commit && i_pb_active;
    assign o_pb_done   = commit && pb_ebreak;
    assign o_pb_abort  = commit && i_pb_active && is_trap && !pb_ebreak;
    assign o_sfence    = commit && is_sys && (i_head_ctrl.sys_op == QV_SYS_SFENCE_VMA) && !faulted;

    wire is_csr  = (i_head_ctrl.cls == QV_FU_CSR) && !i_head_ctrl.xcpt;

    logic [3:0] cause;
    always_comb begin
        if (i_head_ctrl.xcpt)                          cause = i_head_ctrl.cause;
        else if (i_head_ctrl.trig_exc)                 cause = 4'd3;        // an action-0 trigger: a breakpoint
        else if (mem_xcpt)                             cause = i_lsu_res.cause;
        else if (i_head_ctrl.sys_op == QV_SYS_EBREAK)  cause = 4'd3;
        else if (priv_q == QV_PRIV_U)                  cause = 4'd8;        // ECALL from U
        else if (priv_q == QV_PRIV_S)                  cause = 4'd9;        // ... S
        else if (priv_q == QV_PRIV_M)                  cause = 4'd11;       // ... M
        else                                           cause = 4'd0;        // privilege 2'b10: ref_core.sv falls through to 0
    end

    logic [63:0] tval;
    always_comb begin
        if (i_head_ctrl.xcpt && i_head_ctrl.cause == 4'd2)
            tval = {32'b0, i_head_entry.raw};      // raw is already {16'b0, hw} for RVC
        else if (i_head_ctrl.xcpt && i_head_ctrl.cause == 4'd1)
            tval = i_head_entry.pc;
        else if (i_head_ctrl.xcpt && i_head_ctrl.cause == 4'd12)
            tval = i_head_ctrl.xcpt_hi ? i_head_entry.pc + 64'd8 : i_head_entry.pc;   // ref_core.sv reports the second dword's address
        else if (i_head_ctrl.trig_exc)
            tval = i_head_entry.pc;                // errata E2: the trigger ranks with its cause, so its tval is the pc
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

    // a trap from below M goes to S when medeleg says so; never from M
    wire trap_to_s = trap_fx && (priv_q != QV_PRIV_M) && i_medeleg[{2'b00, cause}];

    // an interrupt goes through the same csr_file0 trap channel: cause with
    // the interrupt bit, no tval, and its own delegation
    assign o_trap_taken    = (commit && trap_fx) || irq;
    assign o_trap_to_s     = irq ? int_to_s : trap_to_s;
    assign o_sret_taken    = commit && sret_fx;
    assign o_trap_cause    = irq ? {1'b1, 59'b0, int_cause} : {60'b0, cause};
    assign o_trap_val      = irq ? 64'b0 : tval;
    assign o_mret_taken    = commit && mret_fx;
    assign o_instr_retired = commit && !faulted && !(i_dbg_in_debug && i_dcsr[10]);   // dcsr.stopcount

    // ---------------- retirement ----------------
    wire [63:0] rd_value = is_csr ? i_csr_rdata : i_head_entry.value;

    assign o_commit_pop = commit;
    assign o_commit_now = commit;

    // ---------------- LR/SC reservation ----------------
    // Set by a clean LR, to the address it loaded. Cleared by retiring any
    // store-class op -- a store, an SC (whether or not it succeeded) or an
    // AMO -- faulting or not, at any address; ref_core.sv's rule exactly. Traps
    // and interrupts leave it alone. The LSU reads it when an SC reaches the
    // head: everything older has retired by then, so it can't change under it.
    logic        res_valid_q;
    logic [63:0] res_addr_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            res_valid_q <= 1'b0;
        end else if (commit && i_head_ctrl.is_lr && !is_trap) begin
            res_valid_q <= 1'b1;
            res_addr_q  <= i_lsu_res.vaddr;
        end else if (commit && i_head_ctrl.is_store_class) begin
            res_valid_q <= 1'b0;
        end
    end
    assign o_res_valid = res_valid_q;
    assign o_res_addr  = res_addr_q;

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
    logic [63:0] arch_pc_q;
    always_comb begin
        if (trap_fx)      actual_next_pc = trap_to_s ? {i_stvec[63:2], 2'b00} : {i_mtvec[63:2], 2'b00};
        else if (mret_fx) actual_next_pc = i_mepc;
        else if (sret_fx) actual_next_pc = i_sepc;
        else              actual_next_pc = i_head_entry.next_pc;
    end

    // privilege after this retirement; trap wins over xRET, as in ref_core.sv
    always_ff @(posedge clk) begin
        if (rst) begin
            priv_q <= QV_PRIV_M;
        end else if (irq) begin
            priv_q <= int_to_s ? QV_PRIV_S : QV_PRIV_M;
        end else if (commit) begin
            if (trap_fx)      priv_q <= trap_to_s ? QV_PRIV_S : QV_PRIV_M;
            else if (mret_fx) priv_q <= i_mstatus_mpp;
            else if (sret_fx) priv_q <= i_mstatus_spp ? QV_PRIV_S : QV_PRIV_U;
        end
    end

    // an interrupt redirects to the vector of the mode it is taken in (direct mode only)
    wire [63:0] irq_vector = int_to_s ? {i_stvec[63:2], 2'b00} : {i_mtvec[63:2], 2'b00};
    // A debug entry redirects to the architectural pc (fetch is held, so it only records it and everything
    // in flight is flushed); a resume restarts at the live dpc.
    assign o_redirect_valid = irq || halt_take || head_dbg_entry || i_dbg_resume
                              || (commit && (trap_fx || mret_fx || sret_fx || i_head_entry.mispredict
                                             || i_head_ctrl.serialize));
    assign o_redirect_pc    = irq ? irq_vector : (halt_take || head_dbg_entry) ? arch_pc_q : i_dbg_resume ? i_dpc : actual_next_pc;
    assign o_redirect_ctx   = irq || (commit && (trap_fx || mret_fx || sret_fx || i_head_ctrl.serialize));

    // architectural PC: the next instruction to retire
    always_ff @(posedge clk) begin
        if (rst)                arch_pc_q <= RESET_PC;
        else if (irq)           arch_pc_q <= irq_vector;
        else if (i_dbg_resume)  arch_pc_q <= i_dpc;
        else if (commit)        arch_pc_q <= actual_next_pc;
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
    assign o_rvfi_trap      = commit && trap_fx;
    assign o_rvfi_intr      = commit && (i_head_entry.pc != prev_pc_wdata_q);
    assign o_rvfi_rs1_addr  = i_head_shadow.rs1_addr;
    assign o_rvfi_rs2_addr  = i_head_shadow.rs2_addr;
    assign o_rvfi_rs1_rdata = i_head_shadow.rs1_rdata;
    assign o_rvfi_rs2_rdata = i_head_shadow.rs2_rdata;
    assign o_rvfi_rd_addr   = writes_rd ? i_head_entry.rd : 5'b0;
    assign o_rvfi_rd_wdata  = (writes_rd && i_head_entry.rd != 5'b0) ? rd_value : 64'b0;
    assign o_rvfi_pc_rdata  = i_head_entry.pc;
    assign o_rvfi_pc_wdata  = actual_next_pc;
    // a trapping access still reports its would-be fields, as ref_core.sv does
    assign o_rvfi_mem_addr  = is_lsu ? i_lsu_res.mem_addr  : 64'b0;
    assign o_rvfi_mem_rmask = is_lsu ? i_lsu_res.mem_rmask : 8'b0;
    assign o_rvfi_mem_wmask = is_lsu ? i_lsu_res.mem_wmask : 8'b0;
    assign o_rvfi_mem_rdata = is_lsu ? i_lsu_res.mem_rdata : 64'b0;
    assign o_rvfi_mem_wdata = is_lsu ? i_lsu_res.mem_wdata : 64'b0;
endmodule
