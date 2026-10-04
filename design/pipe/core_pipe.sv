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
 *   C  qv_commit   in-order retirement, regfile0 write, RVFI
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
 * MUL/MULH/MULHSU/MULHU/MULW -- plus conditional branches, JAL, JALR,
 * loads and stores (performed one at a time, at the ROB head), FENCE,
 * FENCE.I, the six Zicsr instructions, ECALL, EBREAK, MRET and WFI (a
 * no-op),
 * with M-mode synchronous traps, and RVC: compressed instructions on any
 * 2-byte boundary, including 32-bit ones that straddle two fetched
 * dwords. Everything else decodes as an illegal-instruction trap. Not
 * yet: SFENCE.VMA, U/S modes, SRET, interrupts, debug, DIV/REM, A.
 * wb_mem_lock_o and the debug/progbuf outputs are held inert. The
 * Debug Module's GPR/CSR access mux (core.sv wires it around regfile0
 * and csr_file0) comes back with debug support.
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
    parameter int ROB_DEPTH = qv_pkg::QV_ROB_DEPTH
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

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        i_debug_halt_req = 1'b0,
    input  logic        i_debug_resume_req = 1'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        o_debug_mode,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic         i_dm_csr_we = 1'b0,
    input  logic [11:0]  i_dm_csr_addr = 12'b0,
    input  logic [63:0]  i_dm_csr_wdata = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0]  o_dm_csr_rdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic         i_dm_gpr_we = 1'b0,
    input  logic [4:0]   i_dm_gpr_sel = 5'b0,
    input  logic [63:0]  i_dm_gpr_wdata = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0]  o_dm_gpr_rdata,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic         i_progbuf_start = 1'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [3:0]   o_progbuf_pc,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]  i_progbuf_data = 32'b0,
    /* verilator lint_on UNUSEDSIGNAL */
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

    // ---------------- redirects ----------------
    logic        redirect_valid, fe_redirect_valid;
    logic [63:0] redirect_pc, fe_redirect_pc;
    wire         flush = redirect_valid;
    wire         fetch_redirect    = redirect_valid || fe_redirect_valid;
    wire [63:0]  fetch_redirect_pc = redirect_valid ? redirect_pc : fe_redirect_pc;

    // ---------------- F: fetch ----------------
    logic        fb_valid, fb_err, fb_pop;
    logic [63:0] fb_pc, fb_data;
    logic        fetch_hold, fetch_idle;     // FENCE.I, with commit

    qv_fetch #(.RESET_PC(RESET_PC)) fetch0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wb_fetch_addr_o), .wb_fetch_cyc_o(wb_fetch_cyc_o), .wb_fetch_stb_o(wb_fetch_stb_o),
        .wb_fetch_dat_i(wb_fetch_dat_i), .wb_fetch_ack_i(wb_fetch_ack_i), .wb_fetch_err_i(wb_fetch_err_i),
        .i_redirect_valid(fetch_redirect), .i_redirect_pc(fetch_redirect_pc),
        .i_hold(fetch_hold), .o_idle(fetch_idle),
        .o_buf_valid(fb_valid), .o_buf_pc(fb_pc), .o_buf_data(fb_data), .o_buf_err(fb_err),
        .i_buf_pop(fb_pop)
    );

    // ---------------- A: align -> instruction queue ----------------
    localparam int FE_W = $bits(fe_instr_t);

    logic         p0_valid, p1_valid, iq_push_ready;
    fe_instr_t    p0_data, p1_data;
    logic         iq_valid, iq_pop;
    logic [FE_W-1:0] iq_bits;
    fe_instr_t    iq_head;
    assign iq_head = iq_bits;

    qv_align align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(fb_valid), .i_buf_pc(fb_pc), .i_buf_data(fb_data), .i_buf_err(fb_err),
        .o_buf_pop(fb_pop),
        .o_push0_valid(p0_valid), .o_push0_data(p0_data),
        .o_push1_valid(p1_valid), .o_push1_data(p1_data),
        .i_push_ready(iq_push_ready),
        .o_redirect_valid(fe_redirect_valid), .o_redirect_pc(fe_redirect_pc)
    );

    qv_fifo #(.WIDTH(FE_W), .DEPTH(4)) iq0 (
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
    fu_req_t                 alu_req, bru_req, lsu_req;
    logic                    lsu_free;
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
        .i_commit_valid(c_valid), .i_commit_rd(c_rd), .i_commit_rd_wen(c_rd_wen), .i_commit_tag(c_tag)
    );

    // LSU outputs, declared ahead of the ROB and commit, which take them
    wb_t      lsu_wb;
    lsu_res_t lsu_res;

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
        .o_empty(rob_empty), .i_wb(wb_bus), .i_wb2(lsu_wb),
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
    // cycle, so at most one result is ever valid. A multi-cycle unit
    // (DIV) will need a real writeback arbiter.
    assign wb_bus = bru_wb.valid ? bru_wb : alu_wb;

    // ---------------- X: LSU -> slow writeback port ----------------
    // No bypass from it: a dependent reads the ROB the next cycle, which
    // keeps wb_mem_dat_i out of issue's combinational paths.
    qv_lsu lsu0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(lsu_req), .o_free(lsu_free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .wb_mem_addr_o(wb_mem_addr_o), .wb_mem_dat_o(wb_mem_dat_o), .wb_mem_sel_o(wb_mem_sel_o),
        .wb_mem_we_o(wb_mem_we_o), .wb_mem_cyc_o(wb_mem_cyc_o), .wb_mem_stb_o(wb_mem_stb_o),
        .wb_mem_dat_i(wb_mem_dat_i), .wb_mem_ack_i(wb_mem_ack_i), .wb_mem_err_i(wb_mem_err_i),
        .o_wb(lsu_wb), .o_res(lsu_res),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_head_started()          // interrupts/debug (P5) will wait on this
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ---------------- C: commit ----------------
    logic        rf_we;
    logic [4:0]  rf_sel;
    logic [63:0] rf_data;
    logic        commit_now_w;
    logic [63:0] arch_pc, retire_next_pc;
    logic [4:0]  c_rs1_addr, c_rs2_addr;
    logic [11:0] c_csr_addr;
    logic [63:0] c_csr_wdata, c_trap_cause, c_trap_val;
    logic        c_csr_we, c_instr_retired, c_trap_taken, c_mret_taken;
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

    qv_commit #(.RESET_PC(RESET_PC)) commit0 (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(head_entry), .i_head_tag(head_tag),
        .i_head_shadow(head_shadow), .i_head_ctrl(head_ctrl), .i_lsu_res(lsu_res), .o_commit_pop(commit_pop),
        .o_regfile_we(rf_we), .o_regfile_sel(rf_sel), .o_regfile_data(rf_data),
        .o_commit_valid(c_valid), .o_commit_rd(c_rd), .o_commit_rd_wen(c_rd_wen), .o_commit_tag(c_tag),
        .o_csr_addr(c_csr_addr), .i_csr_rdata(csr_rdata), .o_csr_we(c_csr_we), .o_csr_wdata(c_csr_wdata),
        .o_instr_retired(c_instr_retired), .o_trap_taken(c_trap_taken), .o_trap_cause(c_trap_cause),
        .o_trap_val(c_trap_val), .o_mret_taken(c_mret_taken), .i_mtvec(mtvec_w), .i_mepc(mepc_w),
        .o_fetch_hold(fetch_hold), .i_fetch_idle(fetch_idle), .o_icache_flush(icache_flush_o),
        .o_commit_now(commit_now_w), .o_pc(arch_pc), .o_next_pc(retire_next_pc),
        .o_redirect_valid(redirect_valid), .o_redirect_pc(redirect_pc),
        .o_rvfi_order(c_order), .o_rvfi_insn(c_insn), .o_rvfi_trap(c_rvfi_trap), .o_rvfi_intr(c_intr),
        .o_rvfi_rs1_addr(c_rs1_addr), .o_rvfi_rs2_addr(c_rs2_addr),
        .o_rvfi_rs1_rdata(c_rs1_rdata), .o_rvfi_rs2_rdata(c_rs2_rdata),
        .o_rvfi_rd_addr(c_rd_addr), .o_rvfi_rd_wdata(c_rd_wdata),
        .o_rvfi_pc_rdata(c_pc_rdata), .o_rvfi_pc_wdata(c_pc_wdata),
        .o_rvfi_mem_addr(c_mem_addr), .o_rvfi_mem_rmask(c_mem_rmask), .o_rvfi_mem_wmask(c_mem_wmask),
        .o_rvfi_mem_rdata(c_mem_rdata), .o_rvfi_mem_wdata(c_mem_wdata)
    );

    // ---------------- architectural state ----------------
    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(rs1_sel), .o_read_gpr_A_data(rs1_data),
        .i_read_gpr_B_sel(rs2_sel), .o_read_gpr_B_data(rs2_data),
        .i_load_gpr(rf_we), .i_load_gpr_sel(rf_sel), .i_load_gpr_data(rf_data)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] stvec_w, sepc_w, medeleg_w, mip_w, mie_w, mideleg_w;
    logic [63:0] dcsr_o, dpc_o, tdata1_0_w, tdata1_1_w, tdata2_0_w, tdata2_1_w;
    logic [63:0] pmpcfg0_w, pmpaddr0_w, pmpaddr1_w, pmpaddr2_w, pmpaddr3_w, satp_w;
    logic [1:0]  mstatus_mpp_w;
    logic        mstatus_spp_w, mstatus_tsr_w, mstatus_mie_w, mstatus_sie_w;
    logic        mstatus_mprv_w, mstatus_sum_w, mstatus_mxr_w, mstatus_tvm_w;
    /* verilator lint_on UNUSEDSIGNAL */
`ifdef RISCV_FORMAL
    logic [63:0] mcause_w, scause_w, mepc_next_w, sepc_next_w, mcause_next_w, scause_next_w;
`endif

    csr_file csr_file0 (
        .i_clk(clk), .i_rst(rst),
        .i_csr_addr(c_csr_addr), .o_csr_rdata(csr_rdata), .i_csr_we(c_csr_we), .i_csr_wdata(c_csr_wdata),
        .i_instr_retired(c_instr_retired),
        .i_current_priv(2'b11),
        .i_mtip(i_mtip), .i_meip(i_meip), .i_seip(i_seip),
        .i_trap_taken(c_trap_taken), .i_trap_cause(c_trap_cause), .i_trap_val(c_trap_val),
        .i_trap_pc(arch_pc),
        .i_trap_to_s(1'b0), .i_mret_taken(c_mret_taken), .i_sret_taken(1'b0),
        .i_debug_entry(1'b0), .i_debug_cause(3'b0),
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
    wire [1:0]  current_priv   = 2'b11;
    wire [63:0] dpc_w          = dpc_o;
    wire [63:0] dcsr_w         = dcsr_o;
    wire        trap_taken     = c_trap_taken;
    wire [63:0] trap_val       = c_trap_val;
    wire        csr_we         = c_csr_we;
    wire        mret_taken     = c_mret_taken;
    wire        is_ebreak      = head_ctrl.cls == QV_FU_SYS && head_ctrl.sys_op == QV_SYS_EBREAK;

    wire        interrupt_taken      = 1'b0;
    wire        route_to_s           = 1'b0;
    wire        sret_taken           = 1'b0;
    wire        is_div_family        = 1'b0;
    wire        div_stall            = 1'b0;
    wire        debug_halt_req_entry = 1'b0;
    wire        debug_ebreak_entry   = 1'b0;
    wire        trigger_debug_entry  = 1'b0;
    wire        in_debug_mode        = 1'b0;
    wire        debug_progbuf_active = 1'b0;
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- inert ports ----------------
    assign wb_mem_lock_o   = 1'b0;
    assign o_debug_mode    = in_debug_mode;
    assign o_dm_csr_rdata  = csr_rdata;
    assign o_dm_gpr_rdata  = rs2_data;
    assign o_progbuf_pc    = 4'b0;
    assign o_progbuf_done  = 1'b0;
    assign o_progbuf_abort = 1'b0;

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
    assign rvfi_any_debug_entry    = debug_ebreak_entry || debug_halt_req_entry || trigger_debug_entry;
`endif
endmodule
