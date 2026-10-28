/*
 * lockstep_side.sv -- one full side of the lockstep comparison: a core
 * instance (ref_core, optionally mutated via QV_MUTANT, or with
 * CORE_PIPE=1 the pipelined core, design/pipe/core.sv, module `core`) plus
 * its own bus fabric, memory, delay injection, MMIO and interrupt injection.
 *
 * Both cores have the same port list and the same internal net names
 * for everything read below, so the two generate branches share one
 * label (g_core) and one instance name (core0), and the references below
 * work for either. ref_core keeps its native name here (no
 * -DQV_REF_AS_CORE): the pipelined core reuses design/'s leaf modules,
 * ref_core its ref_* copies, so both can sit in one compilation unit.
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
`ifndef QV_FPU_EN
`define QV_FPU_EN 1
`endif

module lockstep_side #(
    parameter int QV_MUTANT        = 0,    // structural: selects a generate-gated RTL mutant (ref_core)
    parameter bit CORE_PIPE        = 1'b0, // structural: the pipelined core instead of ref_core
    parameter bit MEMCFG_CACHE     = 1'b0, // structural: selects the memory topology
    parameter int DELAY_MAX        = 0     // structural: 0 disables both delay-shim FSMs
) (
    input  logic clk,
    input  logic rst,

    input  logic [31:0] delay_seed_fetch_i,  // runtime
    input  logic [31:0] delay_seed_mem_i,    // runtime
    input  logic [31:0] irq_mode_i,          // runtime
    input  logic [31:0] irq_seed_i,          // runtime
    input  logic [31:0] irq_density_i,       // runtime, see lockstep_irq.sv
    input  logic        irq_late_i,          // runtime, see lockstep_irq.sv
    input  logic [31:0] dbg_mode_i,          // runtime, see lockstep_dbg.sv (0 = no debug script)
    input  logic [31:0] dbg_seed_i,          // runtime
    input  logic [31:0] dbg_density_i,       // runtime
    input  logic [31:0] dbg_feat_i,          // runtime, feature mask
    input  logic        dbg_late_i,          // runtime, halt level visible one cycle later
    input  logic [63:0] dbg_max_retire_i,    // runtime, the run's MAX_RETIRE (0 = tohost-terminated)
    // The run is over for this side's retirements (it has pushed its stop_at records): halt the core at that
    // boundary, so it retires nothing more while it keeps clocking until its store buffer has drained (the pipelined
    // core writes the bus after a store retires; ref_core before). The halt belongs to the harness, not to the
    // compared behavior: the debug script is silenced, so it logs no event and writes nothing from here on.
    input  logic        stop_i,

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
    // F/D: {the FP register this retirement wrote: valid, number; mstatus.FS; frm; fflags} and the value written
    output logic [15:0] o_fp_word,
    output logic [63:0] o_fp_wdata,

    // ordered committed-write log
    output logic        o_wr_valid,
    output logic [31:0] o_wr_addr,
    output logic [7:0]  o_wr_sel,
    output logic [63:0] o_wr_data,

    // ordered MMIO-read log
    output logic        o_mmio_rd_valid,
    output logic [31:0] o_mmio_rd_addr,
    output logic [63:0] o_mmio_rd_data,

    // debug-script event log (lockstep_dbg.sv)
    output logic        o_ev_valid,
    output logic [3:0]  o_ev_kind,
    output logic [63:0] o_ev_order,
    output logic [63:0] o_ev_a,
    output logic [63:0] o_ev_b
);
    logic i_mtip, i_meip, i_seip;
    logic icache_flush;

    logic [31:0] wb_fetch_addr, wb_mem_addr;
    logic        wb_fetch_cyc, wb_fetch_stb, wb_fetch_ack, wb_fetch_err;
    logic [63:0] wb_fetch_dat;
    logic [63:0] wb_mem_dat_o, wb_mem_dat_i;
    logic [7:0]  wb_mem_sel;
    logic        wb_mem_we, wb_mem_cyc, wb_mem_stb, wb_mem_ack, wb_mem_err, wb_mem_lock;

    // Debug Module wiring, as soc.sv does it: dm0's plain register interface is driven by lockstep_dbg.sv
    // (a scripted debugger), everything between dm0 and the core is the real thing.
    logic        dbg_halted;                        // core0.o_debug_mode
    logic        dm_halt_req, dm_resume_req, script_halt_req, core_halt_req;
    logic        dm_gpr_we, dm_csr_we;
    logic [4:0]  dm_gpr_sel;
    logic [11:0] dm_csr_addr;
    logic [63:0] dm_gpr_wdata, dm_csr_wdata, dm_gpr_rdata, dm_csr_rdata;
    logic        dm_fpr_we;                         // F/D: Access Register to the FP registers
    logic [4:0]  dm_fpr_sel;
    logic [63:0] dm_fpr_wdata, dm_fpr_rdata;
    logic        progbuf_start, progbuf_done, progbuf_abort;
    logic [3:0]  progbuf_pc;
    logic [31:0] progbuf_data;
    logic [6:0]  dmi_addr;
    logic [31:0] dmi_wdata, dmi_rdata;
    logic        dmi_we;
    assign core_halt_req = dm_halt_req | script_halt_req | stop_i;
    logic        rvfi_frd_wvalid;
    logic [4:0]  rvfi_frd_addr;
    logic [63:0] rvfi_frd_wdata;

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
        .rvfi_any_trap_taken(rvfi_any_trap_taken), .rvfi_any_debug_entry(rvfi_any_debug_entry), \
        .rvfi_frd_wvalid(rvfi_frd_wvalid), .rvfi_frd_addr(rvfi_frd_addr), .rvfi_frd_wdata(rvfi_frd_wdata), \
        .o_debug_mode(dbg_halted), .i_debug_halt_req(core_halt_req), .i_debug_resume_req(dm_resume_req), \
        .i_dm_gpr_we(dm_gpr_we), .i_dm_gpr_sel(dm_gpr_sel), .i_dm_gpr_wdata(dm_gpr_wdata), .o_dm_gpr_rdata(dm_gpr_rdata), \
        .i_dm_csr_we(dm_csr_we), .i_dm_csr_addr(dm_csr_addr), .i_dm_csr_wdata(dm_csr_wdata), .o_dm_csr_rdata(dm_csr_rdata), \
        .i_dm_fpr_we(dm_fpr_we), .i_dm_fpr_sel(dm_fpr_sel), .i_dm_fpr_wdata(dm_fpr_wdata), .o_dm_fpr_rdata(dm_fpr_rdata), \
        .i_progbuf_start(progbuf_start), .o_progbuf_pc(progbuf_pc), .i_progbuf_data(progbuf_data), \
        .o_progbuf_done(progbuf_done), .o_progbuf_abort(progbuf_abort)

    /* verilator lint_off PINCONNECTEMPTY */
    generate
        if (CORE_PIPE) begin : g_core
            // RAM is the 1 MiB flat image: its stores are posted by the store buffer. On the flat SRAM fetch and the
            // memory port share one slave through an arbiter, so the fetch stream gives way to the memory port; with the
            // caches fetch has the instruction cache to itself.
            core #(.PMA_RAM_SIZE(64'(`QV_LOCKSTEP_RAM_WORDS) * 64'd8), .FETCH_YIELD(!MEMCFG_CACHE)) core0 (`LS_CORE_PORTS);
`ifdef LS_HAVE_PIPE
            // the pipelined core takes an interrupt, a halt or an EBREAK/trigger entry without waiting for the LSU, which is
            // only safe because nothing can be on the data bus then (it asserts that too, but an assertion only
            // prints): make it fatal here. (Only when the pipelined core is in the build: Verilator checks the names even
            // in a branch that is not taken.)
            always @(posedge clk) begin
                if (!rst && (core0.interrupt_taken || core0.debug_halt_req_entry || core0.debug_ebreak_entry
                             || core0.trigger_debug_entry) && core0.lsu_head_started) begin
                    $display("LOCKSTEP_RESULT: FAIL (the pipelined core entered an interrupt or Debug Mode with a data access started)");
                    $finish;
                end
            end
`endif
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

    // The levels drop on this side's own RETIRED store to MAGIC_CLR, seen through RVFI, never on the
    // bus write: the pipelined core writes the bus a cycle before the store retires and ref_core in the same
    // cycle, so a bus-keyed drop lands on different sides of a sample point on the two sides. Keyed
    // on retirement the stimulus is a pure function of the retirement stream, as lockstep_irq.sv
    // promises. (The MMIO device's own strobe, magic_clr_we, is no longer used.)
    localparam logic [31:0] MAGIC_DWORD = `QV_LOCKSTEP_MAGIC_SET & ~32'h7;
    wire        ret_clr_we    = rvfi_valid && !rvfi_trap && (rvfi_mem_wmask[7:4] != 4'b0)
                                && (rvfi_mem_addr[31:3] == MAGIC_DWORD[31:3]);
    wire [31:0] ret_clr_wdata = rvfi_mem_wdata[63:32];

    lockstep_irq irq0 (
        .clk(clk), .rst(rst),
        .irq_mode_i(irq_mode_i), .seed_i(irq_seed_i), .density_i(irq_density_i), .late_i(irq_late_i),
        .rvfi_valid(rvfi_valid),
        .magic_clr_we(ret_clr_we), .magic_clr_wdata(ret_clr_wdata),
        .o_mtip(i_mtip), .o_meip(i_meip), .o_seip(i_seip)
    );

    // The Debug Module itself (its System Bus Access port is unused here) and the scripted debugger in
    // front of it. With dbg_mode_i == 0 the script never acts and nothing on these wires moves.
    /* verilator lint_off PINCONNECTEMPTY */
    dm #(.HAS_FPR(`QV_FPU_EN != 0)) dm0 (
        .clk(clk), .rst(rst),
        .i_reg_addr(dmi_addr), .i_reg_wdata(dmi_wdata), .i_reg_we(dmi_we && !stop_i), .i_reg_re(1'b0),
        .o_reg_rdata(dmi_rdata),
        .i_hart_halted(dbg_halted),
        .o_debug_halt_req(dm_halt_req), .o_debug_resume_req(dm_resume_req),
        .o_dm_gpr_we(dm_gpr_we), .o_dm_gpr_sel(dm_gpr_sel),
        .o_dm_gpr_wdata(dm_gpr_wdata), .i_dm_gpr_rdata(dm_gpr_rdata),
        .o_dm_csr_we(dm_csr_we), .o_dm_csr_addr(dm_csr_addr),
        .o_dm_csr_wdata(dm_csr_wdata), .i_dm_csr_rdata(dm_csr_rdata),
        .o_dm_fpr_we(dm_fpr_we), .o_dm_fpr_sel(dm_fpr_sel),
        .o_dm_fpr_wdata(dm_fpr_wdata), .i_dm_fpr_rdata(dm_fpr_rdata),
        .o_progbuf_start(progbuf_start), .i_progbuf_pc(progbuf_pc),
        .o_progbuf_data(progbuf_data), .i_progbuf_done(progbuf_done),
        .i_progbuf_abort(progbuf_abort),
        .o_sba_addr(), .o_sba_dat(), .i_sba_dat(64'b0),
        .o_sba_sel(), .o_sba_we(), .o_sba_cyc(), .o_sba_stb(),
        .i_sba_ack(1'b0), .i_sba_err(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic ev_valid_raw;
    assign o_ev_valid = ev_valid_raw && !stop_i;

    lockstep_dbg dbg0 (
        .clk(clk), .rst(rst),
        .mode_i(dbg_mode_i), .seed_i(dbg_seed_i), .density_i(dbg_density_i), .feat_i(dbg_feat_i),
        .late_i(dbg_late_i), .max_retire_i(dbg_max_retire_i),
        .rvfi_valid(rvfi_valid), .debug_mode_i(dbg_halted),
        .o_reg_addr(dmi_addr), .o_reg_wdata(dmi_wdata), .o_reg_we(dmi_we), .i_reg_rdata(dmi_rdata),
        .o_halt_req(script_halt_req),
        .o_ev_valid(ev_valid_raw), .o_ev_kind(o_ev_kind), .o_ev_order(o_ev_order),
        .o_ev_a(o_ev_a), .o_ev_b(o_ev_b)
    );

    // magic_set_we/wdata are captured for symmetry with the plan's "set"
    // register but nothing drives real behavior off it yet -- no
    // generated program writes it today (see gen/qvgen.py's own
    // MAGIC_IRQ_CLR-only convention). Silence the unused-signal warning
    // rather than pretend a consumer exists.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_magic_set = magic_set_we & (|magic_set_wdata) & magic_clr_we & (|magic_clr_wdata);
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
    // F/D: the same names in both cores (csr_file0's exports)
    assign o_fp_word  = {rvfi_frd_wvalid, rvfi_frd_addr, g_core.core0.mstatus_fs_w, g_core.core0.frm_w,
                         g_core.core0.fflags_w};
    assign o_fp_wdata = rvfi_frd_wdata;

    // Not re-exported anywhere in csr_file0's own port list -- a true
    // peek past it.
    assign o_mtval    = g_core.core0.csr_file0.mtval_q;
    assign o_stval     = g_core.core0.csr_file0.stval_q;
    assign o_mscratch  = g_core.core0.csr_file0.mscratch_q;
    assign o_sscratch  = g_core.core0.csr_file0.sscratch_q;
    assign o_minstret  = g_core.core0.csr_file0.minstret_q;
endmodule
