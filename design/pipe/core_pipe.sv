// SPDX-License-Identifier: MIT

`include "defaults/defaults.sv"

/*
 * core_pipe -- the pipelined core (pipelining plan, P4 onward).
 *
 * Port list is core.sv's exactly, including ANSI defaults and the
 * RISCV_FORMAL-only RVFI block, so it drops in anywhere `core` is
 * instantiated by name: compile with -DQV_PIPE_AS_CORE and this module
 * is named `core`, the same scheme ref_core.sv uses with QV_REF_AS_CORE.
 * Unlike ref_core.sv it reuses the same physical leaf modules core.sv
 * does (decoder/alu/register_file/csr_file), so no macro renaming is
 * needed.
 *
 *   F  qv_fetch    pc generation, Wishbone fetch master, fetch buffer
 *   A  qv_align    dword -> up to two fe_instr_t
 *      qv_fifo     instruction queue
 *   D  qv_decode   decoder.sv + uop builder
 *   I  qv_issue    operand resolution, producer table, ROB allocation
 *   X  qv_exu_alu  alu.sv
 *      qv_exu_div  divider.sv, one divide at a time
 *   C  qv_commit   in-order retirement, regfile0 write, RVFI
 *      qv_dbg      Debug Mode state (halted, single-stepping)
 *
 * regfile0 and csr_file0 live here at top level (regfile0 is written
 * only at commit, so it always holds architectural state), so their
 * hierarchical paths match core.sv's. The compatibility signals tests
 * reach hierarchically (dut.commit_now, dut.core0.trap_taken, ...) are
 * declared here at top-level scope too, including ones testbench/
 * rvfi_tracer.sv references unconditionally (route_to_s, trap_val).
 *
 * Implemented so far: every single-cycle integer ALU instruction --
 * RV64I register/immediate ops including the *W forms, LUI, AUIPC, and
 * MUL/MULH/MULHSU/MULHU/MULW -- DIV/DIVU/REM/REMU and the W forms (one at
 * a time, on the divider), conditional branches, JAL, JALR,
 * loads and stores (performed one at a time, at the ROB head), FENCE,
 * FENCE.I, LR/SC and the nine AMOs (.W and .D, also at the head, with the
 * bus locked across an AMO's read and write), the six Zicsr instructions,
 * ECALL, EBREAK, MRET, SRET, WFI (a no-op) and SFENCE.VMA (it serializes and
 * empties the TLBs), with the three privilege levels, trap
 * delegation and the privilege rules (CSR access, TSR, TVM), and RVC:
 * compressed instructions on any 2-byte boundary, including 32-bit ones
 * that straddle two fetched dwords. Everything else decodes as an
 * illegal-instruction trap. Interrupts (MEI, MTI, SEI) are taken as core.sv
 * takes them, only in the cycle after a retirement, and the PMP is
 * checked on the fetch (in decode) and on the data accesses (in the LSU).
 * Debug: halt requests, resume and single steps, taken at the same sample
 * point as interrupts, and the Debug Module's Access Register path, muxed
 * around regfile0 and csr_file0 as core.sv does it; EBREAK (dcsr.ebreak*)
 * and the two execute triggers, matched in decode and acted on at the ROB
 * head; the Program Buffer, whose words qv_dbg feeds into the instruction
 * queue one at a time (see there). Sv39: data accesses and instruction fetches
 * are translated, each side with its own TLB (qv_xlate) and one walker (qv_ptw)
 * that shares the memory port with the LSU; a fetch translates in a phase of its
 * own request (qv_fetch) and carries the physical page to decode's PMP check.
 *
 * Redirects: commit's (a trap, xRET, serialize, or a retiring
 * mispredicted branch or jump) kill everything in flight -- the same
 * signal is every stage's flush. Align's (a statically predicted-taken
 * branch or jump) only restart fetch; commit's wins a tie.
 */
// Testbenches instantiate `core` with no parameter overrides, so the
// debug knobs can also be set from the command line.
`ifndef QV_PIPE_SERIALIZE
`define QV_PIPE_SERIALIZE 1'b0
`endif
`ifndef QV_PIPE_BYPASS_EN
`define QV_PIPE_BYPASS_EN 1'b1
`endif
// QV_FORMAL_SMALL: a smaller ROB and IQ, to keep riscv-formal's models small
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_ROB_DEPTH 4
`define QV_PIPE_IQ_DEPTH  2
`else
`define QV_PIPE_ROB_DEPTH qv_pkg::QV_ROB_DEPTH
`define QV_PIPE_IQ_DEPTH  4
`endif

// QV_FORMAL_NO_SV39: no translation at all (no walker, no TLB): the Bare paths only. The riscv-formal sweep that
// pins satp to Bare uses it, so its models do not grow by the TLBs and the walker.
`ifdef QV_FORMAL_NO_SV39
`define QV_PIPE_SV39_EN 1'b0
`else
`define QV_PIPE_SV39_EN 1'b1
`endif

// under QV_PIPE_AS_CORE the module name deliberately differs from the file's
/* verilator lint_off DECLFILENAME */
`ifdef QV_PIPE_AS_CORE
module core
`else
module core_pipe
`endif
/* verilator lint_on DECLFILENAME */
#(
    parameter bit SERIALIZE = `QV_PIPE_SERIALIZE,
    parameter bit BYPASS_EN = `QV_PIPE_BYPASS_EN,
    parameter int ROB_DEPTH = `QV_PIPE_ROB_DEPTH,   // power of 2, <= qv_pkg::QV_ROB_DEPTH
    parameter int IQ_DEPTH  = `QV_PIPE_IQ_DEPTH,    // power of 2, >= 2
    parameter bit SV39_EN   = `QV_PIPE_SV39_EN      // address translation present
) (
    input logic clk,
    input logic rst,

    output logic [31:0] wb_fetch_addr_o,
    output logic        wb_fetch_cyc_o,
    output logic        wb_fetch_stb_o,
    input  logic [63:0] wb_fetch_dat_i,
    input  logic        wb_fetch_ack_i,
    input  logic        wb_fetch_err_i,

    output logic [31:0] wb_mem_addr_o,
    output logic [63:0] wb_mem_dat_o,
    input  logic [63:0] wb_mem_dat_i,
    output logic [7:0]  wb_mem_sel_o,
    output logic        wb_mem_we_o,
    output logic        wb_mem_cyc_o,
    output logic        wb_mem_stb_o,
    input  logic        wb_mem_ack_i,
    input  logic        wb_mem_err_i,
    output logic        wb_mem_lock_o,
    output logic        icache_flush_o,
    input  logic         i_mtip = 1'b0,
    input  logic         i_meip = 1'b0,
    input  logic         i_seip = 1'b0,

    input  logic        i_debug_halt_req = 1'b0,
    input  logic        i_debug_resume_req = 1'b0,
    output logic        o_debug_mode,

    input  logic         i_dm_csr_we = 1'b0,
    input  logic [11:0]  i_dm_csr_addr = 12'b0,
    input  logic [63:0]  i_dm_csr_wdata = 64'b0,
    output logic [63:0]  o_dm_csr_rdata,
    input  logic         i_dm_gpr_we = 1'b0,
    input  logic [4:0]   i_dm_gpr_sel = 5'b0,
    input  logic [63:0]  i_dm_gpr_wdata = 64'b0,
    output logic [63:0]  o_dm_gpr_rdata,

    input  logic         i_progbuf_start = 1'b0,
    output logic [3:0]   o_progbuf_pc,
    input  logic [31:0]  i_progbuf_data = 32'b0,
    output logic         o_progbuf_done,
    output logic         o_progbuf_abort

`ifdef RISCV_FORMAL
    ,
    output logic        rvfi_valid,
    output logic [63:0] rvfi_order,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic        rvfi_halt,
    output logic        rvfi_intr,
    output logic [1:0]  rvfi_mode,
    output logic [1:0]  rvfi_ixl,
    output logic [4:0]  rvfi_rs1_addr,
    output logic [4:0]  rvfi_rs2_addr,
    output logic [63:0] rvfi_rs1_rdata,
    output logic [63:0] rvfi_rs2_rdata,
    output logic [4:0]  rvfi_rd_addr,
    output logic [63:0] rvfi_rd_wdata,
    output logic [63:0] rvfi_pc_rdata,
    output logic [63:0] rvfi_pc_wdata,
    output logic [63:0] rvfi_mem_addr,
    output logic [7:0]  rvfi_mem_rmask,
    output logic [7:0]  rvfi_mem_wmask,
    output logic [63:0] rvfi_mem_rdata,
    output logic [63:0] rvfi_mem_wdata,
    output logic [63:0] rvfi_csr_mepc_rmask,
    output logic [63:0] rvfi_csr_mepc_wmask,
    output logic [63:0] rvfi_csr_mepc_rdata,
    output logic [63:0] rvfi_csr_mepc_wdata,
    output logic [63:0] rvfi_csr_mcause_rmask,
    output logic [63:0] rvfi_csr_mcause_wmask,
    output logic [63:0] rvfi_csr_mcause_rdata,
    output logic [63:0] rvfi_csr_mcause_wdata,
    output logic [63:0] rvfi_csr_sepc_rmask,
    output logic [63:0] rvfi_csr_sepc_wmask,
    output logic [63:0] rvfi_csr_sepc_rdata,
    output logic [63:0] rvfi_csr_sepc_wdata,
    output logic [63:0] rvfi_csr_scause_rmask,
    output logic [63:0] rvfi_csr_scause_wmask,
    output logic [63:0] rvfi_csr_scause_rdata,
    output logic [63:0] rvfi_csr_scause_wdata,
    output logic [63:0] rvfi_csr_pmpcfg0_rmask,
    output logic [63:0] rvfi_csr_pmpcfg0_wmask,
    output logic [63:0] rvfi_csr_pmpcfg0_rdata,
    output logic [63:0] rvfi_csr_pmpcfg0_wdata,
    output logic [63:0] rvfi_csr_pmpaddr0_rmask,
    output logic [63:0] rvfi_csr_pmpaddr0_wmask,
    output logic [63:0] rvfi_csr_pmpaddr0_rdata,
    output logic [63:0] rvfi_csr_pmpaddr0_wdata,
    output logic [63:0] rvfi_csr_medeleg_rmask,
    output logic [63:0] rvfi_csr_medeleg_wmask,
    output logic [63:0] rvfi_csr_medeleg_rdata,
    output logic [63:0] rvfi_csr_medeleg_wdata,
    output logic [63:0] rvfi_csr_satp_rmask,
    output logic [63:0] rvfi_csr_satp_wmask,
    output logic [63:0] rvfi_csr_satp_rdata,
    output logic [63:0] rvfi_csr_satp_wdata,
    output logic rvfi_any_trap_taken,
    output logic rvfi_any_debug_entry
`endif
);
    import qv_pkg::*;

    localparam logic [63:0] RESET_PC = 64'h0;   // core.sv's own reset pc

    // ---------------- csr_file0's exports ----------------
    // declared up here: decode, commit and the fetch path all read some of them
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] stvec_w, sepc_w, medeleg_w, mip_w, mie_w, mideleg_w;
    logic [63:0] dcsr_o, dpc_o, tdata1_0_w, tdata1_1_w, tdata2_0_w, tdata2_1_w;
    logic [63:0] pmpcfg0_w, pmpaddr0_w, pmpaddr1_w, pmpaddr2_w, pmpaddr3_w, satp_w;
    logic [1:0]  mstatus_mpp_w;
    logic        mstatus_spp_w, mstatus_tsr_w, mstatus_mie_w, mstatus_sie_w;
    logic        mstatus_mprv_w, mstatus_sum_w, mstatus_mxr_w, mstatus_tvm_w;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [1:0]  priv;                       // the privilege commit keeps
    logic        c_trap_to_s, c_sret_taken;

    // Sv39 is on when satp says so (and the build has translation at all)
    wire         satp_on = SV39_EN && (satp_w[63:60] == 4'd8);

    // ---------------- Debug Mode ----------------
    // commit decides when the hart halts, qv_dbg keeps the flags
    logic        dbg_entry, dbg_halt_entry, dbg_ebreak_entry, dbg_trigger_entry;
    logic        dbg_resume, dbg_in_debug, dbg_stepping, dm_access_active, pb_active, pb_commit, pb_done, pb_abort;
    logic        inj_valid;
    logic [3:0]  pb_idx;
    logic [63:0] arch_pc;                    // commit's architectural pc: the next instruction to retire
    logic [2:0]  dbg_cause;

    // ---------------- redirects ----------------
    logic        redirect_valid, fe_redirect_valid;
    logic [63:0] redirect_pc, fe_redirect_pc;
    wire         flush = redirect_valid;
    wire         fetch_redirect    = redirect_valid || fe_redirect_valid;
    wire [63:0]  fetch_redirect_pc = redirect_valid ? redirect_pc : fe_redirect_pc;

    // ---------------- F: fetch ----------------
    logic        fb_valid, fb_err, fb_pop, fb_xl;
    logic [63:0] fb_pc, fb_data;
    logic [3:0]  fb_cause;
    logic [43:0] fb_pg;
    logic        fetch_hold, fetch_idle;
    logic        commit_fetch_hold;          // FENCE.I, from commit
    // fetch is held for a FENCE.I and for as long as the hart is halted (including the entry cycle itself)
    assign fetch_hold = commit_fetch_hold || dbg_in_debug || dbg_entry;

    // Instruction fetch is translated below M (the raw privilege: MPRV never applies to fetch) when satp says
    // Sv39, except in a Program Buffer run. Fetch samples this when it issues a request.
    wire         fetch_xl_on = satp_on && !pb_active && (priv != 2'b11);
    logic        f_xl_req, f_xl_cancel, f_xl_done, f_xl_pf, f_xl_af;
    logic [63:0] f_xl_va;
    logic [43:0] f_xl_ppn;
    logic        fetch_redirect_ctx;         // below, once commit's outputs are declared

    qv_fetch #(.RESET_PC(RESET_PC)) fetch0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wb_fetch_addr_o), .wb_fetch_cyc_o(wb_fetch_cyc_o), .wb_fetch_stb_o(wb_fetch_stb_o),
        .wb_fetch_dat_i(wb_fetch_dat_i), .wb_fetch_ack_i(wb_fetch_ack_i), .wb_fetch_err_i(wb_fetch_err_i),
        .i_redirect_valid(fetch_redirect), .i_redirect_pc(fetch_redirect_pc), .i_redirect_ctx(fetch_redirect_ctx),
        .i_hold(fetch_hold), .o_idle(fetch_idle),
        .i_xl_on(fetch_xl_on),
        .o_xl_req(f_xl_req), .o_xl_va(f_xl_va), .o_xl_cancel(f_xl_cancel),
        .i_xl_done(f_xl_done), .i_xl_pf(f_xl_pf), .i_xl_af(f_xl_af), .i_xl_ppn(f_xl_ppn),
        .o_buf_valid(fb_valid), .o_buf_pc(fb_pc), .o_buf_data(fb_data), .o_buf_err(fb_err),
        .o_buf_cause(fb_cause), .o_buf_xl(fb_xl), .o_buf_pg(fb_pg),
        .i_buf_pop(fb_pop)
    );

    // ---------------- A: align -> instruction queue ----------------
    localparam int FE_W = $bits(fe_instr_t);

    logic         p0_valid, p1_valid, iq_push_ready;
    fe_instr_t    p0_data, p1_data;
    logic         a0_valid, a1_valid;
    fe_instr_t    a0_data, a1_data;
    fe_instr_t    inj_data;
    logic         iq_valid, iq_pop;
    logic [FE_W-1:0] iq_bits;
    fe_instr_t    iq_head;
    assign iq_head = iq_bits;

    qv_align align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(fb_valid), .i_buf_pc(fb_pc), .i_buf_data(fb_data), .i_buf_err(fb_err),
        .i_buf_cause(fb_cause), .i_buf_xl(fb_xl), .i_buf_pg(fb_pg),
        .o_buf_pop(fb_pop),
        .o_push0_valid(a0_valid), .o_push0_data(a0_data),
        .o_push1_valid(a1_valid), .o_push1_data(a1_data),
        .i_push_ready(iq_push_ready),
        .o_redirect_valid(fe_redirect_valid), .o_redirect_pc(fe_redirect_pc)
    );

    // While halted the instruction queue is fed by the Program Buffer injector (nothing comes from fetch then):
    // a 32-bit word at the architectural pc, no fault, no prediction.
    always_comb begin
        inj_data      = '0;
        inj_data.pc   = arch_pc;
        inj_data.raw  = i_progbuf_data;
    end
    assign p0_valid = dbg_in_debug ? inj_valid : a0_valid;
    assign p0_data  = dbg_in_debug ? inj_data  : a0_data;
    assign p1_valid = dbg_in_debug ? 1'b0      : a1_valid;
    assign p1_data  = a1_data;

    qv_fifo #(.WIDTH(FE_W), .DEPTH(IQ_DEPTH)) iq0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push0_valid(p0_valid), .i_push0_data(p0_data),
        .i_push1_valid(p1_valid), .i_push1_data(p1_data),
        .o_push_ready(iq_push_ready),
        .o_head_valid(iq_valid), .o_head_data(iq_bits),
        .i_pop(iq_pop)
    );

    // ---------------- D: decode ----------------
    logic uop_valid, issue_fire;
    uop_t uop;

    qv_decode decode0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_priv(priv), .i_tsr(mstatus_tsr_w), .i_tvm(mstatus_tvm_w), .i_in_debug(dbg_in_debug), .i_pb_active(pb_active),
        .i_tdata1_0(tdata1_0_w), .i_tdata2_0(tdata2_0_w), .i_tdata1_1(tdata1_1_w), .i_tdata2_1(tdata2_1_w),
        .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
        .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
        .i_iq_valid(iq_valid), .i_iq_data(iq_head), .o_iq_pop(iq_pop),
        .o_valid(uop_valid), .o_uop(uop), .i_issue_ready(issue_fire)
    );

    // ---------------- I: issue ----------------
    logic [4:0]              rs1_sel, rs2_sel;
    logic [63:0]             rs1_data, rs2_data;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic [63:0]             alloc_pc, alloc_next_pc;
    logic [31:0]             alloc_raw;
    logic [4:0]              alloc_rd;
    rvfi_shadow_t            alloc_shadow;
    rob_ctrl_t               alloc_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, l1_tag, l2_tag;
    logic                    l1_complete, l2_complete;
    logic [63:0]             l1_value, l2_value;
    wb_t                     wb_bus;
    fu_req_t                 alu_req, bru_req, lsu_req, div_req;
    logic                    lsu_free, div_free;
    logic                    res_valid;      // the LR/SC reservation, kept by commit
    logic [63:0]             res_addr;
    logic                    c_valid, c_rd_wen;
    logic [4:0]              c_rd;
    logic [QV_ROB_TAG_W-1:0] c_tag;

    qv_issue #(.SERIALIZE(SERIALIZE), .BYPASS_EN(BYPASS_EN)) issue0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_uop_valid(uop_valid), .i_uop(uop), .o_issue(issue_fire),
        .o_rs1_sel(rs1_sel), .o_rs2_sel(rs2_sel), .i_rs1_data(rs1_data), .i_rs2_data(rs2_data),
        .o_alloc_valid(alloc_valid), .o_alloc_pc(alloc_pc), .o_alloc_raw(alloc_raw),
        .o_alloc_rd(alloc_rd), .o_alloc_rd_wen(alloc_rd_wen), .o_alloc_next_pc(alloc_next_pc),
        .o_alloc_shadow(alloc_shadow), .o_alloc_ctrl(alloc_ctrl),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(alloc_ready),
        .i_rob_empty(rob_empty),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l1_complete), .i_lookup1_value(l1_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l2_complete), .i_lookup2_value(l2_value),
        .i_wb(wb_bus), .o_alu_req(alu_req), .o_bru_req(bru_req),
        .o_lsu_req(lsu_req), .i_lsu_free(lsu_free),
        .o_div_req(div_req), .i_div_free(div_free),
        .i_commit_valid(c_valid), .i_commit_rd(c_rd), .i_commit_rd_wen(c_rd_wen), .i_commit_tag(c_tag)
    );

    // slow-unit outputs, declared ahead of the ROB and commit, which take them
    wb_t      lsu_wb, div_wb;
    lsu_res_t lsu_res;
    logic     c_sfence;                    // commit: an SFENCE.VMA retires, empty the TLBs

    // ---------------- ROB ----------------
    logic                    head_valid, commit_pop;
    rob_entry_t              head_entry;
    logic [QV_ROB_TAG_W-1:0] head_tag;
    rvfi_shadow_t            head_shadow;
    rob_ctrl_t               head_ctrl;

    qv_rob #(.ROB_DEPTH(ROB_DEPTH)) rob0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_alloc_valid(alloc_valid), .i_alloc_pc(alloc_pc), .i_alloc_raw(alloc_raw),
        .i_alloc_rd(alloc_rd), .i_alloc_rd_wen(alloc_rd_wen), .i_alloc_next_pc(alloc_next_pc),
        .i_alloc_shadow(alloc_shadow), .i_alloc_ctrl(alloc_ctrl),
        .o_alloc_tag(alloc_tag), .o_alloc_ready(alloc_ready),
        .o_empty(rob_empty), .i_wb(wb_bus), .i_wb2(lsu_wb), .i_wb3(div_wb),
        .i_lookup1_tag(l1_tag), .o_lookup1_complete(l1_complete), .o_lookup1_value(l1_value),
        .i_lookup2_tag(l2_tag), .o_lookup2_complete(l2_complete), .o_lookup2_value(l2_value),
        .o_head_valid(head_valid), .o_head_entry(head_entry), .o_head_tag(head_tag),
        .o_head_shadow(head_shadow), .o_head_ctrl(head_ctrl), .i_commit_pop(commit_pop)
    );

    // ---------------- X: ALU, BRU -> writeback bus ----------------
    wb_t alu_wb, bru_wb;
    qv_exu_alu exu_alu0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(alu_req), .o_wb(alu_wb));
    qv_exu_bru exu_bru0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(bru_req), .o_wb(bru_wb));

    // Both units take one cycle and issue sends at most one uop per
    // cycle, so at most one result is ever valid. The multi-cycle units
    // (LSU, divider) each have a writeback port of their own into the ROB
    // instead, so they never contend for this one.
    assign wb_bus = bru_wb.valid ? bru_wb : alu_wb;

    // ---------------- X: divider -> slow writeback port ----------------
    // Like the LSU, no bypass: a dependent reads the ROB the next cycle.
    // Every flush kills a divide in flight.
    qv_exu_div exu_div0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(div_req), .o_free(div_free), .o_wb(div_wb));

    // ---------------- X: LSU -> slow writeback port ----------------
    // read only by the interrupt check below
    /* verilator lint_off UNUSEDSIGNAL */
    logic lsu_head_started;
    /* verilator lint_on UNUSEDSIGNAL */

    // The LSU and the page-table walker share the memory port. The walker owns it while a PTE read of its is
    // in flight (ptw_beat); the LSU holds the walker off while it has an access started or ready to start
    // (lsu_bus_busy), so the two never drive the port in the same cycle, and the port stays a single master
    // for wb_arbiter2 and the caches (cyc and stb drop in the response cycle for both).
    logic [31:0] lsu_addr;
    logic [63:0] lsu_dat;
    logic [7:0]  lsu_sel;
    logic        lsu_we, lsu_cyc, lsu_stb, lsu_lock;
    logic [31:0] ptw_addr;
    logic        ptw_cyc, ptw_beat, lsu_bus_busy;
    assign wb_mem_addr_o = ptw_beat ? ptw_addr : lsu_addr;
    assign wb_mem_dat_o  = lsu_dat;
    assign wb_mem_sel_o  = ptw_beat ? 8'hFF : lsu_sel;
    assign wb_mem_we_o   = ptw_beat ? 1'b0 : lsu_we;
    assign wb_mem_cyc_o  = ptw_beat ? ptw_cyc : lsu_cyc;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_lock_o = ptw_beat ? 1'b0 : lsu_lock;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        lsu_stb_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign lsu_stb_unused = lsu_stb;

    // translation of the data accesses: the LSU's request, answered by its own qv_xlate (a TLB and the check
    // of a hit), which asks the one walker on a miss
    logic        x_req, x_wr, x_active, x_cancel, x_done, x_pf, x_af;
    logic [63:0] x_va;
    logic [1:0]  x_priv;
    logic [43:0] x_ppn;

    // No bypass from the LSU's writeback: a dependent reads the ROB the next cycle, which
    // keeps wb_mem_dat_i out of issue's combinational paths.
    qv_lsu lsu0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(lsu_req), .o_free(lsu_free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_priv(priv), .i_mprv(mstatus_mprv_w), .i_mpp(mstatus_mpp_w), .i_pmp_bypass(pb_active),
        .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
        .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
        .wb_mem_addr_o(lsu_addr), .wb_mem_dat_o(lsu_dat), .wb_mem_sel_o(lsu_sel),
        .wb_mem_we_o(lsu_we), .wb_mem_cyc_o(lsu_cyc), .wb_mem_stb_o(lsu_stb),
        .wb_mem_lock_o(lsu_lock),
        .wb_mem_dat_i(wb_mem_dat_i), .wb_mem_ack_i(wb_mem_ack_i), .wb_mem_err_i(wb_mem_err_i),
        .o_wb(lsu_wb), .o_res(lsu_res),
        .o_head_started(lsu_head_started),
        .i_satp_on(satp_on),
        .o_xl_req(x_req), .o_xl_va(x_va), .o_xl_wr(x_wr), .o_xl_active(x_active), .o_xl_priv(x_priv),
        .o_xl_cancel(x_cancel),
        .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn),
        .i_ptw_beat(ptw_beat), .o_bus_busy(lsu_bus_busy)
    );

    generate
        if (SV39_EN) begin : g_sv39
            wire         w_d_req, w_d_cancel, w_d_done;
            wire         w_f_req, w_f_cancel, w_f_done;
            wire         w_ok, w_pf, w_af, w_r, w_w, w_x, w_u, w_d;
            wire  [26:0] w_vpn;
            wire  [1:0]  w_level;
            wire  [43:0] w_ppn;

            qv_ptw ptw0 (
                .clk(clk), .rst(rst),
                .o_bus_addr(ptw_addr), .o_bus_cyc(ptw_cyc),
                .i_bus_dat(wb_mem_dat_i), .i_bus_ack(wb_mem_ack_i), .i_bus_err(wb_mem_err_i),
                .i_lsu_busy(lsu_bus_busy), .o_beat(ptw_beat),
                .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
                .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
                .i_d_req(w_d_req), .i_d_va(x_va), .i_d_wr(x_wr), .i_d_priv(x_priv),
                .i_d_sum(mstatus_sum_w), .i_d_mxr(mstatus_mxr_w), .i_d_root(satp_w[43:0]),
                .i_d_cancel(w_d_cancel), .o_d_done(w_d_done),
                .i_f_req(w_f_req), .i_f_va(f_xl_va), .i_f_priv(priv), .i_f_root(satp_w[43:0]),
                .i_f_cancel(w_f_cancel), .o_f_done(w_f_done),
                .o_res_ok(w_ok), .o_res_pf(w_pf), .o_res_af(w_af), .o_res_vpn(w_vpn), .o_res_level(w_level),
                .o_res_ppn(w_ppn), .o_res_r(w_r), .o_res_w(w_w), .o_res_x(w_x), .o_res_u(w_u), .o_res_d(w_d)
            );

            qv_xlate #(.TLB_ENTRIES(4)) xlate_d (
                .clk(clk), .rst(rst),
                .i_req(x_req), .i_va(x_va), .i_is_mem(1'b1), .i_wr(x_wr), .i_active(x_active), .i_priv(x_priv),
                .i_sum(mstatus_sum_w), .i_mxr(mstatus_mxr_w), .i_cancel(x_cancel), .i_flush_tlb(c_sfence),
                .o_done(x_done), .o_pf(x_pf), .o_af(x_af), .o_ppn(x_ppn),
                .o_w_req(w_d_req), .o_w_cancel(w_d_cancel),
                .i_w_done(w_d_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn),
                .i_w_level(w_level), .i_w_ppn(w_ppn), .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u),
                .i_w_d(w_d)
            );

            // the instruction side: its own TLB, asked by fetch; no SUM or MXR for an execute
            qv_xlate #(.TLB_ENTRIES(4)) xlate_f (
                .clk(clk), .rst(rst),
                .i_req(f_xl_req), .i_va(f_xl_va), .i_is_mem(1'b0), .i_wr(1'b0), .i_active(fetch_xl_on), .i_priv(priv),
                .i_sum(1'b0), .i_mxr(1'b0), .i_cancel(f_xl_cancel), .i_flush_tlb(c_sfence),
                .o_done(f_xl_done), .o_pf(f_xl_pf), .o_af(f_xl_af), .o_ppn(f_xl_ppn),
                .o_w_req(w_f_req), .o_w_cancel(w_f_cancel),
                .i_w_done(w_f_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn),
                .i_w_level(w_level), .i_w_ppn(w_ppn), .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u),
                .i_w_d(w_d)
            );
        end else begin : g_nosv39
            // Bare only: neither side ever asks (satp_on is tied low), and no walker means no beat
            assign x_done   = 1'b1;
            assign x_pf     = 1'b0;
            assign x_af     = 1'b0;
            assign x_ppn    = x_va[55:12];
            assign f_xl_done = 1'b1;
            assign f_xl_pf   = 1'b0;
            assign f_xl_af   = 1'b0;
            assign f_xl_ppn  = f_xl_va[55:12];
            assign ptw_addr = 32'b0;
            assign ptw_cyc  = 1'b0;
            assign ptw_beat = 1'b0;
        end
    endgenerate

    // ---------------- C: commit ----------------
    logic        rf_we;
    logic [4:0]  rf_sel;
    logic [63:0] rf_data;
    logic        commit_now_w;
    logic [63:0] retire_next_pc;
    logic [4:0]  c_rs1_addr, c_rs2_addr;
    logic [11:0] c_csr_addr;
    logic [63:0] c_csr_wdata, c_trap_cause, c_trap_val;
    logic        c_csr_we, c_instr_retired, c_trap_taken, c_mret_taken, c_irq_taken;
    // read only by the RISCV_FORMAL port block
    /* verilator lint_off UNUSEDSIGNAL */
    logic        c_rvfi_trap;
    logic [63:0] c_order, c_rs1_rdata, c_rs2_rdata, c_rd_wdata, c_pc_rdata, c_pc_wdata;
    logic [31:0] c_insn;
    logic        c_intr;
    logic [4:0]  c_rd_addr;
    logic [63:0] c_mem_addr, c_mem_rdata, c_mem_wdata;
    logic [7:0]  c_mem_rmask, c_mem_wmask;
    /* verilator lint_on UNUSEDSIGNAL */

    // declared ahead of csr_file0, which drives them
    logic [63:0] csr_rdata, mtvec_w, mepc_w;

    // A redirect that changes the translation context (commit's o_redirect_ctx) makes fetch wait a cycle before
    // it issues from the target -- but only where translation is or is about to be on: with satp Bare no
    // privilege or TLB change matters to fetch (the PMP is checked in decode), and the one thing that can turn
    // translation on is a write to satp.
    logic        c_redirect_ctx;
    assign fetch_redirect_ctx = redirect_valid && c_redirect_ctx && SV39_EN
                                && (satp_on || (head_ctrl.cls == QV_FU_CSR && head_ctrl.csr_addr == 12'h180));

    qv_commit #(.RESET_PC(RESET_PC)) commit0 (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(head_entry), .i_head_tag(head_tag),
        .i_head_shadow(head_shadow), .i_head_ctrl(head_ctrl), .i_lsu_res(lsu_res), .o_commit_pop(commit_pop),
        .o_res_valid(res_valid), .o_res_addr(res_addr),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_csr_addr(c_csr_addr), .i_csr_rdata(csr_rdata), .o_csr_we(c_csr_we), .o_csr_wdata(c_csr_wdata),
        .o_instr_retired(c_instr_retired), .o_trap_taken(c_trap_taken), .o_trap_cause(c_trap_cause),
        .o_trap_val(c_trap_val), .o_mret_taken(c_mret_taken), .i_mtvec(mtvec_w), .i_mepc(mepc_w),
        .o_sret_taken(c_sret_taken), .o_trap_to_s(c_trap_to_s), .o_priv(priv),
        .i_stvec(stvec_w), .i_sepc(sepc_w), .i_medeleg(medeleg_w),
        .i_mstatus_mpp(mstatus_mpp_w), .i_mstatus_spp(mstatus_spp_w),
        .i_mip(mip_w), .i_mie(mie_w), .i_mideleg(mideleg_w),
        .i_mstatus_mie(mstatus_mie_w), .i_mstatus_sie(mstatus_sie_w), .o_irq_taken(c_irq_taken),
        .i_dbg_halt_req(i_debug_halt_req), .i_dbg_stepping(dbg_stepping), .i_dbg_in_debug(dbg_in_debug),
        .i_dbg_resume(dbg_resume), .i_dpc(dpc_o), .i_dcsr(dcsr_o),
        .o_dbg_entry(dbg_entry), .o_dbg_cause(dbg_cause), .o_dbg_halt_entry(dbg_halt_entry),
        .o_dbg_ebreak_entry(dbg_ebreak_entry), .o_dbg_trigger_entry(dbg_trigger_entry),
        .i_pb_active(pb_active), .o_pb_commit(pb_commit), .o_pb_done(pb_done), .o_pb_abort(pb_abort),
        .o_fetch_hold(commit_fetch_hold), .i_fetch_idle(fetch_idle), .o_icache_flush(icache_flush_o),
        .o_sfence(c_sfence),
        .o_commit_now(commit_now_w), .o_pc(arch_pc), .o_next_pc(retire_next_pc),
        .o_redirect_valid(redirect_valid), .o_redirect_pc(redirect_pc), .o_redirect_ctx(c_redirect_ctx),
        .o_rvfi_order(c_order), .o_rvfi_insn(c_insn), .o_rvfi_trap(c_rvfi_trap), .o_rvfi_intr(c_intr),
        .o_rvfi_rs1_addr(c_rs1_addr), .o_rvfi_rs2_addr(c_rs2_addr),
        .o_rvfi_rs1_rdata(c_rs1_rdata), .o_rvfi_rs2_rdata(c_rs2_rdata),
        .o_rvfi_rd_addr(c_rd_addr), .o_rvfi_rd_wdata(c_rd_wdata),
        .o_rvfi_pc_rdata(c_pc_rdata), .o_rvfi_pc_wdata(c_pc_wdata),
        .o_rvfi_mem_addr(c_mem_addr), .o_rvfi_mem_rmask(c_mem_rmask), .o_rvfi_mem_wmask(c_mem_wmask),
        .o_rvfi_mem_rdata(c_mem_rdata), .o_rvfi_mem_wdata(c_mem_wdata)
    );

    qv_dbg dbg0 (
        .clk(clk), .rst(rst),
        .i_entry(dbg_entry), .i_halt_entry(dbg_halt_entry),
        .i_resume_req(i_debug_resume_req), .i_dcsr_step(dcsr_o[2]),
        .i_progbuf_start(i_progbuf_start), .i_pb_commit(pb_commit), .i_pb_end(pb_done || pb_abort),
        .i_inject_ready(iq_push_ready),
        .o_in_debug(dbg_in_debug), .o_stepping(dbg_stepping), .o_resume(dbg_resume),
        .o_dm_access_active(dm_access_active), .o_progbuf_active(pb_active), .o_progbuf_pc(pb_idx),
        .o_inject_valid(inj_valid)
    );

    // ---------------- architectural state ----------------
    // The Debug Module's GPR access shares read port B and the write port outright, as in core.sv: while the
    // hart is halted (dm_access_active) nothing issues and nothing retires, so the two users are never live in
    // the same cycle. o_dm_gpr_rdata is the very same wire rs2_data, trusted by the Debug Module only then.
    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(rs1_sel), .o_read_gpr_A_data(rs1_data),
        .i_read_gpr_B_sel(dm_access_active ? i_dm_gpr_sel : rs2_sel), .o_read_gpr_B_data(rs2_data),
        .i_load_gpr(dm_access_active ? i_dm_gpr_we : rf_we),
        .i_load_gpr_sel(dm_access_active ? i_dm_gpr_sel : rf_sel),
        .i_load_gpr_data(dm_access_active ? i_dm_gpr_wdata : rf_data)
    );

`ifdef RISCV_FORMAL
    logic [63:0] mcause_w, scause_w, mepc_next_w, sepc_next_w, mcause_next_w, scause_next_w;
`endif

    csr_file csr_file0 (
        .i_clk(clk), .i_rst(rst),
        .i_csr_addr(dm_access_active ? i_dm_csr_addr : c_csr_addr), .o_csr_rdata(csr_rdata),
        .i_csr_we(dm_access_active ? i_dm_csr_we : c_csr_we),
        .i_csr_wdata(dm_access_active ? i_dm_csr_wdata : c_csr_wdata),
        .i_instr_retired(c_instr_retired),
        .i_current_priv(priv),
        .i_mtip(i_mtip), .i_meip(i_meip), .i_seip(i_seip),
        .i_trap_taken(c_trap_taken), .i_trap_cause(c_trap_cause), .i_trap_val(c_trap_val),
        .i_trap_pc(arch_pc),
        .i_trap_to_s(c_trap_to_s), .i_mret_taken(c_mret_taken), .i_sret_taken(c_sret_taken),
        .i_debug_entry(dbg_entry), .i_debug_cause(dbg_cause),
        .o_mtvec(mtvec_w), .o_stvec(stvec_w), .o_mepc(mepc_w), .o_sepc(sepc_w),
        .o_medeleg(medeleg_w),
        .o_mstatus_mpp(mstatus_mpp_w), .o_mstatus_spp(mstatus_spp_w), .o_mstatus_tsr(mstatus_tsr_w),
        .o_mip(mip_w), .o_mie(mie_w), .o_mideleg(mideleg_w),
        .o_mstatus_mie(mstatus_mie_w), .o_mstatus_sie(mstatus_sie_w),
        .o_dcsr(dcsr_o), .o_dpc(dpc_o),
        .o_tdata1_0(tdata1_0_w), .o_tdata1_1(tdata1_1_w),
        .o_tdata2_0(tdata2_0_w), .o_tdata2_1(tdata2_1_w),
        .o_pmpcfg0(pmpcfg0_w), .o_pmpaddr0(pmpaddr0_w), .o_pmpaddr1(pmpaddr1_w),
        .o_pmpaddr2(pmpaddr2_w), .o_pmpaddr3(pmpaddr3_w), .o_mstatus_mprv(mstatus_mprv_w),
        .o_satp(satp_w), .o_mstatus_sum(mstatus_sum_w), .o_mstatus_mxr(mstatus_mxr_w),
        .o_mstatus_tvm(mstatus_tvm_w)
`ifdef RISCV_FORMAL
        , .o_mcause(mcause_w), .o_scause(scause_w),
        .o_mepc_next(mepc_next_w), .o_sepc_next(sepc_next_w),
        .o_mcause_next(mcause_next_w), .o_scause_next(scause_next_w)
`endif
    );

    // ---------------- compatibility layer ----------------
    // Names match core.sv's own internal signals, for tests that reach
    // them hierarchically. Live ones first, then the not-yet-implemented
    // ones at their "never happens" value.
    /* verilator lint_off UNUSEDSIGNAL */
    wire        commit_now     = commit_now_w;
    wire [63:0] pc             = arch_pc;
    wire [63:0] next_pc        = retire_next_pc;
    wire [4:0]  read_gpr_A_sel = c_rs1_addr;
    wire [4:0]  read_gpr_B_sel = c_rs2_addr;
    wire [1:0]  current_priv   = priv;
    wire [63:0] dpc_w          = dpc_o;
    wire [63:0] dcsr_w         = dcsr_o;
    wire        trap_taken     = c_trap_taken && !c_irq_taken;    // a synchronous exception only
    wire [63:0] trap_val       = c_trap_val;
    wire        csr_we         = c_csr_we;
    wire        mret_taken     = c_mret_taken;
    wire        is_ebreak      = head_ctrl.cls == QV_FU_SYS && head_ctrl.sys_op == QV_SYS_EBREAK;
    // the head is a divide (high through its commit cycle) / is still waiting
    // for its result; a faulting uop is classed ALU, so cls == DIV is a real divide
    wire        is_div_family  = head_valid && head_ctrl.cls == QV_FU_DIV;
    wire        div_stall      = is_div_family && !head_entry.complete;

    wire        interrupt_taken      = c_irq_taken;
    wire        route_to_s           = c_trap_to_s;
    wire        sret_taken           = c_sret_taken;
    wire        debug_halt_req_entry = dbg_halt_entry;
    wire        debug_ebreak_entry   = dbg_ebreak_entry;
    wire        trigger_debug_entry  = dbg_trigger_entry;
    wire        in_debug_mode        = dbg_in_debug;
    wire        debug_progbuf_active = pb_active;
    wire        stepping_q           = dbg_stepping;
    wire [2:0]  debug_cause_code     = dbg_cause;
    wire        divider_o_busy       = !div_free;
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- ports ----------------
    assign o_debug_mode    = in_debug_mode;
    assign o_dm_csr_rdata  = csr_rdata;
    assign o_dm_gpr_rdata  = rs2_data;
    assign o_progbuf_pc    = pb_idx;
    assign o_progbuf_done  = pb_done;
    assign o_progbuf_abort = pb_abort;

    // ---------------- RVFI ----------------
`ifdef RISCV_FORMAL
    assign rvfi_valid     = commit_now_w;
    assign rvfi_order     = c_order;
    assign rvfi_insn      = c_insn;
    assign rvfi_trap      = c_rvfi_trap;
    assign rvfi_halt      = 1'b0;
    assign rvfi_intr      = c_intr;
    assign rvfi_mode      = current_priv;
    assign rvfi_ixl       = 2'd2;
    assign rvfi_rs1_addr  = c_rs1_addr;
    assign rvfi_rs2_addr  = c_rs2_addr;
    assign rvfi_rs1_rdata = c_rs1_rdata;
    assign rvfi_rs2_rdata = c_rs2_rdata;
    assign rvfi_rd_addr   = c_rd_addr;
    assign rvfi_rd_wdata  = c_rd_wdata;
    assign rvfi_pc_rdata  = c_pc_rdata;
    assign rvfi_pc_wdata  = c_pc_wdata;
    assign rvfi_mem_addr  = c_mem_addr;
    assign rvfi_mem_rmask = c_mem_rmask;
    assign rvfi_mem_wmask = c_mem_wmask;
    assign rvfi_mem_rdata = c_mem_rdata;
    assign rvfi_mem_wdata = c_mem_wdata;

    assign rvfi_csr_mepc_rmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_wmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_rdata     = mepc_w;
    assign rvfi_csr_mepc_wdata     = mepc_next_w;
    assign rvfi_csr_mcause_rmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_wmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_rdata   = mcause_w;
    assign rvfi_csr_mcause_wdata   = mcause_next_w;
    assign rvfi_csr_sepc_rmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_wmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_rdata     = sepc_w;
    assign rvfi_csr_sepc_wdata     = sepc_next_w;
    assign rvfi_csr_scause_rmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_wmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_rdata   = scause_w;
    assign rvfi_csr_scause_wdata   = scause_next_w;
    assign rvfi_csr_pmpcfg0_rmask  = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpcfg0_wmask  = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpcfg0_rdata  = pmpcfg0_w;
    assign rvfi_csr_pmpcfg0_wdata  = pmpcfg0_w;
    assign rvfi_csr_pmpaddr0_rmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpaddr0_wmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpaddr0_rdata = pmpaddr0_w;
    assign rvfi_csr_pmpaddr0_wdata = pmpaddr0_w;
    assign rvfi_csr_medeleg_rmask  = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_medeleg_wmask  = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_medeleg_rdata  = medeleg_w;
    assign rvfi_csr_medeleg_wdata  = medeleg_w;
    assign rvfi_csr_satp_rmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_satp_wmask     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_satp_rdata     = satp_w;
    assign rvfi_csr_satp_wdata     = satp_w;
    assign rvfi_any_trap_taken     = trap_taken || interrupt_taken;

    // An interrupt or a halt is only ever taken with nothing started on the data bus: the cycle before
    // retired something, so no memory op was in flight, and a head that would start in that cycle is held
    // off by the flush. An EBREAK or trigger entry happens at a head that is not a memory op, and memory
    // ops only start at the head. (A started access cannot be abandoned, so this is what makes entering
    // Debug Mode without waiting for the LSU safe.)
    always @* assert (!((interrupt_taken || debug_halt_req_entry || debug_ebreak_entry || trigger_debug_entry)
                        && lsu_head_started));
    // The LSU and the walker never drive the memory port together: the walker starts a beat only while the LSU
    // has nothing started or ready to start, and the LSU waits out a beat in flight.
    always @* assert (!(lsu_cyc && ptw_cyc));
    assign rvfi_any_debug_entry    = debug_ebreak_entry || debug_halt_req_entry || trigger_debug_entry
                                     || dm_access_active;
`endif
endmodule
