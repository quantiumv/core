// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: core (multi-cycle RV64I, Wishbone master)
 *
 * Supersedes the single-cycle version: instead of a combinational-read
 * imem/dmem pair private to this module, the core is now the SOLE master
 * on a shared Wishbone bus (see design/wb_addr_decoder.sv,
 * design/wb4_sram.sv, design/uart_tx.sv) -- instruction fetch and data
 * access are both real bus transactions now, and both slaves ack one
 * cycle after being addressed (registered, not combinational). That
 * multi-cycle reality is why this can no longer be single-cycle: a
 * 5-state FSM (S_FETCH / S_EXEC / S_MEM / S_AMO_WRITE / S_FETCH_HI)
 * sequences each instruction instead.
 *
 * decoder/alu/register_file are reused completely unchanged from the
 * single-cycle version -- they were already purely combinational glue
 * with no notion of "cycle" baked in, so nothing about them needed to
 * change. What's new here is entirely the FSM: WHEN the bus is driven,
 * and WHEN the results of that already-combinational logic are allowed to
 * actually commit (register-file write, pc update). See `commit_now`
 * below -- that one signal is the entire difference between this file and
 * the single-cycle version's control-flow shape.
 *
 * Per-instruction flow:
 *  S_FETCH: issue a bus read at pc (dword-aligned -- the bus is 64-bit
 *           wide, so one beat fetches up to 4 compressed halfwords or 2
 *           adjacent 32-bit instructions; pc[2:1] selects which of the
 *           4 halfword slots this instruction actually starts at -- see
 *           the C extension note below). Wait for ack, latch the 64-bit
 *           line, move to S_EXEC -- UNLESS the halfword at pc turns out
 *           to be the low half of an uncompressed instruction starting
 *           in the dword's LAST slot, in which case its other 16 bits
 *           live in the NEXT dword and next state is S_FETCH_HI instead.
 *  S_FETCH_HI: (C extension only, dword-crossing 32-bit instructions)
 *           issue a bus read at the NEXT dword. Wait for ack, latch its
 *           low 16 bits, move to S_EXEC.
 *  S_EXEC:  bus idle. The fetched halfword(s) are first run through
 *           design/c_expand.sv (a compressed instruction is expanded
 *           into its standard 32-bit equivalent; an uncompressed one
 *           passes through as-is) before decoder/alu/register_file
 *           settle combinationally off the result (exactly the
 *           single-cycle version's Decode/Control/Execute/Writeback/
 *           Next-PC logic, verbatim -- decoder.sv itself needs no C
 *           extension awareness at all). If this instruction is a load
 *           or store, move to S_MEM without committing anything yet.
 *           Otherwise this is the instruction's last cycle: commit
 *           (regfile write + pc update, by is_compressed ? 2 : 4 bytes)
 *           on this edge and return to S_FETCH.
 *  S_MEM:   (loads/stores only) issue a bus read or write at alu_result.
 *           Wait for ack; on that edge commit (a load's regfile write
 *           happens HERE, not in S_EXEC, since the loaded value doesn't
 *           exist yet when S_EXEC ends) and return to S_FETCH -- UNLESS
 *           this is one of the 9 read-modify-write AMO ops, in which case
 *           this ack was only the READ half and next state is
 *           S_AMO_WRITE instead.
 *  S_AMO_WRITE: (the 9 read-modify-write AMO ops only) issue a bus write
 *           at the SAME address S_MEM just read from, using a value
 *           computed from the just-captured old memory value and rs2.
 *           Wait for ack; commit (both the memory write's effect and
 *           rd = the OLD value) happens HERE, not in S_MEM.
 *
 * Why nothing needs re-latching between S_EXEC and S_MEM: pc doesn't
 * change until commit_now, and the fetched instruction doesn't change
 * until the next S_FETCH's (or, for a crossing instruction, S_FETCH_HI's)
 * ack -- so every combinational signal derived from them
 * (decoded_instruction, imm_1/imm_2, alu_result, next_pc, ...) is already
 * stable for the instruction's entire multi-cycle lifetime, with no extra
 * latching required beyond the (now up to two) real latches this design
 * adds (the fetched instruction line, plus -- only for a dword-crossing
 * C instruction -- the second dword's low halfword).
 *
 * Scope: full RV64IMAC base ISA + Zicsr + full U/S/M privilege modes,
 * plus machine-timer interrupts (CLINT mtime/mtimecmp, see i_mtip below
 * and the Interrupts section near csr_file0's instantiation). No Sv39,
 * no external/PLIC interrupts, no IPI/msip -- later milestones (a
 * different teammate's work for Sv39). Misaligned DATA access (loads/stores) traps cleanly (see
 * mem_load_misaligned/mem_store_misaligned below) rather than being
 * handled in hardware -- actual misaligned load/store SUPPORT stays
 * deferred to a later milestone alongside Sv39, but silently truncating
 * an overflowing access instead of either handling or trapping it, as
 * this core did before, isn't spec-legal, so the trap half is done now.
 * FENCE is still deliberately under-implemented (see its handling
 * below). Misaligned INSTRUCTION fetch, by contrast, is a real,
 * exercised case as of the C extension (any compressed instruction can
 * leave pc 2-byte- rather than 4-byte-aligned) and IS correctly
 * handled, not a gap. wb_err_i now feeds instruction/load/store
 * access-fault traps (causes 1/5/7 -- see wb_done/wb_ok, fetch_fault_q,
 * mem_load_access_fault/mem_store_access_fault below).
 *
 * Input ports:
 *  clk: Clock.
 *  rst: Synchronous reset (active high) -- resets pc and FSM state.
 *       Does NOT reset register/memory contents; the ISA doesn't
 *       require it, and real hardware doesn't guarantee it either
 *       (only the reset vector is architecturally defined).
 *
 * Wishbone master port: standard CLASSIC-cycle signal names, written
 * from this module's (the master's) point of view -- `_o` drives the
 * bus, `_i` reads it. Connects to design/wb_addr_decoder.sv's CPU-facing
 * port one-for-one (that module's `_i`/`_o` are the mirror image of
 * these, as expected for a master/slave pair).
 *
 * wb_ifetch_o: side-band, not part of the Wishbone protocol itself --
 * high while the CURRENT bus transaction is an instruction fetch
 * (S_FETCH/S_FETCH_HI), low for load/store/AMO (S_MEM/S_AMO_WRITE). This
 * core still exposes only ONE time-multiplexed Wishbone master port
 * (fetch and mem/AMO never overlap -- single-issue, non-pipelined), so a
 * downstream cache layer has no other way to tell which logical stream
 * (I$ vs D$) a given transaction belongs to. Defined off `state` directly
 * (see wb_master_drive below), not gated by !wb_done the way
 * wb_addr_o/wb_cyc_o are -- `state` only updates on the following clock
 * edge, so this stays stable through the exact cycle a downstream router
 * needs it on, unlike wb_addr_o/wb_cyc_o which combinationally collapse
 * to idle the instant the bus cycle terminates (ack or err).
 *
 * icache_flush_o: Zifencei's FENCE.I, side-band like wb_ifetch_o above --
 * pulses one cycle on FENCE.I's own retirement (assign icache_flush_o =
 * commit_now && is_fence_i;), telling a downstream I$ to invalidate its
 * contents. Timing is provably clean, not just probably fine: FENCE.I
 * retires purely within S_EXEC (bus-idle for this single-issue,
 * non-pipelined core -- it issues zero bus traffic during S_EXEC), so
 * the I$ is provably CACHE_IDLE at the exact cycle this pulses -- no
 * mid-refill-flush case exists to reason about. D$ never needed a
 * flush path to begin with (write-through already keeps a store hit's
 * cached copy and SRAM in lockstep).
 *
 * i_mtip: machine-timer-interrupt-pending level from an external CLINT
 * (design/clint.sv's mtip_o, see soc.sv). Continuously-valid status
 * level, not a pulse -- spliced into mip's bit 7 inside csr_file0 and
 * consumed combinationally by this module's own Interrupts section
 * (near csr_file0's instantiation, below) to decide interrupt_taken.
 * ANSI default (= 1'b0) so the 16+ testbenches/harnesses that
 * instantiate core directly without driving this port stay compile-
 * and lint-clean (same precedent as csr_file.sv's own i_mtip default).
 */
module core (
    input logic clk,
    input logic rst,

    output logic [31:0] wb_addr_o,
    output logic [63:0] wb_dat_o,
    input  logic [63:0] wb_dat_i,
    output logic [7:0]  wb_sel_o,
    output logic        wb_we_o,
    output logic        wb_cyc_o,
    output logic        wb_stb_o,
    input  logic        wb_ack_i,
    input  logic        wb_err_i,
    output logic        wb_ifetch_o,
    output logic        icache_flush_o,
    input  logic         i_mtip = 1'b0

    /*
     * RVFI (RISC-V Formal Interface) -- only present when compiled for
     * riscv-formal (see verification/riscv-formal/), never in a normal
     * build/lint/simulation run. Hand-written rather than pulled in via
     * riscv-formal's own `RVFI_OUTPUTS macro (checks/rvfi_macros.vh) so
     * core.sv has no dependency on that separately-cloned repo existing
     * at build time -- these widths are just RVFI_OUTPUTS's own
     * expansion for our fixed NRET=1/XLEN=64/ILEN=32, spelled out
     * directly. First slice covers base-ISA checks (isa=rv64i in
     * checks.cfg) only. CSR trace ports added deliberately, one extension's
     * worth at a time: mepc/mcause/sepc/scause first (simple 3-source
     * always_ff registers, mirrored combinationally in csr_file.sv for the
     * *_next/wdata side -- see that module's own header comment) --
     * mstatus deliberately deferred (12 real fields written from 5
     * different sources, a substantially bigger lift, its own round later).
     */
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
    output logic [63:0] rvfi_csr_scause_wdata
`endif
);

    /* --------------------------------------------------------------- *
     * FSM state
     * --------------------------------------------------------------- */

    /*
     * C extension: S_FETCH_HI is appended LAST, not inserted after
     * S_FETCH where it would read more naturally -- load-bearing, not
     * cosmetic. This preserves S_FETCH=0/S_EXEC=1/S_MEM=2/S_AMO_WRITE=3 at
     * their CURRENT numeric values (only the enum's bit-width widens,
     * 2->3 bits), so the 15 existing testbenches that hardcode a numeric
     * state literal (e.g. 2'd1 for S_EXEC, 2'd3 for S_AMO_WRITE -- see
     * testbench/core_priv_tb.sv, core_priv_u_ecall_tb.sv, core_zicsr_tb.sv
     * via pc_trigger_sample_monitor's default STATE_WIDTH=2, and the
     * hand-rolled checks in core_a_ext_tb.sv/core_m_ext_tb.sv) keep
     * comparing correctly -- Verilog zero-extends their narrower literal
     * against this now-wider signal, landing on the same enum value.
     * Inserting the new state anywhere else would silently renumber
     * every later state and either misfire or, worse, silently match the
     * wrong state in all 15 of those pre-existing call sites.
     */
    typedef enum logic [2:0] {
        S_FETCH,
        S_EXEC,
        S_MEM,
        S_AMO_WRITE,
        S_FETCH_HI
    } state_t;

    state_t state;

    /*
     * Current privilege level (U/S/M privilege-mode milestone). Standard
     * RISC-V encoding -- bare local enum, no defaults.sv entry, same
     * precedent as state_t immediately above.
     */
    typedef enum logic [1:0] {
        PRIV_U = 2'b00,
        PRIV_S = 2'b01,
        PRIV_M = 2'b11
    } priv_t;

    priv_t current_priv;

    logic [(`WORD_SIZE - 1):0] pc;
    logic [(`WORD_SIZE - 1):0] next_pc;

    /*
     * Forward-declared here (driven later, in the Control unit and
     * PC/halt sections respectively) purely because Icarus Verilog wants
     * a signal declared before its first use, textually -- unlike the
     * rest of this file, mem_phase_needed/wb_master_drive genuinely need
     * to reference them earlier in the file than where they're driven.
     * div_stall joins them for the same reason -- commit_now/the S_EXEC
     * transition below need it, but it isn't actually driven until the
     * "M extension: divide" section, much further down. is_amo_rmw joins
     * them for the identical reason (A extension) -- driven later via a
     * plain assign, never redeclared as `wire ... = ...` at its point of
     * computation.
     *
     * amo_rdata_q/amo_addr_q/amo_sel_q are forward-declared for a
     * different reason: they're REGISTERS (driven by an always_ff),
     * needed by alu_operand_a/b (Execute, textually early) but only
     * correctly drivable after Memory's load_data/mem_addr/mem_sel exist
     * (textually late) -- same "declare early, drive late" split
     * csr_rdata/medeleg_w already use.
     */
    logic is_load, is_store;
    logic div_stall;
    logic is_amo_rmw;
    logic mem_load_misaligned, mem_store_misaligned;
    logic mem_load_access_fault, mem_store_access_fault;
    /*
     * trap_taken: forward-declared here (assigned near exc_code far
     * below) purely so the reservation register block above its own
     * declaration site can gate on it -- same forward-reference pattern
     * mem_load_misaligned/mem_store_misaligned already establish.
     */
    logic trap_taken;
    /*
     * interrupt_taken/interrupt_to_s: forward-declared here for the same
     * reason as trap_taken -- csr_file0's own i_trap_taken/i_trap_to_s
     * connections need them, but their real assign lives in the new
     * Interrupts section after csr_file0's instantiation (it needs
     * csr_file0's own mip_w/mie_w/etc. outputs first).
     *
     * trap_vector: forward-declared (was previously declared+driven
     * together as `wire trap_vector = ...`) because wb_master_drive's
     * S_FETCH arm now needs to read it, but wb_master_drive is textually
     * BEFORE trap_vector's own real assign (down near Next PC) -- same
     * "declare early, drive late" split trap_val/amo_rdata_q already use.
     */
    logic interrupt_taken;
    logic interrupt_to_s;
    logic [(`WORD_SIZE - 1):0] trap_vector;
    logic [(`WORD_SIZE - 1):0] amo_rdata_q;
    /*
     * amo_addr_q: WORD_SIZE-wide for the RVFI tap's rvfi_mem_addr (see its
     * own assign's comment) -- real hardware only ever consumes its low 32
     * bits for the actual bus address (wb_addr_o = amo_addr_q[31:0], this
     * core's physical address space is deliberately 32-bit), same
     * reasoning/precedent as mem_paddr above. Bits[63:32] are no longer
     * dead outside `ifdef RISCV_FORMAL, though: trap_val's access-fault
     * arm (see mem_load_access_fault/mem_store_access_fault below) reads
     * this register unconditionally, since it's the only stable address
     * during S_AMO_WRITE (mem_paddr is repurposed for the modify value by
     * then) -- genuinely fully used in every build now.
     */
    logic [(`WORD_SIZE - 1):0] amo_addr_q;
    logic [7:0]  amo_sel_q;
    /*
     * amo_byte_off_q: the TRUE (unrounded) low 3 address bits, captured
     * separately from amo_addr_q -- amo_addr_q is deliberately rounded
     * down to a dword boundary (needed for both the real bus address and
     * the RVFI-tap address), which throws away exactly the information
     * amo_wdata's byte-lane shift needs for a .W AMO sitting in the
     * UPPER word of its containing dword (address bit 2 set -- legal:
     * .W only needs 4-byte alignment, not 8-byte). See amo_wdata's own
     * comment for the real bug this fixes.
     */
    logic [2:0]  amo_byte_off_q;

    /*
     * commit_now: the single edge, per instruction, where the
     * register-file write and the pc update are allowed to actually
     * happen. Every other cycle of an instruction's multi-cycle lifetime
     * (bus wait states, the settle cycle itself) must NOT commit, even
     * though decoder/alu outputs are sitting there fully formed the
     * whole time -- reg_write/next_pc are free-running combinational
     * signals with no notion of "am I allowed to land yet", so this is
     * the one gate that turns "instruction is decoded" into "instruction
     * has retired". Non-memory instructions retire at the end of
     * S_EXEC; loads/stores retire when S_MEM's bus transaction acks.
     *
     * div_stall generalizes this same idea to the one OTHER thing that
     * can now make a non-memory instruction take more than a single
     * S_EXEC cycle: an in-flight divide (see "M extension: divide"
     * below, and design/divider.sv's own header -- this is the first
     * variable-latency non-memory instruction this core has ever had).
     * div_stall/is_div_family are declared further down, in the M
     * extension section, but referenced here -- same forward-reference
     * pattern is_load/is_store already use from this exact spot.
     * mem_phase_needed and div_stall can never both be true together (a
     * single decoded instruction can't be both a divide and a load/store),
     * so there's no ordering/priority to arbitrate between them below.
     *
     * mem_load_misaligned/mem_store_misaligned (driven in the Memory
     * section below, once mem_paddr exists -- same forward-reference
     * split as is_load/is_store) suppress the bus phase entirely for a
     * misaligned access: it commits (traps) at the end of S_EXEC instead,
     * same mechanism illegal-instruction/ecall already use to trap
     * without ever touching the bus.
     */
    wire mem_phase_needed = (is_load || is_store) && !(mem_load_misaligned || mem_store_misaligned);

    /*
     * wb_done/wb_ok: wb4_sram.sv (the real leaf memory) keeps ack/err
     * mutually exclusive per the Wishbone B4 convention -- an out-of-range
     * access sets err_o with ack_o held 0. But icache.sv/dcache.sv (fixed
     * for an earlier hang bug, see their own CACHE_REFILL comments) assert
     * ack_o TOGETHER WITH err_o on a downstream error -- a deliberate
     * compromise made back when this file had nothing consuming wb_err_i
     * at all. Through the real soc.sv topology, that means wb_ack_i can go
     * high even on an errored cache response, so bare wb_ack_i is
     * ambiguous: it no longer means "this succeeded". wb_done means "this
     * bus cycle has terminated, one way or another" (safe for anything
     * that just needs to stop waiting -- state-transition/re-issue-guard
     * triggers); wb_ok means "terminated CLEANLY, no error" (needed
     * wherever a decision about proceeding to the NEXT NORMAL phase is
     * made -- fetch_hi_taken below, and S_MEM's AMO-read-succeeded
     * decision). Never use bare wb_ack_i below this point.
     */
    wire wb_done = wb_ack_i || wb_err_i;
    wire wb_ok   = wb_ack_i && !wb_err_i;

    /*
     * commit_now, extended for the A extension: an AMO op's
     * mem_phase_needed=1 now spans TWO sequential bus transactions
     * (S_MEM's read, then S_AMO_WRITE's write), not one -- S_MEM's ack
     * must NOT commit for an AMO op (it only ends the read half), only
     * S_AMO_WRITE's ack does. LR/SC/plain loads/stores are unaffected:
     * is_amo_rmw is false for all of them, so the new `&& !is_amo_rmw`
     * term is a no-op and they still commit at S_MEM exactly as before.
     *
     * Bus-error trapping: an S_MEM response that errors commits
     * IMMEDIATELY (the `|| wb_err_i` term) regardless of is_amo_rmw --
     * an AMO whose read phase faults must trap right there, not proceed
     * into S_AMO_WRITE and issue a bogus second write (see the FSM below).
     * S_AMO_WRITE now commits on wb_done (ack OR err), not just wb_ack_i,
     * since a faulted write phase must still retire (as a trap) rather
     * than hang. mem_load_access_fault/mem_store_access_fault (declared
     * near mem_load_misaligned/mem_store_misaligned below) turn these
     * error-commits into the correct trap via exc_code/trap_val.
     *
     * `!halted` (2026-08-12, removed 2026-08-20): a prior milestone added
     * an explicit `!halted` term here to close a riscv-formal pc_fwd_ch0
     * counterexample -- a spurious post-halt wb_ack_i could otherwise
     * produce a bogus extra rvfi_valid pulse with pc frozen but state
     * still oscillating, since nothing structurally prevented state from
     * reaching S_EXEC again once parked in S_FETCH forever. That whole
     * scenario no longer exists as a concept now that EBREAK is a real
     * trap (see is_ebreak's own arm in exc_code/trap_taken below): the
     * core never parks in S_FETCH permanently anymore, so there is no
     * "post-halt" state left to guard against. Confirmed, not assumed:
     * pc_fwd_ch0 and pc_bwd_ch0 (the two checks that originally caught
     * this counterexample) both re-run clean against this exact removal.
     */
    wire commit_now = (state == S_EXEC && !mem_phase_needed && !div_stall)
                    || (state == S_MEM && ((wb_ok && !is_amo_rmw) || wb_err_i))
                    || (state == S_AMO_WRITE && wb_done);

    /*
     * C extension: fetch_hi_needed decides, on the SAME edge S_FETCH's
     * ack arrives, whether the halfword about to become "the current
     * instruction" is the low half of an uncompressed (32-bit)
     * instruction that starts in this dword's LAST halfword slot
     * (pc[2:1]==2'b11) -- the one case where the other 16 bits live in
     * the NEXT dword, needing a second bus transaction (S_FETCH_HI)
     * before Execute can begin. Computed directly off the live
     * wb_dat_i, not the not-yet-updated instr_line_q -- the exact same
     * "combinationally derive from wb_dat_i on the same edge a sibling
     * register captures it" pattern the A extension's
     * amo_rdata_q <= load_data already established (load_data is
     * itself combinationally wb_dat_i-derived), just applied to a new
     * spot. A compressed instruction never needs this: any 2-byte-
     * aligned halfword is always fully inside its own 8-byte dword, so
     * a quadrant field (the halfword's own low 2 bits) of anything
     * other than 2'b11 rules out crossing regardless of pc[2:1].
     *
     * fetch_hi_taken adds wb_ok on top of fetch_hi_needed: on a fetch
     * error, wb_dat_i's bits are meaningless, so a faulted fetch must
     * never chase a second, bogus fetch based on garbage -- it needs to
     * fall straight through to S_EXEC and trap via fetch_fault_q instead.
     */
    wire fetch_hi_needed = (pc[2:1] == 2'b11) && (wb_dat_i[49:48] == 2'b11);
    wire fetch_hi_taken  = wb_ok && fetch_hi_needed;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
        end else begin
            case (state)
                S_FETCH:     if (wb_done) state <= state_t'(fetch_hi_taken ? S_FETCH_HI : S_EXEC);
                S_FETCH_HI:  if (wb_done) state <= S_EXEC;
                S_EXEC:      state <= state_t'(mem_phase_needed ? S_MEM : (div_stall ? S_EXEC : S_FETCH));
                S_MEM:       if (wb_done) state <= state_t'((wb_ok && is_amo_rmw) ? S_AMO_WRITE : S_FETCH);
                S_AMO_WRITE: if (wb_done) state <= S_FETCH;
                default:     state <= S_FETCH;
            endcase
        end
    end

    /* --------------------------------------------------------------- *
     * Fetch
     * --------------------------------------------------------------- */

    /*
     * The bus is 64-bit wide and word-addressed (low 3 address bits
     * unused, same convention as wb4_sram.sv/wb_addr_decoder.sv) -- one
     * fetch beat brings in a full dword: up to 4 compressed halfwords,
     * or 2 uncompressed 32-bit instructions. C extension: pc is no
     * longer always 4-byte-aligned (a compressed instruction is only 2
     * bytes), so pc[2:1] -- not just pc[2] -- now selects which of the
     * dword's 4 halfword slots is "first". An uncompressed instruction
     * starting in the LAST slot (pc[2:1]==2'b11) needs a second dword;
     * instr_hi_q/crossed_q exist for exactly that case (see
     * fetch_hi_needed above).
     */
    logic [63:0] instr_line_q;
    logic [15:0] instr_hi_q;
    logic        crossed_q;
    /*
     * fetch_fault_q: captures whether THIS fetch (S_FETCH or S_FETCH_HI)
     * came back as a bus error, at the exact same edge instr_line_q/
     * instr_hi_q get latched. No explicit reset needed -- mirrors those
     * two registers' own established convention: always freshly written
     * on the edge S_EXEC is first reached, so nothing ever consults it
     * uninitialized. Consumed by `instruction` below (substitutes an
     * inert placeholder so decode never runs on garbage fetched bits) and
     * by exc_code/trap_val (instruction access fault, cause 1).
     */
    logic        fetch_fault_q;
    always_ff @(posedge clk) begin
        if (state == S_FETCH && wb_done) begin
            instr_line_q  <= wb_dat_i;
            crossed_q     <= fetch_hi_taken;
            fetch_fault_q <= wb_err_i;
        end
        if (state == S_FETCH_HI && wb_done) begin
            instr_hi_q    <= wb_dat_i[15:0];
            fetch_fault_q <= wb_err_i;  // plain overwrite, not an OR-latch: S_FETCH_HI is
                                         // only ever reached when S_FETCH's own crossed_q
                                         // (== wb_ok) was set, so fetch_fault_q is
                                         // guaranteed 0 walking into S_FETCH_HI.
        end
    end

    /*
     * The dword's 4 possible 16-bit slots, and the "first"/"second"
     * halfword of the instruction actually at pc, selected by pc[2:1].
     * second_hw's own pc[2:1]==2'b11 arm is structural don't-care, not
     * a real case -- that combination is exactly what triggers
     * S_FETCH_HI instead (raw32_noncompressed below reads instr_hi_q in
     * that case, never second_hw).
     */
    wire [15:0] hw0 = instr_line_q[15:0];
    wire [15:0] hw1 = instr_line_q[31:16];
    wire [15:0] hw2 = instr_line_q[47:32];
    wire [15:0] hw3 = instr_line_q[63:48];

    wire [15:0] first_hw  = pc[2:1] == 2'b00 ? hw0 :
                             pc[2:1] == 2'b01 ? hw1 :
                             pc[2:1] == 2'b10 ? hw2 : hw3;
    /* verilator lint_off WIDTHEXPAND */
    wire [15:0] second_hw = pc[2:1] == 2'b00 ? hw1 :
                             pc[2:1] == 2'b01 ? hw2 :
                             pc[2:1] == 2'b10 ? hw3 : 16'bx;
    /* verilator lint_on WIDTHEXPAND */

    /*
     * C extension: is_compressed is true iff first_hw's own quadrant
     * field (its own low 2 bits) isn't 2'b11 -- the RISC-V-standard
     * "which instruction length is this" test, independent of
     * crossed_q. A genuinely crossing 32-bit instruction (crossed_q=1)
     * always has first_hw[1:0]==2'b11 too (that's exactly what
     * triggered S_FETCH_HI), so the !crossed_q term isn't strictly
     * required for correctness here, but keeps this wire's meaning
     * self-evidently right without relying on that cross-reasoning.
     */
    wire is_compressed = !crossed_q && (first_hw[1:0] != 2'b11);

    wire [31:0] c_expand_out;
    wire        c_expand_illegal;
    c_expand c_expand0 (
        .i_instr16 (first_hw),
        .o_instr32 (c_expand_out),
        .o_illegal (c_expand_illegal)
    );

    /*
     * The real 32-bit instruction when !is_compressed: either both
     * halves already sit in instr_line_q (the common, non-crossing
     * case), or the low half is first_hw (== hw3 whenever crossed_q,
     * since crossing only ever happens at pc[2:1]==2'b11) and the high
     * half is instr_hi_q, captured during S_FETCH_HI.
     */
    wire [31:0] raw32_noncompressed = crossed_q ? {instr_hi_q, hw3} : {second_hw, first_hw};

    logic [(`INSTR_SIZE - 1):0] instruction;
    assign instruction = fetch_fault_q
        ? 32'h00000013 /* addi x0,x0,0 -- inert placeholder for a FAULTED fetch
                           (instr_line_q/instr_hi_q are garbage on wb_err_i).
                           Same trick as the compressed-illegal placeholder
                           below, one more reason it's safe to reuse: this
                           makes every downstream classification (is_load,
                           is_store, is_ebreak, is_illegal_instr, ...)
                           harmless ADDI-shaped no-ops, so nothing can act on
                           the garbage bits before the real trap mechanism
                           (fetch_fault_q feeding exc_code/trap_taken/trap_val
                           directly, see below) takes over. */
        : is_compressed
            ? (c_expand_illegal ? 32'h00000013 /* addi x0,x0,0 -- inert placeholder
                                                   value only, never the real trap
                                                   mechanism: is_illegal_instr below
                                                   (fed by c_expand_illegal
                                                   directly) is what actually traps
                                                   a reserved compressed encoding. */
                                 : c_expand_out)
            : raw32_noncompressed;

    /*
     * pc_plus_len: C extension's generalization of the old fixed pc+4
     * -- this instruction's real length is 2 bytes when compressed, 4
     * otherwise. Declared here (not down in Writeback, where the old
     * pc_plus_4 lived) since is_compressed is already available this
     * early and every consumer downstream just wants the resulting
     * wire. is_compressed itself is stable for the instruction's whole
     * multi-cycle lifetime (a pure combinational function of
     * instr_line_q/crossed_q/pc, all latched no later than S_EXEC),
     * same stability class as instruction itself.
     */
    wire [(`WORD_SIZE - 1):0] instr_len   = is_compressed ? `WORD_SIZE'(2) : `WORD_SIZE'(4);
    wire [(`WORD_SIZE - 1):0] pc_plus_len = pc + instr_len;

    /*
     * Dword-aligned fetch address, precomputed as a plain wire rather
     * than inline inside wb_master_drive's always_comb below -- same
     * "Icarus doesn't fully support constant selects inside always_*
     * processes" reason as everywhere else this pattern appears in this
     * file.
     */
    /*
     * fetch_paddr: named indirection point for a future Sv39 MMU stage.
     * Today a pure passthrough (pc IS the physical address -- no
     * translation exists yet); when Sv39 lands, only this wire's RHS
     * needs to change (e.g. to a page-table-walker's translated
     * output), with no restructuring of the surrounding FSM/bus-driving
     * logic below. (The halfword-select logic above is deliberately
     * left keyed on raw pc, not fetch_paddr -- pc[2:1] are page-OFFSET
     * bits, always identity-mapped even under Sv39, so there's nothing
     * for translation to ever change there.)
     *
     * Deliberately WORD_SIZE-wide even though only bits[31:3] are
     * consumed today (this core's physical address space is 32 bits) --
     * a real translated address should be able to occupy the full seam
     * width without a resize, so the unused bits are structural, not an
     * oversight.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] fetch_paddr = pc;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] fetch_addr = {fetch_paddr[31:3], 3'b0};

    /*
     * C extension: the second dword a crossing (S_FETCH_HI) fetch
     * needs, one dword past fetch_addr. Only ever driven onto the bus
     * from the S_FETCH_HI arm of wb_master_drive below.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] fetch_paddr_hi = fetch_paddr + `WORD_SIZE'(8);
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] fetch_addr_hi = {fetch_paddr_hi[31:3], 3'b0};

    /* --------------------------------------------------------------- *
     * Decode
     * --------------------------------------------------------------- */

    logic [(`L2_REG_FILE_SIZE - 1):0] read_gpr_A_sel, read_gpr_B_sel;
    logic [(`WORD_SIZE - 1):0]        read_gpr_A_data, read_gpr_B_data;
    logic [(`INSTR_CODE_SIZE - 1):0]  decoded_instruction;
    logic [(`WORD_SIZE - 1):0]        imm_1, imm_2;
    logic [(`B_IMM_SIZE - 1):0]       imm_3_or_dest_addr;

    /*
     * decoder <-> register_file looks port-level circular (decoder's
     * *_sel outputs feed regfile's read ports; regfile's read *_data
     * outputs feed back into decoder's i_read_gpr_*_data inputs, which
     * decoder uses to produce o_imm_1/o_imm_2) but it isn't a real
     * combinational cycle: the *_sel outputs depend ONLY on
     * i_instruction inside decoder, never on the data that comes back.
     * It settles in zero simulated time as a plain feedforward chain --
     * and since `instruction` is latched (stable for the whole
     * instruction), so is everything downstream of it here.
     */
    decoder decoder0 (
        .i_instruction(instruction),
        .i_instruction_address(pc),
        /*
         * Explicitly connected to nothing (not omitted) -- it's just a
         * passthrough of i_instruction_address (i.e. pc), nothing
         * downstream needs a second copy of it. Empty parens rather than
         * leaving the line out entirely so lint tools see this as
         * deliberate rather than a possibly-forgotten connection.
         */
        /* verilator lint_off PINCONNECTEMPTY */
        .o_instruction_address(),
        /* verilator lint_on PINCONNECTEMPTY */
        .o_read_gpr_A_sel(read_gpr_A_sel),
        .i_read_gpr_A_data(read_gpr_A_data),
        .o_read_gpr_B_sel(read_gpr_B_sel),
        .i_read_gpr_B_data(read_gpr_B_data),
        .o_decoded_instruction(decoded_instruction),
        .o_imm_1(imm_1),
        .o_imm_2(imm_2),
        .o_imm_3_or_dest_addr(imm_3_or_dest_addr)
    );

    logic                       reg_write;
    logic [(`WORD_SIZE - 1):0]  reg_write_data;

    register_file regfile0 (
        .i_clk(clk),
        .i_read_gpr_A_sel(read_gpr_A_sel),
        .o_read_gpr_A_data(read_gpr_A_data),
        .i_read_gpr_B_sel(read_gpr_B_sel),
        .o_read_gpr_B_data(read_gpr_B_data),
        .i_load_gpr(reg_write),
        /*
         * imm_3_or_dest_addr means two unrelated things depending on
         * instruction type (see decoder.sv's port doc for the full
         * story): a signed S/B-type offset, or a plain 5-bit rd index
         * (R/I/U/J-type). Here we use ONLY the low 5 bits, as an
         * unsigned register index -- correct for the R/I/U/J case, and
         * harmless for S/B-type (stores and branches never assert
         * reg_write, so regfile0 ignores this value in that case
         * regardless of what garbage sign bits sit above it). Getting
         * this confused with the SIGNED interpretation (imm3_sext,
         * below) is the single easiest mistake to make with this port --
         * small positive immediates look identical either way, so a
         * quick smoke test won't catch it, only a negative-offset test
         * will (see core_load_store_tb.sv).
         */
        .i_load_gpr_sel(imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0]),
        .i_load_gpr_data(reg_write_data)
    );

    /* Sign-extended S/B-type offset -- see the comment above. */
    wire [(`WORD_SIZE - 1):0] imm3_sext =
        {{(`WORD_SIZE - `B_IMM_SIZE){imm_3_or_dest_addr[`B_IMM_SIZE - 1]}}, imm_3_or_dest_addr};

    /* --------------------------------------------------------------- *
     * Control unit
     * --------------------------------------------------------------- */

    wire is_auipc  = (decoded_instruction == `INSTR_CODE(AUIPC));
    wire is_jal    = (decoded_instruction == `INSTR_CODE(JAL));
    wire is_jalr   = (decoded_instruction == `INSTR_CODE(JALR));
    wire is_ebreak = (decoded_instruction == `INSTR_CODE(EBREAK));

    /*
     * ADDW/SUBW/ADDIW reuse the plain ADD/SUB ALU ops on full 64-bit
     * operands (bit-identical to a native 32-bit add/sub in the low 32
     * bits -- two's-complement addition is modular arithmetic) and get
     * truncated+re-signed HERE, centrally, in the write-back mux below.
     * SLLW/SRLW/SRAW(+I variants) can't take that shortcut -- a shift is
     * NOT bit-identical across widths (wrong-width operand, bits enter
     * from the wrong end) -- so those instead use dedicated 32-bit-wide
     * ALU ops (see alu_ops.sv) whose output is already the final,
     * correctly-extended 64-bit value; they fall through the write-back
     * mux untouched, same as any ordinary ALU result.
     */
    /*
     * MULW joins this same group for the same reason ADDW/SUBW do: a
     * 32x32-truncated-to-32 product is bit-identical regardless of what's
     * in the operands' upper 32 bits (multiplication mod 2^32 doesn't
     * depend on that), so MULW reuses MUL wholesale and just needs the
     * same central truncate+resign as ADDW/SUBW/ADDIW -- see
     * design/defaults/alu_ops.sv's own header comment on MUL for the
     * full argument. DIVW/DIVUW/REMW/REMUW do NOT belong here -- see the
     * "M extension: divide" section below for why they need their own
     * (non-ALU) truncation path instead.
     */
    wire is_word_arith = (decoded_instruction == `INSTR_CODE(ADDW))
                       || (decoded_instruction == `INSTR_CODE(SUBW))
                       || (decoded_instruction == `INSTR_CODE(ADDIW))
                       || (decoded_instruction == `INSTR_CODE(MULW));

    /*
     * A extension: LR/SC/AMO classification. Placed here, before
     * alu_op_sel/mem_control below -- load-bearing, not stylistic:
     * mem_control's SC arm needs sc_success, so this whole block must be
     * textually established first (unlike CSR's own classification,
     * which comes AFTER mem_control today, since nothing in mem_control
     * needs it).
     */
    wire is_lr_w = (decoded_instruction == `INSTR_CODE(LR_W));
    wire is_lr_d = (decoded_instruction == `INSTR_CODE(LR_D));
    wire is_lr   = is_lr_w || is_lr_d;

    wire is_sc_w = (decoded_instruction == `INSTR_CODE(SC_W));
    wire is_sc_d = (decoded_instruction == `INSTR_CODE(SC_D));
    wire is_sc   = is_sc_w || is_sc_d;

    wire is_amoswap_w = (decoded_instruction == `INSTR_CODE(AMOSWAP_W));
    wire is_amoswap_d = (decoded_instruction == `INSTR_CODE(AMOSWAP_D));
    wire is_amoadd_w  = (decoded_instruction == `INSTR_CODE(AMOADD_W));
    wire is_amoadd_d  = (decoded_instruction == `INSTR_CODE(AMOADD_D));
    wire is_amoxor_w  = (decoded_instruction == `INSTR_CODE(AMOXOR_W));
    wire is_amoxor_d  = (decoded_instruction == `INSTR_CODE(AMOXOR_D));
    wire is_amoor_w   = (decoded_instruction == `INSTR_CODE(AMOOR_W));
    wire is_amoor_d   = (decoded_instruction == `INSTR_CODE(AMOOR_D));
    wire is_amoand_w  = (decoded_instruction == `INSTR_CODE(AMOAND_W));
    wire is_amoand_d  = (decoded_instruction == `INSTR_CODE(AMOAND_D));
    wire is_amomin_w  = (decoded_instruction == `INSTR_CODE(AMOMIN_W));
    wire is_amomin_d  = (decoded_instruction == `INSTR_CODE(AMOMIN_D));
    wire is_amomax_w  = (decoded_instruction == `INSTR_CODE(AMOMAX_W));
    wire is_amomax_d  = (decoded_instruction == `INSTR_CODE(AMOMAX_D));
    wire is_amominu_w = (decoded_instruction == `INSTR_CODE(AMOMINU_W));
    wire is_amominu_d = (decoded_instruction == `INSTR_CODE(AMOMINU_D));
    wire is_amomaxu_w = (decoded_instruction == `INSTR_CODE(AMOMAXU_W));
    wire is_amomaxu_d = (decoded_instruction == `INSTR_CODE(AMOMAXU_D));

    wire is_amoswap = is_amoswap_w || is_amoswap_d;

    wire is_amo_rmw_w = is_amoswap_w || is_amoadd_w || is_amoxor_w || is_amoor_w
                      || is_amoand_w || is_amomin_w || is_amomax_w || is_amominu_w || is_amomaxu_w;
    wire is_amo_rmw_d = is_amoswap_d || is_amoadd_d || is_amoxor_d || is_amoor_d
                      || is_amoand_d || is_amomin_d || is_amomax_d || is_amominu_d || is_amomaxu_d;
    assign is_amo_rmw = is_amo_rmw_w || is_amo_rmw_d;   // drives the forward-declared logic above

    /* All 22 -- used only by the address-phase operand-B redirect below. */
    wire is_amo_family = is_lr || is_sc || is_amo_rmw;

    /*
     * amo_modify_phase: true for exactly the cycles alu0's inputs must be
     * redirected from "compute the address" to "compute the modify
     * value" -- gated purely on state, not on is_amo_rmw, since
     * S_AMO_WRITE is a state ONLY an is_amo_rmw instruction can ever
     * reach (LR/SC never transition there), so the state check alone is
     * unambiguous.
     */
    wire amo_modify_phase = (state == S_AMO_WRITE);

    /*
     * LR/SC/AMO's address is rs1 alone, no offset -- imm_1 IS the
     * address, available immediately post-decode. Deliberately NOT
     * alu_result/mem_paddr here (even though they're numerically equal
     * during S_EXEC): sc_success below is needed by mem_control, which
     * is declared textually BEFORE alu0 exists (Execute comes later) --
     * using imm_1 sidesteps that ordering entirely rather than requiring
     * mem_control to be relocated after Execute.
     */
    wire [(`WORD_SIZE - 1):0] amo_target_addr = imm_1;

    /*
     * Reservation register (LR/SC). Set unconditionally on LR's own
     * retirement (a fresh LR always creates a new reservation,
     * superseding any prior one -- a plain overwrite, not a conditional
     * set) -- but ONLY when LR actually retires cleanly (`!trap_taken`),
     * same gate reg_write/csr_we already use. Without it, a faulted LR
     * (misaligned, or -- since is_lr is purely combinational/decode-based
     * and doesn't care about the bus outcome -- a real access-fault via
     * mem_store_access_fault, newly reachable once wb_err_i started
     * feeding commit_now) would still set a "valid" reservation for a
     * load that never happened, letting a later SC to that address
     * spuriously report success. Found via code review, not a test
     * failure -- see testbench/core_reservation_fault_tb.sv for the
     * proof (a faulted LR immediately followed by an SC to the same
     * address must NOT report success). Cleared on ANY store-class
     * instruction's retirement: ordinary SB/SH/SW/SD (is_store), SC
     * either way (is_sc, since is_store alone only catches SC's MATCHED
     * case), or an AMO's write (is_amo_rmw) -- matching the spec
     * requirement that a used reservation can't be reused. The clear
     * arm doesn't need the same `!trap_taken` guard: a faulted store/SC/
     * AMO-write never actually wrote anything either, but invalidating
     * the reservation anyway is still spec-conformant (a reservation
     * surviving a faulted store attempt is not architecturally
     * guaranteed) and strictly safer than leaving it valid.
     */
    logic reservation_valid_q;
    logic [(`WORD_SIZE - 1):0] reservation_addr_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            reservation_valid_q <= 1'b0;
        end else if (commit_now && is_lr && !trap_taken) begin
            reservation_valid_q <= 1'b1;
            reservation_addr_q  <= amo_target_addr;
        end else if (commit_now && (is_store || is_sc || is_amo_rmw)) begin
            reservation_valid_q <= 1'b0;
        end
    end

    /*
     * sc_success: a pure register compare, no bus access needed -- known
     * combinationally as soon as decode settles in S_EXEC, and stable
     * for SC's entire (possibly multi-cycle) lifetime, since nothing
     * else can retire (and so mutate the reservation) while SC itself is
     * in flight.
     */
    wire sc_addr_match = reservation_valid_q && (reservation_addr_q == amo_target_addr);
    wire sc_success = is_sc && sc_addr_match;
    wire [(`WORD_SIZE - 1):0] sc_result = sc_success ? `WORD_SIZE'(0) : `WORD_SIZE'(1);

    /*
     * amo_rs2_operand: rs2, width-adjusted for the modify-phase
     * computation. Per spec, only rs2's low 32 bits are ever meaningful
     * for a .W op -- sign-extended here to 64 bits uniformly for ALL 9
     * RMW ops (not just the signed-compare ones), same pattern
     * is_div_w_family already uses for DIVW's divisor. Safe for every
     * op, not just the "obviously signed" ones: ADD/XOR/OR/AND's low-32-
     * bit result is provably invariant to how the upper 32 bits of
     * either 64-bit operand are populated, and MINU/MAXU's unsigned
     * 32-bit comparison is provably identical to an unsigned 64-bit
     * comparison of the two sign-extended operands (sign extension is an
     * order-preserving embedding for unsigned comparison too).
     */
    wire [(`WORD_SIZE - 1):0] amo_rs2_operand = is_amo_rmw_w ? {{32{imm_2[31]}}, imm_2[31:0]} : imm_2;

    /*
     * amo_modify_operand_a/b: AMOSWAP's "new value" is rs2 verbatim --
     * same "operand_b=0, ADD" passthrough trick LUI/CSRRW already use,
     * just with operand_a set to amo_rs2_operand instead of the default
     * imm_1. Every other RMW op reads the just-captured OLD value
     * (amo_rdata_q) as operand_a and rs2 as operand_b.
     */
    wire [(`WORD_SIZE - 1):0] amo_modify_operand_a = is_amoswap ? amo_rs2_operand : amo_rdata_q;
    wire [(`WORD_SIZE - 1):0] amo_modify_operand_b = is_amoswap ? `WORD_SIZE'(0)  : amo_rs2_operand;

    logic [(`ALU_OPSIZE - 1):0] amo_modify_op;
    always_comb begin: amo_modify_op_sel
        case (decoded_instruction)
            `INSTR_CODE(AMOSWAP_W), `INSTR_CODE(AMOSWAP_D): amo_modify_op = `ADD;  // passthrough
            `INSTR_CODE(AMOADD_W),  `INSTR_CODE(AMOADD_D):  amo_modify_op = `ADD;
            `INSTR_CODE(AMOXOR_W),  `INSTR_CODE(AMOXOR_D):  amo_modify_op = `XOR;
            `INSTR_CODE(AMOOR_W),   `INSTR_CODE(AMOOR_D):   amo_modify_op = `OR;
            `INSTR_CODE(AMOAND_W),  `INSTR_CODE(AMOAND_D):  amo_modify_op = `AND;
            `INSTR_CODE(AMOMIN_W),  `INSTR_CODE(AMOMIN_D):  amo_modify_op = `MIN;
            `INSTR_CODE(AMOMAX_W),  `INSTR_CODE(AMOMAX_D):  amo_modify_op = `MAX;
            `INSTR_CODE(AMOMINU_W), `INSTR_CODE(AMOMINU_D): amo_modify_op = `MINU;
            `INSTR_CODE(AMOMAXU_W), `INSTR_CODE(AMOMAXU_D): amo_modify_op = `MAXU;
            default: amo_modify_op = `ADD; // don't-care -- LR/SC never reach S_AMO_WRITE
        endcase
    end: amo_modify_op_sel

    logic [(`ALU_OPSIZE - 1):0] alu_op;
    always_comb begin: alu_op_sel
        /*
         * A extension: during S_AMO_WRITE, alu0 is being reused for the
         * modify computation (old value op rs2), not the address
         * computation every other state uses it for -- the first
         * state-dependent alu_op in this file. LR/SC/AMO-during-address-
         * phase need no arm inside the case below at all -- they fall
         * through the existing default: alu_op = `ADD, exactly like
         * branches/loads/stores/CSR do today.
         */
        if (amo_modify_phase) begin
            alu_op = amo_modify_op;
        end else
        case (decoded_instruction)
            `INSTR_CODE(ADDI), `INSTR_CODE(ADD),
            `INSTR_CODE(ADDIW), `INSTR_CODE(ADDW),
            /*
             * Also every instruction that uses the ALU purely as an
             * adder rather than for its "own" arithmetic meaning: LUI
             * (o_imm_2=0 from the decoder, so ADD is a passthrough of
             * o_imm_1), AUIPC (pc + immediate, via the operand-A mux
             * below), JALR and every load/store (base + offset address
             * calculation).
             */
            `INSTR_CODE(LUI), `INSTR_CODE(AUIPC), `INSTR_CODE(JALR),
            `INSTR_CODE(LB), `INSTR_CODE(LH), `INSTR_CODE(LW),
            `INSTR_CODE(LBU), `INSTR_CODE(LHU), `INSTR_CODE(LWU), `INSTR_CODE(LD),
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD):
                alu_op = `ADD;

            `INSTR_CODE(SUB), `INSTR_CODE(SUBW):
                alu_op = `SUB;

            `INSTR_CODE(SLTI), `INSTR_CODE(SLT):   alu_op = `SLT;
            `INSTR_CODE(SLTIU), `INSTR_CODE(SLTU): alu_op = `SLTU;
            `INSTR_CODE(XORI), `INSTR_CODE(XOR):   alu_op = `XOR;
            `INSTR_CODE(ORI), `INSTR_CODE(OR):     alu_op = `OR;
            `INSTR_CODE(ANDI), `INSTR_CODE(AND):   alu_op = `AND;

            `INSTR_CODE(SLLI), `INSTR_CODE(SLL): alu_op = `SLL;
            `INSTR_CODE(SRLI), `INSTR_CODE(SRL): alu_op = `SRL;
            `INSTR_CODE(SRAI), `INSTR_CODE(SRA): alu_op = `SRA;

            `INSTR_CODE(SLLIW), `INSTR_CODE(SLLW): alu_op = `SLLW;
            `INSTR_CODE(SRLIW), `INSTR_CODE(SRLW): alu_op = `SRLW;
            `INSTR_CODE(SRAIW), `INSTR_CODE(SRAW): alu_op = `SRAW;

            /*
             * Zicsr: no new ALU ops needed (see the operand-mux comments
             * above for the operand-B redirect each of these relies on).
             */
            `INSTR_CODE(CSRRS), `INSTR_CODE(CSRRSI): alu_op = `OR;
            `INSTR_CODE(CSRRC), `INSTR_CODE(CSRRCI): alu_op = `AND;
            `INSTR_CODE(CSRRW), `INSTR_CODE(CSRRWI): alu_op = `ADD;

            /*
             * M extension: multiply. MULW reuses MUL (see is_word_arith
             * above). DIV/DIVU/REM/REMU (and their W variants) get no
             * arms here at all -- they don't use alu_result any more than
             * branches/JAL do (see the "M extension: divide" section
             * below), so they correctly fall through to the same
             * don't-care default as everything else that bypasses the
             * ALU.
             */
            `INSTR_CODE(MUL), `INSTR_CODE(MULW): alu_op = `MUL;
            `INSTR_CODE(MULH):                   alu_op = `MULH;
            `INSTR_CODE(MULHSU):                 alu_op = `MULHSU;
            `INSTR_CODE(MULHU):                  alu_op = `MULHU;

            /*
             * Branches/JAL/FENCE/ECALL/EBREAK/INVALID don't use
             * alu_result for anything (branches have their own
             * comparator below; JAL's target/link come from the PC
             * adder and pc_plus_len directly) -- alu_op is a don't-care
             * for these, defaulted to ADD purely so alu_op always has a
             * defined value.
             */
            default: alu_op = `ADD;
        endcase
    end: alu_op_sel

    logic [1:0] mem_size;
    logic load_signed;
    always_comb begin: mem_control
        is_load = 1'b0;
        is_store = 1'b0;
        mem_size = 2'b10;
        load_signed = 1'b0;
        case (decoded_instruction)
            `INSTR_CODE(LB):  begin is_load = 1'b1; mem_size = 2'b00; load_signed = 1'b1; end
            `INSTR_CODE(LBU): begin is_load = 1'b1; mem_size = 2'b00; load_signed = 1'b0; end
            `INSTR_CODE(LH):  begin is_load = 1'b1; mem_size = 2'b01; load_signed = 1'b1; end
            `INSTR_CODE(LHU): begin is_load = 1'b1; mem_size = 2'b01; load_signed = 1'b0; end
            `INSTR_CODE(LW):  begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end
            `INSTR_CODE(LWU): begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b0; end
            `INSTR_CODE(LD):  begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end
            `INSTR_CODE(SB):  begin is_store = 1'b1; mem_size = 2'b00; end
            `INSTR_CODE(SH):  begin is_store = 1'b1; mem_size = 2'b01; end
            `INSTR_CODE(SW):  begin is_store = 1'b1; mem_size = 2'b10; end
            `INSTR_CODE(SD):  begin is_store = 1'b1; mem_size = 2'b11; end

            /*
             * A extension. LR/AMO's read phase behaves exactly like
             * LW/LD (reusing load_data's existing byte/half/word/dword
             * formatting infrastructure with zero changes to it, per
             * spec's requirement that a .W AMO/LR sign-extend the loaded
             * word). SC's arm makes is_store a DYNAMIC, reservation-
             * dependent value: when sc_success=0, is_store=0 for that SC
             * => mem_phase_needed=0 => SC commits immediately in S_EXEC
             * via the unmodified existing commit_now formula, with
             * rd = sc_result = 1. No new logic needed for that path
             * specifically -- it falls out of the existing machinery
             * once is_store is correctly 0.
             */
            `INSTR_CODE(LR_W): begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end
            `INSTR_CODE(LR_D): begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end

            `INSTR_CODE(SC_W): begin is_store = sc_success; mem_size = 2'b10; end
            `INSTR_CODE(SC_D): begin is_store = sc_success; mem_size = 2'b11; end

            `INSTR_CODE(AMOSWAP_W), `INSTR_CODE(AMOADD_W), `INSTR_CODE(AMOXOR_W), `INSTR_CODE(AMOOR_W),
            `INSTR_CODE(AMOAND_W), `INSTR_CODE(AMOMIN_W), `INSTR_CODE(AMOMAX_W), `INSTR_CODE(AMOMINU_W),
            `INSTR_CODE(AMOMAXU_W):
                begin is_load = 1'b1; mem_size = 2'b10; load_signed = 1'b1; end

            `INSTR_CODE(AMOSWAP_D), `INSTR_CODE(AMOADD_D), `INSTR_CODE(AMOXOR_D), `INSTR_CODE(AMOOR_D),
            `INSTR_CODE(AMOAND_D), `INSTR_CODE(AMOMIN_D), `INSTR_CODE(AMOMAX_D), `INSTR_CODE(AMOMINU_D),
            `INSTR_CODE(AMOMAXU_D):
                begin is_load = 1'b1; mem_size = 2'b11; load_signed = 1'b1; end

            default: ;
        endcase
    end: mem_control

    /*
     * reg_write: computed by excluding the SHORT list of instructions
     * that don't write rd, rather than enumerating the long list that
     * does -- fewer places to accidentally miss an entry when a future
     * milestone adds more instructions. Gated by commit_now (see its own
     * comment above) so this only actually reaches regfile0 on the one
     * edge each instruction is allowed to retire, not throughout the
     * whole multi-cycle window it happens to be decoded.
     */
    logic reg_write_ctrl;
    always_comb begin: reg_write_control
        case (decoded_instruction)
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD),
            `INSTR_CODE(BEQ), `INSTR_CODE(BNE), `INSTR_CODE(BLT),
            `INSTR_CODE(BGE), `INSTR_CODE(BLTU), `INSTR_CODE(BGEU),
            `INSTR_CODE(FENCE), `INSTR_CODE(FENCE_I), `INSTR_CODE(ECALL), `INSTR_CODE(EBREAK),
            `INSTR_CODE(MRET), `INSTR_CODE(SRET), `INSTR_CODE(WFI), `INSTR_CODE(SFENCE_VMA),
            `INSTR_CODE(INVALID):
                reg_write_ctrl = 1'b0;
            default:
                reg_write_ctrl = 1'b1;
        endcase
    end: reg_write_control

    /*
     * Zicsr classification. mem_control/reg_write_control above need no
     * new arms for these six codes: mem_control's default (is_load=0,
     * is_store=0) already applies, so a CSR instruction retires in a
     * single S_EXEC cycle like any ordinary ALU op; reg_write_control's
     * default (reg_write_ctrl = 1'b1) already applies too, so rd gets
     * written same as any other non-excluded instruction.
     */
    wire is_csrrw  = (decoded_instruction == `INSTR_CODE(CSRRW));
    wire is_csrrs  = (decoded_instruction == `INSTR_CODE(CSRRS));
    wire is_csrrc  = (decoded_instruction == `INSTR_CODE(CSRRC));
    wire is_csrrwi = (decoded_instruction == `INSTR_CODE(CSRRWI));
    wire is_csrrsi = (decoded_instruction == `INSTR_CODE(CSRRSI));
    wire is_csrrci = (decoded_instruction == `INSTR_CODE(CSRRCI));
    wire is_csr_rw = is_csrrw || is_csrrwi;
    wire is_csr_rs = is_csrrs || is_csrrsi;
    wire is_csr_rc = is_csrrc || is_csrrci;
    wire is_csr    = is_csr_rw || is_csr_rs || is_csr_rc;

    /*
     * Write-suppress condition, per spec: CSRRS/CSRRC suppress the write
     * when rs1's FIELD is x0 (read_gpr_A_sel == 0) -- a register OTHER
     * than x0 that happens to hold value 0 must still attempt the write,
     * so this must NOT be checked as imm_1 == 0 (the runtime value).
     * CSRRSI/CSRRCI have no such field/value distinction -- uimm IS a
     * literal -- so imm_1 == 0 (which is where the decoder parks the
     * zero-extended uimm) is correct there.
     */
    wire csr_write_suppress = (is_csrrs || is_csrrc)   ? (read_gpr_A_sel == 0) :
                               (is_csrrsi || is_csrrci) ? (imm_1 == 0)         :
                                                           1'b0;

    /*
     * Forward-declared here, same reason is_load/is_store are
     * (see the comment near the top of this file): csr_rdata is
     * referenced below in the operand muxes, textually before csr_file0
     * -- the instance that actually drives it -- is declared (csr_file0
     * has to come after alu0, since its write data is alu_result).
     */
    logic [(`WORD_SIZE - 1):0] csr_rdata;

    /*
     * Privilege / trap classification (U/S/M privilege-mode milestone).
     * Forward-declared, same reason csr_rdata is above: medeleg_w is
     * driven by csr_file0, not instantiated until Execute (needs
     * alu_result first), but trap_to_s below needs its value now, at
     * classification time.
     */
    logic [(`WORD_SIZE - 1):0] medeleg_w;

    wire is_mret = (decoded_instruction == `INSTR_CODE(MRET));
    wire is_sret = (decoded_instruction == `INSTR_CODE(SRET));

    /*
     * Illegal-instruction sources this milestone: a genuinely
     * unrecognized encoding, OR a CSR access below its address-encoded
     * minimum privilege (bits[9:8], computed from the ADDRESS,
     * independent of whether csr_file.sv actually backs it), OR MRET
     * below M-mode / SRET below S-mode (also illegal-instruction per
     * spec, not a separate source), OR SRET executed in S-mode while
     * mstatus.TSR=1 (spec: "Trap SRET" -- an S-mode SRET must trap to
     * M-mode when TSR=1, letting M-mode emulate/intercept the return;
     * found via a real ACT4 S-00 failure tracing an sret-from-S-mode
     * subtest that expects exactly this trap and got a normal return
     * instead, since TSR was until now inert storage only).
     *
     * Read-only-CSR-write attempts (bits[11:10]=='11', a real write
     * genuinely attempted -- see csr_readonly_violation below) also
     * trap as illegal-instruction, per spec ("Attempts to write a
     * read-only CSR... raise illegal instruction exceptions"). Found
     * 2026-08-20 via a real ACT4 U-00 failure (newly exercised once
     * EBREAK became a real, resumable trap -- U-00's own boot sequence
     * attempts csrrw x0, cycle(0xC00), x10, a write to a genuinely
     * read-only CSR): traced via sail_riscv_sim --trace-instr/--trace-reg
     * against the real ELF, diffed against this core's own RVFI
     * retirement trace, confirming the exact first divergence is this
     * core silently no-op'ing the write instead of trapping. Previously
     * csr_file.sv silently ignored these writes (a Zicsr-milestone
     * decision core_zicsr_tb.sv's own csrrwi-to-mhartid case used to
     * depend on -- that subtest is retired now that the real trap
     * exists; see core_csr_readonly_trap_tb.sv for its replacement).
     *
     * Still NOT covered: SFENCE.VMA from U-mode (spec-should-trap, but
     * decoded as an unconditional NOP this milestone -- see its own
     * comment in instructions_and_masks.sv) and TVM/TW (mstatus's other
     * two "trap on privileged op" bits, same "real storage, not
     * enforced" status TSR had before its own fix -- SFENCE.VMA-under-
     * TVM and WFI-under-TW remain a separate, not-yet-exercised gap).
     */
    // Declared here (ahead of csr_file0's instantiation further down)
    // purely because Icarus's single-pass elaborator wants a net's
    // declaration textually before its first use in a continuous
    // assignment, unlike mstatus_mpp_w/mstatus_spp_w below which are
    // only ever used later in the file.
    wire mstatus_tsr_w;
    wire is_invalid_instr    = (decoded_instruction == `INSTR_CODE(INVALID));
    wire csr_priv_violation  = is_csr  && (imm_2[9:8] > 2'(current_priv));
    // A real write is attempted by every CSR instruction except the
    // csrr{s,c}{,i} forms with a zero source (csr_write_suppress already
    // captures exactly that set) -- csrrw/csrrwi always attempt a write
    // regardless of rd, per spec. bits[11:10]=='11' marks a read-only CSR.
    wire csr_readonly_violation = is_csr && !csr_write_suppress && (imm_2[11:10] == 2'b11);
    /*
     * Debug-mode CSRs (dcsr/dpc/dscratch0/dscratch1, 0x7B0-0x7B3) are a
     * genuinely separate check from csr_priv_violation above, not an
     * extension of it: that check is a magnitude comparison against
     * current_priv (imm_2[9:8] > current_priv), and these four addresses
     * encode imm_2[9:8]==2'b11 -- the same encoding as an ordinary
     * M-mode-only CSR -- so M-mode code would sail straight through
     * csr_priv_violation untouched. Per the RISC-V Debug spec, Debug
     * CSRs must only be accessible from Debug Mode itself, never merely
     * M-mode, hence a dedicated in_debug_mode gate instead of a
     * privilege-level comparison. in_debug_mode is a forward reference --
     * tied 0 here until Milestone 4 builds the real halt/resume FSM this
     * state belongs to; until then every access from anywhere traps,
     * which is spec-correct (this core has no Debug Mode to legally be
     * in yet).
     */
    wire in_debug_mode = 1'b0;
    wire is_debug_csr_addr = is_csr && (imm_2[11:2] == 10'h1EC);
    wire debug_csr_violation = is_debug_csr_addr && !in_debug_mode;
    wire mret_priv_violation = is_mret && (current_priv != PRIV_M);
    wire sret_priv_violation = is_sret && ((current_priv == PRIV_U)
                              || (current_priv == PRIV_S && mstatus_tsr_w));
    /*
     * C extension: a reserved/unassigned compressed encoding is also
     * illegal-instruction -- c_expand_illegal is only meaningful when
     * is_compressed (it's a pure combinational function of first_hw,
     * computed unconditionally regardless of whether the current
     * instruction turned out compressed at all), hence the explicit
     * is_compressed guard here rather than trusting c_expand_illegal
     * alone.
     */
    wire is_illegal_instr = is_invalid_instr || csr_priv_violation || csr_readonly_violation
                          || debug_csr_violation
                          || mret_priv_violation || sret_priv_violation
                          || (is_compressed && c_expand_illegal);
    wire is_ecall = (decoded_instruction == `INSTR_CODE(ECALL));
    /*
     * Zifencei: is_fence_i drives icache_flush_o below (see that port's
     * own header comment for why the timing is provably clean). Declared
     * here rather than next to is_illegal_instr/is_ecall's own forward
     * reference needs -- FENCE.I isn't consumed by exc_code/trap_taken at
     * all, so it doesn't need the same forward-declaration treatment
     * those wires do.
     */
    wire is_fence_i = (decoded_instruction == `INSTR_CODE(FENCE_I));

    /* Exception codes, per spec's machine-cause table (synchronous only
     * -- bit 63/Interrupt is always 0, no interrupt source exists yet).
     * 4/6 (load/store-AMO address misaligned) are standard RISC-V causes;
     * mem_load_misaligned/mem_store_misaligned are driven in the Memory
     * section below, once mem_paddr exists. 1/5/7 (instruction/load/
     * store-AMO access fault) are likewise standard causes, driven by a
     * real wb_err_i response -- fetch_fault_q (instruction, cause 1) and
     * mem_load_access_fault/mem_store_access_fault (cause 5/7, also
     * driven in the Memory section below) are this file's classification
     * of WHICH access faulted, mirroring the misaligned pair exactly.
     * fetch_fault_q is checked first -- defensive, not strictly required
     * (the `instruction` substitution above already makes is_illegal_instr
     * etc. structurally false whenever it's set), but omitting its own
     * arm would let the fault be silently swallowed as a harmless ADDI. */
    wire [3:0] exc_code = fetch_fault_q                         ? 4'd1  :
                           is_illegal_instr                     ? 4'd2  :
                           is_ebreak                            ? 4'd3  :
                           (is_ecall && current_priv == PRIV_U) ? 4'd8  :
                           (is_ecall && current_priv == PRIV_S) ? 4'd9  :
                           (is_ecall && current_priv == PRIV_M) ? 4'd11 :
                           mem_load_misaligned                  ? 4'd4  :
                           mem_store_misaligned                 ? 4'd6  :
                           mem_load_access_fault                ? 4'd5  :
                           mem_store_access_fault               ? 4'd7  :
                                                                   4'd0; // don't-care, gated by trap_taken

    assign trap_taken = commit_now && (fetch_fault_q || is_illegal_instr || is_ebreak || is_ecall
                                   || mem_load_misaligned || mem_store_misaligned
                                   || mem_load_access_fault || mem_store_access_fault);
    /* An M-mode trap never delegates, regardless of medeleg -- falls out
     * naturally here since current_priv==M forces this wire to 0. */
    wire trap_to_s  = trap_taken && (current_priv != PRIV_M) && medeleg_w[6'(exc_code)];
    wire [(`WORD_SIZE - 1):0] trap_cause = {60'b0, exc_code};
    /*
     * trap_val: forward-declared (`logic`, not `wire ... =`) -- its
     * misaligned-access arm needs mem_paddr, which doesn't exist until
     * the Memory section further down (same "declare early, drive late"
     * split is_load/is_store/mem_load_misaligned already use). The real
     * assign lives right after mem_load_misaligned/mem_store_misaligned
     * are computed.
     *
     * C extension note (kept from the original illegal-instruction arm):
     * for a compressed illegal instruction, the real faulting bits are
     * the 16-bit halfword (zero-extended), not `instruction` -- which,
     * in that exact case, holds the inert 32'h00000013 placeholder
     * substituted above, not anything real.
     */
    logic [(`WORD_SIZE - 1):0] trap_val;

    wire mret_taken = commit_now && is_mret && !mret_priv_violation;
    wire sret_taken = commit_now && is_sret && !sret_priv_violation;

    wire csr_we = is_csr && commit_now && !csr_write_suppress && !trap_taken;

    /*
     * reg_write: relocated here (from immediately after reg_write_control
     * above) since it now depends on trap_taken, which isn't computed
     * until this classification section -- reg_write itself is already
     * forward-declared near the top of the Decode section (`logic
     * reg_write;`), so driving it later in the file is a continuation of
     * that same established pattern, not a new one. A trapping
     * instruction never writes rd -- its "normal" semantics (including
     * whatever reg_write_ctrl computed) are entirely overridden by
     * trap-entry.
     */
    assign reg_write = reg_write_ctrl && commit_now && !trap_taken;

    /*
     * M extension: divide. DIV/DIVU/REM/REMU (and their W variants)
     * execute via design/divider.sv, a separate multi-cycle module, not
     * the (purely combinational) ALU -- mem_control/reg_write_control
     * above still need no new arms for these 8 codes, same reasoning as
     * the CSR classification above: mem_control's default (is_load=0,
     * is_store=0) and reg_write_control's default (reg_write_ctrl=1'b1)
     * both already do the right thing.
     *
     * The *W variants need their low-32-bit operands correctly sign- or
     * zero-extended to WORD_SIZE before reaching the divider (matching
     * DIVW/DIVUW/REMW/REMUW's spec-defined 32-bit-domain semantics) --
     * unlike MULW, this can't just reuse the 64-bit path and truncate
     * the RESULT afterward, since division (unlike multiplication mod
     * 2^n) genuinely depends on the operands' actual magnitude, not just
     * their low bits. The result side mirrors is_word_arith/
     * alu_result_w_trunc below: truncate+resign whichever of quotient/
     * remainder the instruction actually wants.
     */
    wire is_div    = (decoded_instruction == `INSTR_CODE(DIV));
    wire is_divu   = (decoded_instruction == `INSTR_CODE(DIVU));
    wire is_rem    = (decoded_instruction == `INSTR_CODE(REM));
    wire is_remu   = (decoded_instruction == `INSTR_CODE(REMU));
    wire is_divw   = (decoded_instruction == `INSTR_CODE(DIVW));
    wire is_divuw  = (decoded_instruction == `INSTR_CODE(DIVUW));
    wire is_remw   = (decoded_instruction == `INSTR_CODE(REMW));
    wire is_remuw  = (decoded_instruction == `INSTR_CODE(REMUW));
    wire is_div_family = is_div || is_divu || is_rem || is_remu
                       || is_divw || is_divuw || is_remw || is_remuw;
    wire is_div_w_family      = is_divw || is_divuw || is_remw || is_remuw;
    wire is_div_signed_family = is_div || is_rem || is_divw || is_remw;
    wire is_div_wants_quotient = is_div || is_divu || is_divw || is_divuw;

    wire [(`WORD_SIZE - 1):0] div_dividend_in =
        !is_div_w_family      ? imm_1 :
        is_div_signed_family  ? {{32{imm_1[31]}}, imm_1[31:0]} : {32'b0, imm_1[31:0]};
    wire [(`WORD_SIZE - 1):0] div_divisor_in =
        !is_div_w_family      ? imm_2 :
        is_div_signed_family  ? {{32{imm_2[31]}}, imm_2[31:0]} : {32'b0, imm_2[31:0]};

    /*
     * i_start deliberately does NOT need its own "have I already pulsed
     * this" flag -- divider_o_busy rises (registered, one cycle after
     * i_start) exactly in time to naturally gate this back to 0 on every
     * subsequent cycle of the same divide, so this is a clean one-cycle
     * pulse without extra bookkeeping here.
     *
     * (state == S_EXEC) is a REQUIRED third condition here, not
     * belt-and-suspenders -- decoded_instruction (and so is_div_family)
     * is only meaningful once a fetch has actually settled. During
     * S_FETCH's transient window, `instruction` still reads whatever the
     * PREVIOUS fetch's instr_line_q held, indexed by the NEW pc's own
     * pc[2] bit -- a stale, arbitrary combination that can alias to a
     * genuine div-family encoding purely by coincidence (found exactly
     * this way: DIVU's own encoding, still sitting in instr_line_q's low
     * half, aliased as "the next instruction" for one cycle while its
     * successor's real fetch was still in flight -- spuriously
     * retriggering the divider). commit_now and the S_EXEC transition
     * below don't need this same guard -- both are already nested inside
     * their own `state == S_EXEC` conditions -- but i_start drives
     * divider0 directly and unconditionally, so it has to check for
     * itself.
     */
    logic divider_o_busy, divider_o_done;
    logic [(`WORD_SIZE - 1):0] divider_o_quotient, divider_o_remainder;
    divider divider0 (
        .i_clk(clk), .i_rst(rst),
        .i_start(is_div_family && (state == S_EXEC) && !divider_o_busy && !divider_o_done),
        .i_dividend(div_dividend_in), .i_divisor(div_divisor_in), .i_signed(is_div_signed_family),
        .o_busy(divider_o_busy), .o_done(divider_o_done),
        .o_quotient(divider_o_quotient), .o_remainder(divider_o_remainder)
    );

    assign div_stall = is_div_family && !divider_o_done;
    wire [(`WORD_SIZE - 1):0] div_result_raw = is_div_wants_quotient ? divider_o_quotient : divider_o_remainder;
    wire [(`WORD_SIZE - 1):0] div_result = is_div_w_family
                                            ? {{32{div_result_raw[31]}}, div_result_raw[31:0]}
                                            : div_result_raw;

    /* --------------------------------------------------------------- *
     * Execute
     * --------------------------------------------------------------- */

    /*
     * AUIPC needs pc+imm, but the decoder parks the U-immediate on
     * o_imm_1 (the "A slot") for both LUI and AUIPC, with o_imm_2
     * hardwired to 0 (OUTPUT_U_TYPE_INSTR). LUI rides that as-is: A =
     * imm_1, B = imm_2 (0), giving imm+0. AUIPC instead needs pc as one
     * addend and the immediate as the other, so it swaps BOTH operands:
     * A becomes pc, and B is redirected to imm_1 to recover the
     * immediate that A just displaced -- using the default imm_2 here
     * (0) would silently compute pc+0 and drop the immediate entirely.
     */
    /*
     * CSRRS/CSRRC redirect A to the CSR's CURRENT value -- "OR/AND a
     * mask into/out of the CSR" reads the CSR, not rs1/uimm -- same
     * operand-redirect idea AUIPC already uses above, just sourced from
     * csr_rdata instead of pc. CSRRW/CSRRWI need no redirect: their new
     * value IS rs1/uimm, which is already sitting on imm_1 by default.
     */
    /*
     * A extension: amo_modify_phase takes top priority -- during
     * S_AMO_WRITE, alu0 is computing the modify value (old op rs2), not
     * an address, and amo_modify_operand_a/b (declared above, in the A
     * extension classification section) already account for AMOSWAP's
     * passthrough shape. Outside that phase, LR/SC/AMO's address is rs1
     * alone (imm_1), so they fall through to the same default every
     * plain load/store already uses -- no address-phase arm needed here.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_a = amo_modify_phase          ? amo_modify_operand_a :
                                               (is_csr_rs || is_csr_rc)  ? csr_rdata :
                                               is_auipc                  ? pc        :
                                                                           imm_1;
    /*
     * CSRRS ORs the rs1/uimm mask (already on imm_1) into the CSR -- B =
     * imm_1, paired with alu_op_sel's OR arm below. CSRRC ANDs with the
     * bitwise-complement of that same mask -- B = ~imm_1, paired with
     * AND (pre-inverting the operand here instead of adding a dedicated
     * "AND-NOT" ALU op, same trick as AUIPC's operand redirect above).
     * CSRRW/CSRRWI overwrite the CSR outright -- B forced to 0, paired
     * with ADD (the same passthrough trick LUI's ADD-with-B=0 already
     * uses) -- so alu_result ends up uniformly "the new CSR value" for
     * all 6 variants, and csr_file0's write port needs no extra mux.
     *
     * is_amo_family's arm MUST sit above is_store here -- SC's is_store
     * is DYNAMICALLY 1 when matched (see mem_control above), and without
     * this arm operand_b would fall through to `is_store ? imm3_sext :
     * ...`, which is WRONG: imm3_sext reinterprets
     * o_imm_3_or_dest_addr as a signed S/B offset, but for an R-type-
     * shaped decode (which is what OUTPUT_R_TYPE_INSTR gives every
     * A-extension instruction) that port instead holds rd, zero-
     * extended -- a small positive "offset" that would silently corrupt
     * the address computation for any matched SC with a nonzero rd.
     * LR/AMO never set is_store at all, so they'd never have hit this
     * arm regardless, but SC's dynamic is_store makes the priority
     * ordering genuinely load-bearing, not just tidy.
     */
    wire [(`WORD_SIZE - 1):0] alu_operand_b = amo_modify_phase ? amo_modify_operand_b :
                                               is_amo_family     ? `WORD_SIZE'(0) :
                                               is_store            ? imm3_sext :
                                               is_auipc             ? imm_1 :
                                               is_csr_rs             ? imm_1 :
                                               is_csr_rc               ? ~imm_1 :
                                               is_csr_rw                 ? `WORD_SIZE'(0) :
                                                                            imm_2;

    logic [(`WORD_SIZE - 1):0] alu_result;
    alu alu0 (
        .i_operand_A(alu_operand_a),
        .i_operation(alu_op),
        .i_operand_B(alu_operand_b),
        .o_result(alu_result)
    );

    /*
     * A extension: amo_result_w_trunc is a SEPARATE wire from
     * alu_result_w_trunc (Writeback section, further down) rather than a
     * relocation of it -- deliberate, to avoid perturbing the
     * already-working M-extension writeback path in the same change.
     * Same formula, needed here (before Memory) rather than there (after
     * Wishbone-master bus-driving).
     *
     * Needed because a .W AMO's raw 64-bit alu0 output is NOT
     * automatically the correct sign-extension of the true 32-bit result
     * for every op -- ADD is the counter-example: sign-extend(0x7FFFFFFF)
     * + sign-extend(1) = 0x0000000080000000, but the CORRECT
     * sign-extension of the true 32-bit sum (0x7FFFFFFF+1=0x80000000,
     * i.e. INT32_MIN) is 0xFFFFFFFF80000000 -- different! (XOR/OR/AND and
     * MIN/MAX/MINU/MAXU happen to already be correctly sign-extended when
     * fed sign-extended operands, but applying this truncate+resign step
     * UNIFORMLY to all 9 ops is far simpler than reasoning per-op about
     * which ones need it.)
     */
    wire [(`WORD_SIZE - 1):0] amo_result_w_trunc = {{32{alu_result[31]}}, alu_result[31:0]};
    wire [(`WORD_SIZE - 1):0] amo_new_value = is_amo_rmw_w ? amo_result_w_trunc : alu_result;

    /*
     * csr_file0: instantiated here, after alu0 rather than up with the
     * rest of the new Zicsr wires in the Control unit section above --
     * its write data is alu_result, which by construction (see the
     * operand-mux/alu_op_sel comments above) is uniformly "the new CSR
     * value" for all 6 variants, and alu_result doesn't exist until
     * alu0 above is declared.
     */
    wire [(`WORD_SIZE - 1):0] mtvec_w, stvec_w, mepc_w, sepc_w;
    wire [1:0] mstatus_mpp_w;
    wire mstatus_spp_w;
    /*
     * mip_w/mie_w/mideleg_w: WORD_SIZE-wide (matching csr_file0's real
     * architectural CSR width), but the Interrupts section below only
     * ever reads bit 7 (MTIE/MTIP/the MTI delegation bit) off each --
     * every other bit is genuinely unused by this milestone's logic
     * (they exist for a real, spec-shaped mip/mie/mideleg, not padding),
     * same "wrap the genuinely-partial-usage bits" precedent
     * trap_vector_base already establishes below for mtvec/stvec's own
     * MODE field.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] mip_w, mie_w, mideleg_w;
    /* verilator lint_on UNUSEDSIGNAL */
    wire mstatus_mie_w, mstatus_sie_w;
`ifdef RISCV_FORMAL
    wire [(`WORD_SIZE - 1):0] mcause_w, scause_w;
    wire [(`WORD_SIZE - 1):0] mepc_next_w, sepc_next_w, mcause_next_w, scause_next_w;
`endif

    csr_file csr_file0 (
        .i_clk(clk),
        .i_rst(rst),
        .i_csr_addr(imm_2[(`CSR_ADDR_SIZE - 1):0]),
        .o_csr_rdata(csr_rdata),
        .i_csr_we(csr_we),
        .i_csr_wdata(alu_result),
        .i_instr_retired(commit_now),

        .i_current_priv(current_priv),
        .i_mtip(i_mtip),
        .i_trap_taken(trap_taken || interrupt_taken),
        .i_trap_cause(trap_taken ? trap_cause : {1'b1, 63'd7}),
        .i_trap_val(trap_taken ? trap_val : `WORD_SIZE'(0)),
        .i_trap_pc(pc),
        .i_trap_to_s(trap_taken ? trap_to_s : interrupt_to_s),
        .i_mret_taken(mret_taken),
        .i_sret_taken(sret_taken),

        .o_mtvec(mtvec_w),
        .o_stvec(stvec_w),
        .o_mepc(mepc_w),
        .o_sepc(sepc_w),
        .o_medeleg(medeleg_w),
        .o_mstatus_mpp(mstatus_mpp_w),
        .o_mstatus_spp(mstatus_spp_w),
        .o_mstatus_tsr(mstatus_tsr_w),

        /*
         * Milestone 5 (csr_file.sv CSR-side CLINT/interrupt plumbing) added
         * these 5 outputs; Milestone 6 (this section) is their real
         * consumer -- see the Interrupts section immediately following
         * this instantiation, which drives mti_pending/mti_to_s/
         * mti_enabled/interrupt_taken/interrupt_to_s off exactly these
         * five wires.
         */
        .o_mip(mip_w),
        .o_mie(mie_w),
        .o_mideleg(mideleg_w),
        .o_mstatus_mie(mstatus_mie_w),
        .o_mstatus_sie(mstatus_sie_w),

        /*
         * Milestone 3 (Debug CSRs) added dcsr/dpc storage in csr_file.sv,
         * but this milestone's own core.sv work stops at trapping illegal
         * access to them (see debug_csr_violation above) -- no halt/
         * resume FSM exists yet to actually consume a live dpc/dcsr
         * value. Explicitly, deliberately unconnected (not omitted) so
         * lint tools see this as intentional, not a forgotten
         * connection -- same precedent soc.sv's own dram_* ports use;
         * Milestone 4's halt/resume FSM is the real consumer.
         */
        /* verilator lint_off PINCONNECTEMPTY */
        .o_dcsr(), .o_dpc()
        /* verilator lint_on PINCONNECTEMPTY */
`ifdef RISCV_FORMAL
        ,
        .o_mcause(mcause_w),
        .o_scause(scause_w),
        .o_mepc_next(mepc_next_w),
        .o_sepc_next(sepc_next_w),
        .o_mcause_next(mcause_next_w),
        .o_scause_next(scause_next_w)
`endif
    );

    /* --------------------------------------------------------------- *
     * Interrupts (CLINT machine-timer, Milestone 6)
     * --------------------------------------------------------------- */

    // MTIE & MTIP (bit 7). mti_to_s reads mideleg_w[7] -- real, unmasked,
    // software-writable storage, not hardwired 0; reads 0 in practice
    // only because nothing this milestone writes it.
    wire mti_pending = mie_w[7] & mip_w[7];
    wire mti_to_s    = mideleg_w[7];
    wire mti_enabled = mti_to_s
        ? ((current_priv == PRIV_U) ? 1'b1 : (current_priv == PRIV_S) ? mstatus_sie_w : 1'b0)
        : ((current_priv != PRIV_M) ? 1'b1 : mstatus_mie_w);
    wire int_pending_and_enabled = mti_pending && mti_enabled;

    logic commit_now_q;
    always_ff @(posedge clk) begin
        if (rst) commit_now_q <= 1'b0;
        else     commit_now_q <= commit_now;
    end

    // interrupt_taken/interrupt_to_s: forward-declared above -- csr_file0's
    // own i_trap_taken/i_trap_to_s need them before this section (which
    // itself needs csr_file0's own outputs) can exist.
    //
    // No `!halted` guard here anymore (removed alongside halted's own
    // removal below) -- there is no longer a permanent-freeze state to
    // guard against post-EBREAK; a future Debug Module halt/resume
    // milestone will reintroduce an analogous guard with real semantics.
    assign interrupt_taken = commit_now_q && int_pending_and_enabled;
    assign interrupt_to_s  = interrupt_taken && mti_to_s;

    logic fetch_redirect_q;
    always_ff @(posedge clk) begin
        if (rst) fetch_redirect_q <= 1'b0;
        else if (interrupt_taken)             fetch_redirect_q <= 1'b1;
        else if (state == S_FETCH && wb_done) fetch_redirect_q <= 1'b0;
    end
    wire fetch_from_trap_vector = interrupt_taken || fetch_redirect_q;

    /*
     * Branch comparator: NOT routed through alu0. alu_ops.sv has no
     * equality/inequality op, and each branch type needs a different
     * comparison (equality, signed, unsigned) -- easier as its own small
     * block than trying to force it through a shared single-op ALU
     * interface. default: 1'b0 doubles as "this instruction isn't a
     * branch at all", so the next-PC mux below needs no separate
     * is_branch gate.
     */
    logic take_branch;
    always_comb begin: branch_comparator
        case (decoded_instruction)
            `INSTR_CODE(BEQ):  take_branch = (imm_1 == imm_2);
            `INSTR_CODE(BNE):  take_branch = (imm_1 != imm_2);
            `INSTR_CODE(BLT):  take_branch = ($signed(imm_1) <  $signed(imm_2));
            `INSTR_CODE(BGE):  take_branch = ($signed(imm_1) >= $signed(imm_2));
            `INSTR_CODE(BLTU): take_branch = (imm_1 < imm_2);
            `INSTR_CODE(BGEU): take_branch = (imm_1 >= imm_2);
            default:           take_branch = 1'b0;
        endcase
    end: branch_comparator

    /* --------------------------------------------------------------- *
     * Memory
     * --------------------------------------------------------------- */

    /*
     * alu_result does triple duty here: it's "the ALU's answer" for
     * every non-memory instruction, "the memory address" for
     * loads/stores (base register + offset, computed by the same adder
     * via the operand muxing above), AND the source of the bus's
     * dword-aligned address plus the byte-lane shift amount below --
     * deliberate reuse of one datapath, not a coincidence.
     *
     * The bus (see wb4_sram.sv/uart_tx.sv) is word-granular: address
     * bits [2:0] aren't decoded by either slave, and sub-dword access
     * width instead comes from which of the 8 sel_o lanes are asserted.
     * So a byte/half/word access needs its size turned into a lane mask,
     * shifted into position by the address's low 3 bits -- the same
     * mask-and-shift technique wb4_sram.sv uses for its own byte-enable
     * writes.
     */
    wire [7:0] mem_size_mask = (mem_size == 2'b00) ? 8'b0000_0001 :
                                (mem_size == 2'b01) ? 8'b0000_0011 :
                                (mem_size == 2'b10) ? 8'b0000_1111 :
                                                       8'b1111_1111;
    /*
     * mem_paddr: named indirection point for a future Sv39 MMU stage,
     * mirroring fetch_paddr above. All FOUR downstream consumers of
     * "alu_result as an address" route through this one wire, not just
     * mem_addr, so there's exactly one RHS to touch when Sv39 lands and
     * no risk of missing a spot. Deliberately WORD_SIZE-wide even though
     * only bits[31:0] are consumed today, same reasoning as fetch_paddr
     * above.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] mem_paddr = alu_result;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0] mem_sel = mem_size_mask << mem_paddr[2:0];

    /* Dword-aligned memory address -- same precompute-outside-always_comb reason as fetch_addr above. */
    wire [31:0] mem_addr = {mem_paddr[31:3], 3'b0};

    /*
     * Misaligned data-access detection. RV64 requires natural alignment:
     * a byte access is always aligned; halfword/word/dword need address
     * bits [0], [1:0], [2:0] respectively to be zero. Same case-ladder
     * idiom as mem_size_mask above, keyed off the same mem_size encoding.
     * Closes the trap half of a real gap this file's header comment
     * documents: mem_sel's shift below has no carry into a second bus
     * word, so an overflowing access used to silently truncate instead
     * of either correctly handling it or trapping -- the spec requires
     * one or the other.
     */
    wire mem_misaligned = (mem_size == 2'b01) ? (mem_paddr[0]   != 1'b0)   :
                           (mem_size == 2'b10) ? (mem_paddr[1:0] != 2'b00) :
                           (mem_size == 2'b11) ? (mem_paddr[2:0] != 3'b000) :
                                                  1'b0; // byte access: always aligned
    /*
     * mem_load_misaligned/mem_store_misaligned classify WHICH cause code
     * applies (4 vs 6). LR/AMO's read phase sets is_load=1 (mem_control
     * above) but is classified as "Store/AMO" per the spec's cause
     * table, hence the explicit is_lr/is_amo_rmw exclusion from the load
     * side and inclusion on the store side. Checking once here, gating
     * mem_phase_needed before S_MEM is ever entered, covers both an
     * AMO's read and write phase with one check -- it does NOT need to
     * (and must NOT) stay live once past that point: mem_paddr(=
     * alu_result) gets REPURPOSED for the AMO modify value the instant
     * S_AMO_WRITE begins (same hazard the amo_addr_q/amo_sel_q capture
     * registers below already exist to avoid), and is_amo_rmw stays high
     * throughout both phases -- so without the `state == S_EXEC` guard,
     * this wire would spuriously reread the modify value's low bits AS
     * an address every cycle of S_AMO_WRITE too, and could fire a bogus
     * trap right at the AMO's real commit. Gating to S_EXEC matches
     * exactly the one place mem_phase_needed/trap_taken actually consult
     * these signals.
     *
     * mem_store_misaligned is keyed off is_sc (the STATIC "this
     * instruction is SC" signal), not is_store (which for SC is
     * DYNAMICALLY gated on sc_success in mem_control) -- per spec,
     * address misalignment is a property of the address alone,
     * independent of whether SC's reservation matches, so a misaligned
     * SC must trap even on a mismatch.
     */
    assign mem_load_misaligned  = (state == S_EXEC) && mem_misaligned && is_load && !is_lr && !is_amo_rmw;
    assign mem_store_misaligned = (state == S_EXEC) && mem_misaligned && (is_store || is_sc || is_lr || is_amo_rmw);

    /*
     * mem_load_access_fault/mem_store_access_fault: same is_load/is_lr/
     * is_amo_rmw split as mem_load_misaligned/mem_store_misaligned above
     * (LR is spec-classified under store/AMO, cause 7, not load, cause 5
     * -- same reasoning, not just convention-matching), but keyed off a
     * real wb_err_i response during S_MEM/S_AMO_WRITE instead of a
     * combinational address check during S_EXEC -- a bus error can only
     * be discovered once a real bus cycle actually returns. An AMO's
     * read-phase fault (S_MEM, wb_err_i, is_amo_rmw) falls into the
     * store/AMO term below, same as LR -- it never reaches S_AMO_WRITE
     * (see commit_now/the FSM above). An AMO's write-phase fault
     * (S_AMO_WRITE, wb_err_i) is its own explicit term, since is_load/
     * is_store don't apply there.
     */
    assign mem_load_access_fault  = (state == S_MEM) && wb_err_i && is_load && !is_lr && !is_amo_rmw;
    assign mem_store_access_fault = ((state == S_MEM) && wb_err_i && (is_store || is_sc || is_lr || is_amo_rmw))
                                  || ((state == S_AMO_WRITE) && wb_err_i);

    /*
     * mem_access_fault_addr: the one place mem_paddr vs. amo_addr_q
     * genuinely matters for trap_val below. mem_paddr is live/correct
     * during S_MEM, but gets REPURPOSED to the AMO modify value the
     * instant S_AMO_WRITE begins (the same hazard the AMO RVFI tap
     * already works around) -- an AMO write-phase fault must use
     * amo_addr_q instead, or mtval reports garbage. Named separately so
     * trap_val's own chain stays a flat, single-level ternary matching
     * every sibling arm, rather than growing a nested one just for this
     * case.
     */
    wire [(`WORD_SIZE - 1):0] mem_access_fault_addr = (state == S_AMO_WRITE) ? amo_addr_q : mem_paddr;

    /* trap_val, continued from its forward declaration above: the
     * misaligned-access and access-fault causes report the faulting
     * address, per spec's mtval/stval convention. fetch_fault_q (cause 1)
     * uses pc directly -- csr_file0.i_trap_pc already receives pc
     * unconditionally for every trap, so mepc == mtval here, which is
     * both spec-correct and sidesteps needing to know whether S_FETCH or
     * S_FETCH_HI was the one that actually faulted. */
    assign trap_val = fetch_fault_q ? pc
        : is_illegal_instr ? (is_compressed ? {48'b0, first_hw}
                                             : {{(`WORD_SIZE - `INSTR_SIZE){1'b0}}, instruction})
        : (mem_load_misaligned || mem_store_misaligned) ? mem_paddr
        : (mem_load_access_fault || mem_store_access_fault) ? mem_access_fault_addr
        : `WORD_SIZE'(0);

    /* Store data, pre-shifted into the byte lane(s) it'll land in. */
    wire [(`WORD_SIZE - 1):0] mem_wdata = imm_2 << (mem_paddr[2:0] * 8);

    /* Read response, shifted back down so the wanted byte(s) start at bit 0. */
    wire [(`WORD_SIZE - 1):0] mem_rdata_shifted = wb_dat_i >> (mem_paddr[2:0] * 8);

    /*
     * Precomputed slices, not inline inside load_format's case statement
     * below -- Icarus Verilog doesn't fully support constant selects
     * inside always_* processes (same reason as alu.sv's shamt_masked).
     */
    wire [7:0]  load_byte  = mem_rdata_shifted[7:0];
    wire [15:0] load_half  = mem_rdata_shifted[15:0];
    wire [31:0] load_word  = mem_rdata_shifted[31:0];
    /* Sign bits, precomputed too -- same reason (also used inside a replication below). */
    wire load_byte_sign = load_byte[7];
    wire load_half_sign = load_half[15];
    wire load_word_sign = load_word[31];

    logic [(`WORD_SIZE - 1):0] load_data;
    always_comb begin: load_format
        case (mem_size)
            2'b00: load_data = load_signed ? {{56{load_byte_sign}}, load_byte}
                                            : {56'b0, load_byte};
            2'b01: load_data = load_signed ? {{48{load_half_sign}}, load_half}
                                            : {48'b0, load_half};
            2'b10: load_data = load_signed ? {{32{load_word_sign}}, load_word}
                                            : {32'b0, load_word};
            default: load_data = mem_rdata_shifted; // 2'b11: doubleword, no extension needed
        endcase
    end: load_format

    /*
     * A extension: amo_rdata_q/amo_addr_q/amo_sel_q, captured on the
     * S_MEM-ack-to-S_AMO_WRITE transition edge (the same edge
     * instr_line_q captures a fresh fetch on). amo_rdata_q holds the OLD
     * (pre-modification) memory value -- destined for rd. amo_addr_q/
     * amo_sel_q are NECESSARY, not just convenient: mem_addr/mem_sel are
     * combinational functions of mem_paddr(=alu_result), and alu_result
     * gets REPURPOSED for the modify value the instant amo_modify_phase
     * goes high (S_AMO_WRITE) -- so mem_addr/mem_sel, left un-latched,
     * would silently start reflecting the WRONG thing (the modify
     * computation, reinterpreted as an address) the moment S_AMO_WRITE
     * begins. Latching them at the one moment they're still correct
     * sidesteps that entirely.
     */
    always_ff @(posedge clk) begin
        if (state == S_MEM && wb_ok && is_amo_rmw) begin
            // wb_ok, not bare wb_ack_i -- belt-and-suspenders: the FSM fix
            // above (commit_now/state transitions) already guarantees
            // S_AMO_WRITE is never entered on an errored read, so this
            // capture's value is never consumed either way on a fault, but
            // keying it on wb_ack_i alone would still populate it with
            // garbage on a paired-error read (icache/dcache's ack+err
            // coupling) for no reason.
            amo_rdata_q <= load_data;
            /*
             * Full WORD_SIZE-wide, aligned the same way the load/store RVFI
             * tap's own rvfi_mem_addr is (see that assign's comment) --
             * deliberately NOT mem_addr (only 32 bits, the bus-facing
             * truncation): a real riscv-formal counterexample already
             * caught the exact same 32-bit-truncation bug on the plain
             * load/store tap (the spec model computes its own full 64-bit
             * expected address from the solver's free rs1_rdata, which
             * this core's real 32-bit physical address space doesn't
             * bound). Truncated back to 32 bits at the one real-bus-use
             * site below (wb_addr_o), same convention as mem_paddr/
             * fetch_paddr elsewhere in this file.
             */
            amo_addr_q     <= {mem_paddr[63:3], 3'b0};
            amo_sel_q      <= mem_sel;
            amo_byte_off_q <= mem_paddr[2:0];
        end
    end

    /*
     * Shifted into byte-lane position, same idiom mem_wdata already uses
     * (mem_wdata = imm_2 << (mem_paddr[2:0] * 8), the TRUE unrounded low
     * bits). MUST use amo_byte_off_q here, NOT amo_addr_q[2:0] -- a real
     * riscv-formal counterexample (insn_amoswap_w_ch0, 2026-08-13) caught
     * this: amo_addr_q is deliberately rounded to a dword boundary, so
     * its low 3 bits are always zero, silently dropping the shift for
     * any .W AMO at an upper-word address (addr[2]=1, legal -- .W only
     * needs 4-byte alignment). This was a genuine, pre-existing hardware
     * bug (predates this session's amo_addr_q widening entirely) that
     * would have silently corrupted the write data on real silicon for
     * exactly that address pattern -- amo_sel_q never had this problem
     * (mem_sel is computed, using the true unrounded address, BEFORE
     * being latched), only the wdata shift did.
     */
    wire [(`WORD_SIZE - 1):0] amo_wdata = amo_new_value << (amo_byte_off_q * 8);

    /* --------------------------------------------------------------- *
     * Wishbone master: bus driving
     * --------------------------------------------------------------- */

    /*
     * Idle by default (every field), overridden per-state below -- keeps
     * this a clean combinational mux with no inferred latches, same
     * defaults-then-case idiom already used for mem_control/
     * reg_write_control above. S_EXEC drives nothing: the bus is only
     * needed to fetch (S_FETCH) or to access memory (S_MEM), never
     * during the settle-and-decode cycle in between.
     *
     * Both S_FETCH and S_MEM additionally gate cyc_o/stb_o with
     * !wb_done, NOT just `state == S_*` -- this is load-bearing, not
     * decoration. `state` only updates on the NEXT clock edge after
     * wb_ack_i/wb_err_i is observed (see the state always_ff above), so
     * for the entire cycle in between -- from the moment the slave's
     * registered ack_o/err_o first becomes 1 to the edge core.sv's FSM
     * actually reacts to it -- cyc_o/stb_o would otherwise still read as
     * asserted. A slave that simply does `if (cyc_i && stb_i) <act once,
     * ack>` (both wb4_sram.sv and uart_tx.sv do exactly this, and
     * correctly so -- nothing about the spec obligates a slave to guess
     * whether a still-asserted cyc/stb is a new request or the master
     * being slow to notice the old one) would then see cyc/stb still
     * high on that extra cycle and serve the SAME request a second time.
     * Found via this exact symptom: the UART printed "HH" for a
     * single-byte write. Gating with !wb_done drops cyc_o/stb_o
     * combinationally the moment the cycle terminates, one way or
     * another -- standard Wishbone master practice, and the same root
     * cause (not the same fix -- that one patched a testbench's own
     * master-role loop) as the wb_cycle ack-timing bug in
     * wb4_sram_tb.sv/uart_tx_tb.sv. Using wb_done rather than bare
     * wb_ack_i also matters for a genuinely unpaired error response
     * (wb4_sram.sv's own convention: err_o without ack_o) -- keyed on
     * ack alone, this guard would keep re-driving cyc_o/stb_o forever
     * after an error the slave already terminated, the exact bug class
     * bus-error trapping (see wb_done/wb_ok's own comment above) exists
     * to close everywhere.
     */

    // See this port's own header comment (module port list, above) for
    // why this is a plain wire off `state`, not folded into
    // wb_master_drive's !wb_done-gated combinational block below.
    assign wb_ifetch_o = (state == S_FETCH) || (state == S_FETCH_HI);

    // See this port's own header comment (module port list, above) for
    // the timing argument.
    assign icache_flush_o = commit_now && is_fence_i;

    always_comb begin: wb_master_drive
        wb_cyc_o  = 1'b0;
        wb_stb_o  = 1'b0;
        wb_we_o   = 1'b0;
        wb_addr_o = 32'b0;
        wb_dat_o  = 64'b0;
        wb_sel_o  = 8'b0;
        case (state)
            S_FETCH: begin
                if (!wb_done) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_addr_o = fetch_from_trap_vector ? {trap_vector[31:3], 3'b0} : fetch_addr;
                    wb_sel_o  = 8'hFF; // don't-care for a read; full line for clarity
                end
            end
            /*
             * C extension: the second dword of a crossing fetch --
             * reuses the exact same !wb_done gating discipline as
             * every other arm here.
             */
            S_FETCH_HI: begin
                if (!wb_done) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_addr_o = fetch_addr_hi;
                    wb_sel_o  = 8'hFF;
                end
            end
            S_MEM: begin
                if (!wb_done) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_we_o   = is_store;
                    wb_addr_o = mem_addr;
                    wb_sel_o  = mem_sel;
                    wb_dat_o  = mem_wdata;
                end
            end
            /*
             * A extension: the write half of a read-modify-write AMO.
             * Reuses the exact same !wb_done gating discipline as
             * S_FETCH/S_MEM above -- load-bearing here too, same reason.
             */
            S_AMO_WRITE: begin
                if (!wb_done) begin
                    wb_cyc_o  = 1'b1;
                    wb_stb_o  = 1'b1;
                    wb_we_o   = 1'b1;      // always a write -- this state exists for exactly this
                    wb_addr_o = amo_addr_q[31:0]; // real bus is 32-bit; amo_addr_q is WORD_SIZE-wide for RVFI
                    wb_sel_o  = amo_sel_q;
                    wb_dat_o  = amo_wdata;
                end
            end
            default: ; // S_EXEC: bus idle
        endcase
    end: wb_master_drive

    /* --------------------------------------------------------------- *
     * Writeback
     * --------------------------------------------------------------- */

    /* See the is_word_arith comment above for why only some *W ops need this. */
    wire [(`WORD_SIZE - 1):0] alu_result_w_trunc = {{32{alu_result[31]}}, alu_result[31:0]};

    /*
     * Zicsr writes the OLD CSR value to rd, for all 6 variants (per
     * spec) -- csr_rdata was captured combinationally off the CSR's
     * pre-write contents this same cycle, same "read before the
     * same-edge overwrite" principle as every other read-then-write
     * already in this design (e.g. the regfile's own read-before-write).
     */
    /*
     * A extension: is_amo_rmw MUST be checked before is_load: is_load is
     * TRUE for an AMO's entire decode-level lifetime (see mem_control
     * above), but AMO only ever COMMITS during S_AMO_WRITE (never
     * S_MEM), at which point load_data/wb_dat_i reflect the WRITE
     * transaction's bus lines, not a real read -- using load_data here
     * would silently write garbage to rd. amo_rdata_q (the captured OLD
     * value, per spec -- NOT amo_new_value, which is the NEW value
     * destined for memory, not rd) is the correct, stable value at that
     * commit edge. is_sc's arm produces the success(0)/failure(1) flag
     * -- no existing arm could ever produce this.
     */
    assign reg_write_data = is_amo_rmw            ? amo_rdata_q :
                             is_sc                 ? sc_result :
                             is_load                ? load_data :
                             (is_jal || is_jalr)     ? pc_plus_len :
                             is_word_arith            ? alu_result_w_trunc :
                             is_csr                    ? csr_rdata :
                             is_div_family               ? div_result :
                                                            alu_result; // ALU ops, LUI, AUIPC, *W shifts

    /* --------------------------------------------------------------- *
     * Next PC
     * --------------------------------------------------------------- */

    /* JAL's immediate lands on imm_1 (OUTPUT_J_TYPE_INSTR); branches' on imm3_sext. */
    wire [(`WORD_SIZE - 1):0] pc_rel_offset = is_jal ? imm_1 : imm3_sext;
    wire [(`WORD_SIZE - 1):0] pc_rel_target = pc + pc_rel_offset;

    /*
     * Per spec, JALR's target is (rs1 + sext(imm)) with bit 0 forced to
     * 0 -- guarantees an even target regardless of whether rs1+imm
     * happens to be odd. Only the JUMP TARGET's LSB is cleared here; the
     * link value written back to rd (pc_plus_len, declared up in Fetch
     * -- C extension's generalization of the old fixed pc+4) is always
     * unmodified.
     */
    wire [(`WORD_SIZE - 1):0] jalr_target = {alu_result[63:1], 1'b0};

    /*
     * Trap-vector redirect (U/S/M privilege-mode milestone). Direct mode
     * only -- mtvec/stvec's MODE bits[1:0] are stored as written (WARL)
     * but never consulted; Vectored mode's only benefit (cause-indexed
     * jump) is moot with no interrupt source, and even real
     * Vectored-mode hardware jumps straight to BASE for synchronous
     * exceptions regardless, per spec. trap_vector_base's own low 2
     * bits (the MODE field) are structurally never read below -- masked
     * off, not an oversight.
     */
    wire route_to_s = trap_taken ? trap_to_s : interrupt_to_s;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [(`WORD_SIZE - 1):0] trap_vector_base = route_to_s ? stvec_w : mtvec_w;
    /* verilator lint_on UNUSEDSIGNAL */
    assign trap_vector = {trap_vector_base[63:2], 2'b00};   // was `wire trap_vector =` -- now forward-declared

    assign next_pc = trap_taken              ? trap_vector   :
                      mret_taken              ? mepc_w        :
                      sret_taken              ? sepc_w        :
                      (is_jal || take_branch) ? pc_rel_target :
                      is_jalr                 ? jalr_target   :
                                                 pc_plus_len;

    /* --------------------------------------------------------------- *
     * PC register
     * --------------------------------------------------------------- */

    /*
     * EBREAK is a real synchronous trap now (cause 3, Breakpoint -- see
     * is_ebreak's own arm in exc_code/trap_taken above), so it commits
     * exactly like any other trap: pc jumps to trap_vector via next_pc's
     * own top-priority arm, mepc/mcause/mstatus update for real, and
     * execution resumes from whatever mtvec points at. There is no
     * freeze/halt special-case here anymore.
     *
     * The `halted` register (a permanent one-way EBREAK freeze latch,
     * removed here 2026-08-20) used to be what every testbench polled
     * hierarchically (e.g. dut.halted) to know a test program had
     * finished. Since EBREAK no longer parks the core, testbenches now
     * detect completion by observing the one-shot `trap_taken &&
     * is_ebreak` pulse directly and latching it locally (see
     * testbench/halt_wait.sv's updated contract). A future Debug Module
     * milestone will reintroduce real, resumable halt/resume state under
     * a new name -- this is a clean removal, not a placeholder.
     */
    always_ff @(posedge clk) begin
        if (rst)
            pc <= '0;
        else if (commit_now)
            pc <= next_pc;
        else if (interrupt_taken)
            pc <= trap_vector;
    end

    /*
     * current_priv (U/S/M privilege-mode milestone): resets to M per
     * spec. Updated by whichever of trap-entry/MRET/SRET fired this
     * edge -- at most one of the three can ever be true on the same
     * edge (see this file's Hazards reasoning in the project plan: a
     * trap always overrides an under-privileged MRET/SRET's own
     * mret_taken/sret_taken, via their !mret_priv_violation/
     * !sret_priv_violation gating).
     */
    always_ff @(posedge clk) begin
        if (rst)
            current_priv <= PRIV_M;
        else if (trap_taken)
            current_priv <= priv_t'(trap_to_s ? PRIV_S : PRIV_M);
        else if (mret_taken)
            current_priv <= priv_t'(mstatus_mpp_w);
        else if (sret_taken)
            current_priv <= priv_t'(mstatus_spp_w ? PRIV_S : PRIV_U);
        else if (interrupt_taken)
            current_priv <= priv_t'(interrupt_to_s ? PRIV_S : PRIV_M);
    end

`ifdef RISCV_FORMAL
    /*
     * RVFI tap -- pure combinational off the same signals that already
     * drive the real commit (reg_write_data, current_priv, mem_paddr/
     * mem_sel/mem_wdata, etc.) at the exact commit_now cycle. No new
     * pipeline stage needed: commit_now is already "this instruction
     * retires this cycle" for every instruction shape this core has,
     * including multi-cycle loads/stores/divides -- they just take
     * longer to REACH that one commit_now cycle, which matches RVFI's
     * documented model of exactly one rvfi_valid pulse per retired
     * instruction regardless of cycle count.
     *
     * First slice only -- covers isa=rv64i base-ISA checks
     * (verification/riscv-formal/). No CSR trace ports yet (those need
     * per-CSR rvfi_csr_<name>_* ports added deliberately once base-ISA
     * checks are green). rvfi_insn DOES correctly report the raw 16-bit
     * encoding for compressed instructions (see its own assign below) --
     * real Zca-specific check models still aren't generated yet (isa=rv64i
     * has none), so that path remains formally unexercised except by
     * ill_ch0, but the tap itself is already spec-compliant.
     */
    logic [63:0] rvfi_order_q;
    always_ff @(posedge clk) begin
        if (rst)
            rvfi_order_q <= 64'b0;
        else if (commit_now)
            rvfi_order_q <= rvfi_order_q + 64'b1;
    end

    assign rvfi_valid     = commit_now;
    assign rvfi_order     = rvfi_order_q;

    /*
     * rvfi_intr support: per riscv-formal's own spec (docs/source/rvfi.rst
     * upstream), rvfi_intr must be set for the first instruction that is
     * part of a trap handler, i.e. one whose rvfi_pc_rdata does not match
     * the rvfi_pc_wdata of the previous (valid) retirement. Implemented
     * mechanically -- compare THIS retirement's pc against the LAST
     * retirement's own next_pc -- not semantically ("was the previous
     * retirement a trap_taken/interrupt_taken event"), and deliberately
     * so: next_pc's own mux (see its assign below) already gives
     * trap_taken top priority (trap_taken ? trap_vector : ...), so a
     * synchronous exception's handler-entry PC chain is ALREADY naturally
     * consistent in this design -- no discontinuity to flag. A semantic
     * check would needlessly over-relax an already-tight, already-
     * correctly-passing property for that case. interrupt_taken, by
     * contrast, bypasses next_pc entirely via its own separate PC-register
     * arm (see the PC register always_ff below) -- a genuine discontinuity
     * this mechanical definition catches automatically, with no need to
     * enumerate which mechanisms can cause one (robust to any future
     * redirect mechanism this core grows later). Purely RVFI-scoped state
     * -- zero impact on the real non-formal build.
     */
    logic [63:0] rvfi_prev_pc_wdata_q;
    always_ff @(posedge clk) begin
        if (rst)             rvfi_prev_pc_wdata_q <= '0; // matches pc's own reset value,
                                                          // so the very first retirement
                                                          // after reset correctly reads
                                                          // rvfi_intr=0, no special case.
        else if (commit_now) rvfi_prev_pc_wdata_q <= next_pc;
    end

    /*
     * Per the RVFI spec (docs/source/rvfi.rst upstream): "For compressed
     * instructions the compressed instruction word must be output on
     * this port" -- the RAW 16-bit encoding (zero-extended), not a
     * C-expanded 32-bit equivalent. Reporting instruction (the expanded
     * value) unconditionally was a real spec-compliance gap: harmless
     * for isa=rv64i checks (wrapper.sv's RISCV_FORMAL_ALLOW_COMPRESSED
     * guard keeps is_compressed=0 throughout their entire BMC trace, so
     * this branch was never reachable there), but it made
     * rvfi_insn == 0 architecturally unreachable for the stock
     * rvfi_ill_check.sv template's canonical all-zero illegal-instruction
     * test vector even when the wrapper's guard is relaxed for that one
     * check (see wrapper.sv's RISCV_FORMAL_CHECK_ill exemption) -- a
     * genuinely illegal compressed encoding like 16'h0000 (C.ILLEGAL)
     * now correctly reports as 32'h00000000, not the inert 32'h13
     * placeholder that value still uses internally (that placeholder
     * still exists and is still correct for `instruction`'s OWN job of
     * feeding an always-decoder-safe value -- only what RVFI reports
     * changes here).
     */
    assign rvfi_insn      = is_compressed ? {16'b0, first_hw} : instruction;
    assign rvfi_trap      = trap_taken;
    assign rvfi_halt      = 1'b0; // no graceful-halt model exists yet
    assign rvfi_intr      = commit_now && (pc != rvfi_prev_pc_wdata_q); // see
                                   // rvfi_prev_pc_wdata_q's own comment above for the
                                   // full derivation -- real wiring, no longer hardwired
    assign rvfi_mode      = current_priv; // PRIV_U/S/M already match RVFI's 0/1/3 encoding
    assign rvfi_ixl       = 2'd2; // always 64-bit -- this core never runs 32-bit mode
    assign rvfi_rs1_addr  = read_gpr_A_sel;
    assign rvfi_rs2_addr  = read_gpr_B_sel;
    assign rvfi_rs1_rdata = read_gpr_A_data;
    assign rvfi_rs2_rdata = read_gpr_B_data;
    assign rvfi_rd_addr   = reg_write ? imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0] : 5'b0;
    assign rvfi_rd_wdata  = (reg_write && imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0] != 5'b0)
                             ? reg_write_data : 64'b0;
    assign rvfi_pc_rdata  = pc;
    assign rvfi_pc_wdata  = next_pc;
    /*
     * mem_paddr rounded down to a dword boundary, NOT the bus-facing
     * mem_addr wire -- matches riscv-formal's RISCV_FORMAL_ALIGNED_MEM
     * convention (see checks.cfg): rvfi_mem_rmask/wmask/wdata below are
     * already byte-lane-relative to the aligned bus WORD (mem_sel/
     * mem_wdata), and rvfi_mem_rdata is the raw unshifted bus response
     * (wb_dat_i) -- exactly what that convention expects. Deliberately
     * NOT mem_addr ({mem_paddr[31:3],3'b0}, only 32 bits wide): that's
     * correct for the real bus (this core's physical address space is
     * 32-bit by design) but truncates upper address bits the formal
     * spec model's own 64-bit spec_mem_addr computation doesn't -- a
     * real counterexample caught rvfi_mem_addr silently dropping bits
     * 63:32 whenever the solver picked a load/store address with any of
     * them set. mem_paddr itself is full WORD_SIZE-wide (see its own
     * comment above), so masking it directly here keeps the RVFI tap
     * exact while leaving the real, deliberately-32-bit bus address
     * (mem_addr) untouched.
     */
    /*
     * A extension: is_amo_rmw MUST take priority over is_load/is_store here,
     * same reason it must in mem_control's own read_write_data mux (see that
     * comment) -- is_load stays high for an AMO's ENTIRE lifetime (decode-
     * driven), including the S_AMO_WRITE cycle where rvfi_valid actually
     * pulses, and by then mem_paddr/mem_sel are the REPURPOSED modify value,
     * not the address (see the amo_addr_q/amo_sel_q capture comment above) --
     * amo_addr_q/amo_sel_q (latched before repurposing begins) are the only
     * correct source at that cycle. amo_rdata_q is deliberately used for
     * rvfi_mem_rdata instead of wb_dat_i: S_AMO_WRITE issues a WRITE bus
     * transaction, so the live wb_dat_i at that cycle is unrelated bus
     * garbage, not the old memory value -- and riscv-formal's insn_amo.v
     * spec model expects rvfi_mem_rdata pre-extracted to bit 0 (no
     * addr-offset shift, unlike insn_l*.v's load convention, which DOES
     * shift the raw bus word -- two different conventions sharing one port
     * name, confirmed by reading both generators directly), which is
     * exactly amo_rdata_q's shape (<= load_data, already shifted/extended).
     * Both rmask and wmask report amo_sel_q per riscv-formal's own AMO
     * modelling guidance (docs/source/rvfi.rst: "asserting bits in both
     * rvfi_mem_rmask and rvfi_mem_wmask") -- insn_amo.v's generated
     * spec_mem_rmask is never assigned so this isn't load-bearing for any
     * assertion today, but it's the spec-correct choice and costs nothing.
     */
    assign rvfi_mem_addr  = is_amo_rmw ? amo_addr_q
                           : (is_load || is_store) ? {mem_paddr[63:3], 3'b0}
                                                    : 64'b0;
    assign rvfi_mem_rmask = is_amo_rmw ? amo_sel_q : (is_load  ? mem_sel : 8'b0);
    assign rvfi_mem_wmask = is_amo_rmw ? amo_sel_q : (is_store ? mem_sel : 8'b0);
    assign rvfi_mem_rdata = is_amo_rmw ? amo_rdata_q : wb_dat_i;
    assign rvfi_mem_wdata = is_amo_rmw ? amo_wdata   : mem_wdata;

    /*
     * CSR trace ports: mepc/mcause/sepc/scause. All four are always fully-
     * defined 64-bit values (no partial-validity concerns like a memory
     * access might have), so rmask/wmask are simply all-ones. rdata is the
     * pre-instruction value (mepc_w etc., already wired for the real fetch-
     * redirect logic above); wdata is the post-instruction value (the
     * *_next combinational mirrors from csr_file.sv -- see that module's
     * header comment for why a plain registered value can't serve both
     * roles in the same cycle).
     */
    assign rvfi_csr_mepc_rmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_wmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mepc_rdata   = mepc_w;
    assign rvfi_csr_mepc_wdata   = mepc_next_w;
    assign rvfi_csr_mcause_rmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_wmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_mcause_rdata = mcause_w;
    assign rvfi_csr_mcause_wdata = mcause_next_w;
    assign rvfi_csr_sepc_rmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_wmask   = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_sepc_rdata   = sepc_w;
    assign rvfi_csr_sepc_wdata   = sepc_next_w;
    assign rvfi_csr_scause_rmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_wmask = 64'hffff_ffff_ffff_ffff;
    assign rvfi_csr_scause_rdata = scause_w;
    assign rvfi_csr_scause_wdata = scause_next_w;
`endif

endmodule
