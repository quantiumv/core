// SPDX-License-Identifier: MIT

`include "defaults/defaults.sv"

/*
 * core -- the pipelined core (pipelining plan, P4 onward; it replaced the
 * multi-cycle FSM core at P8). That FSM lives on, frozen, as
 * verification/reference/ref_core.sv, the retirement-by-retirement
 * reference this core is checked against; "ref_core.sv" in the comments
 * of this directory means it.
 *
 * The port list is the FSM core's exactly, including ANSI defaults and the
 * RISCV_FORMAL-only RVFI block, so `core` is instantiated by name
 * everywhere (soc.sv, the harnesses, the formal wrapper). ref_core.sv is
 * named `core` too under -DQV_REF_AS_CORE, which is how the same suite
 * runs against it. Unlike ref_core.sv this core uses design/'s own leaf
 * modules (decoder/alu/register_file/csr_file), so no macro renaming is
 * needed.
 *
 *   F  qv_fetch    pc generation, Wishbone fetch master, fetch buffer; back-to-back requests (P9a)
 *      qv_btb      branch target buffer: where a taken branch in a dword goes (P9c)
 *   A  qv_align    dword -> up to two fe_instr_t; predicts branches: the history table (qv_bht) for
 *                  conditional ones, the return-address stack (qv_ras) for returns, the target buffer's hint
 *      qv_fifo     instruction queue
 *   D  qv_decode   decoder.sv + uop builder
 *   I  qv_issue    operand resolution, producer table, ROB allocation
 *   X  qv_exu_alu  alu.sv
 *      qv_exu_div  divider.sv, one divide at a time
 *   C  qv_commit   in-order retirement, regfile0 write, RVFI; trains the predictors with architectural outcomes
 *      qv_sb       store buffer: stores to RAM retire before they reach the bus (P9d)
 *      qv_dbg      Debug Mode state (halted, single-stepping)
 *
 * regfile0 and csr_file0 live here at top level (regfile0 is written
 * only at commit, so it always holds architectural state), so their
 * hierarchical paths match ref_core.sv's. The compatibility signals tests
 * reach hierarchically (dut.commit_now, dut.core0.trap_taken, ...) are
 * declared here at top-level scope too, including ones testbench/
 * rvfi_tracer.sv references unconditionally (route_to_s, trap_val).
 *
 * Implemented so far: every single-cycle integer ALU instruction --
 * RV64I register/immediate ops including the *W forms, LUI, AUIPC, and
 * MUL/MULH/MULHSU/MULHU/MULW -- DIV/DIVU/REM/REMU and the W forms (one at
 * a time, on the divider), conditional branches, JAL, JALR,
 * loads and stores (performed one at a time, at the ROB head; a plain store to RAM, inside the physical window
 * PMA_RAM_BASE/SIZE the instantiating harness gives, is only checked there and completes at once, and its bus
 * write happens after it retires, from the store buffer), FENCE,
 * FENCE.I, LR/SC and the nine AMOs (.W and .D, also at the head, with the
 * bus locked across an AMO's read and write), the six Zicsr instructions,
 * ECALL, EBREAK, MRET, SRET, WFI (a no-op) and SFENCE.VMA (it serializes and
 * empties the TLBs), with the three privilege levels, trap
 * delegation and the privilege rules (CSR access, TSR, TVM), and RVC:
 * compressed instructions on any 2-byte boundary, including 32-bit ones
 * that straddle two fetched dwords. Everything else decodes as an
 * illegal-instruction trap. Interrupts (MEI, MTI, SEI) are taken as ref_core.sv
 * takes them, only in the cycle after a retirement, and the PMP is
 * checked on the fetch (in decode) and on the data accesses (in the LSU).
 * Debug: halt requests, resume and single steps, taken at the same sample
 * point as interrupts, and the Debug Module's Access Register path, muxed
 * around regfile0 and csr_file0 as ref_core.sv does it; EBREAK (dcsr.ebreak*)
 * and the two execute triggers, matched in decode and acted on at the ROB
 * head; the Program Buffer, whose words qv_dbg feeds into the instruction
 * queue one at a time (see there). Sv39: data accesses and instruction fetches
 * are translated, each side with its own TLB (qv_xlate) and one walker (qv_ptw)
 * that shares the memory port with the LSU; a fetch translates in a phase of its
 * own request (qv_fetch) and carries the physical page to decode's PMP check.
 *
 * Redirects: commit's (a trap, xRET, serialize, or a retiring
 * mispredicted branch or jump) kill everything in flight -- the same
 * signal is every stage's flush. Align's (a predicted-taken branch or
 * jump, or a target-buffer hint that came to nothing) only restart fetch;
 * commit's wins a tie.
 *
 * Knobs (defines, each also a parameter): QV_PIPE_SB_DEPTH (store buffer, 0 = none),
 * QV_PIPE_FETCH_STREAM (back-to-back fetch, bigger fetch buffer and queue), QV_PIPE_BP (the three predictors;
 * their sizes QV_PIPE_BTB_ENTRIES / QV_PIPE_RAS_DEPTH / QV_PIPE_BHT_ENTRIES). With every one off the timing is
 * the one of P8, cycle for cycle.
 */
// Testbenches instantiate `core` with no parameter overrides, so the
// debug knobs can also be set from the command line.
`ifndef QV_PIPE_SERIALIZE
`define QV_PIPE_SERIALIZE 1'b0
`endif
`ifndef QV_PIPE_BYPASS_EN
`define QV_PIPE_BYPASS_EN 1'b1
`endif
// Streaming fetch (P9a): back-to-back fetch requests, a four-entry fetch buffer, an eight-entry instruction queue
// that the aligner feeds when it has room for one. QV_PIPE_FETCH_STREAM 0 is the timing without it.
`ifndef QV_PIPE_FETCH_STREAM
`define QV_PIPE_FETCH_STREAM 1'b1
`endif
// Where the fetch port shares a bus with the memory port through an arbiter (the SRAM harnesses), the stream
// must pause for a cycle now and then so the other master is granted: FETCH_YIELD, set by the instantiating
// harness (the SoC's fetch has the instruction cache to itself).
`ifndef QV_PIPE_FETCH_YIELD
`define QV_PIPE_FETCH_YIELD 1'b0
`endif
// Branch prediction (P9c). QV_PIPE_BP 0 leaves all of it out; the pieces size themselves, each 0 = absent.
`ifndef QV_PIPE_BP
`define QV_PIPE_BP 1
`endif
// QV_FORMAL_SMALL: a smaller ROB, IQ and TLBs, to keep riscv-formal's models small
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_ROB_DEPTH 4
`define QV_PIPE_IQ_DEPTH  2
`define QV_PIPE_FB_DEPTH  2
`define QV_PIPE_TLB_ENTRIES 1
`define QV_PIPE_BTB_ENTRIES ((`QV_PIPE_BP) ? 2 : 0)
`define QV_PIPE_RAS_DEPTH ((`QV_PIPE_BP) ? 2 : 0)
`define QV_PIPE_BHT_ENTRIES ((`QV_PIPE_BP) ? 8 : 0)
`else
`define QV_PIPE_ROB_DEPTH qv_pkg::QV_ROB_DEPTH
`define QV_PIPE_IQ_DEPTH  ((`QV_PIPE_FETCH_STREAM) ? 8 : 4)
`define QV_PIPE_FB_DEPTH  ((`QV_PIPE_FETCH_STREAM) ? 4 : 2)
`define QV_PIPE_TLB_ENTRIES 4
`define QV_PIPE_BTB_ENTRIES ((`QV_PIPE_BP) ? 32 : 0)
`define QV_PIPE_RAS_DEPTH ((`QV_PIPE_BP) ? 8 : 0)
`define QV_PIPE_BHT_ENTRIES ((`QV_PIPE_BP) ? 512 : 0)
`endif

// The store buffer (P9d). QV_PIPE_SB_DEPTH 0 leaves it out. Stores are posted only to RAM, which the core is told
// by the physical window PMA_RAM_BASE/PMA_RAM_SIZE (default size 0: nothing is RAM, so the buffer is idle and the
// timing is the one without it); the harness or SoC that knows its memory sets it.
`ifndef QV_PIPE_SB_DEPTH
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_SB_DEPTH 2
`else
`define QV_PIPE_SB_DEPTH 4
`endif
`endif
`ifndef QV_PIPE_PMA_RAM_BASE
`define QV_PIPE_PMA_RAM_BASE 64'h0
`endif
`ifndef QV_PIPE_PMA_RAM_SIZE
`define QV_PIPE_PMA_RAM_SIZE 64'h0
`endif

// Translated fetch keeps the page of its last translation and skips the translation phase for the next request in
// that page (P10a). 0: every translated request has its own phase.
`ifndef QV_PIPE_FETCH_PAGE_REUSE
`define QV_PIPE_FETCH_PAGE_REUSE 1
`endif

// CSR ops that cannot change what a younger instruction does -- the read-only forms, and writes to the trap CSRs
// (m/s scratch, epc, cause, tval) -- do not serialize (P10c). 0: every CSR op flushes and refetches after it.
`ifndef QV_PIPE_CSR_NOSER
`define QV_PIPE_CSR_NOSER 1
`endif

// The data side looks its translation up before the op is the head, so a TLB hit costs no cycle at the head (P10b).
// 0: looked up at the head only.
`ifndef QV_PIPE_DTLB_PROBE
`define QV_PIPE_DTLB_PROBE 1
`endif

// QV_FORMAL_NO_SV39: no translation at all (no walker, no TLB): the Bare paths only. The riscv-formal sweep that
// pins satp to Bare uses it, so its models do not grow by the TLBs and the walker.
`ifdef QV_FORMAL_NO_SV39
`define QV_PIPE_SV39_EN 1'b0
`else
`define QV_PIPE_SV39_EN 1'b1
`endif

module core
#(
    parameter bit SERIALIZE = `QV_PIPE_SERIALIZE,
    parameter bit BYPASS_EN = `QV_PIPE_BYPASS_EN,
    parameter int ROB_DEPTH = `QV_PIPE_ROB_DEPTH,   // power of 2, <= qv_pkg::QV_ROB_DEPTH
    parameter int IQ_DEPTH  = `QV_PIPE_IQ_DEPTH,    // power of 2, >= 2
    parameter int FB_DEPTH  = `QV_PIPE_FB_DEPTH,    // fetch buffer entries
    parameter bit FETCH_STREAM = `QV_PIPE_FETCH_STREAM,   // back-to-back fetch requests
    parameter bit FETCH_YIELD  = `QV_PIPE_FETCH_YIELD,    // fetch gives way to the memory port's masters (shared bus)
    parameter int BTB_ENTRIES  = `QV_PIPE_BTB_ENTRIES,    // branch target buffer entries, 0: none
    parameter int RAS_DEPTH    = `QV_PIPE_RAS_DEPTH,      // return-address stack entries, 0: none (>= 2 otherwise)
    parameter int BHT_ENTRIES  = `QV_PIPE_BHT_ENTRIES,    // branch history table counters, 0: none (>= 8 otherwise)
    parameter bit SV39_EN   = `QV_PIPE_SV39_EN,     // address translation present
    parameter int TLB_ENTRIES = `QV_PIPE_TLB_ENTRIES, // entries in each of the two TLBs
    parameter bit FETCH_PAGE_REUSE = `QV_PIPE_FETCH_PAGE_REUSE,   // a translated request reuses the last page
    parameter bit DTLB_PROBE = `QV_PIPE_DTLB_PROBE,   // the data side looks up its translation before the head
    parameter bit CSR_NOSER  = `QV_PIPE_CSR_NOSER,    // CSR ops that change nothing a younger one sees do not serialize
    parameter int SB_DEPTH  = `QV_PIPE_SB_DEPTH,     // store buffer entries, 0: none
    parameter logic [63:0] PMA_RAM_BASE = `QV_PIPE_PMA_RAM_BASE,   // physical window of RAM: stores into it are posted
    parameter logic [63:0] PMA_RAM_SIZE = `QV_PIPE_PMA_RAM_SIZE
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
    output logic         o_progbuf_abort,

    // F/D: the Debug Module's abstract FPR access (the same ports as the reference's), on fprf0's port 3
    input  logic         i_dm_fpr_we = 1'b0,
    input  logic [4:0]   i_dm_fpr_sel = 5'b0,
    input  logic [63:0]  i_dm_fpr_wdata = 64'b0,
    output logic [63:0]  o_dm_fpr_rdata

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
    output logic rvfi_any_debug_entry,
    // F/D, not standard RVFI: an FP register written by this retirement (the same ports as the reference's)
    output logic        rvfi_frd_wvalid,
    output logic [4:0]  rvfi_frd_addr,
    output logic [63:0] rvfi_frd_wdata
`endif
);
    import qv_pkg::*;

    // F/D is not built into this core yet: only the Debug Module writes an FP register (fprf0, below)
`ifdef RISCV_FORMAL
    assign rvfi_frd_wvalid = 1'b0;
    assign rvfi_frd_addr   = 5'b0;
    assign rvfi_frd_wdata  = 64'b0;
`endif

    localparam logic [63:0] RESET_PC = 64'h0;   // ref_core.sv's own reset pc

    // ---------------- csr_file0's exports ----------------
    // declared up here: decode, commit and the fetch path all read some of them
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] stvec_w, sepc_w, medeleg_w, mip_w, mie_w, mideleg_w;
    logic [63:0] dcsr_o, dpc_o, tdata1_0_w, tdata1_1_w, tdata2_0_w, tdata2_1_w;
    logic [63:0] pmpcfg0_w, pmpaddr0_w, pmpaddr1_w, pmpaddr2_w, pmpaddr3_w, satp_w;
    logic [1:0]  mstatus_mpp_w;
    logic        mstatus_spp_w, mstatus_tsr_w, mstatus_mie_w, mstatus_sie_w;
    logic        mstatus_mprv_w, mstatus_sum_w, mstatus_mxr_w, mstatus_tvm_w;
    // the F/D state: these three names are read by the lockstep harness, the same in both cores
    logic [1:0]  mstatus_fs_w;
    logic [2:0]  frm_w;
    logic [4:0]  fflags_w;
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
    logic        fetch_xl_flush;             // ... and this: fetch forgets its last translated page
    logic        fetch_yield;                // below, once the memory port's masters are declared
    logic        fb_hint;                    // the fetch buffer's head dword was flagged by the BTB
    logic [1:0]  fb_hoff;
    logic        fb_hx;
    logic [63:0] fb_htgt;
    logic [63:0] btb_lk_pc;
    logic        btb_hit, btb_x;
    logic [1:0]  btb_off;
    logic [63:0] btb_tgt;

    qv_fetch #(.RESET_PC(RESET_PC), .FB_DEPTH(FB_DEPTH), .STREAM(FETCH_STREAM), .BTB_EN(BTB_ENTRIES > 0),
               .PAGE_REUSE(SV39_EN && FETCH_PAGE_REUSE)) fetch0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wb_fetch_addr_o), .wb_fetch_cyc_o(wb_fetch_cyc_o), .wb_fetch_stb_o(wb_fetch_stb_o),
        .wb_fetch_dat_i(wb_fetch_dat_i), .wb_fetch_ack_i(wb_fetch_ack_i), .wb_fetch_err_i(wb_fetch_err_i),
        .i_redirect_valid(fetch_redirect), .i_redirect_pc(fetch_redirect_pc), .i_redirect_ctx(fetch_redirect_ctx),
        .i_hold(fetch_hold), .o_idle(fetch_idle), .i_yield(fetch_yield),
        .o_btb_pc(btb_lk_pc), .i_btb_hit(btb_hit), .i_btb_off(btb_off), .i_btb_x(btb_x), .i_btb_tgt(btb_tgt),
        .i_xl_on(fetch_xl_on),
        .o_xl_req(f_xl_req), .o_xl_va(f_xl_va), .o_xl_cancel(f_xl_cancel),
        .i_xl_done(f_xl_done), .i_xl_pf(f_xl_pf), .i_xl_af(f_xl_af), .i_xl_ppn(f_xl_ppn),
        .i_xl_flush(fetch_xl_flush),
        .o_buf_valid(fb_valid), .o_buf_pc(fb_pc), .o_buf_data(fb_data), .o_buf_err(fb_err),
        .o_buf_cause(fb_cause), .o_buf_xl(fb_xl), .o_buf_pg(fb_pg),
        .o_buf_hint(fb_hint), .o_buf_hoff(fb_hoff), .o_buf_hx(fb_hx), .o_buf_htgt(fb_htgt),
        .i_buf_pop(fb_pop)
    );

    // ---------------- the branch target buffer ----------------
    logic        btb_upd_valid, btb_upd_taken, btb_upd_cross;
    logic [63:0] btb_upd_pc, btb_upd_tgt;
    generate
        if (BTB_ENTRIES > 0) begin : g_btb
            qv_btb #(.ENTRIES(BTB_ENTRIES)) btb0 (
                .clk(clk), .rst(rst),
                .i_lk_pc(btb_lk_pc), .o_hit(btb_hit), .o_off(btb_off), .o_x(btb_x), .o_tgt(btb_tgt),
                .i_upd_valid(btb_upd_valid), .i_upd_pc(btb_upd_pc), .i_upd_taken(btb_upd_taken), .i_upd_cross(btb_upd_cross),
                .i_upd_tgt(btb_upd_tgt)
            );
        end else begin : g_nobtb
            assign btb_hit = 1'b0;
            assign btb_off = 2'b0;
            assign btb_x   = 1'b0;
            assign btb_tgt = 64'b0;
        end
    endgenerate

    // ---------------- the return-address stack ----------------
    logic        ras_has1, ras_push, ras_pop;
    logic [1:0]  ras_op0, ras_op1;
    logic [63:0] ras_addr0, ras_addr1, ras_top, ras_c_addr;
    generate
        if (RAS_DEPTH > 0) begin : g_ras
            qv_ras #(.DEPTH(RAS_DEPTH)) ras0 (
                .clk(clk), .rst(rst),
                .i_sp_op0(ras_op0), .i_sp_addr0(ras_addr0), .i_sp_op1(ras_op1), .i_sp_addr1(ras_addr1),
                .i_cm_push(ras_push), .i_cm_addr(ras_c_addr), .i_cm_pop(ras_pop), .i_flush(flush),
                .o_top(ras_top), .o_has1(ras_has1)
            );
        end else begin : g_noras
            assign ras_top  = 64'b0;
            assign ras_has1 = 1'b0;
        end
    endgenerate

    // ---------------- the branch history table ----------------
    logic [63:0] bht_base, bht_ppc;
    logic [3:0]  bht_known, bht_taken;
    logic        bht_pknown, bht_ptaken, bht_upd_valid, bht_upd_taken;
    generate
        if (BHT_ENTRIES > 0) begin : g_bht
            qv_bht #(.ENTRIES(BHT_ENTRIES)) bht0 (
                .clk(clk), .rst(rst),
                .i_base_pc(bht_base), .i_pend_pc(bht_ppc),
                .o_known(bht_known), .o_taken(bht_taken), .o_pend_known(bht_pknown), .o_pend_taken(bht_ptaken),
                .i_upd_valid(bht_upd_valid), .i_upd_pc(btb_upd_pc), .i_upd_taken(bht_upd_taken)
            );
        end else begin : g_nobht
            assign bht_known  = 4'b0;
            assign bht_taken  = 4'b0;
            assign bht_pknown = 1'b0;
            assign bht_ptaken = 1'b0;
        end
    endgenerate

    // ---------------- A: align -> instruction queue ----------------
    localparam int FE_W = $bits(fe_instr_t);

    logic         p0_valid, p1_valid, iq_push_ready, iq_push_ready1;
    fe_instr_t    p0_data, p1_data;
    logic         a0_valid, a1_valid;
    fe_instr_t    a0_data, a1_data;
    fe_instr_t    inj_data;
    logic         iq_valid, iq_pop;
    logic [FE_W-1:0] iq_bits;
    fe_instr_t    iq_head;
    assign iq_head = iq_bits;

    qv_align #(.ONE_OK(FETCH_STREAM)) align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(fb_valid), .i_buf_pc(fb_pc), .i_buf_data(fb_data), .i_buf_err(fb_err),
        .i_buf_cause(fb_cause), .i_buf_xl(fb_xl), .i_buf_pg(fb_pg),
        .i_buf_hint(fb_hint), .i_buf_hoff(fb_hoff), .i_buf_hx(fb_hx), .i_buf_htgt(fb_htgt),
        .o_buf_pop(fb_pop),
        .o_bht_base(bht_base), .o_bht_ppc(bht_ppc),
        .i_bht_known(bht_known), .i_bht_taken(bht_taken), .i_bht_pknown(bht_pknown), .i_bht_ptaken(bht_ptaken),
        .i_ras_top(ras_top), .i_ras_has1(ras_has1),
        .o_ras_op0(ras_op0), .o_ras_addr0(ras_addr0), .o_ras_op1(ras_op1), .o_ras_addr1(ras_addr1),
        .o_push0_valid(a0_valid), .o_push0_data(a0_data),
        .o_push1_valid(a1_valid), .o_push1_data(a1_data),
        .i_push_ready(iq_push_ready), .i_push_ready1(iq_push_ready1),
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
        .o_push_ready(iq_push_ready), .o_push_ready1(iq_push_ready1),
        .o_head_valid(iq_valid), .o_head_data(iq_bits),
        .i_pop(iq_pop)
    );

    // ---------------- D: decode ----------------
    logic uop_valid, issue_fire;
    uop_t uop;

    qv_decode #(.CSR_NOSER(CSR_NOSER)) decode0 (
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

    qv_issue #(.SERIALIZE(SERIALIZE), .BYPASS_EN(BYPASS_EN), .CSR_LATE(CSR_NOSER)) issue0 (
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
    // the store buffer's drain is the third master: a beat in flight is never interrupted, and the three never
    // start together (the LSU and the walker are held off by sb_beat/sb_go, the drain by their own busy signals)
    logic [31:0] sb_addr;
    logic [63:0] sb_dat;
    logic [7:0]  sb_sel;
    logic        sb_cyc, sb_beat, sb_go, sb_go_idle, sb_ready, sb_empty, sb_match, lsu_load_near, lsu_in_bus, c_sb_push;
    logic [31:3] sb_match_addr;
    logic        ptw_wants;                  // a translation request is waiting for the walker (and so for the memory port)
    // fetch pauses its stream for a cycle when another master of the shared bus wants it
    assign fetch_yield = FETCH_YIELD && (lsu_bus_busy || sb_beat || sb_go_idle || ptw_wants);
    // On a shared bus a translated fetch uses the port in two of every three cycles: its translation phase is the
    // gap. A store that retires at once lets the load behind it reach the ROB head a cycle earlier, and the load's
    // access can then start in the very cycle fetch's request begins its bus beat; the memory port wins that tie
    // and fetch waits out the whole access. The LSU gives way for that one cycle (the access then starts in fetch's
    // response cycle and fetch waits one cycle, not two). Only with the store buffer, so that without it the timing
    // is the one of P8; never with a private fetch path (FETCH_YIELD 0).
    logic fetch_start_q;
    always_ff @(posedge clk) fetch_start_q <= !rst && FETCH_YIELD && (SB_DEPTH > 0) && f_xl_req && f_xl_done && !f_xl_cancel;
    assign wb_mem_addr_o = sb_beat ? sb_addr : ptw_beat ? ptw_addr : lsu_addr;
    assign wb_mem_dat_o  = sb_beat ? sb_dat : lsu_dat;
    assign wb_mem_sel_o  = sb_beat ? sb_sel : ptw_beat ? 8'hFF : lsu_sel;
    assign wb_mem_we_o   = sb_beat ? 1'b1 : ptw_beat ? 1'b0 : lsu_we;
    assign wb_mem_cyc_o  = sb_beat ? sb_cyc : ptw_beat ? ptw_cyc : lsu_cyc;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_lock_o = (sb_beat || ptw_beat) ? 1'b0 : lsu_lock;
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
    logic        x_nowalk;                   // the LSU's request is a lookup only (before the head)

    // No bypass from the LSU's writeback: a dependent reads the ROB the next cycle, which
    // keeps wb_mem_dat_i out of issue's combinational paths.
    qv_lsu #(.SB_EN(SB_DEPTH > 0), .PMA_RAM_BASE(PMA_RAM_BASE), .PMA_RAM_SIZE(PMA_RAM_SIZE),
             .PROBE(SV39_EN && DTLB_PROBE)) lsu0 (
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
        .o_xl_cancel(x_cancel), .o_xl_nowalk(x_nowalk),
        .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn),
        .i_ptw_beat(ptw_beat), .o_bus_busy(lsu_bus_busy),
        .i_sb_empty(sb_empty), .i_sb_match(sb_match), .i_sb_beat(sb_beat), .i_sb_go(sb_go_idle), .i_fetch_start(fetch_start_q),
        .o_sb_addr(sb_match_addr), .o_load_near(lsu_load_near), .o_in_bus(lsu_in_bus)
    );

    // ---------------- the store buffer ----------------
    generate
        if (SB_DEPTH > 0) begin : g_sb
            qv_sb #(.DEPTH(SB_DEPTH)) sb0 (
                .clk(clk), .rst(rst),
                .i_push(c_sb_push), .i_push_addr(lsu_res.mem_addr[31:3]), .i_push_sel(lsu_res.mem_wmask),
                .i_push_data(lsu_res.mem_wdata), .o_ready(sb_ready), .o_empty(sb_empty),
                .i_match_addr(sb_match_addr), .o_match(sb_match),
                .i_lsu_busy(lsu_bus_busy), .i_lsu_inflight(lsu_in_bus), .i_ptw_beat(ptw_beat),
                .i_load_near(lsu_load_near),
                .o_start_now(sb_go), .o_start_idle(sb_go_idle), .o_beat(sb_beat), .o_cyc(sb_cyc),
                .o_addr(sb_addr), .o_dat(sb_dat), .o_sel(sb_sel),
                .i_ack(wb_mem_ack_i), .i_err(wb_mem_err_i)
            );
        end else begin : g_nosb
            assign sb_ready = 1'b1;
            assign sb_empty = 1'b1;
            assign sb_match = 1'b0;
            assign sb_go    = 1'b0;
            assign sb_go_idle = 1'b0;
            assign sb_beat  = 1'b0;
            assign sb_cyc   = 1'b0;
            assign sb_addr  = 32'b0;
            assign sb_dat   = 64'b0;
            assign sb_sel   = 8'b0;
        end
    endgenerate

    generate
        if (SV39_EN) begin : g_sv39
            wire         w_d_req, w_d_cancel, w_d_done;
            wire         w_f_req, w_f_cancel, w_f_done;
            assign ptw_wants = w_d_req || w_f_req;
            wire         w_ok, w_pf, w_af, w_r, w_w, w_x, w_u, w_d;
            wire  [26:0] w_vpn;
            wire  [1:0]  w_level;
            wire  [43:0] w_ppn;

            // F's PTE reads outside RAM wait until nothing older is left: no ROB entry, no uop in decode, nothing in
            // the instruction queue or the fetch buffer (the aligner's stash waits for exactly the dword being walked)
            wire f_nonspec = rob_empty && !uop_valid && !iq_valid && !fb_valid;

            qv_ptw #(.PMA_RAM_BASE(PMA_RAM_BASE), .PMA_RAM_SIZE(PMA_RAM_SIZE)) ptw0 (
                .clk(clk), .rst(rst),
                .o_bus_addr(ptw_addr), .o_bus_cyc(ptw_cyc),
                .i_bus_dat(wb_mem_dat_i), .i_bus_ack(wb_mem_ack_i), .i_bus_err(wb_mem_err_i),
                .i_lsu_busy(lsu_bus_busy || sb_beat || sb_go || !sb_empty), .o_beat(ptw_beat),
                .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
                .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
                .i_d_req(w_d_req), .i_d_va(x_va), .i_d_wr(x_wr), .i_d_priv(x_priv),
                .i_d_sum(mstatus_sum_w), .i_d_mxr(mstatus_mxr_w), .i_d_root(satp_w[43:0]),
                .i_d_cancel(w_d_cancel), .o_d_done(w_d_done),
                .i_f_req(w_f_req), .i_f_va(f_xl_va), .i_f_priv(priv), .i_f_root(satp_w[43:0]),
                .i_f_cancel(w_f_cancel), .o_f_done(w_f_done), .i_f_nonspec(f_nonspec),
                .o_res_ok(w_ok), .o_res_pf(w_pf), .o_res_af(w_af), .o_res_vpn(w_vpn), .o_res_level(w_level),
                .o_res_ppn(w_ppn), .o_res_r(w_r), .o_res_w(w_w), .o_res_x(w_x), .o_res_u(w_u), .o_res_d(w_d)
            );

            qv_xlate #(.TLB_ENTRIES(TLB_ENTRIES)) xlate_d (
                .clk(clk), .rst(rst),
                .i_req(x_req), .i_va(x_va), .i_is_mem(1'b1), .i_wr(x_wr), .i_active(x_active), .i_priv(x_priv),
                .i_sum(mstatus_sum_w), .i_mxr(mstatus_mxr_w), .i_cancel(x_cancel), .i_flush_tlb(c_sfence),
                .i_nowalk(x_nowalk),
                .o_done(x_done), .o_pf(x_pf), .o_af(x_af), .o_ppn(x_ppn),
                .o_w_req(w_d_req), .o_w_cancel(w_d_cancel),
                .i_w_done(w_d_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn),
                .i_w_level(w_level), .i_w_ppn(w_ppn), .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u),
                .i_w_d(w_d)
            );

            // the instruction side: its own TLB, asked by fetch; no SUM or MXR for an execute
            qv_xlate #(.TLB_ENTRIES(TLB_ENTRIES)) xlate_f (
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
            assign ptw_wants = 1'b0;
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
    // what else ends the context of fetch's last translated page: SFENCE.VMA, and halting (a debugger may write
    // satp through the Access Register path, which raises no redirect at all)
    assign fetch_xl_flush = c_sfence || dbg_in_debug || dbg_entry;

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
        .i_sb_ready(sb_ready), .i_sb_empty(sb_empty), .o_sb_push(c_sb_push),
        .o_btb_upd_valid(btb_upd_valid), .o_btb_upd_pc(btb_upd_pc), .o_btb_upd_taken(btb_upd_taken),
        .o_btb_upd_cross(btb_upd_cross),
        .o_bht_upd_valid(bht_upd_valid), .o_bht_upd_taken(bht_upd_taken),
        .o_ras_push(ras_push), .o_ras_addr(ras_c_addr), .o_ras_pop(ras_pop),
        .o_btb_upd_tgt(btb_upd_tgt),
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
    // The Debug Module's GPR access shares read port B and the write port outright, as in ref_core.sv: while the
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

    // F/D: the FP register file (its array fp_registers is a name the lockstep harness reads in both cores). The
    // Debug Module's FPR access takes read port 3 and the write port while the hart is halted, as for regfile0.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] fprs1_data, fprs2_data;
    /* verilator lint_on UNUSEDSIGNAL */
    qv_fprf fprf0 (
        .clk(clk),
        .i_rs1(5'b0), .i_rs2(5'b0), .i_rs3(i_dm_fpr_sel),
        .o_rs1_data(fprs1_data), .o_rs2_data(fprs2_data), .o_rs3_data(o_dm_fpr_rdata),
        .i_we(dm_access_active && i_dm_fpr_we), .i_wsel(i_dm_fpr_sel), .i_wdata(i_dm_fpr_wdata)
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
        .o_mstatus_tvm(mstatus_tvm_w),
        .o_mstatus_fs(mstatus_fs_w), .o_frm(frm_w), .o_fflags(fflags_w)
`ifdef RISCV_FORMAL
        , .o_mcause(mcause_w), .o_scause(scause_w),
        .o_mepc_next(mepc_next_w), .o_sepc_next(sepc_next_w),
        .o_mcause_next(mcause_next_w), .o_scause_next(scause_next_w)
`endif
    );

    // ---------------- compatibility layer ----------------
    // Names match ref_core.sv's own internal signals, for tests that reach
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
    // the Debug Module's system bus access must not read memory behind a retired store: the hart shows as halted
    // to it once the store buffer has drained (internally it is halted at the sample point, as before)
    assign o_debug_mode    = in_debug_mode && sb_empty;
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

    // An interrupt or a halt is only ever taken with nothing started on the LSU's side of the data bus: the cycle
    // before retired something, so no memory op was in flight, and a head that would start in that cycle is held
    // off by the flush. An EBREAK or trigger entry happens at a head that is not a memory op, and memory
    // ops only start at the head. (A started access cannot be abandoned, so this is what makes entering
    // Debug Mode without waiting for the LSU safe. The walker may have a PTE read of a cancelled fetch walk in
    // flight; it is a read that completes and is dropped, and the LSU's next start waits for it.)
    always @* assert (!((interrupt_taken || debug_halt_req_entry || debug_ebreak_entry || trigger_debug_entry)
                        && lsu_head_started));
    // The LSU, the walker and the store buffer's drain never drive the memory port together: each starts a beat
    // only while the others have nothing started or ready to start, and waits out a beat in flight.
    always @* assert (!((lsu_cyc && ptw_cyc) || (lsu_cyc && sb_cyc) || (ptw_cyc && sb_cyc)));

    // The translators are safe only while a client keeps to one rule: a request it holds does not change (what it
    // asks for, the context it asks in) except in the cycle after a cancel, so that the answer of a walk that was
    // cancelled can never reach another request. Fetch replaces a translating request only with a cancel (drop);
    // the LSU's op leaves with a flush, which cancels, and the next op is accepted a cycle later.
    reg        g_f_req = 1'b0, g_x_req = 1'b0, g_f_cancel = 1'b0, g_x_cancel = 1'b0, g_x_wr = 1'b0, g_sum = 1'b0, g_mxr = 1'b0;
    reg [63:0] g_f_va = '0, g_x_va = '0, g_satp = '0;
    reg [1:0]  g_f_priv = '0, g_x_priv = '0;
    always @(posedge clk) begin
        g_f_req    <= f_xl_req && !rst;
        g_f_cancel <= f_xl_cancel;
        g_f_va     <= f_xl_va;
        g_f_priv   <= priv;
        g_x_req    <= x_req && !rst;
        g_x_cancel <= x_cancel;
        g_x_va     <= x_va;
        g_x_wr     <= x_wr;
        g_x_priv   <= x_priv;
        g_sum      <= mstatus_sum_w;
        g_mxr      <= mstatus_mxr_w;
        g_satp     <= satp_w;
    end
    always @* begin
        if (!rst && g_f_req && f_xl_req && !g_f_cancel)
            assert (f_xl_va == g_f_va && priv == g_f_priv && satp_w == g_satp);
        if (!rst && g_x_req && x_req && !g_x_cancel)
            assert (x_va == g_x_va && x_wr == g_x_wr && x_priv == g_x_priv && mstatus_sum_w == g_sum
                    && mstatus_mxr_w == g_mxr && satp_w == g_satp);
    end
    // Fetch's last translated page (P10a) is reused only in the context it was found in: a request that skips its
    // translation sees the satp and privilege of the translation that filled the page, with no SFENCE.VMA and no
    // halt since.
    reg        g_lp_valid = 1'b0;
    reg [63:0] g_lp_satp = '0;
    reg [1:0]  g_lp_priv = '0;
    always @(posedge clk) begin
        if (rst || fetch_xl_flush)
            g_lp_valid <= 1'b0;
        else if (f_xl_req && f_xl_done && !f_xl_pf && !f_xl_af && !fetch_hold && !fetch_redirect) begin
            g_lp_valid <= 1'b1;
            g_lp_satp  <= satp_w;
            g_lp_priv  <= priv;
        end
    end
    always @* if (!rst && fetch0.can_issue && fetch0.issue_reuse)
        assert (g_lp_valid && satp_w == g_lp_satp && priv == g_lp_priv);

    // The data side's translation, once taken (P10b: possibly before the op is the head), stays right while the op
    // waits: from the cycle pa_q is taken until the op leaves WAIT_HEAD, satp, the effective privilege, SUM and MXR do
    // not change and no SFENCE.VMA retires -- every change of them flushes the op first.
    reg        g_px_valid = 1'b0;
    reg [63:0] g_px_satp = '0;
    reg [1:0]  g_px_priv = '0;
    reg        g_px_sum = 1'b0, g_px_mxr = 1'b0;
    always @(posedge clk) begin
        if (rst || flush || lsu0.state_q != 2'd1)
            g_px_valid <= 1'b0;
        else if (lsu0.x_ok) begin
            g_px_valid <= 1'b1;
            g_px_satp  <= satp_w;
            g_px_priv  <= x_priv;
            g_px_sum   <= mstatus_sum_w;
            g_px_mxr   <= mstatus_mxr_w;
        end
    end
    always @* if (!rst && !flush && g_px_valid && lsu0.state_q == 2'd1 && lsu0.xlated_q)
        assert (satp_w == g_px_satp && x_priv == g_px_priv && mstatus_sum_w == g_px_sum && mstatus_mxr_w == g_px_mxr
                && !c_sfence);

    assign rvfi_any_debug_entry    = debug_ebreak_entry || debug_halt_req_entry || trigger_debug_entry
                                     || dm_access_active;
`endif
endmodule
