/*
 * lockstep_side.sv -- one full side of the lockstep comparison: a core
 * instance (ref_core, optionally mutated via QV_MUTANT, or with
 * CORE_PIPE=1 design/pipe/core_pipe.sv) plus its own bus fabric, memory,
 * delay injection, MMIO and interrupt injection.
 *
 * Both cores have the same port list and the same internal net names
 * for everything read below, so the two generate branches share one
 * label (g_core) and one instance name (core0), and the references below
 * work for either. core_pipe keeps its native name here: it reuses
 * design/'s leaf modules, ref_core its ref_* copies, so both can sit in
 * one compilation unit.
 *
 * This is the only module in verification/lockstep/ that reaches into
 * g_core.core0's internals by hierarchical reference (always legal: a module
 * may reference its own child instance's ports and internal signals).
 * Every other lockstep_*.sv file consumes those values as plain flat
 * ports, so nothing downstream needs a hierarchical reference of its
 * own -- keeps lockstep_rec.sv/lockstep_cmp.sv fully portable and
 * sidesteps any Verilator cross-module hierarchical-reference limits.
 *
 * Most CSR state (mtvec, mip, mie, mideleg, medeleg, satp, dcsr, dpc,
 * pmpcfg0, pmpaddr0-3, the decomposed mstatus bits, and -- under
 * RISCV_FORMAL, always defined for this harness -- mcause/scause) is
 * already wired out to ref_core.sv's own top-level internal nets
 * (`<name>_w`, see its csr_file0 instantiation). Only current_priv
 * (core0's own register, not csr_file's) and the handful of CSRs
 * csr_file.sv never re-exports at all (mtval, stval, mscratch, sscratch,
 * minstret) need a deeper peek into csr_file0 itself.
 */
`include "lockstep_defs.svh"

module lockstep_side #(
    parameter int QV_MUTANT        = 0,    // structural: selects a generate-gated RTL mutant (ref_core)
    parameter bit CORE_PIPE        = 1'b0, // structural: core_pipe instead of ref_core
    parameter bit MEMCFG_CACHE     = 1'b0, // structural: selects the memory topology
    parameter int DELAY_MAX        = 0     // structural: 0 disables both delay-shim FSMs
) (
    input  logic clk,
    input  logic rst,

    input  logic [31:0] delay_seed_fetch_i,  // runtime
    input  logic [31:0] delay_seed_mem_i,    // runtime
    input  logic [31:0] irq_mode_i,          // runtime
    input  logic [31:0] irq_seed_i,          // runtime
    input  logic        irq_late_i,          // runtime, see lockstep_irq.sv

    // RVFI passthrough (core/ref_core always built with -DRISCV_FORMAL
    // by this harness -- see run_lockstep.sh)
    output logic        rvfi_valid,
    output logic [63:0] rvfi_order,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap, rvfi_halt, rvfi_intr,
    output logic [1:0]  rvfi_mode, rvfi_ixl,
    output logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr,
    output logic [63:0] rvfi_rs1_rdata, rvfi_rs2_rdata,
    output logic [4:0]  rvfi_rd_addr,
    output logic [63:0] rvfi_rd_wdata,
    output logic [63:0] rvfi_pc_rdata, rvfi_pc_wdata,
    output logic [63:0] rvfi_mem_addr,
    output logic [7:0]  rvfi_mem_rmask, rvfi_mem_wmask,
    output logic [63:0] rvfi_mem_rdata, rvfi_mem_wdata,
    output logic [63:0] rvfi_csr_mepc_rmask, rvfi_csr_mepc_wmask, rvfi_csr_mepc_rdata, rvfi_csr_mepc_wdata,
    output logic [63:0] rvfi_csr_mcause_rmask, rvfi_csr_mcause_wmask, rvfi_csr_mcause_rdata, rvfi_csr_mcause_wdata,
    output logic [63:0] rvfi_csr_sepc_rmask, rvfi_csr_sepc_wmask, rvfi_csr_sepc_rdata, rvfi_csr_sepc_wdata,
    output logic [63:0] rvfi_csr_scause_rmask, rvfi_csr_scause_wmask, rvfi_csr_scause_rdata, rvfi_csr_scause_wdata,
    output logic [63:0] rvfi_csr_pmpcfg0_rmask, rvfi_csr_pmpcfg0_wmask, rvfi_csr_pmpcfg0_rdata, rvfi_csr_pmpcfg0_wdata,
    output logic [63:0] rvfi_csr_pmpaddr0_rmask, rvfi_csr_pmpaddr0_wmask, rvfi_csr_pmpaddr0_rdata, rvfi_csr_pmpaddr0_wdata,
    output logic [63:0] rvfi_csr_medeleg_rmask, rvfi_csr_medeleg_wmask, rvfi_csr_medeleg_rdata, rvfi_csr_medeleg_wdata,
    output logic [63:0] rvfi_csr_satp_rmask, rvfi_csr_satp_wmask, rvfi_csr_satp_rdata, rvfi_csr_satp_wdata,
    output logic        rvfi_any_trap_taken,
    output logic        rvfi_any_debug_entry,

    // derived cause/tval, same technique as testbench/rvfi_tracer.sv
    output logic [63:0] o_cause,
    output logic [63:0] o_tval,

    // full CSR + privilege snapshot, live (not RVFI-trace-conditional)
    output logic [1:0]  o_current_priv,
    output logic [63:0] o_mtvec, o_stvec,
    output logic [63:0] o_mepc, o_sepc,
    output logic [63:0] o_mcause, o_scause,
    output logic [63:0] o_mtval, o_stval,
    output logic [63:0] o_satp, o_medeleg, o_mideleg,
    output logic [63:0] o_mie, o_mip,
    output logic [63:0] o_mscratch, o_sscratch, o_minstret,
    output logic [63:0] o_pmpcfg0,
    output logic [63:0] o_pmpaddr0, o_pmpaddr1, o_pmpaddr2, o_pmpaddr3,
    output logic [63:0] o_dcsr, o_dpc,
    output logic        o_mstatus_spp, o_mstatus_tsr, o_mstatus_mie, o_mstatus_sie,
    output logic        o_mstatus_mprv, o_mstatus_sum, o_mstatus_mxr, o_mstatus_tvm,
    output logic [1:0]  o_mstatus_mpp,

    // ordered committed-write log
    output logic        o_wr_valid,
    output logic [31:0] o_wr_addr,
    output logic [7:0]  o_wr_sel,
    output logic [63:0] o_wr_data,

    // ordered MMIO-read log
    output logic        o_mmio_rd_valid,
    output logic [31:0] o_mmio_rd_addr,
    output logic [63:0] o_mmio_rd_data
);
    logic i_mtip, i_meip, i_seip;
    logic icache_flush;

    logic [31:0] wb_fetch_addr, wb_mem_addr;
    logic        wb_fetch_cyc, wb_fetch_stb, wb_fetch_ack, wb_fetch_err;
    logic [63:0] wb_fetch_dat;
    logic [63:0] wb_mem_dat_o, wb_mem_dat_i;
    logic [7:0]  wb_mem_sel;
    logic        wb_mem_we, wb_mem_cyc, wb_mem_stb, wb_mem_ack, wb_mem_err, wb_mem_lock;

    // the port list both branches share
`define LS_CORE_PORTS \
        .clk(clk), .rst(rst), \
        .wb_fetch_addr_o(wb_fetch_addr), .wb_fetch_cyc_o(wb_fetch_cyc), .wb_fetch_stb_o(wb_fetch_stb), \
        .wb_fetch_dat_i(wb_fetch_dat), .wb_fetch_ack_i(wb_fetch_ack), .wb_fetch_err_i(wb_fetch_err), \
        .wb_mem_addr_o(wb_mem_addr), .wb_mem_dat_o(wb_mem_dat_o), .wb_mem_dat_i(wb_mem_dat_i), \
        .wb_mem_sel_o(wb_mem_sel), .wb_mem_we_o(wb_mem_we), \
        .wb_mem_cyc_o(wb_mem_cyc), .wb_mem_stb_o(wb_mem_stb), \
        .wb_mem_ack_i(wb_mem_ack), .wb_mem_err_i(wb_mem_err), .wb_mem_lock_o(wb_mem_lock), \
        .icache_flush_o(icache_flush), \
        .i_mtip(i_mtip), .i_meip(i_meip), .i_seip(i_seip), \
        .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn), \
        .rvfi_trap(rvfi_trap), .rvfi_halt(rvfi_halt), .rvfi_intr(rvfi_intr), \
        .rvfi_mode(rvfi_mode), .rvfi_ixl(rvfi_ixl), \
        .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr), \
        .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata), \
        .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata), \
        .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata), \
        .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask), \
        .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata), \
        .rvfi_mem_wdata(rvfi_mem_wdata), \
        .rvfi_csr_mepc_rmask(rvfi_csr_mepc_rmask), .rvfi_csr_mepc_wmask(rvfi_csr_mepc_wmask), \
        .rvfi_csr_mepc_rdata(rvfi_csr_mepc_rdata), .rvfi_csr_mepc_wdata(rvfi_csr_mepc_wdata), \
        .rvfi_csr_mcause_rmask(rvfi_csr_mcause_rmask), .rvfi_csr_mcause_wmask(rvfi_csr_mcause_wmask), \
        .rvfi_csr_mcause_rdata(rvfi_csr_mcause_rdata), .rvfi_csr_mcause_wdata(rvfi_csr_mcause_wdata), \
        .rvfi_csr_sepc_rmask(rvfi_csr_sepc_rmask), .rvfi_csr_sepc_wmask(rvfi_csr_sepc_wmask), \
        .rvfi_csr_sepc_rdata(rvfi_csr_sepc_rdata), .rvfi_csr_sepc_wdata(rvfi_csr_sepc_wdata), \
        .rvfi_csr_scause_rmask(rvfi_csr_scause_rmask), .rvfi_csr_scause_wmask(rvfi_csr_scause_wmask), \
        .rvfi_csr_scause_rdata(rvfi_csr_scause_rdata), .rvfi_csr_scause_wdata(rvfi_csr_scause_wdata), \
        .rvfi_csr_pmpcfg0_rmask(rvfi_csr_pmpcfg0_rmask), .rvfi_csr_pmpcfg0_wmask(rvfi_csr_pmpcfg0_wmask), \
        .rvfi_csr_pmpcfg0_rdata(rvfi_csr_pmpcfg0_rdata), .rvfi_csr_pmpcfg0_wdata(rvfi_csr_pmpcfg0_wdata), \
        .rvfi_csr_pmpaddr0_rmask(rvfi_csr_pmpaddr0_rmask), .rvfi_csr_pmpaddr0_wmask(rvfi_csr_pmpaddr0_wmask), \
        .rvfi_csr_pmpaddr0_rdata(rvfi_csr_pmpaddr0_rdata), .rvfi_csr_pmpaddr0_wdata(rvfi_csr_pmpaddr0_wdata), \
        .rvfi_csr_medeleg_rmask(rvfi_csr_medeleg_rmask), .rvfi_csr_medeleg_wmask(rvfi_csr_medeleg_wmask), \
        .rvfi_csr_medeleg_rdata(rvfi_csr_medeleg_rdata), .rvfi_csr_medeleg_wdata(rvfi_csr_medeleg_wdata), \
        .rvfi_csr_satp_rmask(rvfi_csr_satp_rmask), .rvfi_csr_satp_wmask(rvfi_csr_satp_wmask), \
        .rvfi_csr_satp_rdata(rvfi_csr_satp_rdata), .rvfi_csr_satp_wdata(rvfi_csr_satp_wdata), \
        .rvfi_any_trap_taken(rvfi_any_trap_taken), .rvfi_any_debug_entry(rvfi_any_debug_entry)

    /* verilator lint_off PINCONNECTEMPTY */
    generate
        if (CORE_PIPE) begin : g_core
            core_pipe core0 (`LS_CORE_PORTS);
        end else begin : g_core
            ref_core #(.QV_MUTANT(QV_MUTANT)) core0 (`LS_CORE_PORTS);
        end
    endgenerate
    `undef LS_CORE_PORTS
    /* verilator lint_on PINCONNECTEMPTY */

    logic        magic_set_we, magic_clr_we;
    logic [31:0] magic_set_wdata, magic_clr_wdata;

    lockstep_mem #(
        .MEMCFG_CACHE(MEMCFG_CACHE),
        .DELAY_MAX(DELAY_MAX)
    ) mem0 (
        .clk(clk), .rst(rst),
        .delay_seed_fetch_i(delay_seed_fetch_i), .delay_seed_mem_i(delay_seed_mem_i),
        .fetch_addr_i(wb_fetch_addr), .fetch_cyc_i(wb_fetch_cyc), .fetch_stb_i(wb_fetch_stb),
        .fetch_dat_o(wb_fetch_dat), .fetch_ack_o(wb_fetch_ack), .fetch_err_o(wb_fetch_err),
        .mem_addr_i(wb_mem_addr), .mem_dat_i(wb_mem_dat_o), .mem_dat_o(wb_mem_dat_i),
        .mem_sel_i(wb_mem_sel), .mem_we_i(wb_mem_we),
        .mem_cyc_i(wb_mem_cyc), .mem_stb_i(wb_mem_stb),
        .mem_ack_o(wb_mem_ack), .mem_err_o(wb_mem_err), .mem_lock_i(wb_mem_lock),
        .icache_flush_i(icache_flush),
        .o_magic_set_we(magic_set_we), .o_magic_set_wdata(magic_set_wdata),
        .o_magic_clr_we(magic_clr_we), .o_magic_clr_wdata(magic_clr_wdata),
        .o_wr_valid(o_wr_valid), .o_wr_addr(o_wr_addr), .o_wr_sel(o_wr_sel), .o_wr_data(o_wr_data),
        .o_rd_valid(o_mmio_rd_valid), .o_rd_addr(o_mmio_rd_addr), .o_rd_data(o_mmio_rd_data)
    );

    lockstep_irq irq0 (
        .clk(clk), .rst(rst),
        .irq_mode_i(irq_mode_i), .seed_i(irq_seed_i), .late_i(irq_late_i),
        .rvfi_valid(rvfi_valid),
        .magic_clr_we(magic_clr_we), .magic_clr_wdata(magic_clr_wdata),
        .o_mtip(i_mtip), .o_meip(i_meip), .o_seip(i_seip)
    );

    // magic_set_we/wdata are captured for symmetry with the plan's "set"
    // register but nothing drives real behavior off it yet -- no
    // generated program writes it today (see gen/qvgen.py's own
    // MAGIC_IRQ_CLR-only convention). Silence the unused-signal warning
    // rather than pretend a consumer exists.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_magic_set = magic_set_we & (|magic_set_wdata);
    /* verilator lint_on UNUSEDSIGNAL */

    // Derived cause/tval -- identical technique to testbench/rvfi_tracer.sv.
    // rvfi_csr_{m,s}cause_wdata is architecturally don't-care whenever its
    // own wmask is 0 (RVFI CSR trace port convention) -- testbench/
    // rvfi_tracer.sv's identical derivation never hit this because it
    // only ever ran one core instance at a time, with nothing to compare
    // the resulting garbage against. Here it produced a real false
    // divergence: two identical ref_core instances, running the same
    // program under different bus delay, disagreeing on `cause` for a
    // retirement that (per its matching mcause_w/scause_w snapshot on
    // both sides) never actually wrote either CSR -- caught by an actual
    // REF-vs-REF run with perturbed timing, not by inspection. Gating on
    // the relevant wmask makes both sides deterministically settle on 0
    // instead of reading whatever stale value happened to be sitting on
    // that wire.
    wire cause_wmask_relevant = g_core.core0.route_to_s ? (|rvfi_csr_scause_wmask) : (|rvfi_csr_mcause_wmask);
    assign o_cause = (rvfi_trap && cause_wmask_relevant) ? (g_core.core0.route_to_s ? rvfi_csr_scause_wdata : rvfi_csr_mcause_wdata) : 64'b0;
    assign o_tval  = rvfi_trap ? g_core.core0.trap_val : 64'b0;

    // Full CSR/privilege snapshot. Most of these are already exposed as
    // ref_core.sv's own internal top-level nets (see its csr_file0
    // instantiation); only current_priv and the 5 CSRs csr_file.sv never
    // re-exports need a peek past csr_file0 itself.
    assign o_current_priv = g_core.core0.current_priv;
    assign o_mtvec    = g_core.core0.mtvec_w;
    assign o_stvec     = g_core.core0.stvec_w;
    assign o_mepc      = g_core.core0.mepc_w;
    assign o_sepc      = g_core.core0.sepc_w;
    assign o_mcause    = g_core.core0.mcause_w;
    assign o_scause    = g_core.core0.scause_w;
    assign o_satp      = g_core.core0.satp_w;
    assign o_medeleg   = g_core.core0.medeleg_w;
    assign o_mideleg   = g_core.core0.mideleg_w;
    assign o_mie       = g_core.core0.mie_w;
    assign o_mip       = g_core.core0.mip_w;
    assign o_dcsr      = g_core.core0.dcsr_w;
    assign o_dpc       = g_core.core0.dpc_w;
    assign o_pmpcfg0   = g_core.core0.pmpcfg0_w;
    assign o_pmpaddr0  = g_core.core0.pmpaddr0_w;
    assign o_pmpaddr1  = g_core.core0.pmpaddr1_w;
    assign o_pmpaddr2  = g_core.core0.pmpaddr2_w;
    assign o_pmpaddr3  = g_core.core0.pmpaddr3_w;
    assign o_mstatus_mpp  = g_core.core0.mstatus_mpp_w;
    assign o_mstatus_spp  = g_core.core0.mstatus_spp_w;
    assign o_mstatus_tsr  = g_core.core0.mstatus_tsr_w;
    assign o_mstatus_mie  = g_core.core0.mstatus_mie_w;
    assign o_mstatus_sie  = g_core.core0.mstatus_sie_w;
    assign o_mstatus_mprv = g_core.core0.mstatus_mprv_w;
    assign o_mstatus_sum  = g_core.core0.mstatus_sum_w;
    assign o_mstatus_mxr  = g_core.core0.mstatus_mxr_w;
    assign o_mstatus_tvm  = g_core.core0.mstatus_tvm_w;

    // Not re-exported anywhere in csr_file0's own port list -- a true
    // peek past it.
    assign o_mtval    = g_core.core0.csr_file0.mtval_q;
    assign o_stval     = g_core.core0.csr_file0.stval_q;
    assign o_mscratch  = g_core.core0.csr_file0.mscratch_q;
    assign o_sscratch  = g_core.core0.csr_file0.sscratch_q;
    assign o_minstret  = g_core.core0.csr_file0.minstret_q;
endmodule
