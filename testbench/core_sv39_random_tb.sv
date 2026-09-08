// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core_sv39_random_tb -- randomized/property-based test for the
 * Sv39 page-table walker in design/core.sv, via core_wb4_sram_harness (a
 * real core + flat WB SRAM, no cache -- the same isolation level as
 * core_sv39_fetch_tb.sv/core_sv39_mem_tb.sv/core_sv39_tlb_tb.sv). This is
 * the verification method never yet applied to Sv39: every one of the 9
 * real RTL bugs found across the 6-milestone Sv39 plan plus its follow-up
 * adversarial-review round was found by static review or hand-directed
 * simulation, never by randomized testing.
 *
 * Idiom: mirrors design/csr_file_priv_random_tb.sv's SHAPE (an
 * independently-coded shadow model cross-checked against the real DUT
 * every iteration, full reproducible-scenario dump on any mismatch,
 * quiet_on_pass to keep the log readable) -- but NOT its file structure.
 * csr_file_priv_random_tb.sv drives csr_file.sv directly, one CSR edge per
 * iteration, no memory/instruction stream. This file has to drive REAL
 * instruction streams (a page-table walk is triggered only by an actual
 * fetch/load/store/AMO/LR through core.sv, never by poking a CSR), so each
 * iteration is a short hand-assembled program run to completion, not a
 * single clock edge.
 *
 * ---- Per-iteration mechanism (why this is fast enough for hundreds of
 * iterations without hundreds of module instances or complex on-chip
 * looping) ----
 * design/register_file.sv has NO reset input (only a time-0 zero-fill) --
 * but core.sv's own PC/CSRs (including satp/mstatus/pmpcfg0/pmpaddrN and
 * the Sv39 TLB's own valid bits, confirmed via `tlb0_valid_q <= 1'b0` in
 * core.sv's own Sv39-TLB reset arm) all DO reset. So each iteration:
 *   1. Pulses `rst` for two clock edges (clears CSRs/TLB/PC; GPRs are left
 *      alone -- every register this file reads back is EITHER explicitly
 *      re-zeroed by that iteration's own program before the tested access,
 *      OR is only ever written via that SAME iteration's own trap-capture
 *      handler, so no register ever carries stale content across
 *      iterations into a check).
 *   2. Pokes a fresh page table + a short M-mode driver program directly
 *      into the harness's backing SRAM (same raw-PTE-word idiom every
 *      earlier Sv39 testbench already uses), reusing the SAME small
 *      address range every iteration.
 *   3. Releases reset and runs to completion under a bounded per-iteration
 *      cycle watchdog.
 * This is the SAME "poke raw memory, then run" idiom as
 * core_sv39_fetch_tb.sv's dut_a..dut_e, just executed against ONE
 * long-lived core instance across many sequential reset pulses instead of
 * five parallel module instances -- avoids both the complexity of an
 * on-chip test-vector loop AND the compile/elaboration cost of hundreds of
 * separate `core` instantiations.
 *
 * ---- Uniform pass/fault funnel (why every scenario, fetch or mem,
 * success or fault, is checked the exact same way) ----
 * medeleg is never written (stays 0 after reset) -- EVERY trap, from ANY
 * privilege level, always lands at mtvec (M-mode), never delegated. Each
 * iteration's program is built so BOTH outcomes funnel through the exact
 * same fixed trap handler at byte 0x100 (word 32/33 -- same address
 * every earlier Sv39 testbench's own capture handler uses):
 *   - FETCH stream: mepc = target VA, MRET to the target privilege. If the
 *     walk faults, the fault traps directly to the handler. If it
 *     succeeds, the walker resolved a real leaf, so the CPU actually
 *     fetches+executes `addi x30,x0,1 ; ebreak` (pre-seeded at the
 *     resolved leaf address, same "marker register" idiom
 *     core_sv39_fetch_tb.sv tests A/B already use) -- that EBREAK is
 *     ALSO a trap (cause 3, breakpoint), landing at the SAME handler.
 *   - MEM stream (load/store/AMO-RMW/LR): stays in M-mode throughout,
 *     using mstatus.MPRV=1 + MPP=target as the effective-privilege
 *     mechanism (spec-legal, and explicitly what core.sv's own
 *     mem_effective_priv formula is built around -- see this file's own
 *     "MPRV-only" scope note below). If the walk/permission check faults,
 *     it traps directly to the handler (current_priv is already M, so the
 *     trap goes to M regardless of delegation, same as any M-mode trap).
 *     If it succeeds, the NEXT instruction is an inline EBREAK (the
 *     success terminator) -- ALSO traps to the SAME handler (cause 3).
 * The handler (csrrs mcause->x20 ; csrrs mtval->x21 ; nop ; ebreak) always
 * runs exactly once per iteration, so mcause_actual==3 (breakpoint)
 * unambiguously means "the tested access succeeded, execution reached its
 * own terminator", and any other mcause_actual is the walker's own real
 * fault classification -- ONE observable signal distinguishes success
 * from fault for every access type and every category below, no separate
 * bookkeeping needed. (The handler's own capture point is pc==0x108, not
 * 0x100 -- 0x100/0x104 are the two CSRRS instructions themselves; sampling
 * at 0x108 guarantees BOTH have already committed, matching
 * core_sv39_fetch_tb.sv/core_sv39_mem_tb.sv's own capture-point choice
 * exactly.)
 *
 * ---- Memory layout (fixed, reused every iteration -- reset provides a
 * fresh CPU state each time, but the SRAM itself is NOT cleared by reset,
 * so every relevant word is explicitly (re)written every iteration) ----
 *   0x0000-0x00FF : M-mode driver program (rebuilt fresh every iteration --
 *                   up to 20 instructions / 10 words, well under the 32
 *                   words available before the handler).
 *   0x0100-0x010F : trap-capture handler (written ONCE, word32/33, byte
 *                   layout {csrrs mcause@0x100, csrrs mtval@0x104,
 *                   ebreak@0x108, nop@0x10C} -- same shape every earlier
 *                   Sv39 testbench's own handler uses).
 *   0x0200-0x0248 : per-iteration scratch DATA words (NOT instructions --
 *                   raw 64-bit values the driver program LDs directly,
 *                   sidestepping the need to hand-encode arbitrary random
 *                   64-bit immediates through addi/slli/or chains): satp,
 *                   mstatus, pmpcfg0, pmpaddr0, pmpaddr1, pmpaddr2, va,
 *                   operand (store data / AMO addend).
 *   0x1000        : L2 (root) table, entry index 1 (byte 0x1008) --
 *                   satp always points here (PPN=1); this is the ONLY
 *                   entry ever touched, so satp itself never needs to
 *                   vary between iterations.
 *   0x2000        : L1 table, entry index 2 (byte 0x2010).
 *   0x3000        : L0 table, entry index 3 (byte 0x3018) OR the resolved
 *                   leaf/data target for a megapage/gigapage-leaf
 *                   iteration (mutually exclusive by construction -- a
 *                   megapage/gigapage iteration never populates the L0
 *                   table at all, so reusing this same byte range as that
 *                   iteration's own DATA target is harmless).
 *   0x4000        : resolved leaf/data target for a 4KB-leaf iteration.
 * Every one of these addresses matches (or is the direct, deliberate
 * generalization of) the exact addresses core_sv39_fetch_tb.sv/
 * core_sv39_mem_tb.sv already use for their own hand-picked cases --
 * chosen specifically so this file's cross-validation section (below) can
 * feed those files' own exact page-table/VA/PTE values through this
 * file's shadow model and land on identical resolved addresses.
 *
 * ---- Resolved-PA arithmetic (why megapage/gigapage leaves stay small) ----
 * VA is one of exactly two fixed values: NORMAL_VA=0x40403000
 * (vpn2=1,vpn1=2,vpn0=3) for a 4KB or megapage leaf, or GIGA_VA=0x40003000
 * (vpn2=1,vpn1=0,vpn0=3) for a gigapage leaf -- GIGA_VA's own vpn1=0 is
 * not arbitrary: a gigapage's resolved PA is {pte.ppn2, va.vpn1, va.vpn0,
 * offset} (BOTH va.vpn1 and va.vpn0 pass through untouched, per the real
 * spec algorithm re-derived in this file's own shadow model below), so a
 * nonzero va.vpn1 here would blow the resolved PA up into multi-GB
 * territory for no benefit -- exactly the reasoning
 * core_sv39_fetch_tb.sv's own test B comment already documents for this
 * exact VA. A megapage's resolved PA is {pte.ppn2, pte.ppn1, va.vpn0,
 * offset} -- va.vpn1 is consumed purely as the L1-table INDEX, never
 * reaching the resolved PA, so NORMAL_VA's own vpn1=2 is harmless there.
 * Every PTE payload field this file ever picks for ppn2/ppn1 (beyond the
 * level-appropriate 4KB-leaf ppn0=4) is 0, so the resolved PA for a
 * megapage or gigapage success case is always exactly 0x3000, and for a
 * 4KB-leaf success case always exactly 0x4000 -- two fixed, known,
 * verification-friendly targets, never a function of the iteration index.
 *
 * A REAL BUG IN THIS TESTBENCH (not core.sv) was caught here during
 * bring-up: an early draft wrote the NORMAL_VA/GIGA_VA/NONCANON_VA
 * localparams with one extra `4'h0` hex group (`64'h0000_0040_4040_3000`
 * instead of `64'h0000_0000_4040_3000`), silently shifting the intended
 * 0x40403000 up by 32 bits into 0x4040403000 -- which, being >= 2^38,
 * ALSO happened to be noncanonical, AND extracted a garbage vpn2 (257,
 * not 1) that pointed the walker's own first PTE read at byte 0x1808
 * instead of the PMP-covered/page-table-populated 0x1008. Every
 * CAT_PMPDENY iteration whose deny level was 2 failed as a result (the
 * walker's REAL first read landed outside both the intended page table
 * AND the intended PMP deny window, so it saw whatever unrelated,
 * unwritten memory happened to sit at 0x1808 -- a spurious page fault,
 * not the intended PMP access fault). Found via a debug PC/PTW-signal
 * trace during this file's own bring-up (see the git history of this
 * file for that trace), confirmed as testbench-only by hand-decoding the
 * literal hex constant, and fixed by removing the extra hex group --
 * never by touching core.sv, whose own ptw_pte_addr/ptw_vpn2/ptw_pmp_fault
 * behavior traced out to be exactly correct for whatever (wrong) VA it
 * was actually handed.
 *
 * ---- Scope: MPRV-only mem-stream privilege switching (a deliberate,
 * documented narrowing, same discipline every earlier Sv39 testbench's own
 * header already uses) ----
 * Every MEM-stream (load/store/AMO-RMW/LR) iteration here uses
 * mstatus.MPRV+MPP while staying in M-mode, never a real MRET to S/U for
 * the mem stream. core_sv39_mem_tb.sv's own tests A-D already cover ONE
 * real (non-MPRV) S-mode mem access end-to-end (load+store+AMO all
 * succeeding via a genuine MRET). core.sv's own mem_effective_priv formula
 * (`(mstatus_mprv_w && current_priv==PRIV_M) ? mstatus_mpp_w :
 * current_priv`) makes the PERMISSION-CHECK LOGIC itself provably
 * mechanism-agnostic -- the walker's own ptw_check_priv consumes
 * mem_effective_priv either way, with no separate code path for "real S/U"
 * vs "M+MPRV emulating S/U". Exercising real MRET-to-S/U for every one of
 * hundreds of randomized mem-stream iterations would ALSO require a
 * second, always-successful "code leaf" (since the driver program itself
 * would then need its own translated fetch, decoupled from the randomized
 * DATA leaf under test) -- real complexity with no additional coverage of
 * the walker's own fault/permission logic, which is this file's actual
 * target. FETCH-stream iterations, by contrast, MUST use a real MRET
 * (spec-mandated: MPRV never affects instruction fetch, cited directly in
 * this file's own shadow model comment below), so there is no equivalent
 * simplification available there.
 *
 * ---- Coverage ----
 * All 3 leaf sizes (4KB/2MB/1GB); every fault category in the task's own
 * spec grounding (malformed-PTE variants, superpage misalignment at both
 * applicable levels, walk-past-level-0, U-bit/SUM interaction from both
 * streams, permission+MXR interaction including the AMO-needs-BOTH-R-and-W
 * rule, A=0 and D=0-on-a-write Svade faults, noncanonical VA, PMP-on-PTE-
 * read denial); U/S target privilege; plenty of plain successful
 * translations. See CAT_* localparams and the weighted dispatch in the
 * main loop below for the exact category shape/probability of each.
 *
 * ---- Cross-validation (mandatory first step, per this session's task
 * brief) ----
 * Before ANY random generation, this file feeds the exact page-table/VA/
 * PTE/PMP parameters of core_sv39_fetch_tb.sv's tests A-D and
 * core_sv39_mem_tb.sv's tests A-D through sv39_shadow_predict and checks
 * the result against those files' own already-asserted, known-correct
 * outcomes -- see the "Cross-validation" section below, run before the
 * main randomized loop starts.
 */
module core_sv39_random_tb;

    localparam int NUM_ITER = 3000;
    localparam int ITER_CYCLE_BUDGET = 500;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b1;   /* NUM_ITER * several checks would otherwise flood the log. */
    `include "check_lib.sv"

    core_wb4_sram_harness #(.NUM_WORDS(8192)) dut (.clk(clk), .rst(rst));

    /* ----------------------------------------------------------------
     * enc_* helpers not already in riscv_encode.sv -- same style as
     * every earlier Sv39 testbench's own local enc_* block.
     * ---------------------------------------------------------------- */
    localparam logic [2:0] FUNCT3_OR = 3'b110;
    localparam logic [6:0] FUNCT7_OR = 7'b0000000;
    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(FUNCT7_OR, rs2, rs1, FUNCT3_OR, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_csrrw(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_csrrs(input logic [11:0] csr, input logic [4:0] rd);
        return encode_csr(csr, 5'd0, `FUNCT3_CSRRS, rd, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    function automatic logic [31:0] enc_amoadd_d(input logic [4:0] rd, rs1, rs2);
        return encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, rs2, rs1, `FUNCT3_AMO_D, rd, `OPC_AMO);
    endfunction
    function automatic logic [31:0] enc_lr_d(input logic [4:0] rd, rs1);
        return encode_amo(`FUNCT5_LR, 1'b0, 1'b0, 5'd0, rs1, `FUNCT3_AMO_D, rd, `OPC_AMO);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;
    localparam logic [31:0] MRET_INSN   = `INSTR_HEX_MRET;

    /* PTE assembler -- raw bit layout per this session's own spec
     * grounding, independently transcribed (not read from core.sv's own
     * ptw_pte_* extraction wires). */
    function automatic logic [63:0] make_pte(
        input logic v, r, w, x, u, g, a, d,
        input logic [1:0]  rsw,
        input logic [8:0]  ppn0, ppn1,
        input logic [25:0] ppn2,
        input logic [6:0]  reserved,
        input logic [1:0]  pbmt,
        input logic n
    );
        return {n, pbmt, reserved, ppn2, ppn1, ppn0, rsw, d, a, g, u, x, w, r, v};
    endfunction

    /* ----------------------------------------------------------------
     * Memory-map constants (byte addresses / word indices), matching the
     * header comment above exactly.
     * ---------------------------------------------------------------- */
    localparam int HANDLER_WORD      = 32;   // byte 0x100
    localparam int L2_WORD           = 512;  // byte 0x1000
    localparam int L1_WORD           = 1024; // byte 0x2000
    localparam int L0_WORD           = 1536; // byte 0x3000
    localparam int L2_ENTRY          = 1;    // L2_WORD + 1  = byte 0x1008
    localparam int L1_ENTRY          = 2;    // L1_WORD + 2  = byte 0x2010
    localparam int L0_ENTRY          = 3;    // L0_WORD + 3  = byte 0x3018
    localparam logic [63:0] PTE_ADDR_L2 = 64'h1008;
    localparam logic [63:0] PTE_ADDR_L1 = 64'h2010;
    localparam logic [63:0] PTE_ADDR_L0 = 64'h3018;
    localparam int LEAF4K_WORD       = 2048; // byte 0x4000
    localparam int LEAFSUPER_WORD    = L0_WORD; // byte 0x3000 -- megapage/gigapage target
    localparam logic [63:0] TARGET_PA_4K    = 64'h4000;
    localparam logic [63:0] TARGET_PA_SUPER = 64'h3000;
    localparam int S_SATP_W     = 64; localparam int S_SATP_OFF     = 512;
    localparam int S_MSTATUS_W  = 65; localparam int S_MSTATUS_OFF  = 520;
    localparam int S_PMPCFG0_W  = 66; localparam int S_PMPCFG0_OFF  = 528;
    localparam int S_PMPADDR0_W = 67; localparam int S_PMPADDR0_OFF = 536;
    localparam int S_PMPADDR1_W = 68; localparam int S_PMPADDR1_OFF = 544;
    localparam int S_PMPADDR2_W = 69; localparam int S_PMPADDR2_OFF = 552;
    localparam int S_VA_W       = 70; localparam int S_VA_OFF       = 560;
    localparam int S_OPERAND_W  = 71; localparam int S_OPERAND_OFF  = 568;

    localparam logic [63:0] SATP_FIXED = 64'h8000_0000_0000_0001; // MODE=8, PPN=1 (root@0x1000)
    localparam logic [63:0] NORMAL_VA  = 64'h0000_0000_4040_3000; // vpn2=1,vpn1=2,vpn0=3
    localparam logic [63:0] GIGA_VA    = 64'h0000_0000_4000_3000; // vpn2=1,vpn1=0,vpn0=3
    localparam logic [63:0] NONCANON_VA = 64'h8000_0000_4040_3000; // NORMAL_VA with bit63 flipped

    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;

    /* mstatus bit positions -- independently transcribed from the spec
     * (same values csr_file_priv_random_tb.sv's own header already
     * independently transcribed and this project's own PMP milestone
     * shipped), NOT read from csr_file.sv's own internals. */
    localparam int MPRV_BIT = 17, SUM_BIT = 18, MXR_BIT = 19;
    localparam int MPP_LSB = 11, MPP_MSB = 12;

    /* Access-kind encoding used throughout this file. */
    localparam int AK_FETCH = 0, AK_LOAD = 1, AK_STORE = 2, AK_AMO = 3, AK_LR = 4;

    /* Category encoding for the weighted random dispatch. */
    localparam int CAT_SUCCESS      = 0;
    localparam int CAT_MALFORMED    = 1;
    localparam int CAT_SUPERPAGE    = 2;
    localparam int CAT_WALKPASTL0   = 3;
    localparam int CAT_USUM         = 4;
    localparam int CAT_PERMMXR      = 5;
    localparam int CAT_ADFAULT      = 6;
    localparam int CAT_NONCANON     = 7;
    localparam int CAT_PMPDENY      = 8;

    /* ==================================================================
     * SHADOW MODEL -- derived from this session's own spec grounding text
     * (PTE bit layout, VA fields, malformed/superpage-misaligned/
     * no-more-levels/U-SUM/permission+MXR/A-D-Svade/PMP-on-PTE-read/
     * noncanonical-VA rules, translation-active gating). Mirrors the
     * SPEC's own algorithm shape (a level-by-level walk with a PMP check +
     * content check at each visited level), not core.sv's own single-
     * cycle-combinational OR-list shape.
     *
     * HONEST CAVEAT (added after an independent adversarial review of this
     * file, 2026-09-09): despite the above, this model's core fault-
     * classification predicates -- malformed/superpage_misaligned/
     * u_violation/read_ok/perm_violation/ad_fault -- are near-verbatim
     * transcriptions of core.sv's own ptw_pte_malformed/ptw_superpage_
     * misaligned/ptw_u_violation/ptw_read_ok/ptw_perm_violation/ptw_ad_
     * fault wires (core.sv:1800-1855), term-for-term, in the same grouping
     * order. That was not deliberate copying, but the spec grounding this
     * file's own predicates were built from IS itself a restatement of the
     * same wires (both ultimately trace to the same spec reading done when
     * core.sv was originally implemented) -- so this model does NOT
     * provide independent-of-core.sv confirmation that those exact
     * formulas are correct; a bug living in one of them would be silently
     * shared by both sides of every comparison this file makes. What this
     * file DOES provide real, independent coverage of: the FSM sequencing
     * (S_PTW entry/exit, TLB fill/hit), register writeback, trap CSR
     * capture, and PMP address-arithmetic composition -- none of which
     * this shadow model duplicates, and all of which the real DUT
     * execution genuinely exercises against a fresh random scenario every
     * iteration. Treat this file as "prove the sequencing/plumbing layer
     * against the design's own already-reviewed intent," not as "an
     * independently re-derived oracle for the fault-classification rules
     * themselves" -- static review and the fault-taxonomy directed tests
     * (core_sv39_fetch_tb.sv/core_sv39_mem_tb.sv) remain the actual checks
     * on whether those formulas are right.
     *
     * Simplifications that are honest, not corner-cutting (documented so
     * a reader can judge them): every INTERMEDIATE (non-leaf) level this
     * file's own generator ever constructs is a fixed, always-valid plain
     * pointer PTE (V=1,R=W=X=0, no reserved/pbmt/n bits, pointing at the
     * next real table) -- so this shadow model does not need its own
     * generic "is this intermediate PTE itself malformed" logic, only the
     * LEAF's content ever varies. This mirrors real walker behavior
     * exactly (an intermediate PTE CAN independently be malformed in
     * general Sv39 hardware) while keeping the generator's own space
     * tractable -- every fault category the task's spec grounding asks
     * for is about the WALK's overall outcome, and every one of them is
     * reachable by varying only the leaf's own content/level, not by also
     * independently corrupting a pointer level.
     * ================================================================== */
    task automatic sv39_shadow_predict(
        input int level,                 // 0, 1, or 2 -- level the leaf sits at (or would, for walk_past_l0)
        input logic walk_past_l0,        // 1: level-0 entry is itself a non-leaf pointer (no more levels)
        input logic [63:0] va,
        input logic leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d,
        input logic [6:0] leaf_reserved,
        input logic [1:0] leaf_pbmt,
        input logic leaf_n,
        input logic [25:0] leaf_ppn2,
        input logic [8:0]  leaf_ppn1,
        input logic [8:0]  leaf_ppn0,
        input int access_kind,           // AK_*
        input logic [1:0] priv,          // effective priv for THIS access (mem: mem_effective_priv; fetch: current_priv)
        input logic sum_bit,
        input logic mxr_bit,
        input int pmp_deny_level,        // -1 = no PMP denial anywhere in the walk; else 0/1/2
        output logic fault,
        output logic [3:0] cause,
        output logic [63:0] fault_vaddr,
        output logic [63:0] resolved_pa
    );
        logic is_fetch;
        logic needs_write, needs_read, access_fault_store_class;
        logic va_noncanonical;
        logic [8:0] va_vpn1, va_vpn0;
        logic malformed, superpage_bad, u_violation, read_ok, perm_violation, ad_fault;
        logic done;
        int lvl;

        is_fetch    = (access_kind == AK_FETCH);
        // needs_write (page-fault cause 13 vs 15, and the leaf's own W/D
        // permission checks below) EXCLUDES LR, per the task's own spec
        // grounding: "LR is read-only, classified with loads for
        // permission purposes: needs only R, not W". access_fault_store_
        // class (cause 5 vs 7 for a PMP-denied PTE read) is a DIFFERENT,
        // independently-transcribed split that INCLUDES LR alongside
        // store/AMO -- re-derived directly against core.sv's own
        // pmp_store_fault/mem_store_access_fault OR-lists (both of which
        // explicitly fold is_lr in alongside is_store/is_sc/is_amo_rmw,
        // with an explicit comment: "LR is spec-classified under store/
        // AMO, cause 7, not load, cause 5 -- same reasoning, not just
        // convention-matching"), NOT copied from those wires' own RTL
        // shape -- this is a real, spec-documented asymmetry (RISC-V
        // classifies LR/SC's own misaligned/access-fault exceptions under
        // the store/AMO causes even though LR's PAGE-fault/permission
        // classification follows loads) rather than an implementation
        // quirk, so the shadow model must reproduce it too, not paper
        // over it by treating LR as uniformly "load-like".
        needs_write = (access_kind == AK_STORE) || (access_kind == AK_AMO);
        needs_read  = (access_kind == AK_LOAD) || (access_kind == AK_LR) || (access_kind == AK_AMO);
        access_fault_store_class = (access_kind == AK_STORE) || (access_kind == AK_AMO) || (access_kind == AK_LR);

        va_noncanonical = (va[63:39] != {25{va[38]}});
        va_vpn1 = va[29:21];
        va_vpn0 = va[20:12];

        fault = 1'b0;
        cause = 4'd0;
        fault_vaddr = va;
        resolved_pa = 64'd0;
        done = 1'b0;

        for (lvl = 2; lvl >= 0; lvl = lvl - 1) begin
            if (!done && lvl == pmp_deny_level) begin
                // PMP-on-PTE-read (hardwired S, unconditional): denies the
                // READ itself, before any content is ever examined -- an
                // access fault of the ORIGINAL access's own type, never a
                // page fault, regardless of what the (never-read) content
                // would have said.
                fault = 1'b1;
                cause = is_fetch ? 4'd1 : (access_fault_store_class ? 4'd7 : 4'd5);
                done = 1'b1;
            end
            if (!done && va_noncanonical) begin
                // Checked at the first PTE content evaluation regardless of
                // level (real hardware evaluates it on every walk step) --
                // fires here at whichever level is first actually reached
                // (PMP-permitting), always the SAME page-fault-family cause
                // as any other content fault, never an access fault.
                fault = 1'b1;
                cause = is_fetch ? 4'd12 : (needs_write ? 4'd15 : 4'd13);
                done = 1'b1;
            end
            if (!done && (lvl == 0) && walk_past_l0) begin
                // no_more_levels: a non-leaf pointer with nowhere further
                // to descend.
                fault = 1'b1;
                cause = is_fetch ? 4'd12 : (needs_write ? 4'd15 : 4'd13);
                done = 1'b1;
            end
            if (!done && (lvl == level) && !walk_past_l0) begin
                malformed = !leaf_v || (!leaf_r && leaf_w) || (|leaf_reserved) || (|leaf_pbmt) || leaf_n;
                superpage_bad = (lvl != 0)
                    && ((lvl == 2) ? (|{leaf_ppn1, leaf_ppn0}) : (|leaf_ppn0));
                u_violation = leaf_u
                    ? (is_fetch ? (priv == PRIV_S)
                                : !((priv == PRIV_U) || (priv == PRIV_S && sum_bit)))
                    : (priv == PRIV_U);
                read_ok = leaf_r || (mxr_bit && leaf_x);
                // Fetch needs X. Mem: a WRITING access (store, AMO-RMW)
                // needs W; a READING access (load, AMO-RMW's own read
                // phase, LR) needs R-or-(MXR&&X) -- AMO-RMW is BOTH, so it
                // needs both W and read_ok, per the spec grounding's own
                // explicit "AMO-RMW... BOTH" callout.
                perm_violation = is_fetch ? !leaf_x
                    : ((needs_write && !leaf_w) || (needs_read && !read_ok));
                // Svade: A=0 always faults; a WRITING access additionally needs D=1.
                ad_fault = !leaf_a || (needs_write && !leaf_d);

                if (malformed || superpage_bad || u_violation || perm_violation || ad_fault) begin
                    fault = 1'b1;
                    cause = is_fetch ? 4'd12 : (needs_write ? 4'd15 : 4'd13);
                end else begin
                    fault = 1'b0;
                    unique case (lvl)
                        0: resolved_pa = {8'b0, leaf_ppn2, leaf_ppn1, leaf_ppn0,           va[11:0]};
                        1: resolved_pa = {8'b0, leaf_ppn2, leaf_ppn1, va_vpn0,             va[11:0]};
                        default: resolved_pa = {8'b0, leaf_ppn2, va_vpn1, va_vpn0,         va[11:0]};
                    endcase
                end
                done = 1'b1;
            end
            // else (an intermediate, always-valid pointer level): no fault,
            // walk continues to the next (lower) level -- no-op here.
        end
    endtask

    /* ==================================================================
     * Cross-validation -- BEFORE any random generation, feed the exact
     * page-table/VA/PTE/PMP parameters of core_sv39_fetch_tb.sv's tests
     * A-D and core_sv39_mem_tb.sv's tests A-D through the shadow model
     * above and confirm it independently predicts the SAME already
     * hand-verified outcome those files' own checks already assert. Every
     * PTE value below is copied from those files' own literal hex
     * constants (not re-derived), and every expected outcome below is
     * copied from those files' own `check(...)` calls.
     * ================================================================== */
    task automatic run_cross_validation();
        logic f; logic [3:0] c; logic [63:0] fv, rpa;

        // core_sv39_fetch_tb.sv Test A: 4KB walk, PTE=0x10CF (V=R=W=X=A=D=1,U=G=0,PPN0=4).
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd4,
            AK_FETCH, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL fetch_tb A: no fault", {63'b0,f}, 64'd0);
        check("XVAL fetch_tb A: resolved_pa==0x4000", rpa, 64'h4000);

        // core_sv39_fetch_tb.sv Test B: gigapage, PTE=0x00CF (V=R=W=X=1,A=D=0,PPN=0), VA=0x40003000.
        sv39_shadow_predict(2, 1'b0, 64'h40003000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 9'd0,9'd0,26'd0,
            AK_FETCH, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL fetch_tb B: no fault", {63'b0,f}, 64'd0);
        check("XVAL fetch_tb B: resolved_pa==0x3000", rpa, 64'h3000);

        // core_sv39_fetch_tb.sv Test C: V=0 leaf -- instruction page fault, mtval==VA.
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 7'b0,2'b0,1'b0, 9'd0,9'd0,26'd0,
            AK_FETCH, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL fetch_tb C: fault", {63'b0,f}, 64'd1);
        check("XVAL fetch_tb C: cause==12", {60'b0,c}, 64'd12);
        check("XVAL fetch_tb C: mtval==VA", fv, 64'h40403000);

        // core_sv39_fetch_tb.sv Test D: PMP denies the L2 PTE read -- access fault, cause 1.
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd4,
            AK_FETCH, PRIV_S, 1'b0, 1'b0, 2, f, c, fv, rpa);
        check("XVAL fetch_tb D: fault", {63'b0,f}, 64'd1);
        check("XVAL fetch_tb D: cause==1 (not 12)", {60'b0,c}, 64'd1);
        check("XVAL fetch_tb D: mtval==VA (not PTE PA)", fv, 64'h40403000);

        // core_sv39_mem_tb.sv Test A: load+store round trip, full RWX leaf.
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd4,
            AK_LOAD, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL mem_tb A load: no fault", {63'b0,f}, 64'd0);
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd4,
            AK_STORE, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL mem_tb A store: no fault", {63'b0,f}, 64'd0);

        // core_sv39_mem_tb.sv Test B: AMOADD.D through the same full-RWX leaf.
        sv39_shadow_predict(0, 1'b0, 64'h40403000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd4,
            AK_AMO, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL mem_tb B amo: no fault", {63'b0,f}, 64'd0);

        // core_sv39_mem_tb.sv Test C: store to R=1,W=0,X=0 leaf (PTE=0x1443) -- cause 15.
        sv39_shadow_predict(0, 1'b0, 64'h40404000,
            1'b1,1'b1,1'b0,1'b0,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 26'd0,9'd0,9'd5,
            AK_STORE, PRIV_S, 1'b0, 1'b0, -1, f, c, fv, rpa);
        check("XVAL mem_tb C: fault", {63'b0,f}, 64'd1);
        check("XVAL mem_tb C: cause==15", {60'b0,c}, 64'd15);
        check("XVAL mem_tb C: mtval==VA", fv, 64'h40404000);

        // core_sv39_mem_tb.sv Test D: PMP denies the (mem-stream) L0 PTE read -- cause 5.
        sv39_shadow_predict(0, 1'b0, 64'h40400000,
            1'b1,1'b1,1'b1,1'b1,1'b0,1'b1,1'b1, 7'b0,2'b0,1'b0, 9'd0,9'd0,26'd0,
            AK_LOAD, PRIV_S, 1'b0, 1'b0, 0, f, c, fv, rpa);
        check("XVAL mem_tb D: fault", {63'b0,f}, 64'd1);
        check("XVAL mem_tb D: cause==5 (not 13)", {60'b0,c}, 64'd5);
        check("XVAL mem_tb D: mtval==VA", fv, 64'h40400000);
    endtask

    /* ==================================================================
     * Per-iteration runner: pokes the page table + driver program for ONE
     * scenario, pulses reset, runs to completion (or the watchdog), and
     * returns the real DUT's observed outcome.
     * ================================================================== */
    task automatic run_iteration(
        input int level, input logic walk_past_l0, input logic [63:0] va,
        input logic leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d,
        input logic [6:0] leaf_reserved, input logic [1:0] leaf_pbmt, input logic leaf_n,
        input logic [25:0] leaf_ppn2, input logic [8:0] leaf_ppn1, input logic [8:0] leaf_ppn0,
        input int access_kind, input logic [1:0] priv, input logic sum_bit, input logic mxr_bit,
        input int pmp_deny_level,
        input logic [63:0] operand,       // store data / AMO addend
        input logic [63:0] target_pa,     // this scenario's own resolved-on-success PA (0x3000 or 0x4000)
        output logic fault_seen,
        output logic [63:0] mcause_actual, mtval_actual,
        output logic [63:0] x30_actual, x9_actual,
        output logic [63:0] mem_word_actual
    );
        int target_word;
        logic [63:0] pte_leaf, pte_ptr_l1, pte_ptr_l0, pte_l0_nonleaf;
        logic [63:0] mstatus_val, pmpcfg0_val, pmpaddr0_val, pmpaddr1_val, pmpaddr2_val;
        logic [63:0] deny_addr;
        int prog_lo, prog_hi;
        logic [31:0] prog[0:23];
        int pw;
        int cyc;
        logic captured;

        target_word = int'(target_pa >> 3);

        pte_leaf = make_pte(leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, 1'b0, leaf_a, leaf_d,
                             2'b0, leaf_ppn0, leaf_ppn1, leaf_ppn2, leaf_reserved, leaf_pbmt, leaf_n);
        pte_ptr_l1 = make_pte(1'b1,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 2'b0, 9'd2,9'd0,26'd0, 7'b0,2'b0,1'b0); // -> L1@0x2000
        pte_ptr_l0 = make_pte(1'b1,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 2'b0, 9'd3,9'd0,26'd0, 7'b0,2'b0,1'b0); // -> L0@0x3000
        pte_l0_nonleaf = make_pte(1'b1,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, 2'b0, 9'd0,9'd0,26'd0, 7'b0,2'b0,1'b0);

        // ---- Page table: always fully (re)written, unused levels zeroed. ----
        dut.sram0.memory[L2_WORD + L2_ENTRY] = 64'd0;
        dut.sram0.memory[L1_WORD + L1_ENTRY] = 64'd0;
        dut.sram0.memory[L0_WORD + L0_ENTRY] = 64'd0;
        if (level == 2) begin
            dut.sram0.memory[L2_WORD + L2_ENTRY] = pte_leaf;
        end else if (level == 1) begin
            dut.sram0.memory[L2_WORD + L2_ENTRY] = pte_ptr_l1;
            dut.sram0.memory[L1_WORD + L1_ENTRY] = pte_leaf;
        end else begin
            dut.sram0.memory[L2_WORD + L2_ENTRY] = pte_ptr_l1;
            dut.sram0.memory[L1_WORD + L1_ENTRY] = pte_ptr_l0;
            dut.sram0.memory[L0_WORD + L0_ENTRY] = walk_past_l0 ? pte_l0_nonleaf : pte_leaf;
        end

        // ---- Leaf/data target content. ----
        if (access_kind == AK_FETCH) begin
            dut.sram0.memory[target_word] = {EBREAK_INSN, enc_addi(5'd30, 5'd0, 1)};
        end else begin
            // Pre-seed a distinguishable "before" sentinel -- load/lr
            // success expects it back verbatim; store/AMO fault expects it
            // to remain UNCHANGED (proving no side effect leaked through).
            dut.sram0.memory[target_word] = 64'hBEEF_0000_0000_0BEE;
        end

        // ---- PMP configuration. ----
        pmpaddr2_val = 64'h4000; // TOR upper bound, byte 0x10000 (>>2)
        if (pmp_deny_level == 2)      deny_addr = PTE_ADDR_L2;
        else if (pmp_deny_level == 1) deny_addr = PTE_ADDR_L1;
        else if (pmp_deny_level == 0) deny_addr = PTE_ADDR_L0;
        else                          deny_addr = 64'd0;

        if (pmp_deny_level == -1) begin
            pmpaddr0_val = pmpaddr2_val;
            pmpaddr1_val = pmpaddr2_val;
            pmpcfg0_val  = 64'h0000_0000_0000_000F; // region0: TOR[0,0x10000) RWX
        end else begin
            pmpaddr0_val = deny_addr >> 2;
            pmpaddr1_val = (deny_addr + 64'd8) >> 2;
            pmpcfg0_val  = 64'h0000_0000_000F_080F; // region0 RWX, region1 (deny window) none, region2 RWX
        end

        mstatus_val = (64'(priv) << MPP_LSB) | (64'(sum_bit) << SUM_BIT) | (64'(mxr_bit) << MXR_BIT);
        if (access_kind != AK_FETCH) mstatus_val = mstatus_val | (64'd1 << MPRV_BIT);

        dut.sram0.memory[S_SATP_W]     = SATP_FIXED;
        dut.sram0.memory[S_MSTATUS_W]  = mstatus_val;
        dut.sram0.memory[S_PMPCFG0_W]  = pmpcfg0_val;
        dut.sram0.memory[S_PMPADDR0_W] = pmpaddr0_val;
        dut.sram0.memory[S_PMPADDR1_W] = pmpaddr1_val;
        dut.sram0.memory[S_PMPADDR2_W] = pmpaddr2_val;
        dut.sram0.memory[S_VA_W]       = va;
        dut.sram0.memory[S_OPERAND_W]  = operand;

        // ---- Driver program: ALL scratch-data LOADS happen FIRST, while
        // satp is still reset (MODE!=8) AND mstatus.MPRV is still 0 -- so
        // none of these loads can themselves ever become a translated
        // access. Every CSRRW (satp/pmpcfg0/pmpaddrN/mtvec/mstatus) is
        // issued only AFTER every load has already landed in its
        // register, with mstatus's own CSRRW (the one that can activate
        // MPRV) issued LAST, immediately before the tested access.
        //
        // A REAL BUG IN THIS TESTBENCH was caught here during initial
        // bring-up (not a core.sv bug): an earlier draft wrote mstatus
        // (activating MPRV+MPP) BEFORE the later pmpcfg0/pmpaddrN/va/
        // operand loads -- from that point on, mem_effective_priv was no
        // longer M (satp was already Sv39-active from an earlier CSRRW,
        // MPRV was now 1), so EVERY SUBSEQUENT LD in the driver's OWN
        // setup sequence became a real translated access against a page
        // table that was never meant to cover those scratch addresses --
        // an instant, unintended page fault, redirecting to mtvec's own
        // RESET value (0) since mtvec hadn't been programmed yet, an
        // infinite pc==0 loop. Caught immediately via a debug PC trace
        // during this file's own bring-up, before any real scenario was
        // ever run against it -- fixed by this strict "all loads, then
        // all CSR writes, mstatus last" ordering, never by touching
        // core.sv (whose own MPRV/mem_effective_priv behavior here is
        // exactly per spec -- see this file's own header note on
        // MPRV-only mem-stream privilege switching).
        pw = 0;
        prog[pw++] = enc_ld(5'd1, 5'd0, S_SATP_OFF);
        prog[pw++] = enc_ld(5'd3, 5'd0, S_PMPCFG0_OFF);
        prog[pw++] = enc_ld(5'd11, 5'd0, S_PMPADDR0_OFF);
        prog[pw++] = enc_ld(5'd12, 5'd0, S_PMPADDR1_OFF);
        prog[pw++] = enc_ld(5'd13, 5'd0, S_PMPADDR2_OFF);
        prog[pw++] = enc_ld(5'd4, 5'd0, S_VA_OFF);
        if (access_kind != AK_FETCH) prog[pw++] = enc_ld(5'd8, 5'd0, S_OPERAND_OFF);
        prog[pw++] = enc_ld(5'd2, 5'd0, S_MSTATUS_OFF); // loaded early; CSRRW'd last, below
        prog[pw++] = enc_addi(5'd6, 5'd0, 256); // mtvec = 0x100
        prog[pw++] = enc_addi(5'd30, 5'd0, 0);  // clear the fetch-success marker
        prog[pw++] = enc_addi(5'd9, 5'd0, 0);   // clear the amo/lr destination

        prog[pw++] = enc_csrrw(`CSR_SATP, 5'd1);
        prog[pw++] = enc_csrrw(`CSR_PMPCFG0, 5'd3);
        prog[pw++] = enc_csrrw(`CSR_PMPADDR0, 5'd11);
        prog[pw++] = enc_csrrw(`CSR_PMPADDR1, 5'd12);
        prog[pw++] = enc_csrrw(`CSR_PMPADDR2, 5'd13);
        prog[pw++] = enc_csrrw(`CSR_MTVEC, 5'd6);
        prog[pw++] = enc_csrrw(`CSR_MSTATUS, 5'd2); // last CSR write -- may activate MPRV

        if (access_kind == AK_FETCH) begin
            prog[pw++] = enc_csrrw(`CSR_MEPC, 5'd4);
            prog[pw++] = MRET_INSN;
        end else begin
            unique case (access_kind)
                AK_LOAD:  prog[pw++] = enc_ld(5'd30, 5'd4, 0);
                AK_STORE: prog[pw++] = enc_sd(5'd8, 5'd4, 0);
                AK_AMO:   prog[pw++] = enc_amoadd_d(5'd9, 5'd4, 5'd8);
                default:  prog[pw++] = enc_lr_d(5'd9, 5'd4); // AK_LR
            endcase
            prog[pw++] = EBREAK_INSN; // success terminator
        end

        for (prog_lo = pw; prog_lo < 24; prog_lo = prog_lo + 1) prog[prog_lo] = NOP_INSN;
        for (prog_hi = 0; prog_hi < 12; prog_hi = prog_hi + 1)
            dut.sram0.memory[prog_hi] = {prog[2*prog_hi + 1], prog[2*prog_hi]};

        // ---- Handler (written once would suffice, but rewriting every
        // iteration is cheap and removes any doubt it could ever be
        // clobbered by a scenario's own program-word writes above, which
        // only ever touch words 0-11 / bytes 0x00-0x5F). ----
        dut.sram0.memory[HANDLER_WORD]     = {enc_csrrs(`CSR_MTVAL, 5'd21), enc_csrrs(`CSR_MCAUSE, 5'd20)};
        dut.sram0.memory[HANDLER_WORD + 1] = {NOP_INSN, EBREAK_INSN};

        // ---- Reset pulse, then run to completion or timeout. ----
        rst = 1'b1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 1'b0;

        captured = 1'b0;
        mcause_actual = 64'd0;
        mtval_actual  = 64'd0;
        for (cyc = 0; cyc < ITER_CYCLE_BUDGET; cyc = cyc + 1) begin
            @(posedge clk); #1;
            if (!captured && dut.core0.commit_now && dut.core0.pc == 64'h108) begin
                captured = 1'b1;
                mcause_actual = dut.core0.regfile0.gp_registers[20];
                mtval_actual  = dut.core0.regfile0.gp_registers[21];
            end
            if (captured && dut.core0.trap_taken && dut.core0.is_ebreak) begin
                cyc = ITER_CYCLE_BUDGET;
            end
        end
        if (!captured) begin
            $display("TIMEOUT: iteration never reached the trap-capture handler (pc==0x108)");
            $finish;
        end

        fault_seen      = (mcause_actual != 64'd3); // 3 == breakpoint == the success terminator
        x30_actual      = dut.core0.regfile0.gp_registers[30];
        x9_actual       = dut.core0.regfile0.gp_registers[9];
        mem_word_actual = dut.sram0.memory[target_word];
    endtask

    /* ==================================================================
     * Main body: cross-validate, then run NUM_ITER randomized scenarios.
     * ================================================================== */
    int completed_iters = 0;

    initial begin
        rst = 1'b1;
        #1;

        run_cross_validation();

        for (int i = 0; i < NUM_ITER; i = i + 1) begin
            int cat_sel, level, access_kind, sub;
            logic walk_past_l0;
            logic [1:0] priv;
            logic sum_bit, mxr_bit;
            logic leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d, leaf_n;
            logic [6:0] leaf_reserved;
            logic [1:0] leaf_pbmt;
            logic [8:0] leaf_ppn0, leaf_ppn1;
            logic [25:0] leaf_ppn2;
            int pmp_deny_level;
            logic [63:0] va, operand, target_pa;
            string cat_name;

            logic exp_fault; logic [3:0] exp_cause; logic [63:0] exp_vaddr, exp_rpa;
            logic act_fault; logic [63:0] act_mcause, act_mtval, act_x30, act_x9, act_memword;
            string ctx;

            // ---- Defaults: a plain, always-valid leaf (SUCCESS-shaped);
            // each category below overrides only what it needs to. ----
            level = $urandom_range(0, 2);
            access_kind = $urandom_range(0, 4);
            priv = $urandom_range(0, 1) ? PRIV_S : PRIV_U;
            sum_bit = 1'($urandom_range(0, 1));
            mxr_bit = 1'($urandom_range(0, 1));
            walk_past_l0 = 1'b0;
            pmp_deny_level = -1;
            leaf_v = 1'b1; leaf_r = 1'b1; leaf_w = 1'b1; leaf_x = 1'b1;
            leaf_a = 1'b1; leaf_d = 1'b1; leaf_n = 1'b0;
            leaf_reserved = 7'b0; leaf_pbmt = 2'b0;
            leaf_ppn2 = 26'd0; leaf_ppn1 = 9'd0; leaf_ppn0 = 9'd0;
            operand = {$urandom(), $urandom()};

            cat_sel = $urandom_range(0, 99);
            if (cat_sel <= 24)      cat_sel = CAT_SUCCESS;
            else if (cat_sel <= 39) cat_sel = CAT_MALFORMED;
            else if (cat_sel <= 49) cat_sel = CAT_SUPERPAGE;
            else if (cat_sel <= 56) cat_sel = CAT_WALKPASTL0;
            else if (cat_sel <= 68) cat_sel = CAT_USUM;
            else if (cat_sel <= 80) cat_sel = CAT_PERMMXR;
            else if (cat_sel <= 91) cat_sel = CAT_ADFAULT;
            else if (cat_sel <= 95) cat_sel = CAT_NONCANON;
            else                    cat_sel = CAT_PMPDENY;

            unique case (cat_sel)
                CAT_SUCCESS: begin
                    cat_name = "SUCCESS";
                    leaf_u = (priv == PRIV_U);
                    if (level == 0) leaf_ppn0 = 9'd4;
                end

                CAT_MALFORMED: begin
                    cat_name = "MALFORMED";
                    leaf_u = (priv == PRIV_U);
                    if (level == 0) leaf_ppn0 = 9'd4;
                    sub = $urandom_range(0, 4);
                    unique case (sub)
                        0: leaf_v = 1'b0;
                        1: begin leaf_r = 1'b0; leaf_w = 1'b1; end
                        2: leaf_reserved = 7'b0000001;
                        3: leaf_pbmt = 2'b01;
                        default: leaf_n = 1'b1;
                    endcase
                end

                CAT_SUPERPAGE: begin
                    cat_name = "SUPERPAGE_MISALIGN";
                    level = $urandom_range(0, 1) ? 2 : 1; // only levels 1/2 can misalign
                    leaf_u = (priv == PRIV_U);
                    if (level == 2) leaf_ppn1 = 9'd1; // nonzero -> misaligned gigapage
                    else            leaf_ppn0 = 9'd1; // nonzero -> misaligned megapage
                end

                CAT_WALKPASTL0: begin
                    cat_name = "WALK_PAST_LEVEL0";
                    level = 0;
                    walk_past_l0 = 1'b1;
                end

                CAT_USUM: begin
                    cat_name = "U_SUM";
                    if (level == 0) leaf_ppn0 = 9'd4;
                    sub = $urandom_range(0, 3);
                    unique case (sub)
                        0: begin // U=1, priv=S, SUM=0, mem -> fault
                            leaf_u = 1'b1; priv = PRIV_S; sum_bit = 1'b0;
                            access_kind = $urandom_range(0,3) == 0 ? AK_LOAD
                                        : $urandom_range(0,2) == 0 ? AK_STORE
                                        : $urandom_range(0,1) == 0 ? AK_AMO : AK_LR;
                        end
                        1: begin // U=1, priv=S, SUM=1, mem -> succeed
                            leaf_u = 1'b1; priv = PRIV_S; sum_bit = 1'b1;
                            access_kind = $urandom_range(0,3) == 0 ? AK_LOAD
                                        : $urandom_range(0,2) == 0 ? AK_STORE
                                        : $urandom_range(0,1) == 0 ? AK_AMO : AK_LR;
                        end
                        2: begin // U=1, priv=S, fetch -> ALWAYS fault, SUM irrelevant
                            leaf_u = 1'b1; priv = PRIV_S; access_kind = AK_FETCH;
                        end
                        default: begin // U=0, priv=U -> fault, any stream
                            leaf_u = 1'b0; priv = PRIV_U;
                        end
                    endcase
                end

                CAT_PERMMXR: begin
                    cat_name = "PERM_MXR";
                    leaf_u = (priv == PRIV_U);
                    if (level == 0) leaf_ppn0 = 9'd4;
                    sub = $urandom_range(0, 3);
                    unique case (sub)
                        0: begin // execute-only page, load/lr, MXR=0 -> fault
                            leaf_r = 1'b0; leaf_x = 1'b1; mxr_bit = 1'b0;
                            access_kind = $urandom_range(0,1) ? AK_LOAD : AK_LR;
                        end
                        1: begin // execute-only page, load/lr, MXR=1 -> succeed
                            leaf_r = 1'b0; leaf_x = 1'b1; mxr_bit = 1'b1;
                            access_kind = $urandom_range(0,1) ? AK_LOAD : AK_LR;
                        end
                        2: begin // R=1,W=0,X=1, store -> fault (W missing)
                            leaf_r = 1'b1; leaf_w = 1'b0; leaf_x = 1'b1;
                            access_kind = AK_STORE;
                        end
                        default: begin
                            // R=0,W=1,X=0, amo -> fault. HONEST CAVEAT (found by an
                            // independent adversarial review, 2026-09-09): this was
                            // originally meant to isolate "AMO needs read_ok in
                            // addition to W" as its own condition, but R=0,W=1 is
                            // UNCONDITIONALLY malformed per the Sv39 PTE encoding
                            // table (leaf_malformed's own !leaf_r&&leaf_w term) --
                            // there is no legal (non-malformed) PTE that is writable
                            // but not readable, so this scenario is always caught by
                            // the malformed check first and can never actually
                            // isolate the AMO-needs-both-R-and-W permission rule in
                            // its own right; that rule is spec-redundant given the
                            // encoding constraint, not independently testable. Kept
                            // as a (still-real, still-passing) check that malformed-
                            // PTE detection fires correctly for an AMO access
                            // specifically, not as proof of the dual-permission rule.
                            leaf_r = 1'b0; leaf_w = 1'b1; leaf_x = 1'b0; mxr_bit = 1'b0;
                            access_kind = AK_AMO;
                        end
                    endcase
                end

                CAT_ADFAULT: begin
                    cat_name = "AD_FAULT";
                    leaf_u = (priv == PRIV_U);
                    if (level == 0) leaf_ppn0 = 9'd4;
                    sub = $urandom_range(0, 2);
                    unique case (sub)
                        0: leaf_a = 1'b0; // A=0 -> always faults, any access kind
                        1: begin // A=1,D=0, writing access -> faults
                            leaf_a = 1'b1; leaf_d = 1'b0;
                            access_kind = $urandom_range(0,1) ? AK_STORE : AK_AMO;
                        end
                        default: begin // A=1,D=0, reading/fetch access -> succeeds
                            leaf_a = 1'b1; leaf_d = 1'b0;
                            access_kind = $urandom_range(0,2);
                            if (access_kind == AK_STORE) access_kind = AK_LOAD; // never a write here
                            if (access_kind == AK_AMO)   access_kind = AK_LR;
                        end
                    endcase
                end

                CAT_NONCANON: begin
                    cat_name = "NONCANONICAL_VA";
                    level = 0; // content irrelevant -- fires before any leaf is reached
                    leaf_u = (priv == PRIV_U);
                    leaf_ppn0 = 9'd4;
                end

                default: begin // CAT_PMPDENY
                    cat_name = "PMP_DENY";
                    leaf_u = (priv == PRIV_U);
                    if (level == 0) leaf_ppn0 = 9'd4;
                    pmp_deny_level = $urandom_range(level, 2);
                end
            endcase

            va = (cat_sel == CAT_NONCANON) ? NONCANON_VA : (level == 2 ? GIGA_VA : NORMAL_VA);
            target_pa = (level == 0) ? TARGET_PA_4K : TARGET_PA_SUPER;

            sv39_shadow_predict(level, walk_past_l0, va,
                leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d,
                leaf_reserved, leaf_pbmt, leaf_n, leaf_ppn2, leaf_ppn1, leaf_ppn0,
                access_kind, priv, sum_bit, mxr_bit, pmp_deny_level,
                exp_fault, exp_cause, exp_vaddr, exp_rpa);

            run_iteration(level, walk_past_l0, va,
                leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d,
                leaf_reserved, leaf_pbmt, leaf_n, leaf_ppn2, leaf_ppn1, leaf_ppn0,
                access_kind, priv, sum_bit, mxr_bit, pmp_deny_level, operand, target_pa,
                act_fault, act_mcause, act_mtval, act_x30, act_x9, act_memword);

            ctx = $sformatf(
                "iter %0d cat=%s level=%0d walk_past_l0=%0d va=%h access=%0d priv=%0d sum=%0d mxr=%0d leaf[v=%0d r=%0d w=%0d x=%0d u=%0d a=%0d d=%0d n=%0d resv=%h pbmt=%h ppn2=%h ppn1=%h ppn0=%h] pmp_deny=%0d operand=%h target_pa=%h expected[fault=%0d cause=%0d vaddr=%h rpa=%h] actual[fault=%0d mcause=%0d mtval=%h x30=%h x9=%h memword=%h]",
                i, cat_name, level, walk_past_l0, va, access_kind, priv, sum_bit, mxr_bit,
                leaf_v, leaf_r, leaf_w, leaf_x, leaf_u, leaf_a, leaf_d, leaf_n,
                leaf_reserved, leaf_pbmt, leaf_ppn2, leaf_ppn1, leaf_ppn0,
                pmp_deny_level, operand, target_pa,
                exp_fault, exp_cause, exp_vaddr, exp_rpa,
                act_fault, act_mcause, act_mtval, act_x30, act_x9, act_memword);

            check({ctx, " | fault-vs-success"}, {63'b0, act_fault}, {63'b0, exp_fault});

            if (exp_fault) begin
                check({ctx, " | mcause"}, act_mcause, {60'b0, exp_cause});
                check({ctx, " | mtval"},  act_mtval,  exp_vaddr);
                if (access_kind == AK_STORE || access_kind == AK_AMO)
                    check({ctx, " | memword unchanged on fault"}, act_memword, 64'hBEEF_0000_0000_0BEE);
            end else begin
                unique case (access_kind)
                    AK_FETCH: check({ctx, " | x30 marker==1"}, act_x30, 64'd1);
                    AK_LOAD:  check({ctx, " | loaded value"}, act_x30, 64'hBEEF_0000_0000_0BEE);
                    AK_LR:    check({ctx, " | lr value"}, act_x9, 64'hBEEF_0000_0000_0BEE);
                    AK_STORE: check({ctx, " | stored value landed"}, act_memword, operand);
                    default:  begin // AK_AMO
                        check({ctx, " | amo old value"}, act_x9, 64'hBEEF_0000_0000_0BEE);
                        check({ctx, " | amo new value landed"}, act_memword, 64'hBEEF_0000_0000_0BEE + operand);
                    end
                endcase
            end

            completed_iters = i + 1;
        end

        $display("");
        $display("core_sv39_random_tb: %0d iterations, %0d checks passed, %0d checks failed",
                  completed_iters, pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_random_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
