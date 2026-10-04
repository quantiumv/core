/*
 * lockstep_tb.sv -- P3.4 lockstep harness top level (pipelining track
 * plan). Runs two independent core instances against the same program
 * image and compares every retirement plus the ordered bus-write/MMIO-
 * read logs and debug-event counts, ending in a final `LOCKSTEP_RESULT:`
 * line.
 *
 * Side A is always the gold reference: ref_core #(QV_MUTANT=0) on the
 * flat-SRAM memory configuration. Side B is configurable -- a second
 * ref_core #(0) instance with an independently perturbed bus-delay seed
 * and optionally the cache memory configuration (the REF-vs-REF self-
 * proof), or a ref_core #(QV_MUTANT_B) instance for the mutant kill
 * matrix, or (B_PIPE=1) design/pipe/core_pipe.sv for pipe-vs-ref.
 *
 * QV_MUTANT_B/MEMCFG_B_CACHE/DELAY_MAX/B_PIPE select RTL structure (a
 * generate-gated mutant, a memory topology, whether the delay-shim FSMs
 * exist at all, which core is side B), so they're module parameters, overridden at compile
 * time -- e.g. `iverilog ... -Plockstep_tb.QV_MUTANT_B=3`, matching the
 * plan's own "kill matrix of ref_core #(k) against #(0)" framing.
 * Everything else is genuine runtime data and comes in as a plusarg:
 * +HEXFILE=<path> +TOHOST_ADDR=<hex> +MAX_RETIRE=<n> +TIMEOUT=<cycles>
 * +IRQ_MODE=<0|1|2> +IRQ_SEED=<n> +IRQ_LATE=<0|1> +DLY_SEED_A=<n> +DLY_SEED_B=<n>
 * +CORRUPT_AT=<order> +CORRUPT_FIELD=<code> +DUMP_FROM=<cycles> (0 = no
 * VCD).
 *
 * RESOLVED: a run where a real interrupt is actually TAKEN used to
 * silently stall (both sides' retirement rings drain to empty with
 * nothing further ever pushed, ending in a clean exit(0) with no
 * LOCKSTEP_RESULT line at all) -- root cause was lockstep_mmio.sv's own
 * MAGIC_DWORD bug (see that file's header), not anything in this file;
 * fixed there. Reproduce the old symptom's absence with verification/
 * lockstep/repro_irq_stall.s under +IRQ_MODE=2 (any seed) -- it now
 * reaches a clean LOCKSTEP_RESULT either way.
 *
 * Completion is an exact stop (see stop_at below): each side's clock
 * freezes after the same number of retirements -- +MAX_RETIRE, or one
 * past the first retired store to tohost -- so sides running at
 * different speeds (different delays, a cache, a different core) end in
 * identical states and the final register-file/RAM diff is exact. The
 * old rule (tohost visible in both RAMs with both rings drained) only
 * converged when both sides ran at the same speed, and a MAX_RETIRE
 * diff ran while the faster side was up to QV_LOCKSTEP_AHEAD_MAX
 * retirements ahead.
 *
 * QV_MUTANT==5 (ref_core.sv's interrupt_sample_q) samples interrupts
 * one CYCLE late, not one retirement late. Against IRQ_MODE 1/2, whose
 * levels are visible from the cycle right after a retirement, it takes
 * every interrupt at the same retirement boundary as the real core, so
 * its retirement stream and its exact-stop final state both match; it
 * was only ever "caught" by the skew of the old stop. +IRQ_LATE=1
 * shows each level a cycle later still: the real core then takes it
 * only after the next retirement, mutant 5 already after this one.
 */
`include "lockstep_defs.svh"

module lockstep_tb #(
    parameter int QV_MUTANT_B     = 0,
    parameter bit MEMCFG_B_CACHE  = 1'b0,
    parameter int DELAY_MAX       = 0,
    parameter bit B_PIPE          = 1'b0
);
    // ---------------- plusargs ----------------
    string       hex_path;
    logic [31:0] tohost_addr;
    longint      max_retire;
    longint      max_cycles;
    int          irq_mode, irq_seed, irq_late;
    int          dly_seed_a, dly_seed_b;
    longint      corrupt_at;
    int          corrupt_field;
    longint      dump_from;

    initial begin
        if (!$value$plusargs("HEXFILE=%s", hex_path))       hex_path       = "";
        if (!$value$plusargs("TOHOST_ADDR=%h", tohost_addr)) tohost_addr   = 32'b0;
        if (!$value$plusargs("MAX_RETIRE=%d", max_retire))  max_retire     = 0;       // 0 = unbounded
        if (!$value$plusargs("TIMEOUT=%d", max_cycles))     max_cycles     = 2000000;
        if (!$value$plusargs("IRQ_MODE=%d", irq_mode))      irq_mode       = 0;
        if (!$value$plusargs("IRQ_SEED=%d", irq_seed))      irq_seed       = 1;
        if (!$value$plusargs("IRQ_LATE=%d", irq_late))      irq_late       = 0;
        if (!$value$plusargs("DLY_SEED_A=%d", dly_seed_a))  dly_seed_a     = 1;
        if (!$value$plusargs("DLY_SEED_B=%d", dly_seed_b))  dly_seed_b     = 2;
        if (!$value$plusargs("CORRUPT_AT=%d", corrupt_at))  corrupt_at     = 0;       // 0 = disabled
        if (!$value$plusargs("CORRUPT_FIELD=%d", corrupt_field)) corrupt_field = 0;
        if (!$value$plusargs("DUMP_FROM=%d", dump_from))    dump_from      = 0;       // 0 = no VCD
    end

    // ---------------- independent, individually pace-able clocks ----------------
    // clk_mon NEVER pauses -- it drives the comparator (which is what
    // drains each side's ring and lets a pace hold release) and the
    // top-level control loop. Anchoring either of those to clk_a/clk_b
    // instead is a real deadlock: if side A backs up past AHEAD_MAX,
    // pace_a_hold freezes clk_a, which would freeze the very comparator
    // that drains A's ring, so the hold could never release (caught by
    // an actual run hanging indefinitely, not by inspection).
    logic clk_a = 1'b0, clk_b = 1'b0, clk_mon = 1'b0;
    logic rst   = 1'b1;
    logic pace_a_hold, pace_b_hold;
    logic a_stopped, b_stopped;         // see "exact stop" below

    always #5 if (!pace_a_hold) clk_a = ~clk_a;
    always #5 if (!pace_b_hold) clk_b = ~clk_b;
    always #5 clk_mon = ~clk_mon;

    // ---------------- side A: the gold reference ----------------
    logic        a_rvfi_valid, a_rvfi_trap, a_rvfi_halt, a_rvfi_intr, a_rvfi_any_trap_taken, a_rvfi_any_debug_entry;
    logic [63:0] a_rvfi_order, a_rvfi_pc_rdata, a_rvfi_pc_wdata, a_rvfi_rd_wdata, a_rvfi_rs1_rdata, a_rvfi_rs2_rdata;
    logic [31:0] a_rvfi_insn;
    logic [1:0]  a_rvfi_mode, a_rvfi_ixl;
    logic [4:0]  a_rvfi_rs1_addr, a_rvfi_rs2_addr, a_rvfi_rd_addr;
    logic [63:0] a_rvfi_mem_addr, a_rvfi_mem_rdata, a_rvfi_mem_wdata;
    logic [7:0]  a_rvfi_mem_rmask, a_rvfi_mem_wmask;
    logic [63:0] a_cause, a_tval;
    logic [1:0]  a_current_priv;
    logic [63:0] a_mtvec, a_stvec, a_mepc, a_sepc, a_mcause, a_scause;
    logic [63:0] a_mtval, a_stval, a_satp, a_medeleg, a_mideleg;
    logic [63:0] a_mie, a_mip, a_mscratch, a_sscratch, a_minstret;
    logic [63:0] a_pmpcfg0, a_pmpaddr0, a_pmpaddr1, a_pmpaddr2, a_pmpaddr3;
    logic [63:0] a_dcsr, a_dpc;
    logic [1:0]  a_mstatus_mpp;
    logic        a_mstatus_spp, a_mstatus_tsr, a_mstatus_mie, a_mstatus_sie;
    logic        a_mstatus_mprv, a_mstatus_sum, a_mstatus_mxr, a_mstatus_tvm;
    logic        a_wr_valid, a_mmio_rd_valid;
    logic [31:0] a_wr_addr, a_mmio_rd_addr;
    logic [7:0]  a_wr_sel;
    logic [63:0] a_wr_data, a_mmio_rd_data;

    lockstep_side #(
        .QV_MUTANT(0), .MEMCFG_CACHE(1'b0),
        .DELAY_MAX(DELAY_MAX)
    ) side_a (
        .clk(clk_a), .rst(rst),
        .delay_seed_fetch_i(dly_seed_a[31:0]), .delay_seed_mem_i(dly_seed_a[31:0] + 32'h1000),
        .irq_mode_i(irq_mode[31:0]), .irq_seed_i(irq_seed[31:0]), .irq_late_i(irq_late != 0),
        .rvfi_valid(a_rvfi_valid), .rvfi_order(a_rvfi_order), .rvfi_insn(a_rvfi_insn),
        .rvfi_trap(a_rvfi_trap), .rvfi_halt(a_rvfi_halt), .rvfi_intr(a_rvfi_intr),
        .rvfi_mode(a_rvfi_mode), .rvfi_ixl(a_rvfi_ixl),
        .rvfi_rs1_addr(a_rvfi_rs1_addr), .rvfi_rs2_addr(a_rvfi_rs2_addr),
        .rvfi_rs1_rdata(a_rvfi_rs1_rdata), .rvfi_rs2_rdata(a_rvfi_rs2_rdata),
        .rvfi_rd_addr(a_rvfi_rd_addr), .rvfi_rd_wdata(a_rvfi_rd_wdata),
        .rvfi_pc_rdata(a_rvfi_pc_rdata), .rvfi_pc_wdata(a_rvfi_pc_wdata),
        .rvfi_mem_addr(a_rvfi_mem_addr), .rvfi_mem_rmask(a_rvfi_mem_rmask),
        .rvfi_mem_wmask(a_rvfi_mem_wmask), .rvfi_mem_rdata(a_rvfi_mem_rdata), .rvfi_mem_wdata(a_rvfi_mem_wdata),
        .rvfi_csr_mepc_rmask(), .rvfi_csr_mepc_wmask(), .rvfi_csr_mepc_rdata(), .rvfi_csr_mepc_wdata(),
        .rvfi_csr_mcause_rmask(), .rvfi_csr_mcause_wmask(), .rvfi_csr_mcause_rdata(), .rvfi_csr_mcause_wdata(),
        .rvfi_csr_sepc_rmask(), .rvfi_csr_sepc_wmask(), .rvfi_csr_sepc_rdata(), .rvfi_csr_sepc_wdata(),
        .rvfi_csr_scause_rmask(), .rvfi_csr_scause_wmask(), .rvfi_csr_scause_rdata(), .rvfi_csr_scause_wdata(),
        .rvfi_csr_pmpcfg0_rmask(), .rvfi_csr_pmpcfg0_wmask(), .rvfi_csr_pmpcfg0_rdata(), .rvfi_csr_pmpcfg0_wdata(),
        .rvfi_csr_pmpaddr0_rmask(), .rvfi_csr_pmpaddr0_wmask(), .rvfi_csr_pmpaddr0_rdata(), .rvfi_csr_pmpaddr0_wdata(),
        .rvfi_csr_medeleg_rmask(), .rvfi_csr_medeleg_wmask(), .rvfi_csr_medeleg_rdata(), .rvfi_csr_medeleg_wdata(),
        .rvfi_csr_satp_rmask(), .rvfi_csr_satp_wmask(), .rvfi_csr_satp_rdata(), .rvfi_csr_satp_wdata(),
        .rvfi_any_trap_taken(a_rvfi_any_trap_taken), .rvfi_any_debug_entry(a_rvfi_any_debug_entry),
        .o_cause(a_cause), .o_tval(a_tval),
        .o_current_priv(a_current_priv),
        .o_mtvec(a_mtvec), .o_stvec(a_stvec), .o_mepc(a_mepc), .o_sepc(a_sepc),
        .o_mcause(a_mcause), .o_scause(a_scause), .o_mtval(a_mtval), .o_stval(a_stval),
        .o_satp(a_satp), .o_medeleg(a_medeleg), .o_mideleg(a_mideleg),
        .o_mie(a_mie), .o_mip(a_mip), .o_mscratch(a_mscratch), .o_sscratch(a_sscratch), .o_minstret(a_minstret),
        .o_pmpcfg0(a_pmpcfg0), .o_pmpaddr0(a_pmpaddr0), .o_pmpaddr1(a_pmpaddr1),
        .o_pmpaddr2(a_pmpaddr2), .o_pmpaddr3(a_pmpaddr3),
        .o_dcsr(a_dcsr), .o_dpc(a_dpc),
        .o_mstatus_spp(a_mstatus_spp), .o_mstatus_tsr(a_mstatus_tsr),
        .o_mstatus_mie(a_mstatus_mie), .o_mstatus_sie(a_mstatus_sie),
        .o_mstatus_mprv(a_mstatus_mprv), .o_mstatus_sum(a_mstatus_sum),
        .o_mstatus_mxr(a_mstatus_mxr), .o_mstatus_tvm(a_mstatus_tvm), .o_mstatus_mpp(a_mstatus_mpp),
        .o_wr_valid(a_wr_valid), .o_wr_addr(a_wr_addr), .o_wr_sel(a_wr_sel), .o_wr_data(a_wr_data),
        .o_mmio_rd_valid(a_mmio_rd_valid), .o_mmio_rd_addr(a_mmio_rd_addr), .o_mmio_rd_data(a_mmio_rd_data)
    );

    // ---------------- side B: configurable ----------------
    logic        b_rvfi_valid, b_rvfi_trap, b_rvfi_halt, b_rvfi_intr, b_rvfi_any_trap_taken, b_rvfi_any_debug_entry;
    logic [63:0] b_rvfi_order, b_rvfi_pc_rdata, b_rvfi_pc_wdata, b_rvfi_rd_wdata, b_rvfi_rs1_rdata, b_rvfi_rs2_rdata;
    logic [31:0] b_rvfi_insn;
    logic [1:0]  b_rvfi_mode, b_rvfi_ixl;
    logic [4:0]  b_rvfi_rs1_addr, b_rvfi_rs2_addr, b_rvfi_rd_addr;
    logic [63:0] b_rvfi_mem_addr, b_rvfi_mem_rdata, b_rvfi_mem_wdata;
    logic [7:0]  b_rvfi_mem_rmask, b_rvfi_mem_wmask;
    logic [63:0] b_cause, b_tval;
    logic [1:0]  b_current_priv;
    logic [63:0] b_mtvec, b_stvec, b_mepc, b_sepc, b_mcause, b_scause;
    logic [63:0] b_mtval, b_stval, b_satp, b_medeleg, b_mideleg;
    logic [63:0] b_mie, b_mip, b_mscratch, b_sscratch, b_minstret;
    logic [63:0] b_pmpcfg0, b_pmpaddr0, b_pmpaddr1, b_pmpaddr2, b_pmpaddr3;
    logic [63:0] b_dcsr, b_dpc;
    logic [1:0]  b_mstatus_mpp;
    logic        b_mstatus_spp, b_mstatus_tsr, b_mstatus_mie, b_mstatus_sie;
    logic        b_mstatus_mprv, b_mstatus_sum, b_mstatus_mxr, b_mstatus_tvm;
    logic        b_wr_valid, b_mmio_rd_valid;
    logic [31:0] b_wr_addr, b_mmio_rd_addr;
    logic [7:0]  b_wr_sel;
    logic [63:0] b_wr_data, b_mmio_rd_data;

    lockstep_side #(
        .QV_MUTANT(QV_MUTANT_B), .CORE_PIPE(B_PIPE), .MEMCFG_CACHE(MEMCFG_B_CACHE),
        .DELAY_MAX(DELAY_MAX)
    ) side_b (
        .clk(clk_b), .rst(rst),
        .delay_seed_fetch_i(dly_seed_b[31:0]), .delay_seed_mem_i(dly_seed_b[31:0] + 32'h1000),
        .irq_mode_i(irq_mode[31:0]), .irq_seed_i(irq_seed[31:0]), .irq_late_i(irq_late != 0),
        .rvfi_valid(b_rvfi_valid), .rvfi_order(b_rvfi_order), .rvfi_insn(b_rvfi_insn),
        .rvfi_trap(b_rvfi_trap), .rvfi_halt(b_rvfi_halt), .rvfi_intr(b_rvfi_intr),
        .rvfi_mode(b_rvfi_mode), .rvfi_ixl(b_rvfi_ixl),
        .rvfi_rs1_addr(b_rvfi_rs1_addr), .rvfi_rs2_addr(b_rvfi_rs2_addr),
        .rvfi_rs1_rdata(b_rvfi_rs1_rdata), .rvfi_rs2_rdata(b_rvfi_rs2_rdata),
        .rvfi_rd_addr(b_rvfi_rd_addr), .rvfi_rd_wdata(b_rvfi_rd_wdata),
        .rvfi_pc_rdata(b_rvfi_pc_rdata), .rvfi_pc_wdata(b_rvfi_pc_wdata),
        .rvfi_mem_addr(b_rvfi_mem_addr), .rvfi_mem_rmask(b_rvfi_mem_rmask),
        .rvfi_mem_wmask(b_rvfi_mem_wmask), .rvfi_mem_rdata(b_rvfi_mem_rdata), .rvfi_mem_wdata(b_rvfi_mem_wdata),
        .rvfi_csr_mepc_rmask(), .rvfi_csr_mepc_wmask(), .rvfi_csr_mepc_rdata(), .rvfi_csr_mepc_wdata(),
        .rvfi_csr_mcause_rmask(), .rvfi_csr_mcause_wmask(), .rvfi_csr_mcause_rdata(), .rvfi_csr_mcause_wdata(),
        .rvfi_csr_sepc_rmask(), .rvfi_csr_sepc_wmask(), .rvfi_csr_sepc_rdata(), .rvfi_csr_sepc_wdata(),
        .rvfi_csr_scause_rmask(), .rvfi_csr_scause_wmask(), .rvfi_csr_scause_rdata(), .rvfi_csr_scause_wdata(),
        .rvfi_csr_pmpcfg0_rmask(), .rvfi_csr_pmpcfg0_wmask(), .rvfi_csr_pmpcfg0_rdata(), .rvfi_csr_pmpcfg0_wdata(),
        .rvfi_csr_pmpaddr0_rmask(), .rvfi_csr_pmpaddr0_wmask(), .rvfi_csr_pmpaddr0_rdata(), .rvfi_csr_pmpaddr0_wdata(),
        .rvfi_csr_medeleg_rmask(), .rvfi_csr_medeleg_wmask(), .rvfi_csr_medeleg_rdata(), .rvfi_csr_medeleg_wdata(),
        .rvfi_csr_satp_rmask(), .rvfi_csr_satp_wmask(), .rvfi_csr_satp_rdata(), .rvfi_csr_satp_wdata(),
        .rvfi_any_trap_taken(b_rvfi_any_trap_taken), .rvfi_any_debug_entry(b_rvfi_any_debug_entry),
        .o_cause(b_cause), .o_tval(b_tval),
        .o_current_priv(b_current_priv),
        .o_mtvec(b_mtvec), .o_stvec(b_stvec), .o_mepc(b_mepc), .o_sepc(b_sepc),
        .o_mcause(b_mcause), .o_scause(b_scause), .o_mtval(b_mtval), .o_stval(b_stval),
        .o_satp(b_satp), .o_medeleg(b_medeleg), .o_mideleg(b_mideleg),
        .o_mie(b_mie), .o_mip(b_mip), .o_mscratch(b_mscratch), .o_sscratch(b_sscratch), .o_minstret(b_minstret),
        .o_pmpcfg0(b_pmpcfg0), .o_pmpaddr0(b_pmpaddr0), .o_pmpaddr1(b_pmpaddr1),
        .o_pmpaddr2(b_pmpaddr2), .o_pmpaddr3(b_pmpaddr3),
        .o_dcsr(b_dcsr), .o_dpc(b_dpc),
        .o_mstatus_spp(b_mstatus_spp), .o_mstatus_tsr(b_mstatus_tsr),
        .o_mstatus_mie(b_mstatus_mie), .o_mstatus_sie(b_mstatus_sie),
        .o_mstatus_mprv(b_mstatus_mprv), .o_mstatus_sum(b_mstatus_sum),
        .o_mstatus_mxr(b_mstatus_mxr), .o_mstatus_tvm(b_mstatus_tvm), .o_mstatus_mpp(b_mstatus_mpp),
        .o_wr_valid(b_wr_valid), .o_wr_addr(b_wr_addr), .o_wr_sel(b_wr_sel), .o_wr_data(b_wr_data),
        .o_mmio_rd_valid(b_mmio_rd_valid), .o_mmio_rd_addr(b_mmio_rd_addr), .o_mmio_rd_data(b_mmio_rd_data)
    );

    // ---------------- per-side record capture ----------------
    logic        a_rec_avail, b_rec_avail, a_rec_pop, b_rec_pop;
    logic [31:0] a_rec_count, b_rec_count, a_rec_total, b_rec_total;
    logic        a_wr_avail, b_wr_avail, a_wr_pop, b_wr_pop;
    logic        a_rda_avail, b_rda_avail, a_rda_pop, b_rda_pop;
    logic        a_dbg_avail, b_dbg_avail, a_dbg_pop, b_dbg_pop;

    // popped-field buses (a_rp_*/b_rp_*) -- declared once, reused by both
    // the rec instances (outputs) and cmp0 (inputs)
    logic [63:0] a_rp_order, a_rp_pc_rdata, a_rp_pc_wdata, a_rp_rd_wdata, a_rp_rs1_rdata, a_rp_rs2_rdata;
    logic [31:0] a_rp_insn;
    logic        a_rp_trap, a_rp_intr;
    logic [1:0]  a_rp_mode;
    logic [4:0]  a_rp_rd_addr, a_rp_rs1_addr, a_rp_rs2_addr;
    logic [63:0] a_rp_mem_addr, a_rp_mem_rdata, a_rp_mem_wdata;
    logic [7:0]  a_rp_mem_rmask, a_rp_mem_wmask;
    logic [63:0] a_rp_cause, a_rp_tval;
    logic [1:0]  a_rp_current_priv;
    logic [63:0] a_rp_mtvec, a_rp_stvec, a_rp_mepc, a_rp_sepc, a_rp_mcause, a_rp_scause;
    logic [63:0] a_rp_mtval, a_rp_stval, a_rp_satp, a_rp_medeleg, a_rp_mideleg;
    logic [63:0] a_rp_mie, a_rp_mip, a_rp_mscratch, a_rp_sscratch, a_rp_minstret;
    logic [63:0] a_rp_pmpcfg0, a_rp_pmpaddr0, a_rp_pmpaddr1, a_rp_pmpaddr2, a_rp_pmpaddr3;
    logic [63:0] a_rp_dcsr, a_rp_dpc;
    logic [1:0]  a_rp_mstatus_mpp;
    logic        a_rp_mstatus_spp, a_rp_mstatus_tsr, a_rp_mstatus_mie, a_rp_mstatus_sie;
    logic        a_rp_mstatus_mprv, a_rp_mstatus_sum, a_rp_mstatus_mxr, a_rp_mstatus_tvm;
    logic [31:0] a_wrp_addr;
    logic [7:0]  a_wrp_sel;
    logic [63:0] a_wrp_data;
    logic [31:0] a_rdap_addr;
    logic [63:0] a_rdap_data;

    logic [63:0] b_rp_order, b_rp_pc_rdata, b_rp_pc_wdata, b_rp_rd_wdata, b_rp_rs1_rdata, b_rp_rs2_rdata;
    logic [31:0] b_rp_insn;
    logic        b_rp_trap, b_rp_intr;
    logic [1:0]  b_rp_mode;
    logic [4:0]  b_rp_rd_addr, b_rp_rs1_addr, b_rp_rs2_addr;
    logic [63:0] b_rp_mem_addr, b_rp_mem_rdata, b_rp_mem_wdata;
    logic [7:0]  b_rp_mem_rmask, b_rp_mem_wmask;
    logic [63:0] b_rp_cause, b_rp_tval;
    logic [1:0]  b_rp_current_priv;
    logic [63:0] b_rp_mtvec, b_rp_stvec, b_rp_mepc, b_rp_sepc, b_rp_mcause, b_rp_scause;
    logic [63:0] b_rp_mtval, b_rp_stval, b_rp_satp, b_rp_medeleg, b_rp_mideleg;
    logic [63:0] b_rp_mie, b_rp_mip, b_rp_mscratch, b_rp_sscratch, b_rp_minstret;
    logic [63:0] b_rp_pmpcfg0, b_rp_pmpaddr0, b_rp_pmpaddr1, b_rp_pmpaddr2, b_rp_pmpaddr3;
    logic [63:0] b_rp_dcsr, b_rp_dpc;
    logic [1:0]  b_rp_mstatus_mpp;
    logic        b_rp_mstatus_spp, b_rp_mstatus_tsr, b_rp_mstatus_mie, b_rp_mstatus_sie;
    logic        b_rp_mstatus_mprv, b_rp_mstatus_sum, b_rp_mstatus_mxr, b_rp_mstatus_tvm;
    logic [31:0] b_wrp_addr;
    logic [7:0]  b_wrp_sel;
    logic [63:0] b_wrp_data;
    logic [31:0] b_rdap_addr;
    logic [63:0] b_rdap_data;

    lockstep_rec rec_a (
        .clk_push(clk_a), .clk_pop(clk_mon), .rst(rst),
        .rvfi_valid(a_rvfi_valid), .rvfi_order(a_rvfi_order),
        .rvfi_pc_rdata(a_rvfi_pc_rdata), .rvfi_pc_wdata(a_rvfi_pc_wdata), .rvfi_insn(a_rvfi_insn),
        .rvfi_trap(a_rvfi_trap), .rvfi_intr(a_rvfi_intr), .rvfi_mode(a_rvfi_mode),
        .rvfi_rd_addr(a_rvfi_rd_addr), .rvfi_rd_wdata(a_rvfi_rd_wdata),
        .rvfi_rs1_addr(a_rvfi_rs1_addr), .rvfi_rs1_rdata(a_rvfi_rs1_rdata),
        .rvfi_rs2_addr(a_rvfi_rs2_addr), .rvfi_rs2_rdata(a_rvfi_rs2_rdata),
        .rvfi_mem_addr(a_rvfi_mem_addr), .rvfi_mem_rmask(a_rvfi_mem_rmask), .rvfi_mem_wmask(a_rvfi_mem_wmask),
        .rvfi_mem_rdata(a_rvfi_mem_rdata), .rvfi_mem_wdata(a_rvfi_mem_wdata),
        .o_cause(a_cause), .o_tval(a_tval), .o_current_priv(a_current_priv),
        .o_mtvec(a_mtvec), .o_stvec(a_stvec), .o_mepc(a_mepc), .o_sepc(a_sepc),
        .o_mcause(a_mcause), .o_scause(a_scause), .o_mtval(a_mtval), .o_stval(a_stval),
        .o_satp(a_satp), .o_medeleg(a_medeleg), .o_mideleg(a_mideleg),
        .o_mie(a_mie), .o_mip(a_mip), .o_mscratch(a_mscratch), .o_sscratch(a_sscratch), .o_minstret(a_minstret),
        .o_pmpcfg0(a_pmpcfg0), .o_pmpaddr0(a_pmpaddr0), .o_pmpaddr1(a_pmpaddr1),
        .o_pmpaddr2(a_pmpaddr2), .o_pmpaddr3(a_pmpaddr3), .o_dcsr(a_dcsr), .o_dpc(a_dpc),
        .o_mstatus_mpp(a_mstatus_mpp), .o_mstatus_spp(a_mstatus_spp), .o_mstatus_tsr(a_mstatus_tsr),
        .o_mstatus_mie(a_mstatus_mie), .o_mstatus_sie(a_mstatus_sie), .o_mstatus_mprv(a_mstatus_mprv),
        .o_mstatus_sum(a_mstatus_sum), .o_mstatus_mxr(a_mstatus_mxr), .o_mstatus_tvm(a_mstatus_tvm),
        .rvfi_any_debug_entry(a_rvfi_any_debug_entry),
        .wr_valid_i(a_wr_valid), .wr_addr_i(a_wr_addr), .wr_sel_i(a_wr_sel), .wr_data_i(a_wr_data),
        .rd_valid_i(a_mmio_rd_valid), .rd_addr_i(a_mmio_rd_addr), .rd_data_i(a_mmio_rd_data),
        .rec_count(a_rec_count), .rec_total(a_rec_total),
        .rec_avail(a_rec_avail), .rec_pop(a_rec_pop),
        .rp_order(a_rp_order), .rp_pc_rdata(a_rp_pc_rdata), .rp_pc_wdata(a_rp_pc_wdata), .rp_insn(a_rp_insn),
        .rp_trap(a_rp_trap), .rp_intr(a_rp_intr), .rp_mode(a_rp_mode),
        .rp_rd_addr(a_rp_rd_addr), .rp_rd_wdata(a_rp_rd_wdata),
        .rp_rs1_addr(a_rp_rs1_addr), .rp_rs1_rdata(a_rp_rs1_rdata),
        .rp_rs2_addr(a_rp_rs2_addr), .rp_rs2_rdata(a_rp_rs2_rdata),
        .rp_mem_addr(a_rp_mem_addr), .rp_mem_rmask(a_rp_mem_rmask), .rp_mem_wmask(a_rp_mem_wmask),
        .rp_mem_rdata(a_rp_mem_rdata), .rp_mem_wdata(a_rp_mem_wdata),
        .rp_cause(a_rp_cause), .rp_tval(a_rp_tval), .rp_current_priv(a_rp_current_priv),
        .rp_mtvec(a_rp_mtvec), .rp_stvec(a_rp_stvec), .rp_mepc(a_rp_mepc), .rp_sepc(a_rp_sepc),
        .rp_mcause(a_rp_mcause), .rp_scause(a_rp_scause), .rp_mtval(a_rp_mtval), .rp_stval(a_rp_stval),
        .rp_satp(a_rp_satp), .rp_medeleg(a_rp_medeleg), .rp_mideleg(a_rp_mideleg),
        .rp_mie(a_rp_mie), .rp_mip(a_rp_mip), .rp_mscratch(a_rp_mscratch), .rp_sscratch(a_rp_sscratch),
        .rp_minstret(a_rp_minstret),
        .rp_pmpcfg0(a_rp_pmpcfg0), .rp_pmpaddr0(a_rp_pmpaddr0), .rp_pmpaddr1(a_rp_pmpaddr1),
        .rp_pmpaddr2(a_rp_pmpaddr2), .rp_pmpaddr3(a_rp_pmpaddr3), .rp_dcsr(a_rp_dcsr), .rp_dpc(a_rp_dpc),
        .rp_mstatus_mpp(a_rp_mstatus_mpp), .rp_mstatus_spp(a_rp_mstatus_spp), .rp_mstatus_tsr(a_rp_mstatus_tsr),
        .rp_mstatus_mie(a_rp_mstatus_mie), .rp_mstatus_sie(a_rp_mstatus_sie), .rp_mstatus_mprv(a_rp_mstatus_mprv),
        .rp_mstatus_sum(a_rp_mstatus_sum), .rp_mstatus_mxr(a_rp_mstatus_mxr), .rp_mstatus_tvm(a_rp_mstatus_tvm),
        .wr_avail(a_wr_avail), .wr_pop(a_wr_pop), .wrp_addr(a_wrp_addr), .wrp_sel(a_wrp_sel), .wrp_data(a_wrp_data),
        .rd_avail(a_rda_avail), .rd_pop(a_rda_pop), .rdp_addr(a_rdap_addr), .rdp_data(a_rdap_data),
        .dbg_avail(a_dbg_avail), .dbg_pop(a_dbg_pop)
    );

    lockstep_rec rec_b (
        .clk_push(clk_b), .clk_pop(clk_mon), .rst(rst),
        .rvfi_valid(b_rvfi_valid), .rvfi_order(b_rvfi_order),
        .rvfi_pc_rdata(b_rvfi_pc_rdata), .rvfi_pc_wdata(b_rvfi_pc_wdata), .rvfi_insn(b_rvfi_insn),
        .rvfi_trap(b_rvfi_trap), .rvfi_intr(b_rvfi_intr), .rvfi_mode(b_rvfi_mode),
        .rvfi_rd_addr(b_rvfi_rd_addr), .rvfi_rd_wdata(b_rvfi_rd_wdata),
        .rvfi_rs1_addr(b_rvfi_rs1_addr), .rvfi_rs1_rdata(b_rvfi_rs1_rdata),
        .rvfi_rs2_addr(b_rvfi_rs2_addr), .rvfi_rs2_rdata(b_rvfi_rs2_rdata),
        .rvfi_mem_addr(b_rvfi_mem_addr), .rvfi_mem_rmask(b_rvfi_mem_rmask), .rvfi_mem_wmask(b_rvfi_mem_wmask),
        .rvfi_mem_rdata(b_rvfi_mem_rdata), .rvfi_mem_wdata(b_rvfi_mem_wdata),
        .o_cause(b_cause), .o_tval(b_tval), .o_current_priv(b_current_priv),
        .o_mtvec(b_mtvec), .o_stvec(b_stvec), .o_mepc(b_mepc), .o_sepc(b_sepc),
        .o_mcause(b_mcause), .o_scause(b_scause), .o_mtval(b_mtval), .o_stval(b_stval),
        .o_satp(b_satp), .o_medeleg(b_medeleg), .o_mideleg(b_mideleg),
        .o_mie(b_mie), .o_mip(b_mip), .o_mscratch(b_mscratch), .o_sscratch(b_sscratch), .o_minstret(b_minstret),
        .o_pmpcfg0(b_pmpcfg0), .o_pmpaddr0(b_pmpaddr0), .o_pmpaddr1(b_pmpaddr1),
        .o_pmpaddr2(b_pmpaddr2), .o_pmpaddr3(b_pmpaddr3), .o_dcsr(b_dcsr), .o_dpc(b_dpc),
        .o_mstatus_mpp(b_mstatus_mpp), .o_mstatus_spp(b_mstatus_spp), .o_mstatus_tsr(b_mstatus_tsr),
        .o_mstatus_mie(b_mstatus_mie), .o_mstatus_sie(b_mstatus_sie), .o_mstatus_mprv(b_mstatus_mprv),
        .o_mstatus_sum(b_mstatus_sum), .o_mstatus_mxr(b_mstatus_mxr), .o_mstatus_tvm(b_mstatus_tvm),
        .rvfi_any_debug_entry(b_rvfi_any_debug_entry),
        .wr_valid_i(b_wr_valid), .wr_addr_i(b_wr_addr), .wr_sel_i(b_wr_sel), .wr_data_i(b_wr_data),
        .rd_valid_i(b_mmio_rd_valid), .rd_addr_i(b_mmio_rd_addr), .rd_data_i(b_mmio_rd_data),
        .rec_count(b_rec_count), .rec_total(b_rec_total),
        .rec_avail(b_rec_avail), .rec_pop(b_rec_pop),
        .rp_order(b_rp_order), .rp_pc_rdata(b_rp_pc_rdata), .rp_pc_wdata(b_rp_pc_wdata), .rp_insn(b_rp_insn),
        .rp_trap(b_rp_trap), .rp_intr(b_rp_intr), .rp_mode(b_rp_mode),
        .rp_rd_addr(b_rp_rd_addr), .rp_rd_wdata(b_rp_rd_wdata),
        .rp_rs1_addr(b_rp_rs1_addr), .rp_rs1_rdata(b_rp_rs1_rdata),
        .rp_rs2_addr(b_rp_rs2_addr), .rp_rs2_rdata(b_rp_rs2_rdata),
        .rp_mem_addr(b_rp_mem_addr), .rp_mem_rmask(b_rp_mem_rmask), .rp_mem_wmask(b_rp_mem_wmask),
        .rp_mem_rdata(b_rp_mem_rdata), .rp_mem_wdata(b_rp_mem_wdata),
        .rp_cause(b_rp_cause), .rp_tval(b_rp_tval), .rp_current_priv(b_rp_current_priv),
        .rp_mtvec(b_rp_mtvec), .rp_stvec(b_rp_stvec), .rp_mepc(b_rp_mepc), .rp_sepc(b_rp_sepc),
        .rp_mcause(b_rp_mcause), .rp_scause(b_rp_scause), .rp_mtval(b_rp_mtval), .rp_stval(b_rp_stval),
        .rp_satp(b_rp_satp), .rp_medeleg(b_rp_medeleg), .rp_mideleg(b_rp_mideleg),
        .rp_mie(b_rp_mie), .rp_mip(b_rp_mip), .rp_mscratch(b_rp_mscratch), .rp_sscratch(b_rp_sscratch),
        .rp_minstret(b_rp_minstret),
        .rp_pmpcfg0(b_rp_pmpcfg0), .rp_pmpaddr0(b_rp_pmpaddr0), .rp_pmpaddr1(b_rp_pmpaddr1),
        .rp_pmpaddr2(b_rp_pmpaddr2), .rp_pmpaddr3(b_rp_pmpaddr3), .rp_dcsr(b_rp_dcsr), .rp_dpc(b_rp_dpc),
        .rp_mstatus_mpp(b_rp_mstatus_mpp), .rp_mstatus_spp(b_rp_mstatus_spp), .rp_mstatus_tsr(b_rp_mstatus_tsr),
        .rp_mstatus_mie(b_rp_mstatus_mie), .rp_mstatus_sie(b_rp_mstatus_sie), .rp_mstatus_mprv(b_rp_mstatus_mprv),
        .rp_mstatus_sum(b_rp_mstatus_sum), .rp_mstatus_mxr(b_rp_mstatus_mxr), .rp_mstatus_tvm(b_rp_mstatus_tvm),
        .wr_avail(b_wr_avail), .wr_pop(b_wr_pop), .wrp_addr(b_wrp_addr), .wrp_sel(b_wrp_sel), .wrp_data(b_wrp_data),
        .rd_avail(b_rda_avail), .rd_pop(b_rda_pop), .rdp_addr(b_rdap_addr), .rdp_data(b_rdap_data),
        .dbg_avail(b_dbg_avail), .dbg_pop(b_dbg_pop)
    );

    // ---------------- comparator ----------------
    // cmp0 runs off clk_mon (never paced) -- see lockstep_rec.sv's header
    // comment for why gating it (or the ring pop-pointers it drains) on
    // clk_a/clk_b instead is a real deadlock.
    logic        result_fail;
    logic [63:0] fail_order, match_count;

    lockstep_cmp cmp0 (
        .clk(clk_mon), .rst(rst),
        .a_rec_avail(a_rec_avail), .a_rec_total(a_rec_total), .a_rec_pop(a_rec_pop),
        .a_order(a_rp_order), .a_pc_rdata(a_rp_pc_rdata), .a_pc_wdata(a_rp_pc_wdata), .a_insn(a_rp_insn),
        .a_trap(a_rp_trap), .a_intr(a_rp_intr), .a_mode(a_rp_mode),
        .a_rd_addr(a_rp_rd_addr), .a_rd_wdata(a_rp_rd_wdata),
        .a_rs1_addr(a_rp_rs1_addr), .a_rs1_rdata(a_rp_rs1_rdata),
        .a_rs2_addr(a_rp_rs2_addr), .a_rs2_rdata(a_rp_rs2_rdata),
        .a_mem_addr(a_rp_mem_addr), .a_mem_rmask(a_rp_mem_rmask), .a_mem_wmask(a_rp_mem_wmask),
        .a_mem_rdata(a_rp_mem_rdata), .a_mem_wdata(a_rp_mem_wdata),
        .a_cause(a_rp_cause), .a_tval(a_rp_tval), .a_current_priv(a_rp_current_priv),
        .a_mtvec(a_rp_mtvec), .a_stvec(a_rp_stvec), .a_mepc(a_rp_mepc), .a_sepc(a_rp_sepc),
        .a_mcause(a_rp_mcause), .a_scause(a_rp_scause), .a_mtval(a_rp_mtval), .a_stval(a_rp_stval),
        .a_satp(a_rp_satp), .a_medeleg(a_rp_medeleg), .a_mideleg(a_rp_mideleg),
        .a_mie(a_rp_mie), .a_mip(a_rp_mip), .a_mscratch(a_rp_mscratch), .a_sscratch(a_rp_sscratch),
        .a_minstret(a_rp_minstret),
        .a_pmpcfg0(a_rp_pmpcfg0), .a_pmpaddr0(a_rp_pmpaddr0), .a_pmpaddr1(a_rp_pmpaddr1),
        .a_pmpaddr2(a_rp_pmpaddr2), .a_pmpaddr3(a_rp_pmpaddr3), .a_dcsr(a_rp_dcsr), .a_dpc(a_rp_dpc),
        .a_mstatus_mpp(a_rp_mstatus_mpp), .a_mstatus_spp(a_rp_mstatus_spp), .a_mstatus_tsr(a_rp_mstatus_tsr),
        .a_mstatus_mie(a_rp_mstatus_mie), .a_mstatus_sie(a_rp_mstatus_sie), .a_mstatus_mprv(a_rp_mstatus_mprv),
        .a_mstatus_sum(a_rp_mstatus_sum), .a_mstatus_mxr(a_rp_mstatus_mxr), .a_mstatus_tvm(a_rp_mstatus_tvm),

        .b_rec_avail(b_rec_avail), .b_rec_total(b_rec_total), .b_rec_pop(b_rec_pop),
        .b_order(b_rp_order), .b_pc_rdata(b_rp_pc_rdata), .b_pc_wdata(b_rp_pc_wdata), .b_insn(b_rp_insn),
        .b_trap(b_rp_trap), .b_intr(b_rp_intr), .b_mode(b_rp_mode),
        .b_rd_addr(b_rp_rd_addr), .b_rd_wdata(b_rp_rd_wdata),
        .b_rs1_addr(b_rp_rs1_addr), .b_rs1_rdata(b_rp_rs1_rdata),
        .b_rs2_addr(b_rp_rs2_addr), .b_rs2_rdata(b_rp_rs2_rdata),
        .b_mem_addr(b_rp_mem_addr), .b_mem_rmask(b_rp_mem_rmask), .b_mem_wmask(b_rp_mem_wmask),
        .b_mem_rdata(b_rp_mem_rdata), .b_mem_wdata(b_rp_mem_wdata),
        .b_cause(b_rp_cause), .b_tval(b_rp_tval), .b_current_priv(b_rp_current_priv),
        .b_mtvec(b_rp_mtvec), .b_stvec(b_rp_stvec), .b_mepc(b_rp_mepc), .b_sepc(b_rp_sepc),
        .b_mcause(b_rp_mcause), .b_scause(b_rp_scause), .b_mtval(b_rp_mtval), .b_stval(b_rp_stval),
        .b_satp(b_rp_satp), .b_medeleg(b_rp_medeleg), .b_mideleg(b_rp_mideleg),
        .b_mie(b_rp_mie), .b_mip(b_rp_mip), .b_mscratch(b_rp_mscratch), .b_sscratch(b_rp_sscratch),
        .b_minstret(b_rp_minstret),
        .b_pmpcfg0(b_rp_pmpcfg0), .b_pmpaddr0(b_rp_pmpaddr0), .b_pmpaddr1(b_rp_pmpaddr1),
        .b_pmpaddr2(b_rp_pmpaddr2), .b_pmpaddr3(b_rp_pmpaddr3), .b_dcsr(b_rp_dcsr), .b_dpc(b_rp_dpc),
        .b_mstatus_mpp(b_rp_mstatus_mpp), .b_mstatus_spp(b_rp_mstatus_spp), .b_mstatus_tsr(b_rp_mstatus_tsr),
        .b_mstatus_mie(b_rp_mstatus_mie), .b_mstatus_sie(b_rp_mstatus_sie), .b_mstatus_mprv(b_rp_mstatus_mprv),
        .b_mstatus_sum(b_rp_mstatus_sum), .b_mstatus_mxr(b_rp_mstatus_mxr), .b_mstatus_tvm(b_rp_mstatus_tvm),

        .a_wr_avail(a_wr_avail), .b_wr_avail(b_wr_avail), .a_wr_pop(a_wr_pop), .b_wr_pop(b_wr_pop),
        .a_wrp_addr(a_wrp_addr), .b_wrp_addr(b_wrp_addr), .a_wrp_sel(a_wrp_sel), .b_wrp_sel(b_wrp_sel),
        .a_wrp_data(a_wrp_data), .b_wrp_data(b_wrp_data),

        .a_rd_avail(a_rda_avail), .b_rd_avail(b_rda_avail), .a_rd_pop(a_rda_pop), .b_rd_pop(b_rda_pop),
        .a_rdp_addr(a_rdap_addr), .b_rdp_addr(b_rdap_addr), .a_rdp_data(a_rdap_data), .b_rdp_data(b_rdap_data),

        .a_dbg_avail(a_dbg_avail), .b_dbg_avail(b_dbg_avail), .a_dbg_pop(a_dbg_pop), .b_dbg_pop(b_dbg_pop),

        .a_stopped(a_stopped), .b_stopped(b_stopped),
        .corrupt_at(corrupt_at[63:0]), .corrupt_field(corrupt_field),
        .result_fail(result_fail), .fail_order(fail_order), .match_count(match_count)
    );

    // ---------------- exact stop ----------------
    // stop_at is the number of retirements both sides must make before the
    // run ends: MAX_RETIRE, or one past the first retired store of nonzero
    // data to tohost's dword, whichever side retires it first (the faster
    // side always does). Each side's clock freezes the moment it has pushed
    // stop_at records, so both end at exactly the same retirement however
    // different their speeds, and the final register/RAM diff is exact.
    // That needs every store's bus write to land before (or as) it
    // retires, which both cores guarantee.
    longint stop_at;
    initial stop_at = 0;

    function automatic logic tohost_store(input logic valid, input logic trap, input logic [7:0] wmask,
                                          input logic [63:0] addr, input logic [63:0] wdata);
        logic [63:0] lanes;
        for (int i = 0; i < 8; i++) lanes[8*i +: 8] = {8{wmask[i]}};
        return valid && !trap && wmask != 8'b0 && tohost_addr != 32'b0
            && addr[31:3] == tohost_addr[31:3] && (wdata & lanes) != 64'b0;
    endfunction

    always @(posedge clk_a)
        if (!rst && tohost_store(a_rvfi_valid, a_rvfi_trap, a_rvfi_mem_wmask, a_rvfi_mem_addr, a_rvfi_mem_wdata)
                 && (stop_at == 0 || longint'(a_rvfi_order) + 1 < stop_at))
            stop_at = longint'(a_rvfi_order) + 1;
    always @(posedge clk_b)
        if (!rst && tohost_store(b_rvfi_valid, b_rvfi_trap, b_rvfi_mem_wmask, b_rvfi_mem_addr, b_rvfi_mem_wdata)
                 && (stop_at == 0 || longint'(b_rvfi_order) + 1 < stop_at))
            stop_at = longint'(b_rvfi_order) + 1;

    assign a_stopped = (stop_at != 0) && (longint'(a_rec_total) >= stop_at);
    assign b_stopped = (stop_at != 0) && (longint'(b_rec_total) >= stop_at);

    // ---------------- pacing: hold a side's clock once it's too far ahead or done ----------------
    assign pace_a_hold = (a_rec_count >= `QV_LOCKSTEP_AHEAD_MAX) || a_stopped;
    assign pace_b_hold = (b_rec_count >= `QV_LOCKSTEP_AHEAD_MAX) || b_stopped;

    // ---------------- image load, run control, final report ----------------
    // Anchored to clk_mon throughout, deliberately -- never to clk_a/
    // clk_b, which can be paced-held (see lockstep_rec.sv's header
    // comment). A control loop tied to a holdable clock can itself
    // deadlock the same way the ring pop-pointer did.
    longint cycle_q;
    always_ff @(posedge clk_mon) if (!rst) cycle_q <= cycle_q + 1;

    initial begin
        cycle_q = 0;
        if (dump_from == 0) begin
            // no VCD requested
        end else begin
            $dumpfile("lockstep.vcd");
            $dumpvars(0, lockstep_tb);
        end

        repeat (4) @(posedge clk_mon);
        #1;
        if (hex_path != "") begin
            $readmemh(hex_path, side_a.mem0.sram0.memory);
            $readmemh(hex_path, side_b.mem0.sram0.memory);
        end
        @(posedge clk_mon); #1;
        if (max_retire != 0) stop_at = max_retire;
        rst = 1'b0;

        forever begin
            @(posedge clk_mon);
            if (dump_from != 0 && cycle_q == dump_from) begin
                $dumpfile("lockstep.vcd");
                $dumpvars(0, lockstep_tb);
            end
            if (result_fail) begin
                $display("LOCKSTEP_RESULT: FAIL at retirement order=%0d (matched %0d before it)", fail_order, match_count);
                $finish;
            end
            // Done once both sides have stopped at stop_at and every record
            // has been compared. The bus-write, MMIO-read and debug-event
            // logs only pop in pairs, so anything left over on one side
            // (an extra or missing access) is a divergence of its own.
            if (a_stopped && b_stopped && !a_rec_avail && !b_rec_avail
                    && longint'(match_count) >= stop_at) begin
                repeat (4) @(posedge clk_mon);
                if (result_fail) begin
                    $display("LOCKSTEP_RESULT: FAIL at retirement order=%0d (matched %0d before it)", fail_order, match_count);
                    $finish;
                end
                if (a_wr_avail || b_wr_avail || a_rda_avail || b_rda_avail || a_dbg_avail || b_dbg_avail) begin
                    $display("LOCKSTEP_DIVERGENCE: unmatched log entries at the stop (wr a=%0d b=%0d, mmio-rd a=%0d b=%0d, dbg a=%0d b=%0d)",
                             a_wr_avail, b_wr_avail, a_rda_avail, b_rda_avail, a_dbg_avail, b_dbg_avail);
                    $display("LOCKSTEP_RESULT: FAIL (unmatched bus-write/MMIO-read/debug log entries after %0d retirements)", match_count);
                    $finish;
                end
                check_final_state();
                if (tohost_addr != 32'b0 && max_retire == 0)
                    $display("LOCKSTEP_RESULT: PASS (%0d retirements matched, tohost=%0h)", match_count,
                             side_a.mem0.sram0.memory[tohost_addr[31:3]]);
                else
                    $display("LOCKSTEP_RESULT: PASS (%0d retirements matched, MAX_RETIRE reached)", match_count);
                $finish;
            end
            if (cycle_q >= max_cycles) begin
                $display("LOCKSTEP_RESULT: TIMEOUT after %0d cycles (%0d retirements matched)", cycle_q, match_count);
                $finish;
            end
        end
    end

    // Full architectural-state diff at a clean PASS: the whole register
    // file plus the whole RAM image. Diffing all `QV_LOCKSTEP_RAM_WORDS
    // words unconditionally is simpler than -- and strictly subsumes --
    // tracking which words either side actually wrote.
    task check_final_state();
        int mismatches;
        mismatches = 0;
        for (int r = 0; r < 32; r++) begin
            if (side_a.g_core.core0.regfile0.gp_registers[r] != side_b.g_core.core0.regfile0.gp_registers[r]) begin
                $display("LOCKSTEP_DIVERGENCE: final x%0d a=%016h b=%016h",
                         r, side_a.g_core.core0.regfile0.gp_registers[r], side_b.g_core.core0.regfile0.gp_registers[r]);
                mismatches++;
            end
        end
        for (longint w = 0; w < `QV_LOCKSTEP_RAM_WORDS; w++) begin
            if (side_a.mem0.sram0.memory[w] != side_b.mem0.sram0.memory[w]) begin
                $display("LOCKSTEP_DIVERGENCE: final RAM[%0h] a=%016h b=%016h",
                         w * 8, side_a.mem0.sram0.memory[w], side_b.mem0.sram0.memory[w]);
                mismatches++;
            end
        end
        if (mismatches != 0) begin
            $display("LOCKSTEP_RESULT: FAIL (%0d final-state mismatches after a clean retirement stream)", mismatches);
            $finish;
        end
    endtask
endmodule
