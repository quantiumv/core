/*
 * lockstep_rec.sv -- one side's record capture: three fixed-depth ring
 * buffers (retirement stream, ordered bus-write log, ordered MMIO-read
 * log) plus a debug-event counter, all pushed from lockstep_side.sv's
 * flat ports and popped by lockstep_cmp.sv.
 *
 * Two independent clocks, deliberately: clk_push is this side's own
 * core clock (clk_a or clk_b in lockstep_tb.sv), which pauses whenever
 * lockstep_tb's pacing logic holds it. clk_pop is the shared, never-
 * paused monitor clock. A single clk_push-only ring (an earlier version
 * of this file) deadlocks for real: once a side's ring fills past
 * AHEAD_MAX and its clock is held to let the other side catch up, a
 * pop pointer clocked by that SAME held clock can never advance either,
 * so the ring can never drain and the hold can never release -- caught
 * by an actual run hanging indefinitely at 100% CPU, not by inspection.
 * The write pointer lives solely in the clk_push domain, the read
 * pointer solely in clk_pop, and occupancy/avail are derived
 * combinationally from both rather than kept as a separately-clocked
 * counter, so there is exactly one always_ff driver per register.
 *
 * Ring storage is plain parallel arrays (one per field), not an array
 * of a packed struct: iverilog's elaborator crashes on
 * `array_of_packed_struct[i].field`, confirmed by hitting it directly
 * (`assert: elab_expr.cc:2677: failed assertion base_index.size()+1 ==
 * net->packed_dimensions()`) whether read via `assign` or
 * `always_comb`. Exactly the class of risk the plan's P4a
 * toolchain-probe note flags for `qv_pkg.sv` ("arrays of packed
 * structs"), just confirmed here a milestone earlier than planned.
 *
 * A "no fork, fixed rings" build rule (per the plan) applies here.
 */
`include "lockstep_defs.svh"

module lockstep_rec #(
    parameter int REC_DEPTH = `QV_LOCKSTEP_REC_DEPTH,
    parameter int WR_DEPTH  = `QV_LOCKSTEP_WR_DEPTH,
    parameter int RD_DEPTH  = `QV_LOCKSTEP_RD_DEPTH,
    parameter int DBG_DEPTH = `QV_LOCKSTEP_HIST_DEPTH
) (
    input logic clk_push,
    input logic clk_pop,
    input logic rst,

    // retirement stream in (from lockstep_side.sv, flat)
    input logic         rvfi_valid,
    input logic [63:0]  rvfi_order,
    input logic [63:0]  rvfi_pc_rdata, rvfi_pc_wdata,
    input logic [31:0]  rvfi_insn,
    input logic         rvfi_trap, rvfi_intr,
    input logic [1:0]   rvfi_mode,
    input logic [4:0]   rvfi_rd_addr,
    input logic [63:0]  rvfi_rd_wdata,
    input logic [4:0]   rvfi_rs1_addr,
    input logic [63:0]  rvfi_rs1_rdata,
    input logic [4:0]   rvfi_rs2_addr,
    input logic [63:0]  rvfi_rs2_rdata,
    input logic [63:0]  rvfi_mem_addr,
    input logic [7:0]   rvfi_mem_rmask, rvfi_mem_wmask,
    input logic [63:0]  rvfi_mem_rdata, rvfi_mem_wdata,
    input logic [63:0]  o_cause, o_tval,
    input logic [1:0]   o_current_priv,
    input logic [63:0]  o_mtvec, o_stvec, o_mepc, o_sepc, o_mcause, o_scause,
    input logic [63:0]  o_mtval, o_stval, o_satp, o_medeleg, o_mideleg,
    input logic [63:0]  o_mie, o_mip, o_mscratch, o_sscratch, o_minstret,
    input logic [63:0]  o_pmpcfg0, o_pmpaddr0, o_pmpaddr1, o_pmpaddr2, o_pmpaddr3,
    input logic [63:0]  o_dcsr, o_dpc,
    input logic [1:0]   o_mstatus_mpp,
    input logic         o_mstatus_spp, o_mstatus_tsr, o_mstatus_mie, o_mstatus_sie,
    input logic         o_mstatus_mprv, o_mstatus_sum, o_mstatus_mxr, o_mstatus_tvm,

    input logic         rvfi_any_debug_entry,

    input logic         wr_valid_i,
    input logic [31:0]  wr_addr_i,
    input logic [7:0]   wr_sel_i,
    input logic [63:0]  wr_data_i,

    input logic         rd_valid_i,
    input logic [31:0]  rd_addr_i,
    input logic [63:0]  rd_data_i,

    output logic [31:0] rec_count,
    output logic [31:0] rec_total,   // lifetime push count, for the final report

    output logic         rec_avail,
    input  logic         rec_pop,
    output logic [63:0]  rp_order,
    output logic [63:0]  rp_pc_rdata, rp_pc_wdata,
    output logic [31:0]  rp_insn,
    output logic         rp_trap, rp_intr,
    output logic [1:0]   rp_mode,
    output logic [4:0]   rp_rd_addr,
    output logic [63:0]  rp_rd_wdata,
    output logic [4:0]   rp_rs1_addr,
    output logic [63:0]  rp_rs1_rdata,
    output logic [4:0]   rp_rs2_addr,
    output logic [63:0]  rp_rs2_rdata,
    output logic [63:0]  rp_mem_addr,
    output logic [7:0]   rp_mem_rmask, rp_mem_wmask,
    output logic [63:0]  rp_mem_rdata, rp_mem_wdata,
    output logic [63:0]  rp_cause, rp_tval,
    output logic [1:0]   rp_current_priv,
    output logic [63:0]  rp_mtvec, rp_stvec, rp_mepc, rp_sepc, rp_mcause, rp_scause,
    output logic [63:0]  rp_mtval, rp_stval, rp_satp, rp_medeleg, rp_mideleg,
    output logic [63:0]  rp_mie, rp_mip, rp_mscratch, rp_sscratch, rp_minstret,
    output logic [63:0]  rp_pmpcfg0, rp_pmpaddr0, rp_pmpaddr1, rp_pmpaddr2, rp_pmpaddr3,
    output logic [63:0]  rp_dcsr, rp_dpc,
    output logic [1:0]   rp_mstatus_mpp,
    output logic         rp_mstatus_spp, rp_mstatus_tsr, rp_mstatus_mie, rp_mstatus_sie,
    output logic         rp_mstatus_mprv, rp_mstatus_sum, rp_mstatus_mxr, rp_mstatus_tvm,

    output logic         wr_avail,
    input  logic         wr_pop,
    output logic [31:0]  wrp_addr,
    output logic [7:0]   wrp_sel,
    output logic [63:0]  wrp_data,

    output logic         rd_avail,
    input  logic         rd_pop,
    output logic [31:0]  rdp_addr,
    output logic [63:0]  rdp_data,

    output logic         dbg_avail,
    input  logic         dbg_pop
);
    // Plain parallel arrays, one per field, all indexed identically --
    // NOT an array of a packed struct. iverilog's elaborator (confirmed
    // by hitting it directly) crashes on `array_of_packed_struct[i].field`
    // whether read via `assign` or `always_comb`: `assert:
    // elab_expr.cc:2677: failed assertion base_index.size()+1 ==
    // net->packed_dimensions()`. This is the exact class of risk the
    // plan's P4a toolchain-probe note flags for `qv_pkg.sv` ("arrays of
    // packed structs") -- confirmed here, a milestone earlier than the
    // plan expected to probe it. Parallel arrays of plain vectors sidestep
    // it entirely: every access below is a single-dimension array index,
    // never a struct field selection layered on top of one.

    // -------------------- retirement ring --------------------
    // Explicit initial values (not just reset) are load-bearing: this
    // pointer feeds pace_a_hold/pace_b_hold in lockstep_tb.sv, which gate
    // clk_a/clk_b's own toggling. Left X until the first real clock edge,
    // that's a genuine bootstrap deadlock -- pace_*_hold reads as X,
    // `if (!pace_*_hold)` takes neither branch, the clock that would
    // resolve it never ticks. Caught by an actual run hanging at time 0
    // with zero retirements, not by inspection.
    logic [$clog2(REC_DEPTH)-1:0] rec_wp_q = '0, rec_rp_q = '0;
    logic [31:0]                  rec_total_q = '0;

    logic [63:0] ring_order        [0:REC_DEPTH-1];
    logic [63:0] ring_pc_rdata     [0:REC_DEPTH-1];
    logic [63:0] ring_pc_wdata     [0:REC_DEPTH-1];
    logic [31:0] ring_insn         [0:REC_DEPTH-1];
    logic        ring_trap         [0:REC_DEPTH-1];
    logic        ring_intr         [0:REC_DEPTH-1];
    logic [1:0]  ring_mode         [0:REC_DEPTH-1];
    logic [4:0]  ring_rd_addr      [0:REC_DEPTH-1];
    logic [63:0] ring_rd_wdata     [0:REC_DEPTH-1];
    logic [4:0]  ring_rs1_addr     [0:REC_DEPTH-1];
    logic [63:0] ring_rs1_rdata    [0:REC_DEPTH-1];
    logic [4:0]  ring_rs2_addr     [0:REC_DEPTH-1];
    logic [63:0] ring_rs2_rdata    [0:REC_DEPTH-1];
    logic [63:0] ring_mem_addr     [0:REC_DEPTH-1];
    logic [7:0]  ring_mem_rmask    [0:REC_DEPTH-1];
    logic [7:0]  ring_mem_wmask    [0:REC_DEPTH-1];
    logic [63:0] ring_mem_rdata    [0:REC_DEPTH-1];
    logic [63:0] ring_mem_wdata    [0:REC_DEPTH-1];
    logic [63:0] ring_cause        [0:REC_DEPTH-1];
    logic [63:0] ring_tval         [0:REC_DEPTH-1];
    logic [1:0]  ring_current_priv [0:REC_DEPTH-1];
    logic [63:0] ring_mtvec        [0:REC_DEPTH-1];
    logic [63:0] ring_stvec        [0:REC_DEPTH-1];
    logic [63:0] ring_mepc         [0:REC_DEPTH-1];
    logic [63:0] ring_sepc         [0:REC_DEPTH-1];
    logic [63:0] ring_mcause       [0:REC_DEPTH-1];
    logic [63:0] ring_scause       [0:REC_DEPTH-1];
    logic [63:0] ring_mtval        [0:REC_DEPTH-1];
    logic [63:0] ring_stval        [0:REC_DEPTH-1];
    logic [63:0] ring_satp         [0:REC_DEPTH-1];
    logic [63:0] ring_medeleg      [0:REC_DEPTH-1];
    logic [63:0] ring_mideleg      [0:REC_DEPTH-1];
    logic [63:0] ring_mie          [0:REC_DEPTH-1];
    logic [63:0] ring_mip          [0:REC_DEPTH-1];
    logic [63:0] ring_mscratch     [0:REC_DEPTH-1];
    logic [63:0] ring_sscratch     [0:REC_DEPTH-1];
    logic [63:0] ring_minstret     [0:REC_DEPTH-1];
    logic [63:0] ring_pmpcfg0      [0:REC_DEPTH-1];
    logic [63:0] ring_pmpaddr0     [0:REC_DEPTH-1];
    logic [63:0] ring_pmpaddr1     [0:REC_DEPTH-1];
    logic [63:0] ring_pmpaddr2     [0:REC_DEPTH-1];
    logic [63:0] ring_pmpaddr3     [0:REC_DEPTH-1];
    logic [63:0] ring_dcsr         [0:REC_DEPTH-1];
    logic [63:0] ring_dpc          [0:REC_DEPTH-1];
    logic [1:0]  ring_mstatus_mpp  [0:REC_DEPTH-1];
    logic        ring_mstatus_spp  [0:REC_DEPTH-1];
    logic        ring_mstatus_tsr  [0:REC_DEPTH-1];
    logic        ring_mstatus_mie  [0:REC_DEPTH-1];
    logic        ring_mstatus_sie  [0:REC_DEPTH-1];
    logic        ring_mstatus_mprv [0:REC_DEPTH-1];
    logic        ring_mstatus_sum  [0:REC_DEPTH-1];
    logic        ring_mstatus_mxr  [0:REC_DEPTH-1];
    logic        ring_mstatus_tvm  [0:REC_DEPTH-1];

    // Occupancy/avail derived combinationally from the two independently
    // clocked pointers -- see the header comment on why this can't be a
    // single counter incremented/decremented by two different clocks.
    assign rec_count = (rec_wp_q - rec_rp_q) & (REC_DEPTH - 1);
    assign rec_total = rec_total_q;
    assign rec_avail = (rec_wp_q != rec_rp_q);

    always_ff @(posedge clk_push) begin
        if (rst) begin
            rec_wp_q <= '0; rec_total_q <= '0;
        end else if (rvfi_valid) begin
            ring_order[rec_wp_q]        <= rvfi_order;
            ring_pc_rdata[rec_wp_q]     <= rvfi_pc_rdata;
            ring_pc_wdata[rec_wp_q]     <= rvfi_pc_wdata;
            ring_insn[rec_wp_q]         <= rvfi_insn;
            ring_trap[rec_wp_q]         <= rvfi_trap;
            ring_intr[rec_wp_q]         <= rvfi_intr;
            ring_mode[rec_wp_q]         <= rvfi_mode;
            ring_rd_addr[rec_wp_q]      <= rvfi_rd_addr;
            ring_rd_wdata[rec_wp_q]     <= rvfi_rd_wdata;
            ring_rs1_addr[rec_wp_q]     <= rvfi_rs1_addr;
            ring_rs1_rdata[rec_wp_q]    <= rvfi_rs1_rdata;
            ring_rs2_addr[rec_wp_q]     <= rvfi_rs2_addr;
            ring_rs2_rdata[rec_wp_q]    <= rvfi_rs2_rdata;
            ring_mem_addr[rec_wp_q]     <= rvfi_mem_addr;
            ring_mem_rmask[rec_wp_q]    <= rvfi_mem_rmask;
            ring_mem_wmask[rec_wp_q]    <= rvfi_mem_wmask;
            ring_mem_rdata[rec_wp_q]    <= rvfi_mem_rdata;
            ring_mem_wdata[rec_wp_q]    <= rvfi_mem_wdata;
            ring_cause[rec_wp_q]        <= o_cause;
            ring_tval[rec_wp_q]         <= o_tval;
            ring_current_priv[rec_wp_q] <= o_current_priv;
            ring_mtvec[rec_wp_q]        <= o_mtvec;
            ring_stvec[rec_wp_q]        <= o_stvec;
            ring_mepc[rec_wp_q]         <= o_mepc;
            ring_sepc[rec_wp_q]         <= o_sepc;
            ring_mcause[rec_wp_q]       <= o_mcause;
            ring_scause[rec_wp_q]       <= o_scause;
            ring_mtval[rec_wp_q]        <= o_mtval;
            ring_stval[rec_wp_q]        <= o_stval;
            ring_satp[rec_wp_q]         <= o_satp;
            ring_medeleg[rec_wp_q]      <= o_medeleg;
            ring_mideleg[rec_wp_q]      <= o_mideleg;
            ring_mie[rec_wp_q]          <= o_mie;
            ring_mip[rec_wp_q]          <= o_mip;
            ring_mscratch[rec_wp_q]     <= o_mscratch;
            ring_sscratch[rec_wp_q]     <= o_sscratch;
            ring_minstret[rec_wp_q]     <= o_minstret;
            ring_pmpcfg0[rec_wp_q]      <= o_pmpcfg0;
            ring_pmpaddr0[rec_wp_q]     <= o_pmpaddr0;
            ring_pmpaddr1[rec_wp_q]     <= o_pmpaddr1;
            ring_pmpaddr2[rec_wp_q]     <= o_pmpaddr2;
            ring_pmpaddr3[rec_wp_q]     <= o_pmpaddr3;
            ring_dcsr[rec_wp_q]         <= o_dcsr;
            ring_dpc[rec_wp_q]          <= o_dpc;
            ring_mstatus_mpp[rec_wp_q]  <= o_mstatus_mpp;
            ring_mstatus_spp[rec_wp_q]  <= o_mstatus_spp;
            ring_mstatus_tsr[rec_wp_q]  <= o_mstatus_tsr;
            ring_mstatus_mie[rec_wp_q]  <= o_mstatus_mie;
            ring_mstatus_sie[rec_wp_q]  <= o_mstatus_sie;
            ring_mstatus_mprv[rec_wp_q] <= o_mstatus_mprv;
            ring_mstatus_sum[rec_wp_q]  <= o_mstatus_sum;
            ring_mstatus_mxr[rec_wp_q]  <= o_mstatus_mxr;
            ring_mstatus_tvm[rec_wp_q]  <= o_mstatus_tvm;
            rec_wp_q    <= rec_wp_q + 1'b1;
            rec_total_q <= rec_total_q + 1'b1;
        end
    end

    always_ff @(posedge clk_pop) begin
        if (rst) begin
            rec_rp_q <= '0;
        end else if (rec_pop && rec_avail) begin
            rec_rp_q <= rec_rp_q + 1'b1;
        end
    end

    assign rp_order        = ring_order[rec_rp_q];
    assign rp_pc_rdata     = ring_pc_rdata[rec_rp_q];
    assign rp_pc_wdata     = ring_pc_wdata[rec_rp_q];
    assign rp_insn         = ring_insn[rec_rp_q];
    assign rp_trap         = ring_trap[rec_rp_q];
    assign rp_intr         = ring_intr[rec_rp_q];
    assign rp_mode         = ring_mode[rec_rp_q];
    assign rp_rd_addr      = ring_rd_addr[rec_rp_q];
    assign rp_rd_wdata     = ring_rd_wdata[rec_rp_q];
    assign rp_rs1_addr     = ring_rs1_addr[rec_rp_q];
    assign rp_rs1_rdata    = ring_rs1_rdata[rec_rp_q];
    assign rp_rs2_addr     = ring_rs2_addr[rec_rp_q];
    assign rp_rs2_rdata    = ring_rs2_rdata[rec_rp_q];
    assign rp_mem_addr     = ring_mem_addr[rec_rp_q];
    assign rp_mem_rmask    = ring_mem_rmask[rec_rp_q];
    assign rp_mem_wmask    = ring_mem_wmask[rec_rp_q];
    assign rp_mem_rdata    = ring_mem_rdata[rec_rp_q];
    assign rp_mem_wdata    = ring_mem_wdata[rec_rp_q];
    assign rp_cause        = ring_cause[rec_rp_q];
    assign rp_tval         = ring_tval[rec_rp_q];
    assign rp_current_priv = ring_current_priv[rec_rp_q];
    assign rp_mtvec        = ring_mtvec[rec_rp_q];
    assign rp_stvec        = ring_stvec[rec_rp_q];
    assign rp_mepc         = ring_mepc[rec_rp_q];
    assign rp_sepc         = ring_sepc[rec_rp_q];
    assign rp_mcause       = ring_mcause[rec_rp_q];
    assign rp_scause       = ring_scause[rec_rp_q];
    assign rp_mtval        = ring_mtval[rec_rp_q];
    assign rp_stval        = ring_stval[rec_rp_q];
    assign rp_satp         = ring_satp[rec_rp_q];
    assign rp_medeleg      = ring_medeleg[rec_rp_q];
    assign rp_mideleg      = ring_mideleg[rec_rp_q];
    assign rp_mie          = ring_mie[rec_rp_q];
    assign rp_mip          = ring_mip[rec_rp_q];
    assign rp_mscratch     = ring_mscratch[rec_rp_q];
    assign rp_sscratch     = ring_sscratch[rec_rp_q];
    assign rp_minstret     = ring_minstret[rec_rp_q];
    assign rp_pmpcfg0      = ring_pmpcfg0[rec_rp_q];
    assign rp_pmpaddr0     = ring_pmpaddr0[rec_rp_q];
    assign rp_pmpaddr1     = ring_pmpaddr1[rec_rp_q];
    assign rp_pmpaddr2     = ring_pmpaddr2[rec_rp_q];
    assign rp_pmpaddr3     = ring_pmpaddr3[rec_rp_q];
    assign rp_dcsr         = ring_dcsr[rec_rp_q];
    assign rp_dpc          = ring_dpc[rec_rp_q];
    assign rp_mstatus_mpp  = ring_mstatus_mpp[rec_rp_q];
    assign rp_mstatus_spp  = ring_mstatus_spp[rec_rp_q];
    assign rp_mstatus_tsr  = ring_mstatus_tsr[rec_rp_q];
    assign rp_mstatus_mie  = ring_mstatus_mie[rec_rp_q];
    assign rp_mstatus_sie  = ring_mstatus_sie[rec_rp_q];
    assign rp_mstatus_mprv = ring_mstatus_mprv[rec_rp_q];
    assign rp_mstatus_sum  = ring_mstatus_sum[rec_rp_q];
    assign rp_mstatus_mxr  = ring_mstatus_mxr[rec_rp_q];
    assign rp_mstatus_tvm  = ring_mstatus_tvm[rec_rp_q];

    // -------------------- bus-write log ring --------------------
    logic [$clog2(WR_DEPTH)-1:0] wr_wp_q = '0, wr_rp_q = '0;
    logic [31:0] wring_addr [0:WR_DEPTH-1];
    logic [7:0]  wring_sel  [0:WR_DEPTH-1];
    logic [63:0] wring_data [0:WR_DEPTH-1];

    assign wr_avail = (wr_wp_q != wr_rp_q);

    always_ff @(posedge clk_push) begin
        if (rst) begin
            wr_wp_q <= '0;
        end else if (wr_valid_i) begin
            wring_addr[wr_wp_q] <= wr_addr_i;
            wring_sel[wr_wp_q]  <= wr_sel_i;
            wring_data[wr_wp_q] <= wr_data_i;
            wr_wp_q <= wr_wp_q + 1'b1;
        end
    end
    always_ff @(posedge clk_pop) begin
        if (rst) begin
            wr_rp_q <= '0;
        end else if (wr_pop && wr_avail) begin
            wr_rp_q <= wr_rp_q + 1'b1;
        end
    end
    assign wrp_addr = wring_addr[wr_rp_q];
    assign wrp_sel  = wring_sel[wr_rp_q];
    assign wrp_data = wring_data[wr_rp_q];

    // -------------------- mmio-read log ring --------------------
    logic [$clog2(RD_DEPTH)-1:0] rd_wp_q = '0, rd_rp_q = '0;
    logic [31:0] rdring_addr [0:RD_DEPTH-1];
    logic [63:0] rdring_data [0:RD_DEPTH-1];

    assign rd_avail = (rd_wp_q != rd_rp_q);

    always_ff @(posedge clk_push) begin
        if (rst) begin
            rd_wp_q <= '0;
        end else if (rd_valid_i) begin
            rdring_addr[rd_wp_q] <= rd_addr_i;
            rdring_data[rd_wp_q] <= rd_data_i;
            rd_wp_q <= rd_wp_q + 1'b1;
        end
    end
    always_ff @(posedge clk_pop) begin
        if (rst) begin
            rd_rp_q <= '0;
        end else if (rd_pop && rd_avail) begin
            rd_rp_q <= rd_rp_q + 1'b1;
        end
    end
    assign rdp_addr = rdring_addr[rd_rp_q];
    assign rdp_data = rdring_data[rd_rp_q];

    // -------------------- debug-event counter --------------------
    // No payload beyond "one happened" -- rvfi_any_debug_entry carries no
    // extra data of its own to log. Two independent monotonic counters
    // (push-side increments, pop-side increments) instead of one
    // incremented-and-decremented register, for the same single-driver-
    // per-clock-domain reason as the rings above.
    logic [31:0] dbg_push_total_q = '0, dbg_pop_total_q = '0;
    assign dbg_avail = (dbg_push_total_q != dbg_pop_total_q);
    always_ff @(posedge clk_push) begin
        if (rst) begin
            dbg_push_total_q <= '0;
        end else if (rvfi_any_debug_entry) begin
            dbg_push_total_q <= dbg_push_total_q + 1'b1;
        end
    end
    always_ff @(posedge clk_pop) begin
        if (rst) begin
            dbg_pop_total_q <= '0;
        end else if (dbg_pop && dbg_avail) begin
            dbg_pop_total_q <= dbg_pop_total_q + 1'b1;
        end
    end
endmodule
