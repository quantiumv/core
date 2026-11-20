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
 *      qv_lsq      load/store queue: the memory ops between dispatch and retirement, for qv_lsu (O2)
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
 * Knobs (defines, each also a parameter): QV_PIPE_SB_DEPTH (store buffer, 0 = none), QV_PIPE_LSQ_DEPTH (load/store
 * queue, 0 = none: one memory op between dispatch and completion), QV_PIPE_LSQ_EARLY / _EARLY_ST (with the queue,
 * RAM loads / stores before the head), QV_PIPE_LSQ_HANDOFF (the LSU takes the next op as the last completes),
 * QV_PIPE_LSQ_PRE_XL (the queue looks up a queued op's translation while the LSU is busy), QV_PIPE_LSQ_BYPASS (a
 * load's value bypasses to issue), QV_PIPE_RS_DEPTH (the reservation station, 0 = none: a uop goes to its unit only
 * in its dispatch cycle),
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
// (O8b) The aligner works on a window of two fetch-buffer entries (qv_align2): any two instructions a cycle, a
// crossing one with no cycle of its own. 0: one entry at a time (qv_align).
`ifndef QV_PIPE_ALIGN_WIN
`define QV_PIPE_ALIGN_WIN 1'b1
`endif
// (O8c) The branch target buffer keeps a direction counter per conditional branch: a branch that falls through counts
// it down instead of losing its entry, and steers fetch only while the counter says taken. 0: the entry goes.
`ifndef QV_PIPE_BTB_CTR
`define QV_PIPE_BTB_CTR 1'b1
`endif
// (O8a) A global-history direction predictor (qv_gshare) in front of the branch history table: a conditional branch
// takes its direction where its counter is trained, the table's where not. QV_PIPE_GSHARE_H history bits (0: none;
// needs the window aligner and the table), 2^QV_PIPE_GSHARE_BITS counters.
`ifndef QV_PIPE_GSHARE_H
`define QV_PIPE_GSHARE_H 12
`endif
`ifndef QV_PIPE_GSHARE_BITS
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_GSHARE_BITS 3
`else
`define QV_PIPE_GSHARE_BITS 12
`endif
`endif
// Where the fetch port shares a bus with the memory port through an arbiter (the SRAM harnesses), the stream
// must pause for a cycle now and then so the other master is granted: FETCH_YIELD, set by the instantiating
// harness (the SoC's fetch has the instruction cache to itself).
`ifndef QV_PIPE_FETCH_YIELD
`define QV_PIPE_FETCH_YIELD 1'b0
`endif
// (O3) A mispredicted branch recovers at execute: the cycle after its writeback everything younger is killed and
// fetch restarts at the resolved target (commit then retires it without a redirect). 0: commit redirects, as before.
`ifndef QV_PIPE_EXEC_REDIRECT
`define QV_PIPE_EXEC_REDIRECT 1'b1
`endif
// (O3, D7) With a recovery at execute, fetch and the frontend restart in the mispredict's writeback cycle rather than
// the kill cycle after it (the backend's kill stays registered). 0: fetch restarts in the kill cycle.
`ifndef QV_PIPE_XR_EARLY
`define QV_PIPE_XR_EARLY 1'b1
`endif
// (O3) What a recovery at execute puts back in the return-address stack: 0 nothing, 1 its index and count, 2 also
// its top entry (qv_ras REPAIR). The formal models keep the smaller snapshot.
`ifndef QV_PIPE_RAS_REPAIR
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_RAS_REPAIR 1
`else
`define QV_PIPE_RAS_REPAIR 2
`endif
`endif
// Branch prediction (P9c). QV_PIPE_BP 0 leaves all of it out; the pieces size themselves, each 0 = absent.
`ifndef QV_PIPE_BP
`define QV_PIPE_BP 1
`endif
// QV_FORMAL_SMALL: a smaller ROB, IQ and TLBs, to keep riscv-formal's models small
`ifdef QV_FORMAL_SMALL
`ifndef QV_PIPE_ROB_DEPTH
`define QV_PIPE_ROB_DEPTH 4
`endif
`define QV_PIPE_IQ_DEPTH  2
`define QV_PIPE_FB_DEPTH  2
`define QV_PIPE_TLB_ENTRIES 1
`define QV_PIPE_BTB_ENTRIES ((`QV_PIPE_BP) ? 2 : 0)
`define QV_PIPE_RAS_DEPTH ((`QV_PIPE_BP) ? 2 : 0)
`define QV_PIPE_BHT_ENTRIES ((`QV_PIPE_BP) ? 8 : 0)
`else
`ifndef QV_PIPE_ROB_DEPTH
`define QV_PIPE_ROB_DEPTH qv_pkg::QV_ROB_DEPTH                // (O7) a larger ROB needs QV_ROB_MAX as well
`endif
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
// The load/store queue (O2). QV_PIPE_LSQ_DEPTH 0 leaves it out: issue then dispatches a memory op only into a free
// LSU, which is the timing without it. 8 entries since O5/6 (4 before).
`ifndef QV_PIPE_LSQ_DEPTH
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_LSQ_DEPTH 2
`else
`define QV_PIPE_LSQ_DEPTH 8
`endif
`endif
// With the queue, a plain load from RAM starts and a plain store to RAM is posted before it is the ROB head, once
// no barrier is older (O2a). QV_PIPE_LSQ_EARLY 0: only at the head; QV_PIPE_LSQ_EARLY_ST 0: only the loads.
`ifndef QV_PIPE_LSQ_EARLY
`define QV_PIPE_LSQ_EARLY 1
`endif
`ifndef QV_PIPE_LSQ_EARLY_ST
`define QV_PIPE_LSQ_EARLY_ST 1
`endif
// ... and the LSU takes its next op in the cycle the last one completes on the bus or is posted (O2b); 0: a cycle later.
`ifndef QV_PIPE_LSQ_HANDOFF
`define QV_PIPE_LSQ_HANDOFF 1
`endif
// ... and the queue looks up the oldest queued op's translation while the LSU is busy, so a translated op starts in its
// first cycle (O2c); 0: the LSU looks each one up when it takes it.
`ifndef QV_PIPE_LSQ_PRE_XL
`define QV_PIPE_LSQ_PRE_XL 1
`endif
// ... and a load's value reaches issue's bypass in its completion cycle (O2d); 0: dependents read it from the ROB a
// cycle later.
`ifndef QV_PIPE_LSQ_BYPASS
`define QV_PIPE_LSQ_BYPASS 1
`endif
// The reservation station (O1). QV_PIPE_RS_DEPTH 0 leaves it out: issue then sends a uop to its unit only in its
// dispatch cycle, stalling dispatch until it can, which is the timing without it. 8 entries since O7c (4 before).
`ifndef QV_PIPE_RS_DEPTH
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_RS_DEPTH 2
`else
`define QV_PIPE_RS_DEPTH 8
`endif
`endif
// With the station and the queue, a memory op dispatches with its address or data still to come and waits for them in
// the queue (O1c). QV_PIPE_LSQ_WAIT 0: it dispatches only with its operands ready, as without the station.
`ifndef QV_PIPE_LSQ_WAIT
`define QV_PIPE_LSQ_WAIT 1
`endif

// O4 (two-wide), one knob per step: QV_PIPE_COMMIT_W instructions retired a cycle (the RVFI ports carry that many
// channels, oldest in channel 0; qv_commit's pair rule), QV_PIPE_DISPATCH_W dispatched a cycle (qv_issue's pair rules),
// QV_PIPE_ALU_PORTS ALU issue ports (the second without a multiplier or branches). 2 by default since O4e; all three at
// 1, with QV_PIPE_SB_YIELD_READY at 1, are the core before O4, cycle for cycle. The testbenches that size RVFI by
// QV_PIPE_COMMIT_W default to the same.
`ifndef QV_PIPE_COMMIT_W
`define QV_PIPE_COMMIT_W 2
`endif
`ifndef QV_PIPE_DISPATCH_W
`define QV_PIPE_DISPATCH_W 2
`endif
`ifndef QV_PIPE_ALU_PORTS
`define QV_PIPE_ALU_PORTS 2
`endif
// O4f: QV_PIPE_SB_YIELD_READY 1 is P9d's drain rule, the store buffer yields to any LSU access that is ready to start;
// 0 (the default since O4f) yields only to a load near the ROB head (qv_sb.sv).
`ifndef QV_PIPE_SB_YIELD_READY
`define QV_PIPE_SB_YIELD_READY 0
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

// The D$ inside the core (O5a, qv_dc): plain loads from RAM are read beside the LSU, with no bus handshake; only a miss
// goes out, as a refill on the memory port. It caches only the PMA window (RAM), so a core with no window has none.
// 0: every load goes to the bus (and the SoC keeps its D$ on the bus). The SoC turns its own D$ off when this is on.
`ifndef QV_PIPE_DCACHE
`define QV_PIPE_DCACHE 1
`endif
`ifndef QV_PIPE_DC_LINES
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_DC_LINES 2
`else
`define QV_PIPE_DC_LINES 64
`endif
`endif
`ifndef QV_PIPE_DC_WORDS
`ifdef QV_FORMAL_SMALL
`define QV_PIPE_DC_WORDS 2
`else
`define QV_PIPE_DC_WORDS 4
`endif
`endif

// QV_FORMAL_NO_SV39: no translation at all (no walker, no TLB): the Bare paths only. The riscv-formal sweep that
// pins satp to Bare uses it, so its models do not grow by the TLBs and the walker.
`ifdef QV_FORMAL_NO_SV39
`define QV_PIPE_SV39_EN 1'b0
`else
`define QV_PIPE_SV39_EN 1'b1
`endif

// F/D: QV_FPU_EN builds the FP unit in (the reference reads the same define); 0 builds the core without F/D, as it
// was before. QV_FORMAL_NO_FPU forces it off for the riscv-formal models, which have no FP checks.
`ifndef QV_FPU_EN
`define QV_FPU_EN 1
`endif

// Zicntr: QV_ZICNTR_EN makes cycle, time and instret exist (time reads i_time, the platform's mtime); 0 leaves them
// absent (illegal, errata E10). The reference reads the same define and must get the same value: lockstep compiles
// both cores in one unit, where the first definition wins.
`ifndef QV_ZICNTR_EN
`define QV_ZICNTR_EN 1
`endif

module core
#(
    parameter bit SERIALIZE = `QV_PIPE_SERIALIZE,
    parameter bit BYPASS_EN = `QV_PIPE_BYPASS_EN,
    parameter int ROB_DEPTH = `QV_PIPE_ROB_DEPTH,   // power of 2, 2 .. qv_pkg::QV_ROB_DEPTH (QV_ROB_MAX)
    parameter int IQ_DEPTH  = `QV_PIPE_IQ_DEPTH,    // power of 2, >= 2
    parameter int FB_DEPTH  = `QV_PIPE_FB_DEPTH,    // fetch buffer entries
    parameter bit FETCH_STREAM = `QV_PIPE_FETCH_STREAM,   // back-to-back fetch requests
    parameter bit ALIGN_WIN    = `QV_PIPE_ALIGN_WIN,      // (O8b) the aligner's two-entry window
    parameter bit FETCH_YIELD  = `QV_PIPE_FETCH_YIELD,    // fetch gives way to the memory port's masters (shared bus)
    parameter int BTB_ENTRIES  = `QV_PIPE_BTB_ENTRIES,    // branch target buffer entries, 0: none
    parameter bit BTB_CTR      = `QV_PIPE_BTB_CTR,        // (O8c) a direction counter per BTB entry
    parameter int GSHARE_H     = `QV_PIPE_GSHARE_H,       // (O8a) global history bits, 0: no gshare
    parameter int GSHARE_BITS  = `QV_PIPE_GSHARE_BITS,    // (O8a) log2 of its counters
    parameter int RAS_DEPTH    = `QV_PIPE_RAS_DEPTH,      // return-address stack entries, 0: none (>= 2 otherwise)
    parameter int RAS_REPAIR   = `QV_PIPE_RAS_REPAIR,     // (O3) 0 none, 1 index and count, 2 also the top entry
    parameter bit EXEC_REDIRECT = `QV_PIPE_EXEC_REDIRECT, // (O3) a mispredict recovers at execute
    parameter bit XR_EARLY     = `QV_PIPE_XR_EARLY,      // (O3, D7) ... and fetch restarts in its writeback cycle
    parameter int BHT_ENTRIES  = `QV_PIPE_BHT_ENTRIES,    // branch history table counters, 0: none (>= 8 otherwise)
    parameter bit SV39_EN   = `QV_PIPE_SV39_EN,     // address translation present
    parameter int TLB_ENTRIES = `QV_PIPE_TLB_ENTRIES, // entries in each of the two TLBs
    parameter bit FETCH_PAGE_REUSE = `QV_PIPE_FETCH_PAGE_REUSE,   // a translated request reuses the last page
    parameter bit DTLB_PROBE = `QV_PIPE_DTLB_PROBE,   // the data side looks up its translation before the head
    parameter bit CSR_NOSER  = `QV_PIPE_CSR_NOSER,    // CSR ops that change nothing a younger one sees do not serialize
    parameter int SB_DEPTH  = `QV_PIPE_SB_DEPTH,     // store buffer entries, 0: none
    parameter int LSQ_DEPTH = `QV_PIPE_LSQ_DEPTH,    // load/store queue entries (a power of 2), 0: none
    parameter bit LSQ_EARLY = `QV_PIPE_LSQ_EARLY,    // (with the queue) RAM loads and stores go before the head
    parameter bit LSQ_EARLY_ST = `QV_PIPE_LSQ_EARLY_ST,  // ... the stores too
    parameter bit LSQ_HANDOFF  = `QV_PIPE_LSQ_HANDOFF,   // (with the queue) the LSU takes the next op as the last completes
    parameter bit LSQ_PRE_XL   = `QV_PIPE_LSQ_PRE_XL,    // (with the queue and Sv39) queued ops are looked up in the TLB
    parameter bit LSQ_BYPASS   = `QV_PIPE_LSQ_BYPASS,    // (with the queue) the LSU's writeback is a bypass source
    parameter int RS_DEPTH  = `QV_PIPE_RS_DEPTH,     // reservation-station entries, 0: none
    parameter bit LSQ_WAIT  = `QV_PIPE_LSQ_WAIT,     // (with the station and the queue) memory ops wait there for operands
    parameter bit DCACHE    = `QV_PIPE_DCACHE,       // (O5a) the D$ inside the core (needs a PMA window)
    parameter int DC_LINES  = `QV_PIPE_DC_LINES,     // ... its lines (a power of 2)
    parameter int DC_WORDS  = `QV_PIPE_DC_WORDS,     // ... dwords a line (a power of 2)
    parameter int COMMIT_W   = `QV_PIPE_COMMIT_W,    // instructions retired a cycle (1 or 2): the RVFI channels
    parameter int DISPATCH_W = `QV_PIPE_DISPATCH_W,  // instructions dispatched a cycle (1 or 2)
    parameter int ALU_PORTS  = `QV_PIPE_ALU_PORTS,   // ALU issue ports (1 or 2)
    parameter bit SB_YIELD_READY = `QV_PIPE_SB_YIELD_READY,   // the store buffer yields to any ready LSU access (P9d)
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
    input  logic [63:0]  i_time = 64'b0,       // Zicntr: the platform's mtime, which the time CSR reads
    // (O5a) another master (the Debug Module's system bus access) wrote this RAM dword: its line leaves the D$
    input  logic         i_snoop_valid = 1'b0,
    input  logic [31:3]  i_snoop_addr = 29'b0,

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
    // COMMIT_W channels, packed riscv-formal style (channel 0, the oldest, in the low bits); satp stays one channel,
    // as the wrapper and the patched rvfi_testbench.sv have it
    output logic [COMMIT_W-1:0]    rvfi_valid,
    output logic [COMMIT_W*64-1:0] rvfi_order,
    output logic [COMMIT_W*32-1:0] rvfi_insn,
    output logic [COMMIT_W-1:0]    rvfi_trap,
    output logic [COMMIT_W-1:0]    rvfi_halt,
    output logic [COMMIT_W-1:0]    rvfi_intr,
    output logic [COMMIT_W*2-1:0]  rvfi_mode,
    output logic [COMMIT_W*2-1:0]  rvfi_ixl,
    output logic [COMMIT_W*5-1:0]  rvfi_rs1_addr,
    output logic [COMMIT_W*5-1:0]  rvfi_rs2_addr,
    output logic [COMMIT_W*64-1:0] rvfi_rs1_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_rs2_rdata,
    output logic [COMMIT_W*5-1:0]  rvfi_rd_addr,
    output logic [COMMIT_W*64-1:0] rvfi_rd_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_pc_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_pc_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_mem_addr,
    output logic [COMMIT_W*8-1:0]  rvfi_mem_rmask,
    output logic [COMMIT_W*8-1:0]  rvfi_mem_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_mem_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_mem_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mepc_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mepc_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mepc_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mepc_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mcause_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mcause_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mcause_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_mcause_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_sepc_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_sepc_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_sepc_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_sepc_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_scause_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_scause_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_scause_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_scause_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpcfg0_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpcfg0_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpcfg0_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpcfg0_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpaddr0_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpaddr0_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpaddr0_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_pmpaddr0_wdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_medeleg_rmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_medeleg_wmask,
    output logic [COMMIT_W*64-1:0] rvfi_csr_medeleg_rdata,
    output logic [COMMIT_W*64-1:0] rvfi_csr_medeleg_wdata,
    output logic [63:0] rvfi_csr_satp_rmask,
    output logic [63:0] rvfi_csr_satp_wmask,
    output logic [63:0] rvfi_csr_satp_rdata,
    output logic [63:0] rvfi_csr_satp_wdata,
    output logic rvfi_any_trap_taken,
    output logic rvfi_any_debug_entry,
    // F/D, not standard RVFI: an FP register written by this retirement (the same ports as the reference's)
    output logic [COMMIT_W-1:0]    rvfi_frd_wvalid,
    output logic [COMMIT_W*5-1:0]  rvfi_frd_addr,
    output logic [COMMIT_W*64-1:0] rvfi_frd_wdata
`endif
);
    import qv_pkg::*;

`ifdef QV_FORMAL_NO_FPU
    localparam bit FPU_EN = 1'b0;
`else
    localparam bit FPU_EN = (`QV_FPU_EN != 0);
`endif
    localparam bit ZICNTR_EN = (`QV_ZICNTR_EN != 0);

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
    logic [2:0]  mcounteren_w, scounteren_w;   // Zicntr: who below M may read cycle, time and instret
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
    // (O3) a redirect from commit wins, then one from execute (xr_kill, below), then the aligner's
    logic        fetch_redirect;
    logic [63:0] fetch_redirect_pc;

    // ---------------- F: fetch ----------------
    logic        fb_valid, fb_err, fb_pop, fb_xl;
    logic [63:0] fb_pc, fb_data;
    logic [3:0]  fb_cause;
    logic [43:0] fb_pg;
    // (O8b) the entry behind the head, for the window aligner
    /* verilator lint_off UNUSEDSIGNAL */
    logic        fb1_valid, fb1_err, fb1_xl, fb1_hint, fb1_hx;
    logic [63:0] fb1_pc, fb1_data, fb1_htgt;
    logic [43:0] fb1_pg;
    logic [1:0]  fb1_hoff;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        fb_pop2;
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
               .PAGE_REUSE(SV39_EN && FETCH_PAGE_REUSE), .IDLE_GO(ALIGN_WIN)) fetch0 (
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
        .i_buf_pop(fb_pop),
        .o_buf1_valid(fb1_valid), .o_buf1_pc(fb1_pc), .o_buf1_data(fb1_data), .o_buf1_err(fb1_err),
        .o_buf1_xl(fb1_xl), .o_buf1_pg(fb1_pg), .o_buf1_hint(fb1_hint), .o_buf1_hoff(fb1_hoff), .o_buf1_hx(fb1_hx),
        .o_buf1_htgt(fb1_htgt), .i_buf_pop2(fb_pop2)
    );

    // ---------------- the branch target buffer ----------------
    logic        btb_upd_valid, btb_upd_taken, btb_upd_cross;
    logic        bht_upd_valid;              // (declared here: the BTB's counter reads it, O8c)
    logic [63:0] btb_upd_pc, btb_upd_tgt;
    generate
        if (BTB_ENTRIES > 0) begin : g_btb
            qv_btb #(.ENTRIES(BTB_ENTRIES), .CTR(BTB_CTR)) btb0 (
                .clk(clk), .rst(rst),
                .i_lk_pc(btb_lk_pc), .o_hit(btb_hit), .o_off(btb_off), .o_x(btb_x), .o_tgt(btb_tgt),
                .i_upd_valid(btb_upd_valid), .i_upd_pc(btb_upd_pc), .i_upd_taken(btb_upd_taken), .i_upd_cross(btb_upd_cross),
                .i_upd_tgt(btb_upd_tgt),
                .i_upd_cond(bht_upd_valid)       // commit's history-table strobe: the same retirement, a conditional
            );
        end else begin : g_nobtb
            assign btb_hit = 1'b0;
            assign btb_off = 2'b0;
            assign btb_x   = 1'b0;
            assign btb_tgt = 64'b0;
        end
    endgenerate

    // (O3) a recovery at execute: the kill cycle and the mispredicted branch's tag (x_q, below); the frontend (align,
    // the instruction queue, decode) is flushed by it as by a redirect from commit
    logic                    xr_kill;
    logic [QV_ROB_TAG_W-1:0] xr_kill_tag;
    logic [63:0]             xr_pc;
    logic                    x_cap;          // a mispredict written back this cycle is caught for recovery
    logic                    xr_fe;          // fetch restarts for it: in the kill cycle, or with XR_EARLY in x_cap's
    logic [63:0]             xr_fe_pc;
    wire                     fe_flush = flush || xr_fe;

    assign fetch_redirect    = redirect_valid || xr_fe || fe_redirect_valid;
    assign fetch_redirect_pc = redirect_valid ? redirect_pc : xr_fe ? xr_fe_pc : fe_redirect_pc;

    // ---------------- the return-address stack ----------------
    logic        ras_has1, ras_push, ras_pop;
    logic [1:0]  ras_op0, ras_op1;
    logic [63:0] ras_addr0, ras_addr1, ras_top, ras_c_addr;
    ras_snap_t   ras_snap0, ras_snap1, kill_snap;   // (O3) the stack after the aligner's ops; the branch's at a kill
    generate
        if (RAS_DEPTH > 0) begin : g_ras
            qv_ras #(.DEPTH(RAS_DEPTH), .REPAIR(RAS_REPAIR)) ras0 (
                .clk(clk), .rst(rst),
                .i_sp_op0(ras_op0), .i_sp_addr0(ras_addr0), .i_sp_op1(ras_op1), .i_sp_addr1(ras_addr1),
                .i_cm_push(ras_push), .i_cm_addr(ras_c_addr), .i_cm_pop(ras_pop), .i_flush(flush),
                .o_top(ras_top), .o_has1(ras_has1),
                .o_snap0(ras_snap0), .o_snap1(ras_snap1), .i_restore(xr_kill), .i_restore_snap(kill_snap)
            );
        end else begin : g_noras
            assign ras_top   = 64'b0;
            assign ras_has1  = 1'b0;
            assign ras_snap0 = '0;
            assign ras_snap1 = '0;
        end
    endgenerate

    // ---------------- the branch history table ----------------
    logic [63:0] bht_base, bht_ppc;
    logic [3:0]  bht_known, bht_taken;
    logic        bht_pknown, bht_ptaken, bht_upd_taken;
    logic [63:0] bht_base1;                  // (O8b) the window's second dword
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0]  bht_known1, bht_taken1;     // (read only with ALIGN_WIN)
    /* verilator lint_on UNUSEDSIGNAL */
    generate
        if (BHT_ENTRIES > 0) begin : g_bht
            qv_bht #(.ENTRIES(BHT_ENTRIES)) bht0 (
                .clk(clk), .rst(rst),
                .i_base_pc(bht_base), .i_pend_pc(bht_ppc),
                .o_known(bht_known), .o_taken(bht_taken), .o_pend_known(bht_pknown), .o_pend_taken(bht_ptaken),
                .i_base1_pc(bht_base1), .o_known1(bht_known1), .o_taken1(bht_taken1),
                .i_upd_valid(bht_upd_valid), .i_upd_pc(btb_upd_pc), .i_upd_taken(bht_upd_taken)
            );
        end else begin : g_nobht
            assign bht_known  = 4'b0;
            assign bht_taken  = 4'b0;
            assign bht_pknown = 1'b0;
            assign bht_ptaken = 1'b0;
            assign bht_known1 = 4'b0;
            assign bht_taken1 = 4'b0;
        end
    endgenerate

    // (O8a) the direction the aligner gets: gshare's where its counter is trained, the history table's where not
    localparam bit GS_ON = (GSHARE_H > 0) && (BHT_ENTRIES > 0) && ALIGN_WIN;
    logic [3:0]  dir_known, dir_taken;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0]  dir_known1, dir_taken1;     // (read only with ALIGN_WIN)
    /* verilator lint_on UNUSEDSIGNAL */
    logic        dir_pknown, dir_ptaken;

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
    logic         iq1_valid, iq_pop2;          // O4c: the entry behind the IQ head, and a second pop
    logic [FE_W-1:0] iq1_bits;
    /* verilator lint_off UNUSEDSIGNAL */
    fe_instr_t    iq_head1;                    // (read only with DISPATCH_W 2)
    /* verilator lint_on UNUSEDSIGNAL */
    assign iq_head1 = iq1_bits;

    generate
        if (ALIGN_WIN) begin : g_win
            qv_align2 #(.ONE_OK(FETCH_STREAM), .ONE_COND(GS_ON)) align0 (
                .clk(clk), .rst(rst), .i_flush(fe_flush),
                .i_buf_valid(fb_valid), .i_buf_pc(fb_pc), .i_buf_data(fb_data), .i_buf_err(fb_err),
                .i_buf_cause(fb_cause), .i_buf_xl(fb_xl), .i_buf_pg(fb_pg),
                .i_buf_hint(fb_hint), .i_buf_hoff(fb_hoff), .i_buf_hx(fb_hx), .i_buf_htgt(fb_htgt),
                .o_buf_pop(fb_pop),
                .i_buf1_valid(fb1_valid), .i_buf1_pc(fb1_pc), .i_buf1_data(fb1_data), .i_buf1_err(fb1_err),
                .i_buf1_xl(fb1_xl), .i_buf1_pg(fb1_pg), .i_buf1_hint(fb1_hint), .i_buf1_hoff(fb1_hoff),
                .i_buf1_hx(fb1_hx), .i_buf1_htgt(fb1_htgt), .o_buf_pop2(fb_pop2),
                .o_bht_base(bht_base), .o_bht_base1(bht_base1), .o_bht_ppc(bht_ppc),
                .i_bht_known(dir_known), .i_bht_taken(dir_taken), .i_bht_known1(dir_known1),
                .i_bht_taken1(dir_taken1), .i_bht_pknown(dir_pknown), .i_bht_ptaken(dir_ptaken),
                .i_ras_top(ras_top), .i_ras_has1(ras_has1),
                .o_ras_op0(ras_op0), .o_ras_addr0(ras_addr0), .o_ras_op1(ras_op1), .o_ras_addr1(ras_addr1),
                .o_push0_valid(a0_valid), .o_push0_data(a0_data),
                .o_push1_valid(a1_valid), .o_push1_data(a1_data),
                .i_push_ready(iq_push_ready), .i_push_ready1(iq_push_ready1),
                .o_redirect_valid(fe_redirect_valid), .o_redirect_pc(fe_redirect_pc)
            );
        end else begin : g_align
            qv_align #(.ONE_OK(FETCH_STREAM)) align0 (
                .clk(clk), .rst(rst), .i_flush(fe_flush),
                .i_buf_valid(fb_valid), .i_buf_pc(fb_pc), .i_buf_data(fb_data), .i_buf_err(fb_err),
                .i_buf_cause(fb_cause), .i_buf_xl(fb_xl), .i_buf_pg(fb_pg),
                .i_buf_hint(fb_hint), .i_buf_hoff(fb_hoff), .i_buf_hx(fb_hx), .i_buf_htgt(fb_htgt),
                .o_buf_pop(fb_pop),
                .o_bht_base(bht_base), .o_bht_ppc(bht_ppc),
                .i_bht_known(dir_known), .i_bht_taken(dir_taken), .i_bht_pknown(dir_pknown), .i_bht_ptaken(dir_ptaken),
                .i_ras_top(ras_top), .i_ras_has1(ras_has1),
                .o_ras_op0(ras_op0), .o_ras_addr0(ras_addr0), .o_ras_op1(ras_op1), .o_ras_addr1(ras_addr1),
                .o_push0_valid(a0_valid), .o_push0_data(a0_data),
                .o_push1_valid(a1_valid), .o_push1_data(a1_data),
                .i_push_ready(iq_push_ready), .i_push_ready1(iq_push_ready1),
                .o_redirect_valid(fe_redirect_valid), .o_redirect_pc(fe_redirect_pc)
            );
            assign fb_pop2   = 1'b0;
            assign bht_base1 = 64'b0;
        end
    endgenerate

    // While halted the instruction queue is fed by the Program Buffer injector (nothing comes from fetch then):
    // a 32-bit word at the architectural pc, no fault, no prediction.
    always_comb begin
        inj_data      = '0;
        inj_data.pc   = arch_pc;
        inj_data.raw  = i_progbuf_data;
    end
    // (O8a) the global history: the conditional branch the aligner sends out this cycle (one at most, ONE_COND)
    // shifts in its predicted direction; each instruction carries the history from before it. A branch predicted
    // taken to its own fall-through address counts as not taken: it lands at pc + its length either way, so it never
    // mispredicts (nothing would put the history back), and commit trains it as not taken (by its next pc).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic gs_dir(input fe_instr_t i);
        return i.pred_taken && (i.pred_tgt != i.pc + (i.rvc ? 64'd2 : 64'd4));
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    wire         gs_cond0 = GS_ON && a0_valid && qv_is_cond(a0_data.raw);
    wire         gs_cond1 = GS_ON && a1_valid && qv_is_cond(a1_data.raw);
    wire         gs_pred0 = gs_dir(a0_data);
    wire         gs_pred1 = gs_dir(a1_data);
    logic [11:0] gs_hist0, gs_hist1;           // the history before slot 0's instruction, before slot 1's
    generate
        if (GS_ON) begin : g_gs
            logic [3:0]          gs_known, gs_taken, gs_known1, gs_taken1;
            logic                gs_pknown, gs_ptaken;
            logic [GSHARE_H-1:0] gs_h, gs_hc;
            qv_gshare #(.H(GSHARE_H), .BITS(GSHARE_BITS)) gs0 (
                .clk(clk), .rst(rst),
                .i_base_pc(bht_base), .i_base1_pc(bht_base1), .i_pend_pc(bht_ppc),
                .o_known(gs_known), .o_taken(gs_taken), .o_known1(gs_known1), .o_taken1(gs_taken1),
                .o_pend_known(gs_pknown), .o_pend_taken(gs_ptaken), .o_hist(gs_h),
                .i_cond(gs_cond0 || gs_cond1), .i_pred(gs_cond0 ? gs_pred0 : gs_pred1),
                .i_flush(flush), .i_restore(xr_kill), .i_restore_h(kill_snap.gh[GSHARE_H-1:0]),
                .i_restore_cond(kill_snap.gc), .i_restore_pred(kill_snap.gp),
                .i_upd_valid(bht_upd_valid), .i_upd_pc(btb_upd_pc), .i_upd_taken(bht_upd_taken), .o_hist_c(gs_hc)
            );
            /* verilator lint_off UNUSEDSIGNAL */
            wire [GSHARE_H:0] gs_sh0 = {gs_h, gs_pred0};               // (its top bit shifts out)
            /* verilator lint_on UNUSEDSIGNAL */
            assign gs_hist0   = 12'(gs_h);
            assign gs_hist1   = gs_cond0 ? 12'(gs_sh0[GSHARE_H-1:0]) : 12'(gs_h);
            assign dir_known  = gs_known | bht_known;
            assign dir_taken  = (gs_known & gs_taken) | (~gs_known & bht_taken);
            assign dir_known1 = gs_known1 | bht_known1;
            assign dir_taken1 = (gs_known1 & gs_taken1) | (~gs_known1 & bht_taken1);
            assign dir_pknown = gs_pknown | bht_pknown;
            assign dir_ptaken = gs_pknown ? gs_ptaken : bht_ptaken;
        end else begin : g_nogs
            assign gs_hist0   = '0;
            assign gs_hist1   = '0;
            assign dir_known  = bht_known;
            assign dir_taken  = bht_taken;
            assign dir_known1 = bht_known1;
            assign dir_taken1 = bht_taken1;
            assign dir_pknown = bht_pknown;
            assign dir_ptaken = bht_ptaken;
        end
    endgenerate
`ifndef SYNTHESIS
    initial if (GSHARE_H > 0 && !GS_ON) $fatal(1, "core: qv_gshare (GSHARE_H) needs the window aligner and the history table");
`endif

    // (O3) each instruction the aligner emits carries the return-address stack as it left it, (O8a) and the history
    fe_instr_t    a0_snapd, a1_snapd;
    always_comb begin
        a0_snapd             = a0_data;
        a0_snapd.ras_snap    = ras_snap0;
        a0_snapd.ras_snap.gh = gs_hist0;
        a0_snapd.ras_snap.gc = gs_cond0;
        a0_snapd.ras_snap.gp = gs_cond0 && gs_pred0;
        a1_snapd             = a1_data;
        a1_snapd.ras_snap    = ras_snap1;
        a1_snapd.ras_snap.gh = gs_hist1;
        a1_snapd.ras_snap.gc = gs_cond1;
        a1_snapd.ras_snap.gp = gs_cond1 && gs_pred1;
    end
    assign p0_valid = dbg_in_debug ? inj_valid : a0_valid;
    assign p0_data  = dbg_in_debug ? inj_data  : a0_snapd;
    assign p1_valid = dbg_in_debug ? 1'b0      : a1_valid;
    assign p1_data  = a1_snapd;

    qv_fifo #(.WIDTH(FE_W), .DEPTH(IQ_DEPTH)) iq0 (
        .clk(clk), .rst(rst), .i_flush(fe_flush),
        .i_push0_valid(p0_valid), .i_push0_data(p0_data),
        .i_push1_valid(p1_valid), .i_push1_data(p1_data),
        .o_push_ready(iq_push_ready), .o_push_ready1(iq_push_ready1),
        .o_head_valid(iq_valid), .o_head_data(iq_bits),
        .i_pop(iq_pop),
        .o_head1_valid(iq1_valid), .o_head1_data(iq1_bits), .i_pop2(iq_pop2)
    );

    // ---------------- D: decode ----------------
    logic uop_valid, issue_fire;
    uop_t uop;
    logic uop1_valid, issue_fire2;            // O4c: the second decoded uop, and its dispatch
    uop_t uop1;

    generate
        if (DISPATCH_W > 1) begin : g_dec2
            qv_decode2 #(.CSR_NOSER(CSR_NOSER), .FPU_EN(FPU_EN), .ZICNTR_EN(ZICNTR_EN)) decode0 (
                .clk(clk), .rst(rst), .i_flush(fe_flush),
                .i_fs(mstatus_fs_w), .i_frm(frm_w),
                .i_mcounteren(mcounteren_w), .i_scounteren(scounteren_w),
                .i_priv(priv), .i_tsr(mstatus_tsr_w), .i_tvm(mstatus_tvm_w), .i_in_debug(dbg_in_debug),
                .i_pb_active(pb_active),
                .i_tdata1_0(tdata1_0_w), .i_tdata2_0(tdata2_0_w), .i_tdata1_1(tdata1_1_w), .i_tdata2_1(tdata2_1_w),
                .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
                .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
                .i_iq_valid(iq_valid), .i_iq_data(iq_head), .i_iq1_valid(iq1_valid), .i_iq1_data(iq_head1),
                .o_iq_pop(iq_pop), .o_iq_pop2(iq_pop2),
                .o_valid(uop_valid), .o_uop(uop), .o_valid1(uop1_valid), .o_uop1(uop1),
                .i_issue_n(issue_fire2 ? 2'd2 : issue_fire ? 2'd1 : 2'd0)
            );
        end else begin : g_dec1
            qv_decode #(.CSR_NOSER(CSR_NOSER), .FPU_EN(FPU_EN), .ZICNTR_EN(ZICNTR_EN)) decode0 (
                .clk(clk), .rst(rst), .i_flush(fe_flush),
                .i_fs(mstatus_fs_w), .i_frm(frm_w),
                .i_mcounteren(mcounteren_w), .i_scounteren(scounteren_w),
                .i_priv(priv), .i_tsr(mstatus_tsr_w), .i_tvm(mstatus_tvm_w), .i_in_debug(dbg_in_debug), .i_pb_active(pb_active),
                .i_tdata1_0(tdata1_0_w), .i_tdata2_0(tdata2_0_w), .i_tdata1_1(tdata1_1_w), .i_tdata2_1(tdata2_1_w),
                .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
                .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
                .i_iq_valid(iq_valid), .i_iq_data(iq_head), .o_iq_pop(iq_pop),
                .o_valid(uop_valid), .o_uop(uop), .i_issue_ready(issue_fire)
            );
            assign iq_pop2    = 1'b0;
            assign uop1_valid = 1'b0;
            assign uop1       = '0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire   dec1_unused = iq1_valid || (|iq1_bits) || issue_fire2;
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ---------------- I: issue ----------------
    logic [4:0]              rs1_sel, rs2_sel;
    logic [63:0]             rs1_data, rs2_data;
    logic                    alloc_valid, alloc_rd_wen, alloc_ready, rob_empty;
    logic [(1<<QV_ROB_TAG_W)-1:0] kill_vec;  // (O3) the tags a recovery at execute kills (all 0 until it is wired)
    // (O3) the ROB entries a recovery at execute (xr_kill, above) leaves, from which issue rebuilds its producer tables
    logic [QV_ROB_DEPTH-1:0]                   surv_live, surv_int, surv_fp, surv_csr;
    logic [QV_ROB_DEPTH-1:0][QV_ROB_TAG_W-1:0] surv_tag;
    logic [QV_ROB_DEPTH-1:0][4:0]              surv_rd;
    logic [63:0]             alloc_pc, alloc_next_pc;
    logic [31:0]             alloc_raw;
    logic [4:0]              alloc_rd;
    rob_ctrl_t               alloc_ctrl;
    logic [QV_ROB_TAG_W-1:0] alloc_tag, l1_tag, l2_tag;
    logic                    l1_complete, l2_complete;
    logic [63:0]             l1_value, l2_value;
    wb_t                     wb_bus;
    wb_t                     wbp_bus;                 // (O4d) the second ALU port's writeback ('0 without it)
    fu_req_t                 alu_req, bru_req, lsu_req, div_req;
    /* verilator lint_off UNUSEDSIGNAL */
    fu_req_t                 alu1_req;                // (O4d) the second ALU port's request (unread with one port)
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */
    rs_opnd_t                lsu_opa, lsu_opb;     // the dispatching uop's operands, as issue resolved them (the queue reads a memory op's, O1c)
    /* verilator lint_on UNUSEDSIGNAL */
    logic                    lsu_free, div_free;
    // O4c: slot 1's register reads, ROB lookups and allocation; both slots' operands (RVFI)
    logic [4:0]              rs1b_sel, rs2b_sel;
    logic [63:0]             rs1b_data, rs2b_data;
    logic [QV_ROB_TAG_W-1:0] l4_tag, l5_tag, alloc_tag1;
    logic                    l4_complete, l5_complete, alloc_ready2;
    logic [63:0]             l4_value, l5_value;
    logic                    alloc2_valid, alloc2_rd_wen;
    logic [63:0]             alloc2_pc, alloc2_next_pc;
    logic [31:0]             alloc2_raw;
    logic [4:0]              alloc2_rd;
    rob_ctrl_t               alloc2_ctrl;
    /* verilator lint_off UNUSEDSIGNAL */
    rs_opnd_t                src0_a, src0_b, src1_a, src1_b;   // read only by the RISCV_FORMAL block
    /* verilator lint_on UNUSEDSIGNAL */
    logic                    res_valid;      // the LR/SC reservation, kept by commit
    logic [63:0]             res_addr;
    logic                    c_valid, c_rd_wen, c_rd_fp;
    logic [4:0]              c_rd;
    logic [QV_ROB_TAG_W-1:0] c_tag;
    logic                    c2_valid, c2_rd_wen, c2_rd_fp;   // O4: the second retirement of a pair
    logic [4:0]              c2_rd;
    logic [QV_ROB_TAG_W-1:0] c2_tag;
    // F/D: the FP register file's read ports (issue), the third ROB lookup, the FPU's request and writeback
    logic [4:0]              frs1_sel, frs2_sel, frs3_sel;
    logic [63:0]             frs1_data, frs2_data, frs3_data;
    logic [QV_ROB_TAG_W-1:0] l3_tag;
    logic                    l3_complete;
    logic [63:0]             l3_value;
    /* verilator lint_off UNUSEDSIGNAL */
    fpu_req_t                fpu_req;        // (unused without the FPU)
    /* verilator lint_on UNUSEDSIGNAL */
    wb_fp_t                  fpu_wb;
    logic                    fpu_ds_free;

    // slow-unit outputs, declared ahead of issue (the LSU's writeback is a bypass source, O2d), the ROB and commit
    wb_t      lsu_wb, div_wb;
    wb_t      c_bus;                       // commit's regfile write, with the committing tag: wakes the station's late operands
    qv_issue #(.SERIALIZE(SERIALIZE), .BYPASS_EN(BYPASS_EN), .CSR_LATE(CSR_NOSER),
               .LSU_BYPASS(LSQ_DEPTH > 0 && LSQ_BYPASS), .RS_DEPTH(RS_DEPTH),
               .LSQ_WAIT(RS_DEPTH > 0 && LSQ_DEPTH > 0 && LSQ_WAIT), .DISPATCH_W(DISPATCH_W),
               .ALU_PORTS(ALU_PORTS)) issue0 (
        .clk(clk), .rst(rst), .i_flush(flush), .i_kill_vec(kill_vec),
        .i_kill(xr_kill), .i_surv_live(surv_live), .i_surv_tag(surv_tag), .i_surv_rd(surv_rd),
        .i_surv_int(surv_int), .i_surv_fp(surv_fp), .i_surv_csr(surv_csr),
        .o_alu1_req(alu1_req), .i_wbp(wbp_bus),
        .i_uop_valid(uop_valid && !xr_kill), .i_uop(uop), .o_issue(issue_fire),
        .i_uop1_valid(uop1_valid && !xr_kill), .i_uop1(uop1), .i_pb_active(pb_active), .o_issue2(issue_fire2),
        .o_rs1b_sel(rs1b_sel), .o_rs2b_sel(rs2b_sel), .i_rs1b_data(rs1b_data), .i_rs2b_data(rs2b_data),
        .o_lookup4_tag(l4_tag), .i_lookup4_complete(l4_complete), .i_lookup4_value(l4_value),
        .o_lookup5_tag(l5_tag), .i_lookup5_complete(l5_complete), .i_lookup5_value(l5_value),
        .o_alloc2_valid(alloc2_valid), .o_alloc2_pc(alloc2_pc), .o_alloc2_raw(alloc2_raw), .o_alloc2_rd(alloc2_rd),
        .o_alloc2_rd_wen(alloc2_rd_wen), .o_alloc2_next_pc(alloc2_next_pc), .o_alloc2_ctrl(alloc2_ctrl),
        .i_alloc_tag1(alloc_tag1), .i_alloc_ready2(alloc_ready2),
        .o_src0_a(src0_a), .o_src0_b(src0_b), .o_src1_a(src1_a), .o_src1_b(src1_b),
        .o_rs1_sel(rs1_sel), .o_rs2_sel(rs2_sel), .i_rs1_data(rs1_data), .i_rs2_data(rs2_data),
        .o_alloc_valid(alloc_valid), .o_alloc_pc(alloc_pc), .o_alloc_raw(alloc_raw),
        .o_alloc_rd(alloc_rd), .o_alloc_rd_wen(alloc_rd_wen), .o_alloc_next_pc(alloc_next_pc),
        .o_alloc_ctrl(alloc_ctrl),
        .i_alloc_tag(alloc_tag), .i_alloc_ready(alloc_ready),
        .i_rob_empty(rob_empty),
        .o_lookup1_tag(l1_tag), .i_lookup1_complete(l1_complete), .i_lookup1_value(l1_value),
        .o_lookup2_tag(l2_tag), .i_lookup2_complete(l2_complete), .i_lookup2_value(l2_value),
        .i_wb(wb_bus), .o_alu_req(alu_req), .o_bru_req(bru_req),
        .o_lsu_req(lsu_req), .o_lsu_opa(lsu_opa), .o_lsu_opb(lsu_opb), .i_lsu_free(lsu_free),
        .o_div_req(div_req), .i_div_free(div_free),
        .o_lookup3_tag(l3_tag), .i_lookup3_complete(l3_complete), .i_lookup3_value(l3_value),
        .o_frs1_sel(frs1_sel), .o_frs2_sel(frs2_sel), .o_frs3_sel(frs3_sel),
        .i_frs1_data(frs1_data), .i_frs2_data(frs2_data), .i_frs3_data(frs3_data),
        .i_wbf(fpu_wb), .o_fpu_req(fpu_req), .i_fpu_ds_free(fpu_ds_free), .i_wbl(lsu_wb),
        .i_commit_valid(c_valid), .i_commit_rd(c_rd), .i_commit_rd_wen(c_rd_wen), .i_commit_rd_fp(c_rd_fp),
        .i_commit_tag(c_tag), .i_wbd(div_wb), .i_wbc(c_bus),
        .i_commit2_valid(c2_valid), .i_commit2_rd(c2_rd), .i_commit2_rd_wen(c2_rd_wen), .i_commit2_rd_fp(c2_rd_fp),
        .i_commit2_tag(c2_tag)
    );

    lsu_res_t lsu_res;                     // the result of the memory op at the ROB head (commit, RVFI, the store buffer)
    lsu_res_t lsq_res0, lsq_res1;          // (with the queue) its oldest entry's result, and the one behind it
    lsu_res_t lsu_res1;                    // (O4) the second retirement's, when it is a memory op
    logic     c_sfence;                    // commit: an SFENCE.VMA retires, empty the TLBs

    // ---------------- ROB ----------------
    logic                    head_valid, commit_pop, commit_pop2;
    rob_entry_t              head_entry;
    logic [QV_ROB_TAG_W-1:0] head_tag;
    rob_ctrl_t               head_ctrl;
    logic                    head1_valid;   // O4: the entry behind the head
    rob_entry_t              head1_entry;
    logic [QV_ROB_TAG_W-1:0] head1_tag;
    rob_ctrl_t               head1_ctrl;

    qv_rob #(.ROB_DEPTH(ROB_DEPTH)) rob0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_alloc_valid(alloc_valid), .i_alloc_pc(alloc_pc), .i_alloc_raw(alloc_raw),
        .i_alloc_rd(alloc_rd), .i_alloc_rd_wen(alloc_rd_wen), .i_alloc_next_pc(alloc_next_pc),
        .i_alloc_ctrl(alloc_ctrl),
        .o_alloc_tag(alloc_tag), .o_alloc_ready(alloc_ready),
        .i_alloc2_valid(alloc2_valid), .i_alloc2_pc(alloc2_pc), .i_alloc2_raw(alloc2_raw), .i_alloc2_rd(alloc2_rd),
        .i_alloc2_rd_wen(alloc2_rd_wen), .i_alloc2_next_pc(alloc2_next_pc), .i_alloc2_ctrl(alloc2_ctrl),
        .o_alloc_tag1(alloc_tag1), .o_alloc_ready2(alloc_ready2),
        .i_lookup4_tag(l4_tag), .o_lookup4_complete(l4_complete), .o_lookup4_value(l4_value),
        .i_lookup5_tag(l5_tag), .o_lookup5_complete(l5_complete), .o_lookup5_value(l5_value),
        .o_empty(rob_empty), .i_wb(wb_bus), .i_wb2(lsu_wb), .i_wb3(div_wb),
        .i_lookup1_tag(l1_tag), .o_lookup1_complete(l1_complete), .o_lookup1_value(l1_value),
        .i_lookup2_tag(l2_tag), .o_lookup2_complete(l2_complete), .o_lookup2_value(l2_value),
        .i_wb4(fpu_wb), .i_wb5(wbp_bus),
        .i_lookup3_tag(l3_tag), .o_lookup3_complete(l3_complete), .o_lookup3_value(l3_value),
        .o_head_valid(head_valid), .o_head_entry(head_entry), .o_head_tag(head_tag),
        .o_head_ctrl(head_ctrl), .i_commit_pop(commit_pop),
        .o_head1_valid(head1_valid), .o_head1_entry(head1_entry), .o_head1_tag(head1_tag),
        .o_head1_ctrl(head1_ctrl), .i_commit_pop2(commit_pop2),
        .i_kill(xr_kill), .i_kill_tag(xr_kill_tag), .o_kill_vec(kill_vec), .i_wb_recover(x_cap),
        .o_surv_live(surv_live), .o_surv_tag(surv_tag), .o_surv_rd(surv_rd),
        .o_surv_int(surv_int), .o_surv_fp(surv_fp), .o_surv_csr(surv_csr),
        .i_alloc_snap(uop.ras_snap), .i_alloc2_snap(uop1.ras_snap), .o_kill_snap(kill_snap)
    );

    // ---------------- X: ALU, BRU -> writeback bus ----------------
    wb_t alu_wb, bru_wb;
    qv_exu_alu exu_alu0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(alu_req), .i_kill_vec(kill_vec), .o_wb(alu_wb));
    // (O4d) the second ALU port: no multiplier and no branches (issue sends it neither), its own writeback bus
    generate
        if (ALU_PORTS > 1) begin : g_alu1
            qv_exu_alu #(.HAS_MUL(1'b0)) exu_alu1 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(alu1_req),
                                                   .i_kill_vec(kill_vec), .o_wb(wbp_bus));
        end else begin : g_noalu1
            assign wbp_bus = '0;
        end
    endgenerate
    qv_exu_bru exu_bru0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(bru_req), .i_kill_vec(kill_vec), .o_wb(bru_wb));

    // Both units take one cycle and issue sends at most one uop per
    // cycle, so at most one result is ever valid. The multi-cycle units
    // (LSU, divider) each have a writeback port of their own into the ROB
    // instead, so they never contend for this one.
    assign wb_bus = bru_wb.valid ? bru_wb : alu_wb;

    // ---------------- (O3) recovery at execute ----------------
    // A branch that writes back a mispredict (the BRU's port; outside a Program Buffer run, which keeps the commit
    // redirect) is caught in x_q. The next cycle is the kill cycle: everything younger than it is killed (the ROB's
    // tail goes back to the entry after it; the units, the station, the queue and the LSU drop the killed tags; issue
    // rebuilds its producer tables; the return-address stack goes back to the branch's snapshot), nothing is
    // dispatched, and the frontend restarts at the resolved target. A redirect from commit in either cycle wins: it
    // flushes everything, the branch included. An older branch resolving in a kill cycle survives it and is caught
    // for the next (its kill is a superset); a younger one's writeback is masked by the kill.
    assign x_cap = EXEC_REDIRECT && wb_bus.valid && wb_bus.mispredict && !pb_active && !flush;
    logic                    x_q_valid;
    logic [QV_ROB_TAG_W-1:0] x_q_tag;
    logic [63:0]             x_q_pc;
    always_ff @(posedge clk) begin
        if (rst) begin
            x_q_valid <= 1'b0;
            x_q_tag   <= '0;
            x_q_pc    <= 64'b0;
        end else begin
            x_q_valid <= x_cap;
            if (x_cap) begin
                x_q_tag <= wb_bus.tag;
                x_q_pc  <= wb_bus.next_pc;
            end
        end
    end
    assign xr_kill     = x_q_valid && !flush;
    assign xr_kill_tag = x_q_tag;
    assign xr_pc       = x_q_pc;
    // (D7) with XR_EARLY the frontend restarts at the resolved target in the writeback cycle itself (x_cap: never with
    // a redirect from commit, and a younger branch's writeback is masked in an older one's kill cycle, so it is the
    // oldest mispredict resolving); the kill cycle then leaves fetch alone (the new path reaches the aligner two
    // cycles later, after the return-address stack is restored)
    assign xr_fe    = XR_EARLY ? x_cap : xr_kill;
    assign xr_fe_pc = XR_EARLY ? wb_bus.next_pc : xr_pc;

    // ---------------- X: divider -> slow writeback port ----------------
    // Like the LSU, no bypass: a dependent reads the ROB the next cycle.
    // Every flush kills a divide in flight.
    qv_exu_div exu_div0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(div_req), .i_kill_vec(kill_vec), .o_free(div_free),
                         .o_wb(div_wb));

    // ---------------- X: FPU -> its own writeback port and the bypass ----------------
    // A 4-cycle pipeline for everything but divide and square root, which run one at a time beside it (issue waits
    // for fpu_ds_free). Every flush kills both.
    generate
        if (FPU_EN) begin : g_fpu
            qv_exu_fpu fpu0 (.clk(clk), .rst(rst), .i_flush(flush), .i_req(fpu_req), .i_kill_vec(kill_vec),
                             .o_ds_free(fpu_ds_free), .o_wb(fpu_wb));
        end else begin : g_no_fpu
            assign fpu_ds_free = 1'b1;
            assign fpu_wb      = '0;
        end
    endgenerate

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
    // (O5a) the D$'s refill is the fourth master: the LSU asks for it only when the port is free, and it holds the
    // port for the whole line (the others wait while dc_busy)
    localparam bit DC_ON = DCACHE && (PMA_RAM_SIZE != 64'd0);
    logic        dc_busy, dc_hit, dc_cyc, dc_fill_req, dc_fill, dc_fill_err, dc_inv;
    logic [63:0] dc_dat, dc_fill_dat;
    logic [31:3] dc_addr;
    assign fetch_yield = FETCH_YIELD && (lsu_bus_busy || sb_beat || sb_go_idle || ptw_wants || dc_busy);
    // On a shared bus a translated fetch uses the port in two of every three cycles: its translation phase is the
    // gap. A store that retires at once lets the load behind it reach the ROB head a cycle earlier, and the load's
    // access can then start in the very cycle fetch's request begins its bus beat; the memory port wins that tie
    // and fetch waits out the whole access. The LSU gives way for that one cycle (the access then starts in fetch's
    // response cycle and fetch waits one cycle, not two). Only with the store buffer, so that without it the timing
    // is the one of P8; never with a private fetch path (FETCH_YIELD 0).
    logic fetch_start_q;
    always_ff @(posedge clk) fetch_start_q <= !rst && FETCH_YIELD && (SB_DEPTH > 0) && f_xl_req && f_xl_done && !f_xl_cancel;
    assign wb_mem_addr_o = dc_busy ? {dc_addr, 3'b000} : sb_beat ? sb_addr : ptw_beat ? ptw_addr : lsu_addr;
    assign wb_mem_dat_o  = sb_beat ? sb_dat : lsu_dat;
    assign wb_mem_sel_o  = dc_busy ? 8'hFF : sb_beat ? sb_sel : ptw_beat ? 8'hFF : lsu_sel;
    assign wb_mem_we_o   = dc_busy ? 1'b0 : sb_beat ? 1'b1 : ptw_beat ? 1'b0 : lsu_we;
    assign wb_mem_cyc_o  = dc_busy ? dc_cyc : sb_beat ? sb_cyc : ptw_beat ? ptw_cyc : lsu_cyc;
    assign wb_mem_stb_o  = wb_mem_cyc_o;
    assign wb_mem_lock_o = (dc_busy || sb_beat || ptw_beat) ? 1'b0 : lsu_lock;
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
    logic        x_nowalk;                   // the request is a lookup only (before the head)
    // the port is the LSU's when it asks (lx_*), else the load/store queue's lookup of its oldest queued op (qx_*)
    logic        lx_req, lx_wr, lx_nowalk, qx_req, qx_wr;
    logic [63:0] lx_va, qx_va;
    assign x_req    = lx_req || qx_req;
    assign x_va     = lx_req ? lx_va : qx_va;
    assign x_wr     = lx_req ? lx_wr : qx_wr;
    assign x_nowalk = lx_req ? lx_nowalk : 1'b1;

    // The LSU's writeback reaches issue's bypass only with LSQ_BYPASS (O2d); without it a dependent reads the ROB the
    // next cycle, which keeps wb_mem_dat_i out of issue's combinational paths.
    // With the load/store queue, issue dispatches into the queue and the queue hands lsu0 one op at a time (eng_*);
    // without it, issue talks to lsu0 directly.
    fu_req_t  eng_req;
    logic     eng_free, eng_take;
    logic     eng_xl;                       // (the queue) eng_req comes translated, to eng_ppn
    logic [43:0] eng_ppn;
    lsu_res_t eng_res;
    logic     lsq_early, lsq_match;         // (the queue) no barrier is older than lsu0's op; a posted store matches
    qv_lsu #(.SB_EN(SB_DEPTH > 0), .PMA_RAM_BASE(PMA_RAM_BASE), .PMA_RAM_SIZE(PMA_RAM_SIZE),
             .PROBE(SV39_EN && DTLB_PROBE), .EARLY(LSQ_DEPTH > 0 && LSQ_EARLY), .EARLY_ST(LSQ_EARLY_ST),
             .HANDOFF(LSQ_DEPTH > 0 && LSQ_HANDOFF), .DC_EN(DC_ON), .ROB_DEPTH(ROB_DEPTH)) lsu0 (
        .i_kill_vec(kill_vec),
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(eng_req), .o_free(eng_free),
        .i_head_valid(head_valid), .i_head_tag(head_tag), .i_early(lsq_early),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_priv(priv), .i_mprv(mstatus_mprv_w), .i_mpp(mstatus_mpp_w), .i_pmp_bypass(pb_active),
        .i_pmpcfg0(pmpcfg0_w), .i_pmpaddr0(pmpaddr0_w), .i_pmpaddr1(pmpaddr1_w),
        .i_pmpaddr2(pmpaddr2_w), .i_pmpaddr3(pmpaddr3_w),
        .wb_mem_addr_o(lsu_addr), .wb_mem_dat_o(lsu_dat), .wb_mem_sel_o(lsu_sel),
        .wb_mem_we_o(lsu_we), .wb_mem_cyc_o(lsu_cyc), .wb_mem_stb_o(lsu_stb),
        .wb_mem_lock_o(lsu_lock),
        .wb_mem_dat_i(wb_mem_dat_i), .wb_mem_ack_i(wb_mem_ack_i), .wb_mem_err_i(wb_mem_err_i),
        .o_wb(lsu_wb), .o_res(eng_res),
        .o_head_started(lsu_head_started),
        .i_satp_on(satp_on),
        .o_xl_req(lx_req), .o_xl_va(lx_va), .o_xl_wr(lx_wr), .o_xl_active(x_active), .o_xl_priv(x_priv),
        .o_xl_cancel(x_cancel), .o_xl_nowalk(lx_nowalk), .i_req_xl(eng_xl), .i_req_ppn(eng_ppn),
        .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn),
        .i_ptw_beat(ptw_beat), .o_bus_busy(lsu_bus_busy),
        .i_sb_empty(sb_empty), .i_sb_match(sb_match || lsq_match), .i_sb_beat(sb_beat), .i_sb_go(sb_go_idle), .i_fetch_start(fetch_start_q),
        .o_sb_addr(sb_match_addr), .o_load_near(lsu_load_near), .o_in_bus(lsu_in_bus), .o_take(eng_take),
        .i_dc_hit(dc_hit), .i_dc_dat(dc_dat), .i_dc_busy(dc_busy), .o_dc_fill_req(dc_fill_req),
        .i_dc_fill(dc_fill), .i_dc_fill_dat(dc_fill_dat), .i_dc_fill_err(dc_fill_err), .o_dc_inv(dc_inv)
    );

    // ---------------- the load/store queue ----------------
    // A barrier for the early accesses: a uop that may change what an access may do, or must be ordered before one
    // -- a FENCE (the MISC-MEM opcode, funct3 0), a serializing uop, a system op, one that traps or has a trigger.
    wire alloc_bar = alloc_valid && (alloc_ctrl.serialize || alloc_ctrl.cls == QV_FU_SYS || alloc_ctrl.xcpt
                                     || alloc_ctrl.trig_debug || alloc_ctrl.trig_exc
                                     || (alloc_raw[6:0] == 7'b0001111 && alloc_raw[14:12] == 3'b000));
    generate
        if (LSQ_DEPTH > 0) begin : g_lsq
            qv_lsq #(.DEPTH(LSQ_DEPTH), .PRE_XL(SV39_EN && LSQ_PRE_XL), .XL_FWD(DC_ON), .OPW(RS_DEPTH > 0 && LSQ_WAIT),
                     .BYPASS_EN(BYPASS_EN), .LSU_BYPASS(LSQ_BYPASS)) lsq0 (
                .clk(clk), .rst(rst), .i_flush(flush), .i_kill_vec(kill_vec),
                .i_kill(xr_kill), .i_kill_tag(xr_kill_tag),
                .i_req(lsu_req), .o_free(lsu_free), .i_opa(lsu_opa), .i_opb(lsu_opb),
                .i_wb(wb_bus), .i_wbp(wbp_bus), .i_wbd(div_wb), .i_wbf(fpu_wb), .i_wbc(c_bus),
                .o_eng_req(eng_req), .i_eng_take(eng_take), .i_eng_wb(lsu_wb), .i_eng_res(eng_res),
                .i_pop(commit_pop), .i_pop_tag(head_tag), .o_head_res(lsq_res0),
                .i_pop2(commit_pop2), .i_pop2_tag(head1_tag), .o_head1_res(lsq_res1),
                .i_bar_alloc(alloc_bar), .i_bar_tag(alloc_tag), .o_early(lsq_early),
                .i_match_addr(sb_match_addr), .o_match(lsq_match),
                .o_xl_req(qx_req), .o_xl_va(qx_va), .o_xl_wr(qx_wr), .i_xl_free(!lx_req), .i_xl_active(x_active),
                .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn),
                .o_eng_xl(eng_xl), .o_eng_ppn(eng_ppn)
            );
            // the head's result, and (O4) the second retirement's: the queue's oldest entry when the head is no
            // memory op, the one behind it when it is one
            assign lsu_res  = lsq_res0;
            assign lsu_res1 = (head_ctrl.cls == QV_FU_LSU) ? lsq_res1 : lsq_res0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire   free_unused = eng_free;           // the queue follows the LSU's o_take
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_nolsq
            assign eng_req   = lsu_req;
            assign lsu_free  = eng_free;
            assign lsu_res   = eng_res;
            assign lsu_res1  = eng_res;              // never used: without the queue no memory op retires second
            assign lsq_res0  = '0;
            assign lsq_res1  = '0;
            assign lsq_early = 1'b0;
            assign lsq_match = 1'b0;
            assign qx_req    = 1'b0;
            assign qx_va     = 64'b0;
            assign qx_wr     = 1'b0;
            assign eng_xl    = 1'b0;
            assign eng_ppn   = 44'b0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire   bar_unused = alloc_bar || eng_take;
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ---------------- the store buffer ----------------
    // the store pushed is the head's, or (O4) the second retirement's: a pair posts at most one
    logic     c_sb_push1;
    /* verilator lint_off UNUSEDSIGNAL */
    lsu_res_t sb_push_res;                   // only the address, mask and data are pushed
    /* verilator lint_on UNUSEDSIGNAL */
    assign sb_push_res = c_sb_push1 ? lsu_res1 : lsu_res;
    generate
        if (SB_DEPTH > 0) begin : g_sb
            qv_sb #(.DEPTH(SB_DEPTH), .YIELD_READY(SB_YIELD_READY)) sb0 (
                .clk(clk), .rst(rst),
                .i_push(c_sb_push), .i_push_addr(sb_push_res.mem_addr[31:3]), .i_push_sel(sb_push_res.mem_wmask),
                .i_push_data(sb_push_res.mem_wdata), .o_ready(sb_ready), .o_empty(sb_empty),
                .i_match_addr(sb_match_addr), .o_match(sb_match),
                .i_lsu_busy(lsu_bus_busy), .i_lsu_inflight(lsu_in_bus || dc_busy), .i_ptw_beat(ptw_beat),
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

    // ---------------- the D$ (O5a) ----------------
    // looked up at the LSU's physical dword; updated by the store buffer's beats in their response cycle (the store
    // reached memory), emptied of a line the LSU wrote past the buffer or another master wrote (i_snoop_*)
    generate
        if (DC_ON) begin : g_dc
            qv_dc #(.LINES(DC_LINES), .WORDS(DC_WORDS)) dc0 (
                .clk(clk), .rst(rst),
                .i_addr(sb_match_addr), .o_hit(dc_hit), .o_dat(dc_dat), .o_busy(dc_busy),
                .i_fill_req(dc_fill_req), .o_fill(dc_fill), .o_fill_dat(dc_fill_dat), .o_fill_err(dc_fill_err),
                .i_wr(sb_beat && wb_mem_ack_i && !wb_mem_err_i), .i_wr_addr(sb_addr[31:3]), .i_wr_sel(sb_sel),
                .i_wr_dat(sb_dat),
                .i_inv(dc_inv), .i_inv_addr(sb_match_addr), .i_snoop(i_snoop_valid), .i_snoop_addr(i_snoop_addr),
                .o_beat(dc_cyc), .o_addr(dc_addr), .i_ack(wb_mem_ack_i), .i_err(wb_mem_err_i), .i_dat(wb_mem_dat_i)
            );
            // refills read whole lines: the window must hold whole lines
            initial if ((PMA_RAM_BASE % 64'(DC_WORDS * 8)) != 0 || (PMA_RAM_SIZE % 64'(DC_WORDS * 8)) != 0)
                $fatal(1, "core: the PMA window is not a whole number of D$ lines");
        end else begin : g_nodc
            assign dc_busy     = 1'b0;
            assign dc_hit      = 1'b0;
            assign dc_dat      = 64'b0;
            assign dc_cyc      = 1'b0;
            assign dc_addr     = 29'b0;
            assign dc_fill     = 1'b0;
            assign dc_fill_dat = 64'b0;
            assign dc_fill_err = 1'b0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire   dc_unused = dc_fill_req || dc_inv || i_snoop_valid || (|i_snoop_addr);
            /* verilator lint_on UNUSEDSIGNAL */
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
                .i_lsu_busy(lsu_bus_busy || sb_beat || sb_go || !sb_empty || dc_busy), .o_beat(ptw_beat),
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
    always_comb begin                            // the commit bus (declared ahead of issue)
        c_bus       = '0;
        c_bus.valid = rf_we;
        c_bus.tag   = c_tag;
        c_bus.value = rf_data;
    end
    logic        c_fprf_we;                  // F/D: the FP register write, and fflags' accrual
    logic [4:0]  c_fprf_sel, c_fp_accrue;
    logic [63:0] c_fprf_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        c_frd_wvalid;               // read only by the RISCV_FORMAL port block
    logic [4:0]  c_frd_addr;
    logic [63:0] c_frd_wdata;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        commit_now_w;
    logic [63:0] retire_next_pc;
    logic [4:0]  c_rs1_addr, c_rs2_addr;
    logic [11:0] c_csr_addr;
    logic [63:0] c_csr_wdata, c_trap_cause, c_trap_val;
    logic        c_csr_we, c_instr_retired, c_trap_taken, c_mret_taken, c_irq_taken;
    // read only by the RISCV_FORMAL port block
    /* verilator lint_off UNUSEDSIGNAL */
    logic        c_rvfi_trap;
    logic [63:0] c_order, c_rd_wdata, c_pc_rdata, c_pc_wdata;
    logic [31:0] c_insn;
    logic        c_intr;
    logic [4:0]  c_rd_addr;
    logic [63:0] c_mem_addr, c_mem_rdata, c_mem_wdata;
    logic [7:0]  c_mem_rmask, c_mem_wmask;
    // O4: RVFI channel 1, the second retirement
    logic [63:0] c1_order, c1_rd_wdata, c1_pc_rdata, c1_pc_wdata, c1_mem_addr, c1_mem_rdata, c1_mem_wdata;
    logic [63:0] c1_frd_wdata;
    logic [31:0] c1_insn;
    logic [4:0]  c1_rs1_addr, c1_rs2_addr, c1_rd_addr, c1_frd_addr;
    logic [7:0]  c1_mem_rmask, c1_mem_wmask;
    logic        c1_frd_wvalid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        rf2_we;                     // O4: the second retirement's register write (regfile0 port 2)
    logic [4:0]  rf2_sel;
    logic [63:0] rf2_data;
    logic        c_instr_retired2;

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

    qv_commit #(.RESET_PC(RESET_PC), .COMMIT_W(COMMIT_W)) commit0 (
        .clk(clk), .rst(rst),
        .i_head_valid(head_valid), .i_head_entry(head_entry), .i_head_tag(head_tag),
        .i_head_ctrl(head_ctrl), .i_lsu_res(lsu_res), .o_commit_pop(commit_pop),
        .i_head1_valid(head1_valid), .i_head1_entry(head1_entry), .i_head1_tag(head1_tag),
        .i_head1_ctrl(head1_ctrl), .i_lsu_res1(lsu_res1), .i_lsu_res1_ok(LSQ_DEPTH > 0),
        .o_commit_pop2(commit_pop2),
        .o_regfile2_we(rf2_we), .o_regfile2_sel(rf2_sel), .o_regfile2_data(rf2_data),
        .o_commit2_valid(c2_valid), .o_commit2_rd(c2_rd), .o_commit2_rd_wen(c2_rd_wen),
        .o_commit2_rd_fp(c2_rd_fp), .o_commit2_tag(c2_tag),
        .o_instr_retired2(c_instr_retired2), .o_sb_push1(c_sb_push1),
        .o_rvfi1_order(c1_order), .o_rvfi1_insn(c1_insn), .o_rvfi1_rs1_addr(c1_rs1_addr),
        .o_rvfi1_rs2_addr(c1_rs2_addr), .o_rvfi1_rd_addr(c1_rd_addr), .o_rvfi1_rd_wdata(c1_rd_wdata),
        .o_rvfi1_pc_rdata(c1_pc_rdata), .o_rvfi1_pc_wdata(c1_pc_wdata), .o_rvfi1_mem_addr(c1_mem_addr),
        .o_rvfi1_mem_rmask(c1_mem_rmask), .o_rvfi1_mem_wmask(c1_mem_wmask), .o_rvfi1_mem_rdata(c1_mem_rdata),
        .o_rvfi1_mem_wdata(c1_mem_wdata), .o_rvfi1_frd_wvalid(c1_frd_wvalid), .o_rvfi1_frd_addr(c1_frd_addr),
        .o_rvfi1_frd_wdata(c1_frd_wdata),
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
        .o_rvfi_rd_addr(c_rd_addr), .o_rvfi_rd_wdata(c_rd_wdata),
        .o_rvfi_pc_rdata(c_pc_rdata), .o_rvfi_pc_wdata(c_pc_wdata),
        .o_rvfi_mem_addr(c_mem_addr), .o_rvfi_mem_rmask(c_mem_rmask), .o_rvfi_mem_wmask(c_mem_wmask),
        .o_rvfi_mem_rdata(c_mem_rdata), .o_rvfi_mem_wdata(c_mem_wdata),
        .o_rvfi_frd_wvalid(c_frd_wvalid), .o_rvfi_frd_addr(c_frd_addr), .o_rvfi_frd_wdata(c_frd_wdata),
        .o_commit_rd_fp(c_rd_fp), .o_fprf_we(c_fprf_we), .o_fprf_sel(c_fprf_sel), .o_fprf_data(c_fprf_data),
        .o_fp_accrue(c_fp_accrue)
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
        .i_read_gpr_C_sel(rs1b_sel), .o_read_gpr_C_data(rs1b_data),       // (O4c) slot 1's sources
        .i_read_gpr_D_sel(rs2b_sel), .o_read_gpr_D_data(rs2b_data),
        .i_load_gpr(dm_access_active ? i_dm_gpr_we : rf_we),
        .i_load_gpr_sel(dm_access_active ? i_dm_gpr_sel : rf_sel),
        .i_load_gpr_data(dm_access_active ? i_dm_gpr_wdata : rf_data),
        // (O4) the second retirement's write; nothing retires while the Debug Module has the port
        .i_load2_gpr(rf2_we), .i_load2_gpr_sel(rf2_sel), .i_load2_gpr_data(rf2_data)
    );

`ifdef RISCV_FORMAL
    // RVFI's source values are the operands the uop computes with, by ROB index: recorded at dispatch when they are
    // ready, and otherwise (with the station, a waiting one) when its unit takes them. Every uop sends exactly one
    // request (ALU, BRU, divider, FPU, or the LSU engine), with a = rs1 and b = rs2 whenever it reads them, and the
    // request names a live entry (asserted below), so the head's slot holds its own. The insn checks then follow its
    // operands to its result, and the reg check holds them to the architectural registers (a wrong forward or wakeup
    // fails it). Without the station everything is ready at dispatch, and only the first write exists.
    localparam int SRCW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    logic [63:0]          src_a_q [0:ROB_DEPTH-1];
    logic [63:0]          src_b_q [0:ROB_DEPTH-1];
    logic [ROB_DEPTH-1:0] src_wait_a_q, src_wait_b_q;
    wire [SRCW-1:0] s_new = alloc_tag[SRCW-1:0];
    wire [SRCW-1:0] s_new1 = alloc_tag1[SRCW-1:0];
    wire [SRCW-1:0] s_alu = alu_req.tag[SRCW-1:0], s_bru = bru_req.tag[SRCW-1:0], s_div = div_req.tag[SRCW-1:0];
    wire [SRCW-1:0] s_fpu = fpu_req.tag[SRCW-1:0], s_eng = eng_req.tag[SRCW-1:0];
    wire [SRCW-1:0] s_alu1 = alu1_req.tag[SRCW-1:0];
    always_ff @(posedge clk) begin
        if (RS_DEPTH > 0) begin
            if (alu_req.valid && src_wait_a_q[s_alu]) src_a_q[s_alu] <= alu_req.a;
            if (alu_req.valid && src_wait_b_q[s_alu]) src_b_q[s_alu] <= alu_req.b;
            if (bru_req.valid && src_wait_a_q[s_bru]) src_a_q[s_bru] <= bru_req.a;
            if (bru_req.valid && src_wait_b_q[s_bru]) src_b_q[s_bru] <= bru_req.b;
            if (div_req.valid && src_wait_a_q[s_div]) src_a_q[s_div] <= div_req.a;
            if (div_req.valid && src_wait_b_q[s_div]) src_b_q[s_div] <= div_req.b;
            if (fpu_req.valid && src_wait_a_q[s_fpu]) src_a_q[s_fpu] <= fpu_req.a;
            if (fpu_req.valid && src_wait_b_q[s_fpu]) src_b_q[s_fpu] <= fpu_req.b;
            if (eng_req.valid && src_wait_a_q[s_eng]) src_a_q[s_eng] <= eng_req.a;
            if (eng_req.valid && src_wait_b_q[s_eng]) src_b_q[s_eng] <= eng_req.b;
            if (alu1_req.valid && src_wait_a_q[s_alu1]) src_a_q[s_alu1] <= alu1_req.a;      // (O4d)
            if (alu1_req.valid && src_wait_b_q[s_alu1]) src_b_q[s_alu1] <= alu1_req.b;
        end
        if (alloc_valid) begin
            src_a_q[s_new]      <= src0_a.value;
            src_b_q[s_new]      <= src0_b.value;
            src_wait_a_q[s_new] <= !src0_a.rdy;
            src_wait_b_q[s_new] <= !src0_b.rdy;
        end
        if (alloc2_valid) begin                  // (O4c) the second dispatched uop's
            src_a_q[s_new1]      <= src1_a.value;
            src_b_q[s_new1]      <= src1_b.value;
            src_wait_a_q[s_new1] <= !src1_a.rdy;
            src_wait_b_q[s_new1] <= !src1_b.rdy;
        end
    end
    wire [63:0] c_rs1_rdata = (c_rs1_addr != 5'b0) ? src_a_q[head_tag[SRCW-1:0]] : 64'b0;
    wire [63:0] c_rs2_rdata = (c_rs2_addr != 5'b0) ? src_b_q[head_tag[SRCW-1:0]] : 64'b0;
    // (O4) the second retirement's, from its own slot (read only with COMMIT_W 2)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] c1_rs1_rdata = (c1_rs1_addr != 5'b0) ? src_a_q[head1_tag[SRCW-1:0]] : 64'b0;
    wire [63:0] c1_rs2_rdata = (c1_rs2_addr != 5'b0) ? src_b_q[head1_tag[SRCW-1:0]] : 64'b0;
    /* verilator lint_on UNUSEDSIGNAL */
`endif

    // F/D: the FP register file (its array fp_registers is a name the lockstep harness reads in both cores), read by
    // issue and written at commit. The Debug Module's FPR access takes read port 3 and the write port while the hart
    // is halted (dm_access_active: nothing issues or retires then), as for regfile0.
`ifdef QV_FORMAL_FPU_ABSTRACT
    // riscv-formal's pipe-fpu model: no check looks at an FP value (the datapath is free too, qv_exu_fpu.sv), so
    // the FP registers' reads are free and the 32 x 64 file costs nothing
    (* anyseq *) logic [63:0] abs_frs1, abs_frs2, abs_frs3;
    assign frs1_data      = abs_frs1;
    assign frs2_data      = abs_frs2;
    assign frs3_data      = abs_frs3;
    assign o_dm_fpr_rdata = abs_frs3;
`else
    qv_fprf fprf0 (
        .clk(clk), .rst(rst),
        .i_rs1(frs1_sel), .i_rs2(frs2_sel), .i_rs3(dm_access_active ? i_dm_fpr_sel : frs3_sel),
        .o_rs1_data(frs1_data), .o_rs2_data(frs2_data), .o_rs3_data(frs3_data),
        .i_we(dm_access_active ? i_dm_fpr_we : c_fprf_we),
        .i_wsel(dm_access_active ? i_dm_fpr_sel : c_fprf_sel),
        .i_wdata(dm_access_active ? i_dm_fpr_wdata : c_fprf_data)
    );
    assign o_dm_fpr_rdata = frs3_data;
`endif

`ifdef RISCV_FORMAL
    logic [63:0] mcause_w, scause_w, mepc_next_w, sepc_next_w, mcause_next_w, scause_next_w;
`endif

    csr_file #(.FP_EN(FPU_EN), .ZICNTR_EN(ZICNTR_EN)) csr_file0 (
        .i_clk(clk), .i_rst(rst),
        .i_fp_frd_we(c_fprf_we), .i_fp_accrue(c_fp_accrue),
        .i_csr_addr(dm_access_active ? i_dm_csr_addr : c_csr_addr), .o_csr_rdata(csr_rdata),
        .i_csr_we(dm_access_active ? i_dm_csr_we : c_csr_we),
        .i_csr_wdata(dm_access_active ? i_dm_csr_wdata : c_csr_wdata),
        .i_instr_retired(c_instr_retired), .i_instr_retired2(c_instr_retired2),
        .i_current_priv(priv),
        .i_mtip(i_mtip), .i_meip(i_meip), .i_seip(i_seip), .i_time(i_time),
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
        .o_mstatus_fs(mstatus_fs_w), .o_frm(frm_w), .o_fflags(fflags_w),
        .o_mcounteren(mcounteren_w), .o_scounteren(scounteren_w)
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
    // to it once the store buffer has drained (internally it is halted at the sample point, as before), and once an
    // early load that was in flight at the halt has drained, so that the port is quiet
    assign o_debug_mode    = in_debug_mode && sb_empty && !lsu_in_bus && !dc_busy;
    assign o_dm_csr_rdata  = csr_rdata;
    assign o_dm_gpr_rdata  = rs2_data;
    assign o_progbuf_pc    = pb_idx;
    assign o_progbuf_done  = pb_done;
    assign o_progbuf_abort = pb_abort;

`ifndef SYNTHESIS
    // (O8a) every conditional branch that retires was predicted with the committed history (the speculative history of
    // its fetch on the right path): a mismatch is a lost or doubled shift, or a wrong restore
    generate
        if (GS_ON) begin : g_gs_chk
            /* verilator lint_off UNUSEDSIGNAL */
            ras_snap_t gs_tsnap;                                           // (its history field only)
            /* verilator lint_on UNUSEDSIGNAL */
            assign gs_tsnap = rob0.snap_q[(qv_ctl_kind(head_entry.raw) == 2'd0) ? int'(head1_tag) % ROB_DEPTH
                                                                                : int'(head_tag) % ROB_DEPTH];
            always @(posedge clk)
                if (!rst && bht_upd_valid && gs_tsnap.gh[GSHARE_H-1:0] != g_gs.gs_hc)
                    $fatal(1, "core: a conditional branch at %h retires with history %h, the committed one is %h",
                           btb_upd_pc, gs_tsnap.gh[GSHARE_H-1:0], g_gs.gs_hc);
        end
    endgenerate
    // O4: the width knobs whose paths exist so far
    initial if (COMMIT_W < 1 || COMMIT_W > 2 || DISPATCH_W < 1 || DISPATCH_W > 2 || ALU_PORTS < 1 || ALU_PORTS > 2)
        $fatal(1, "core: COMMIT_W, DISPATCH_W and ALU_PORTS must be 1 or 2");
    // O7: tags are sized by the package, so the ROB may be no larger than its depth (QV_ROB_MAX)
    initial if (ROB_DEPTH < 2 || ROB_DEPTH > qv_pkg::QV_ROB_DEPTH || (ROB_DEPTH & (ROB_DEPTH - 1)) != 0)
        $fatal(1, "core: ROB_DEPTH %0d must be a power of 2 from 2 to qv_pkg::QV_ROB_DEPTH (%0d, set by QV_ROB_MAX)",
               ROB_DEPTH, qv_pkg::QV_ROB_DEPTH);
`endif

    // ---------------- RVFI ----------------
`ifdef RISCV_FORMAL
    assign rvfi_valid[0]                    = commit_now_w;
    assign rvfi_order[63:0]                 = c_order;
    assign rvfi_insn[31:0]                  = c_insn;
    assign rvfi_trap[0]                     = c_rvfi_trap;
    assign rvfi_halt[0]                     = 1'b0;
    assign rvfi_intr[0]                     = c_intr;
    assign rvfi_mode[1:0]                   = current_priv;
    assign rvfi_ixl[1:0]                    = 2'd2;
    assign rvfi_rs1_addr[4:0]               = c_rs1_addr;
    assign rvfi_rs2_addr[4:0]               = c_rs2_addr;
    assign rvfi_rs1_rdata[63:0]             = c_rs1_rdata;
    assign rvfi_rs2_rdata[63:0]             = c_rs2_rdata;
    assign rvfi_rd_addr[4:0]                = c_rd_addr;
    assign rvfi_rd_wdata[63:0]              = c_rd_wdata;
    assign rvfi_frd_wvalid[0]               = c_frd_wvalid;
    assign rvfi_frd_addr[4:0]               = c_frd_addr;
    assign rvfi_frd_wdata[63:0]             = c_frd_wdata;
    assign rvfi_pc_rdata[63:0]              = c_pc_rdata;
    assign rvfi_pc_wdata[63:0]              = c_pc_wdata;
    assign rvfi_mem_addr[63:0]              = c_mem_addr;
    assign rvfi_mem_rmask[7:0]              = c_mem_rmask;
    assign rvfi_mem_wmask[7:0]              = c_mem_wmask;
    assign rvfi_mem_rdata[63:0]             = c_mem_rdata;
    assign rvfi_mem_wdata[63:0]             = c_mem_wdata;

    assign rvfi_csr_mepc_rmask[63:0]        = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_wmask[63:0]        = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_rdata[63:0]        = mepc_w;
    assign rvfi_csr_mepc_wdata[63:0]        = mepc_next_w;
    assign rvfi_csr_mcause_rmask[63:0]      = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_wmask[63:0]      = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_rdata[63:0]      = mcause_w;
    assign rvfi_csr_mcause_wdata[63:0]      = mcause_next_w;
    assign rvfi_csr_sepc_rmask[63:0]        = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_wmask[63:0]        = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_rdata[63:0]        = sepc_w;
    assign rvfi_csr_sepc_wdata[63:0]        = sepc_next_w;
    assign rvfi_csr_scause_rmask[63:0]      = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_wmask[63:0]      = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_rdata[63:0]      = scause_w;
    assign rvfi_csr_scause_wdata[63:0]      = scause_next_w;
    assign rvfi_csr_pmpcfg0_rmask[63:0]     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpcfg0_wmask[63:0]     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpcfg0_rdata[63:0]     = pmpcfg0_w;
    assign rvfi_csr_pmpcfg0_wdata[63:0]     = pmpcfg0_w;
    assign rvfi_csr_pmpaddr0_rmask[63:0]    = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpaddr0_wmask[63:0]    = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_pmpaddr0_rdata[63:0]    = pmpaddr0_w;
    assign rvfi_csr_pmpaddr0_wdata[63:0]    = pmpaddr0_w;
    assign rvfi_csr_medeleg_rmask[63:0]     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_medeleg_wmask[63:0]     = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_medeleg_rdata[63:0]     = medeleg_w;
    assign rvfi_csr_medeleg_wdata[63:0]     = medeleg_w;
    assign rvfi_csr_satp_rmask              = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_satp_wmask              = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_satp_rdata              = satp_w;
    assign rvfi_csr_satp_wdata              = satp_w;

    // Channel 1 (COMMIT_W 2): the second retirement of a pair. It is never a trap, an interrupt's first instruction,
    // a halt or a CSR op, and it runs at the head's privilege; the CSR ports show what they show for channel 0 (no
    // instruction in a pair writes those CSRs).
    if (COMMIT_W > 1) begin : g_rvfi_ch1
        assign rvfi_valid[1] = commit_pop2;            assign rvfi_trap[1] = 1'b0;
        assign rvfi_halt[1]  = 1'b0;                   assign rvfi_intr[1] = 1'b0;
        assign rvfi_frd_wvalid[1] = c1_frd_wvalid;
        assign rvfi_order[127:64] = c1_order;          assign rvfi_insn[63:32] = c1_insn;
        assign rvfi_mode[3:2] = current_priv;          assign rvfi_ixl[3:2] = 2'd2;
        assign rvfi_rs1_addr[9:5] = c1_rs1_addr;       assign rvfi_rs2_addr[9:5] = c1_rs2_addr;
        assign rvfi_rd_addr[9:5] = c1_rd_addr;         assign rvfi_frd_addr[9:5] = c1_frd_addr;
        assign rvfi_rs1_rdata[127:64] = c1_rs1_rdata;  assign rvfi_rs2_rdata[127:64] = c1_rs2_rdata;
        assign rvfi_rd_wdata[127:64] = c1_rd_wdata;    assign rvfi_frd_wdata[127:64] = c1_frd_wdata;
        assign rvfi_pc_rdata[127:64] = c1_pc_rdata;    assign rvfi_pc_wdata[127:64] = c1_pc_wdata;
        assign rvfi_mem_addr[127:64] = c1_mem_addr;    assign rvfi_mem_rmask[15:8] = c1_mem_rmask;
        assign rvfi_mem_wmask[15:8] = c1_mem_wmask;    assign rvfi_mem_rdata[127:64] = c1_mem_rdata;
        assign rvfi_mem_wdata[127:64] = c1_mem_wdata;
        assign rvfi_csr_mepc_rmask[127:64]     = rvfi_csr_mepc_rmask[63:0];
        assign rvfi_csr_mepc_wmask[127:64]     = rvfi_csr_mepc_wmask[63:0];
        assign rvfi_csr_mepc_rdata[127:64]     = mepc_w;
        assign rvfi_csr_mepc_wdata[127:64]     = mepc_w;
        assign rvfi_csr_mcause_rmask[127:64]   = rvfi_csr_mcause_rmask[63:0];
        assign rvfi_csr_mcause_wmask[127:64]   = rvfi_csr_mcause_wmask[63:0];
        assign rvfi_csr_mcause_rdata[127:64]   = mcause_w;
        assign rvfi_csr_mcause_wdata[127:64]   = mcause_w;
        assign rvfi_csr_sepc_rmask[127:64]     = rvfi_csr_sepc_rmask[63:0];
        assign rvfi_csr_sepc_wmask[127:64]     = rvfi_csr_sepc_wmask[63:0];
        assign rvfi_csr_sepc_rdata[127:64]     = sepc_w;
        assign rvfi_csr_sepc_wdata[127:64]     = sepc_w;
        assign rvfi_csr_scause_rmask[127:64]   = rvfi_csr_scause_rmask[63:0];
        assign rvfi_csr_scause_wmask[127:64]   = rvfi_csr_scause_wmask[63:0];
        assign rvfi_csr_scause_rdata[127:64]   = scause_w;
        assign rvfi_csr_scause_wdata[127:64]   = scause_w;
        assign rvfi_csr_pmpcfg0_rmask[127:64]  = rvfi_csr_pmpcfg0_rmask[63:0];
        assign rvfi_csr_pmpcfg0_wmask[127:64]  = rvfi_csr_pmpcfg0_wmask[63:0];
        assign rvfi_csr_pmpcfg0_rdata[127:64]  = pmpcfg0_w;
        assign rvfi_csr_pmpcfg0_wdata[127:64]  = pmpcfg0_w;
        assign rvfi_csr_pmpaddr0_rmask[127:64] = rvfi_csr_pmpaddr0_rmask[63:0];
        assign rvfi_csr_pmpaddr0_wmask[127:64] = rvfi_csr_pmpaddr0_wmask[63:0];
        assign rvfi_csr_pmpaddr0_rdata[127:64] = pmpaddr0_w;
        assign rvfi_csr_pmpaddr0_wdata[127:64] = pmpaddr0_w;
        assign rvfi_csr_medeleg_rmask[127:64]  = rvfi_csr_medeleg_rmask[63:0];
        assign rvfi_csr_medeleg_wmask[127:64]  = rvfi_csr_medeleg_wmask[63:0];
        assign rvfi_csr_medeleg_rdata[127:64]  = medeleg_w;
        assign rvfi_csr_medeleg_wdata[127:64]  = medeleg_w;
    end
    assign rvfi_any_trap_taken     = trap_taken || interrupt_taken;

    // An interrupt or a halt is only ever taken with nothing started on the LSU's side of the data bus: the cycle
    // before retired something, so no memory op was in flight, and a head that would start in that cycle is held
    // off by the flush. An EBREAK or trigger entry happens at a head that is not a memory op, and memory
    // ops only start at the head -- or early (O2): a plain read of RAM, which the flush drains and the op does again
    // later, and which lsu_head_started does not count. (A started access cannot be abandoned, so this is what makes entering
    // Debug Mode without waiting for the LSU safe. The walker may have a PTE read of a cancelled fetch walk in
    // flight; it is a read that completes and is dropped, and the LSU's next start waits for it.)
    always @* assert (!((interrupt_taken || debug_halt_req_entry || debug_ebreak_entry || trigger_debug_entry)
                        && lsu_head_started));
    // The LSU, the walker and the store buffer's drain never drive the memory port together: each starts a beat
    // only while the others have nothing started or ready to start, and waits out a beat in flight.
    always @* assert (!((lsu_cyc && ptw_cyc) || (lsu_cyc && sb_cyc) || (ptw_cyc && sb_cyc)));
    // (O5a) nor does the D$'s refill, which the others wait out
    always @* assert (!(dc_cyc && (lsu_cyc || ptw_cyc || sb_cyc)));
    always @* if (o_debug_mode) assert (!dc_busy);
    // (O2) An access that goes before the head is a plain load from RAM or a posted plain store to RAM, of an op no
    // barrier is older than, translated, aligned, allowed, and (a load) with no store to its dword that is posted or
    // buffered and not yet in memory; one started early is always such a load.
    always @* if (!rst && (lsu0.start || lsu0.post_done) && !lsu0.at_head)
        assert (lsu0.EARLY && lsq_early && lsu0.pa_in_window && !lsu0.atomic_q && !pb_active && lsu0.pa_valid
                && !lsu0.misaligned_q && !lsu0.pmp_deny && (lsu0.store_q || !(sb_match || lsq_match)));
    always @* if (!rst && lsu0.in_bus && lsu0.early_q) assert (!lsu0.store_q && !lsu0.atomic_q);
    // (O5a) a load the D$ answers (or refills for) before the head is such a load too
    always @* if (!rst && (lsu0.done_dc || lsu0.dc_miss) && !lsu0.at_head)
        assert (lsu0.EARLY && lsq_early && lsu0.pa_in_window && !lsu0.atomic_q && !pb_active && lsu0.pa_valid
                && !lsu0.misaligned_q && !lsu0.pmp_deny && !lsu0.store_q && !(sb_match || lsq_match));

    // (O1) Every request to a unit and every writeback names an entry the ROB holds (a request sent in its uop's
    // dispatch cycle names the entry being allocated), and a writeback one that is not complete yet: each uop goes to
    // its unit once and completes once, also when the reservation station sends it out of order. The ALU and the BRU
    // never get a request in one cycle (they share the writeback bus).
    localparam int RIW = $clog2(ROB_DEPTH);
    function automatic logic rob_holds(input logic [QV_ROB_TAG_W-1:0] t, input logic [RIW:0] h, input logic [RIW:0] tl);
        logic [RIW:0] p;
        p = t[RIW:0];
        return ((t >> (RIW + 1)) == '0) && ((p - h) < (tl - h));
    endfunction
    wire [RIW:0] rob_h = rob0.head_q;
    wire [RIW:0] rob_t = rob0.tail_q;
    wire [RIW:0] rob_ta = rob0.tail_q + (RIW + 1)'(alloc_valid) + (RIW + 1)'(alloc2_valid);
    always @* if (!rst) begin
        assert (!(alu_req.valid && bru_req.valid));
        if (alu_req.valid) assert (rob_holds(alu_req.tag, rob_h, rob_ta));
        if (bru_req.valid) assert (rob_holds(bru_req.tag, rob_h, rob_ta));
        if (div_req.valid) assert (rob_holds(div_req.tag, rob_h, rob_ta));
        if (lsu_req.valid) assert (rob_holds(lsu_req.tag, rob_h, rob_ta));
        if (fpu_req.valid) assert (rob_holds(fpu_req.tag, rob_h, rob_ta));
        if (eng_req.valid) assert (rob_holds(eng_req.tag, rob_h, rob_ta));
        if (alu1_req.valid) assert (rob_holds(alu1_req.tag, rob_h, rob_ta) && !qv_is_mul(alu1_req.op));
        if (alu1_req.valid && alu_req.valid) assert (alu1_req.tag != alu_req.tag);
        if (alu1_req.valid && bru_req.valid) assert (alu1_req.tag != bru_req.tag);
        if (wb_bus.valid) assert (rob_holds(wb_bus.tag, rob_h, rob_t) && !rob0.complete_q[wb_bus.tag[RIW-1:0]]);
        if (lsu_wb.valid) assert (rob_holds(lsu_wb.tag, rob_h, rob_t) && !rob0.complete_q[lsu_wb.tag[RIW-1:0]]);
        if (div_wb.valid) assert (rob_holds(div_wb.tag, rob_h, rob_t) && !rob0.complete_q[div_wb.tag[RIW-1:0]]);
        if (fpu_wb.valid) assert (rob_holds(fpu_wb.tag, rob_h, rob_t) && !rob0.complete_q[fpu_wb.tag[RIW-1:0]]);
        if (wbp_bus.valid) assert (rob_holds(wbp_bus.tag, rob_h, rob_t) && !rob0.complete_q[wbp_bus.tag[RIW-1:0]]
                                   && !(wb_bus.valid && wb_bus.tag == wbp_bus.tag));
        // (O3) recovery at execute. In the kill cycle nothing carries a killed tag (no unit request, no offer to the
        // LSU, no writeback: a killed tag is about to be given to a new uop), nothing is dispatched, and the branch is
        // a live, complete, recovered mispredict whose resolved target fetch restarts at
        if (xr_kill) begin
            assert (!(alu_req.valid && kill_vec[alu_req.tag]) && !(alu1_req.valid && kill_vec[alu1_req.tag])
                    && !(bru_req.valid && kill_vec[bru_req.tag]) && !(div_req.valid && kill_vec[div_req.tag])
                    && !(fpu_req.valid && kill_vec[fpu_req.tag]) && !(eng_req.valid && kill_vec[eng_req.tag]));
            assert (!(wb_bus.valid && kill_vec[wb_bus.tag]) && !(wbp_bus.valid && kill_vec[wbp_bus.tag])
                    && !(lsu_wb.valid && kill_vec[lsu_wb.tag]) && !(div_wb.valid && kill_vec[div_wb.tag])
                    && !(fpu_wb.valid && kill_vec[fpu_wb.tag]));
            assert (!issue_fire && !issue_fire2 && !alloc_valid && !alloc2_valid);
            assert (rob_holds(xr_kill_tag, rob_h, rob_t) && rob0.complete_q[xr_kill_tag[RIW-1:0]]
                    && rob0.mispredict_q[xr_kill_tag[RIW-1:0]] && rob0.recovered_q[xr_kill_tag[RIW-1:0]]);
            if (!XR_EARLY) assert (fetch_redirect && fetch_redirect_pc == rob0.next_pc_q[xr_kill_tag[RIW-1:0]]);
        end
        if (XR_EARLY && x_cap) assert (fetch_redirect && fetch_redirect_pc == wb_bus.next_pc && !redirect_valid);
        // a killed access on the bus is an early plain load (it drains; nothing the head started is ever killed)
        if (lsu0.killed && lsu0.state_q == 2'd2) assert (lsu0.early_q && !lsu0.store_q && !lsu0.atomic_q);
        // a mispredicted head retires alone (in its kill cycle the entry behind it is a killed one)
        assert (!(commit_pop2 && head_entry.mispredict));
        // what the LSU and the divider hold names an entry in the ROB (after a kill too: the killed ones are dropped)
        if (lsu0.state_q == 2'd1 || lsu0.state_q == 2'd2) assert (rob_holds(lsu0.tag_q, rob_h, rob_t));
        if (exu_div0.busy_q) assert (rob_holds(exu_div0.tag_q, rob_h, rob_t));
    end

    // The translators are safe only while a client keeps to one rule: a request it holds does not change (what it
    // asks for, the context it asks in) except in the cycle after a cancel, so that the answer of a walk that was
    // cancelled can never reach another request. Fetch replaces a translating request only with a cancel (drop);
    // the LSU's op leaves with a flush, which cancels, or once it is translated (it asks nothing then). A request that
    // is a lookup only (nowalk: the LSU's before the head, the load/store queue's) starts no walk, so it may change:
    // the rule binds only one that may walk, and only until it has its answer (then the LSU drops it, and the queue's
    // lookup may take the port in that very cycle).
    reg        g_f_req = 1'b0, g_x_req = 1'b0, g_f_cancel = 1'b0, g_x_cancel = 1'b0, g_x_wr = 1'b0, g_sum = 1'b0, g_mxr = 1'b0;
    reg [63:0] g_f_va = '0, g_x_va = '0, g_satp = '0;
    reg [1:0]  g_f_priv = '0, g_x_priv = '0;
    always @(posedge clk) begin
        g_f_req    <= f_xl_req && !rst;
        g_f_cancel <= f_xl_cancel;
        g_f_va     <= f_xl_va;
        g_f_priv   <= priv;
        g_x_req    <= x_req && !rst && !x_nowalk && !x_done;    // a request may change once it has its answer
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
        if (rst || flush || lsu0.state_q != 2'd1 || lsu0.accept)
            g_px_valid <= 1'b0;
        else if (lsu0.x_ok || (lsu0.accept && eng_xl)) begin
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
