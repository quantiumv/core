// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: csr_file
 *
 * CSR storage and read/write port for Zicsr, plus (as of the U/S/M
 * privilege-mode milestone) the M/S-mode trap-control CSRs and the
 * trap-entry/MRET/SRET side channel that atomically updates several of
 * them at once. No parameters (unlike register_file.sv's num_regs --
 * this CSR set is architecturally fixed).
 *
 * One address port serves both read and write, since a CSR instruction's
 * read and write always target the same address -- unlike GPRs' two
 * independent read ports, there is no dual-address case here.
 *
 * Every address not listed in the address map below reads 0 and ignores
 * writes (see the read mux's default arm, and the read-only-enforcement
 * note below). Backed CSRs fall into four shapes: misa/mvendorid/
 * marchid/mimpid/mhartid are fixed constants with no storage; mscratch/
 * sscratch/stvec/mtvec/mcounteren/scounteren/medeleg/mideleg/satp are
 * plain read/write registers; mcycle/minstret are free-running/
 * retirement counters that stay read-only (deferring writability avoids
 * designing the write-vs-auto-increment interaction for no current
 * benefit); mie/mip/mepc/sepc/mcause/scause/mtval/stval/mstatus each
 * have a SECOND writer beyond an ordinary CSR instruction -- see their
 * own always_ff blocks below.
 *
 * Read-only enforcement (for misa/mvendorid/etc. and any unmapped
 * address) is structural, not a flag check: those addresses simply have
 * no write-reacting arm anywhere to land in -- misa is a WARL field with
 * exactly one legal value, so "writes accepted but have no effect" is
 * spec-conformant, not a shortcut.
 *
 * Privilege-level enforcement (CSR address bits[9:8]) is NOT done here
 * -- it's computed in core.sv (which owns current_priv) and expressed
 * as an illegal-instruction trap that suppresses csr_we for that cycle
 * entirely, so an under-privileged access never reaches this module's
 * write logic at all. This module only backs storage and, for sie/sip/
 * sstatus, masks a read/write against the already-privileged mie/mip/
 * mstatus storage per spec (S-mode CSRs are masked VIEWS of M-mode
 * storage, not independent registers -- see mie_q/mip_q/mstatus_q's own
 * comments below).
 *
 * Input ports:
 *  i_clk: Clock signal (positive edge is used for all state updates).
 *  i_rst: Synchronous reset -- zeroes every real flip-flop in this module.
 *  i_csr_addr: CSR address, shared by both the read and the write.
 *  i_csr_we: High to write i_csr_wdata into the CSR at i_csr_addr. A
 *    bare enable -- core.sv computes *why* externally (rs1==x0/uimm==0
 *    write-suppression, a privilege violation, etc.), same division of
 *    responsibility as register_file.sv's i_load_gpr.
 *  i_csr_wdata: Data to write into the CSR at i_csr_addr, when enabled.
 *  i_instr_retired: Pulses once per retired instruction (any
 *    instruction, not just CSR ones) -- drives minstret_q. Independent
 *    of i_csr_we/i_csr_addr: a CSR instruction that doesn't otherwise
 *    write anything still retires and still increments minstret.
 *  i_current_priv: core.sv's current privilege level (2'b00/01/11 =
 *    U/S/M) -- consumed only by trap-entry below, to know which of
 *    mstatus's MPP/SPP fields records the pre-trap privilege.
 *  i_mtip: a continuously-valid external status level (same shape as
 *    i_current_priv -- not a one-shot pulse like the trap/mret/sret
 *    side channel below), sourced from the CLINT's mtip_o once core.sv
 *    wires it up (Milestone 6). Spliced combinationally into mip's bit
 *    7 (see mip_effective below); defaults to 1'b0 so core.sv's
 *    not-yet-updated instantiation (and csr_file_random_tb.sv/
 *    csr_file_priv_random_tb.sv, which don't drive it either) sees
 *    inert behavior -- an unconnected port floating to X would
 *    otherwise contaminate every mip/sip read on bit 7.
 *  i_meip/i_seip: PMP+PLIC plan Milestone 3's own generalization of
 *    i_mtip's exact same pattern -- continuously-valid external status
 *    levels, sourced from a future PLIC's o_meip/o_seip once core.sv
 *    wires them up (Milestone 6 of that plan). Spliced into mip bits 11
 *    and 9 respectively (see mip_effective below); same ANSI-defaulted
 *    1'b0, same reason (an unconnected port floating to X would
 *    contaminate mip/sip reads on those bits).
 *  i_trap_taken/i_trap_cause/i_trap_val/i_trap_pc/i_trap_to_s: the
 *    trap-entry side channel -- independent of i_csr_we/i_csr_addr,
 *    same "core.sv computes WHY, this module just honors it" division
 *    of responsibility i_instr_retired already established, extended
 *    to the several registers one trap must update atomically in a
 *    single cycle (something the single-address/single-data i_csr_we
 *    path structurally cannot do). i_trap_to_s selects the M- vs
 *    S-target register group (mepc/mcause/mtval/mstatus.MPP-side vs
 *    sepc/scause/stval/mstatus.SPP-side); core.sv computes this from
 *    medeleg (exported below as o_medeleg) and i_current_priv.
 *  i_mret_taken/i_sret_taken: same side-channel shape, for the trap-
 *    RETURN half of mstatus_q's four possible writers (see its own
 *    always_ff below).
 *  i_debug_entry/i_debug_cause: Milestone 3's own event pulse + data,
 *    same shape as the trap-entry side channel above but for Debug-Mode
 *    entry (dcsr.cause/dcsr.prv, dpc). Defaults to 1'b0/3'b0 -- no
 *    Debug-Mode halt/resume FSM exists in core.sv yet (Milestone 4), so
 *    core.sv's own instantiation leaves these unconnected for now,
 *    mirroring i_mtip's identical default-and-defer precedent above.
 *
 * Output ports:
 *  o_csr_rdata: Data read from the CSR at i_csr_addr, combinationally.
 *  o_mtvec/o_stvec/o_mepc/o_sepc/o_medeleg/o_mstatus_mpp/o_mstatus_spp/
 *  o_mstatus_tsr: "control-plane" outputs core.sv's trap/MRET/SRET logic
 *    needs every cycle, independent of whatever i_csr_addr happens to be
 *    driven to that cycle -- unlike o_csr_rdata, which is a single-address
 *    mux. o_mstatus_tsr feeds core.sv's SRET-from-S-mode illegal-instruction
 *    check (TSR itself is still just inert storage here, same as TVM/TW --
 *    core.sv is what turns the bit into an actual trap).
 *  o_mip/o_mie/o_mideleg/o_mstatus_mie/o_mstatus_sie: control-plane exports
 *    for Milestone 6's interrupt-taking logic in core.sv (unused/
 *    unconnected until then). o_mip drives from the derived mip_effective
 *    below, never raw mip_q -- same requirement as the mip/sip read-mux
 *    arms, so core.sv never sees a stale bit 7. o_mie/o_mideleg drive from
 *    plain mie_q/mideleg_q storage. o_mstatus_mie/o_mstatus_sie are
 *    single-bit mstatus taps, same precedent as o_mstatus_spp/o_mstatus_tsr
 *    above.
 *  o_dcsr/o_dpc: control-plane exports for Milestone 4's halt/resume FSM
 *    (unused/unconnected until then, same deferred-consumer precedent
 *    o_mip/etc. above established for Milestone 6). o_dcsr already
 *    overlays the WARL-fixed xdebugver field, same "never let the raw
 *    register leak into a read path" requirement o_mip has for mip_q.
 *  o_pmpcfg0/o_pmpaddr0-3/o_mstatus_mprv: control-plane exports for the
 *    PMP-enforcement milestone in core.sv (unused/unconnected until
 *    then, same deferred-consumer precedent every other control-plane
 *    export group above already established).
 */
module csr_file (
    input  logic i_clk,
    input  logic i_rst,
    input  logic [(`CSR_ADDR_SIZE - 1):0] i_csr_addr,
    output logic [(`WORD_SIZE - 1):0]     o_csr_rdata,
    input  logic                          i_csr_we,
    input  logic [(`WORD_SIZE - 1):0]     i_csr_wdata,
    input  logic                          i_instr_retired,  // drives minstret; independent of i_csr_we/addr

    input  logic [1:0]                    i_current_priv,
    input  logic                          i_mtip = 1'b0,
    input  logic                          i_meip = 1'b0,
    input  logic                          i_seip = 1'b0,

    input  logic                          i_trap_taken,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_cause,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_val,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_pc,
    input  logic                          i_trap_to_s,
    input  logic                          i_mret_taken,
    input  logic                          i_sret_taken,

    input  logic                          i_debug_entry = 1'b0,
    input  logic [2:0]                    i_debug_cause = 3'b0,

    output logic [(`WORD_SIZE - 1):0]     o_mtvec,
    output logic [(`WORD_SIZE - 1):0]     o_stvec,
    output logic [(`WORD_SIZE - 1):0]     o_mepc,
    output logic [(`WORD_SIZE - 1):0]     o_sepc,
    output logic [(`WORD_SIZE - 1):0]     o_medeleg,
    output logic [1:0]                    o_mstatus_mpp,
    output logic                          o_mstatus_spp,
    output logic                          o_mstatus_tsr,

    output logic [(`WORD_SIZE - 1):0]     o_mip,
    output logic [(`WORD_SIZE - 1):0]     o_mie,
    output logic [(`WORD_SIZE - 1):0]     o_mideleg,
    output logic                          o_mstatus_mie,
    output logic                          o_mstatus_sie,

    output logic [(`WORD_SIZE - 1):0]     o_dcsr,
    output logic [(`WORD_SIZE - 1):0]     o_dpc,

    /*
     * Trigger Module (Milestone 9 groundwork): the full composed
     * mcontrol6 value per slot, mirroring o_dcsr's own "export the
     * whole register, let the consumer pick bits" precedent -- core.sv
     * extracts m/s/u/execute/action directly from o_tdata1_0/1, same
     * as it already extracts ebreakm/s/u/step from o_dcsr.
     */
    output logic [(`WORD_SIZE - 1):0]     o_tdata1_0,
    output logic [(`WORD_SIZE - 1):0]     o_tdata1_1,
    output logic [(`WORD_SIZE - 1):0]     o_tdata2_0,
    output logic [(`WORD_SIZE - 1):0]     o_tdata2_1,

    /*
     * PMP (Milestone 1 of the PMP+PLIC staged plan): the whole composed
     * pmpcfg0 register (4 real regions packed into its low 4 bytes,
     * bytes 4-7 always 0) and each region's own pmpaddr, same "export
     * the whole register, let the consumer pick bits" precedent as
     * o_dcsr/o_tdata1_0 above -- core.sv's own PMP enforcement (a later
     * milestone, unconnected/unread until then) extracts L/A/X/W/R per
     * region directly from o_pmpcfg0. o_mstatus_mprv is MSTATUS_MPRV_BIT
     * (already-existing, previously-inert storage)'s first-ever real
     * consumer -- needed by that same later milestone to compute the
     * MPRV-aware effective privilege PMP's data-access check requires.
     */
    output logic [(`WORD_SIZE - 1):0]     o_pmpcfg0,
    output logic [(`WORD_SIZE - 1):0]     o_pmpaddr0,
    output logic [(`WORD_SIZE - 1):0]     o_pmpaddr1,
    output logic [(`WORD_SIZE - 1):0]     o_pmpaddr2,
    output logic [(`WORD_SIZE - 1):0]     o_pmpaddr3,
    output logic                          o_mstatus_mprv
`ifdef RISCV_FORMAL
    /*
     * mcause/scause: no real core.sv control logic needs these today (unlike
     * mtvec/stvec/mepc/sepc, which feed fetch redirection) -- only exposed
     * for the RVFI CSR trace ports below. The four *_next ports mirror each
     * register's own always_ff priority-mux combinationally (reset -> trap-
     * capture -> CSR-write -> unchanged) so core.sv can report both the
     * pre-instruction (rdata) and post-instruction (wdata) value in the same
     * cycle rvfi_valid pulses -- the always_ff itself only makes the new
     * value visible the FOLLOWING cycle, too late for RVFI's same-cycle
     * contract.
     */
    ,
    output logic [(`WORD_SIZE - 1):0]     o_mcause,
    output logic [(`WORD_SIZE - 1):0]     o_scause,
    output logic [(`WORD_SIZE - 1):0]     o_mepc_next,
    output logic [(`WORD_SIZE - 1):0]     o_sepc_next,
    output logic [(`WORD_SIZE - 1):0]     o_mcause_next,
    output logic [(`WORD_SIZE - 1):0]     o_scause_next
`endif
);
    /* ----------------------------------------------------------------- *
     * CSR address map (module-local constants, same register-map-
     * constant `localparam` style as uart_tx.sv's TX_DATA_SEL/
     * TX_STATUS_SEL -- not a shared `define, since nothing outside
     * this module needs to name a CSR by address).
     * ----------------------------------------------------------------- */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MISA      = 12'h301;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MVENDORID = 12'hF11;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MARCHID   = 12'hF12;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIMPID    = 12'hF13;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MHARTID   = 12'hF14;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSCRATCH  = 12'h340;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCYCLE    = 12'hB00;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MINSTRET  = 12'hB02;

    /*
     * U/S/M privilege-mode milestone additions. S-mode CSRs first (per
     * spec, several of these -- sstatus/sie/sip -- are masked VIEWS into
     * the M-mode storage below, not independent registers; see their
     * always_ff blocks/read-mux arms for exactly which bits), then the
     * M-mode trap-control CSRs.
     */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSTATUS    = 12'h100;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SIE        = 12'h104;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVEC      = 12'h105;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SCOUNTEREN = 12'h106;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SSCRATCH   = 12'h140;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SEPC       = 12'h141;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SCAUSE     = 12'h142;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_STVAL      = 12'h143;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SIP        = 12'h144;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_SATP       = 12'h180;

    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MSTATUS    = 12'h300;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEDELEG    = 12'h302;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIDELEG    = 12'h303;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIE        = 12'h304;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVEC      = 12'h305;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCOUNTEREN = 12'h306;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MEPC       = 12'h341;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MCAUSE     = 12'h342;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MTVAL      = 12'h343;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_MIP        = 12'h344;

    /*
     * Debug-mode CSRs (Milestone 3 of the EBREAK/JTAG staged plan). Real
     * spec addresses -- confirmed free of collision with anything above.
     * Only meaningfully accessible from Debug Mode; core.sv is
     * responsible for trapping any access attempted outside it (see
     * design/core.sv's debug_csr_violation, a check separate from
     * csr_priv_violation above -- these four addresses encode
     * imm_2[9:8]==2'b11, the same bit pattern as an ordinary M-mode-only
     * CSR, so the existing magnitude-comparison privilege check would
     * let M-mode straight through). This module itself still does no
     * address-based access control, same division of responsibility
     * described in the module header.
     */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DCSR      = 12'h7B0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DPC       = 12'h7B1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DSCRATCH0 = 12'h7B2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_DSCRATCH1 = 12'h7B3;

    /*
     * Trigger Module CSRs (Milestone 9 groundwork -- mcontrol6 only, 2
     * fixed slots, execute-address-match only). Real spec addresses.
     * Same Debug-Mode-only division of responsibility as the Debug-mode
     * CSR block above -- this module does no address-based access
     * control; see design/core.sv's is_trigger_csr_addr/
     * trigger_csr_violation.
     */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TSELECT = 12'h7A0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA1  = 12'h7A1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA2  = 12'h7A2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TDATA3  = 12'h7A3;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_TINFO   = 12'h7A4;

    /*
     * Physical Memory Protection CSRs (Milestone 1 of the PMP+PLIC staged
     * plan). Real spec addresses -- 0x3A0-0x3EF's own bits[9:8]=2'b11
     * already make every one of these M-mode-only for free via the
     * existing csr_priv_violation magnitude check in design/core.sv, the
     * same free privilege-gating precedent the Trigger Module CSRs above
     * already rely on for their own, different address range. Only 4
     * regions are implemented (pmpcfg0's low 4 bytes; pmpcfg2 and up,
     * and pmpaddr4-63, are simply never added to this address map at
     * all -- see the read mux's own default arm for why that's
     * sufficient, not a gap).
     */
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPCFG0  = 12'h3A0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR0 = 12'h3B0;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR1 = 12'h3B1;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR2 = 12'h3B2;
    localparam logic [(`CSR_ADDR_SIZE - 1):0] CSR_ADDR_PMPADDR3 = 12'h3B3;

    /*
     * Read-only CSRs with no backing storage at all -- fixed values
     * returned directly by the read mux below, nothing to reset. misa's
     * value: MXL = 2 in bits[63:62] (selects XLEN=64) plus bit 8 set
     * (the 'I' extension letter, where A=0, B=1, ... Z=25). Writes are
     * accepted on the Zicsr write path (see mscratch_q's block below --
     * that path is shared, but misa has no write-reacting arm of its
     * own) yet have no effect, which is spec-legal for a WARL field
     * with exactly one legal value.
     */
    localparam logic [(`WORD_SIZE - 1):0] MISA_VALUE      = 64'h8000_0000_0000_0100;
    localparam logic [(`WORD_SIZE - 1):0] MVENDORID_VALUE = `WORD_SIZE'(0);
    localparam logic [(`WORD_SIZE - 1):0] MARCHID_VALUE   = `WORD_SIZE'(0);
    localparam logic [(`WORD_SIZE - 1):0] MIMPID_VALUE    = `WORD_SIZE'(0);
    localparam logic [(`WORD_SIZE - 1):0] MHARTID_VALUE   = `WORD_SIZE'(0);
    /*
     * tinfo (Milestone 9): version=1 (bits[31:24], ratified Sdtrig
     * v1.0 -- required since this core implements mcontrol6, which
     * needs tinfo.version>=1), info=0x0041 (bits[15:0]: bit 0 = type 0
     * "no trigger" always trivially supported, bit 6 = type 6
     * mcontrol6; every other type unsupported).
     */
    localparam logic [(`WORD_SIZE - 1):0] TINFO_VALUE = 64'h0000_0000_0100_0041;

    /*
     * Unlike register_file.sv's gp_registers (no reset port there at
     * all -- zeroed only via a simulation-only `initial` block, since
     * the ISA defines no required GPR reset value), these three CSRs
     * get a real synchronous i_rst arm in each always_ff block below.
     * Same underlying reasoning as register_file.sv's zero-fill -- a
     * clean, checkable 0 instead of undefined 'X for the entire
     * simulation -- just achieved through this module's actual reset
     * port instead of an `initial` block, since csr_file.sv (unlike
     * register_file.sv) has one.
     */

    /* ----------------------------------------------------------------- *
     * Real storage. No [0:4095]-style address-indexed array: every
     * mapped-but-unbacked CSR above is a constant, and every unmapped
     * address reads 0 via the read mux's default arm below, so there is
     * nothing else to back with real state. (The U/S/M privilege-mode
     * milestone adds a lot more storage than the original 3 flip-flops
     * here -- see the block below this one.)
     * ----------------------------------------------------------------- */
    logic [(`WORD_SIZE - 1):0] mscratch_q;
    logic [(`WORD_SIZE - 1):0] mcycle_q;
    logic [(`WORD_SIZE - 1):0] minstret_q;

    /*
     * mscratch: plain full read/write, zero side effects -- the
     * "vanilla CSR" proof point. This is the ONLY always_ff block in
     * this module with a write-reacting arm; that is deliberate, not
     * an oversight -- see the read-only-enforcement note in the module
     * header above.
     */
    always_ff @(posedge i_clk) begin
        if (i_rst)
            mscratch_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MSCRATCH))
            mscratch_q <= i_csr_wdata;
    end

    /*
     * mcycle: free-running, increments unconditionally every clock
     * edge past reset -- counts clock cycles, not retired
     * instructions, so it advances regardless of
     * i_csr_we/i_instr_retired. Read-only for now (see design doc);
     * accordingly this block has no write arm at all, so a write here
     * structurally cannot land (same trick as misa above, but via
     * absent write logic in a real always_ff block instead of absent
     * storage entirely).
     */
    always_ff @(posedge i_clk) begin
        if (i_rst)
            mcycle_q <= '0;
        else
            mcycle_q <= mcycle_q + 1'b1;
    end

    /*
     * minstret: increments by 1 on every instruction retirement
     * (i_instr_retired, driven externally by core.sv's commit_now --
     * including CSR instructions themselves, no special-casing needed
     * here). Also read-only for now, same reasoning/mechanism as
     * mcycle above.
     */
    always_ff @(posedge i_clk) begin
        if (i_rst)
            minstret_q <= '0;
        else if (i_instr_retired)
            minstret_q <= minstret_q + 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * U/S/M privilege-mode milestone: new storage.
     * ----------------------------------------------------------------- */

    /*
     * Plain full read/write registers -- same "vanilla CSR" shape as
     * mscratch_q above, one always_ff block each. mtvec/stvec: only
     * their BASE field (bits[63:2]) is ever consumed (by core.sv's
     * trap-vector mux) -- the MODE field (bits[1:0]) is stored as
     * written (WARL) but never itself changes behavior, since Vectored
     * mode's only benefit (cause-indexed jump) is moot with no
     * interrupt source yet, and even real Vectored-mode hardware jumps
     * straight to BASE for synchronous exceptions regardless, per spec.
     */
    logic [(`WORD_SIZE - 1):0] stvec_q, mtvec_q;
    logic [(`WORD_SIZE - 1):0] mcounteren_q, scounteren_q;
    logic [(`WORD_SIZE - 1):0] sscratch_q;
    logic [(`WORD_SIZE - 1):0] satp_q;
    logic [(`WORD_SIZE - 1):0] medeleg_q, mideleg_q;

    always_ff @(posedge i_clk) begin
        if (i_rst) stvec_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_STVEC)) stvec_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) mtvec_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MTVEC)) mtvec_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) mcounteren_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MCOUNTEREN)) mcounteren_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) scounteren_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SCOUNTEREN)) scounteren_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) sscratch_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SSCRATCH)) sscratch_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        /* satp: real storage, zero page-table-walker consumer yet --
         * deliberately, this is the Sv39 milestone's own seam. */
        if (i_rst) satp_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SATP)) satp_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        /* medeleg: real storage AND enforced -- core.sv's trap-entry
         * logic reads o_medeleg to decide the M- vs S-mode trap target. */
        if (i_rst) medeleg_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MEDELEG)) medeleg_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        /* mideleg: real storage, inert -- no interrupt source exists yet
         * to delegate, but a future interrupt milestone shouldn't need
         * to re-touch this module's basic structure to add it. */
        if (i_rst) mideleg_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MIDELEG)) mideleg_q <= i_csr_wdata;
    end

    /*
     * mie/mip: written directly via their own addresses, OR through the
     * sie/sip addresses masked by mideleg_q -- per spec, sie/sip are
     * masked VIEWS of mie/mip (only the interrupt causes delegated to
     * S via mideleg are visible/writable through sie/sip), not
     * independent storage. Both real storage, both inert -- no
     * interrupt source exists yet to ever set a bit here itself.
     */
    logic [(`WORD_SIZE - 1):0] mie_q, mip_q;

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            mie_q <= '0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_MIE)) begin
            mie_q <= i_csr_wdata;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_SIE)) begin
            mie_q <= (mie_q & ~mideleg_q) | (i_csr_wdata & mideleg_q);
        end
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            mip_q <= '0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_MIP)) begin
            mip_q <= i_csr_wdata & ~64'hA80;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_SIP)) begin
            mip_q <= ((mip_q & ~mideleg_q) | (i_csr_wdata & mideleg_q)) & ~64'hA80;
        end
    end

    /*
     * mepc/sepc, mcause/scause, mtval/stval: each written by EITHER
     * trap-entry targeting that privilege level, OR an ordinary CSR
     * write to that address. These two writers can never genuinely
     * race -- see core.sv's Hazards section -- so the if/else-if order
     * below is a documentation aid, not an arbiter resolving a real
     * conflict: whenever i_trap_taken fires for a CSR-privilege-
     * violation instruction, core.sv has already forced i_csr_we to 0
     * for that same cycle (see core.sv's csr_we/!trap_taken gate), so
     * the "ordinary write" arm structurally cannot also fire then.
     */
    logic [(`WORD_SIZE - 1):0] mepc_q, sepc_q;
    logic [(`WORD_SIZE - 1):0] mcause_q, scause_q;
    logic [(`WORD_SIZE - 1):0] mtval_q, stval_q;

    /*
     * mepc/sepc are WARL: per spec, bit 0 must always read as zero (this
     * core has IALIGN=16 via Zca, so only bit 0 needs masking, not
     * bit[1:0] as an IALIGN=32-only core would need). The trap-entry
     * write (i_trap_pc, sourced from core.sv's own pc register) is
     * already architecturally guaranteed even -- every next_pc-producing
     * path there either masks explicitly (jalr_target, trap_vector) or
     * is a sum of an already-even base and an ISA-guaranteed-even
     * offset (branch/jump immediates always have bit 0 hardwired 0 in
     * their encoding) -- so only the direct CSR-write arm needs masking
     * here: an ordinary `csrrw mepc, x1` can set x1 to any 64-bit value,
     * including odd, with nothing upstream to stop it.
     */
    always_ff @(posedge i_clk) begin
        if (i_rst) mepc_q <= '0;
        else if (i_trap_taken && !i_trap_to_s) mepc_q <= i_trap_pc;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MEPC)) mepc_q <= {i_csr_wdata[(`WORD_SIZE - 1):1], 1'b0};
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) sepc_q <= '0;
        else if (i_trap_taken && i_trap_to_s) sepc_q <= i_trap_pc;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SEPC)) sepc_q <= {i_csr_wdata[(`WORD_SIZE - 1):1], 1'b0};
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) mcause_q <= '0;
        else if (i_trap_taken && !i_trap_to_s) mcause_q <= i_trap_cause;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MCAUSE)) mcause_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) scause_q <= '0;
        else if (i_trap_taken && i_trap_to_s) scause_q <= i_trap_cause;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SCAUSE)) scause_q <= i_csr_wdata;
    end

`ifdef RISCV_FORMAL
    /*
     * mepc_next/sepc_next/mcause_next/scause_next: read-only combinational
     * transcriptions of the four always_ff bodies immediately above (reset
     * arm dropped -- rvfi_valid can never be true during reset, so it's
     * never sampled) -- see this port group's own comment on the module
     * header for why RVFI needs both the pre- and post-instruction value
     * in the same cycle.
     */
    assign o_mepc_next   = (i_trap_taken && !i_trap_to_s) ? i_trap_pc
                          : (i_csr_we && (i_csr_addr == CSR_ADDR_MEPC)) ? {i_csr_wdata[(`WORD_SIZE - 1):1], 1'b0}
                          : mepc_q;
    assign o_sepc_next   = (i_trap_taken && i_trap_to_s) ? i_trap_pc
                          : (i_csr_we && (i_csr_addr == CSR_ADDR_SEPC)) ? {i_csr_wdata[(`WORD_SIZE - 1):1], 1'b0}
                          : sepc_q;
    assign o_mcause_next = (i_trap_taken && !i_trap_to_s) ? i_trap_cause
                          : (i_csr_we && (i_csr_addr == CSR_ADDR_MCAUSE)) ? i_csr_wdata
                          : mcause_q;
    assign o_scause_next = (i_trap_taken && i_trap_to_s) ? i_trap_cause
                          : (i_csr_we && (i_csr_addr == CSR_ADDR_SCAUSE)) ? i_csr_wdata
                          : scause_q;
`endif

    always_ff @(posedge i_clk) begin
        if (i_rst) mtval_q <= '0;
        else if (i_trap_taken && !i_trap_to_s) mtval_q <= i_trap_val;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MTVAL)) mtval_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) stval_q <= '0;
        else if (i_trap_taken && i_trap_to_s) stval_q <= i_trap_val;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_STVAL)) stval_q <= i_csr_wdata;
    end

    /*
     * mstatus: backs BOTH mstatus (0x300) and sstatus (0x100) -- per
     * spec sstatus is a masked VIEW/alias of mstatus, not independent
     * storage, so there is exactly one flip-flop group here, not two.
     * Bit positions below match the RISC-V privileged spec exactly;
     * everything not named here (FS/XS/VS/SD, the FP/vector-extension
     * fields this core doesn't have, etc.) stays hardwired 0 -- there's
     * no storage for them at all, so a write can't set them regardless
     * of what i_csr_wdata contains.
     *
     * FOUR possible writers: trap-entry (pushes IE into PIE and sets
     * PP to the pre-trap privilege), MRET/SRET (pops PIE back into IE,
     * resets PP to U per spec), or an ordinary ISR write to mstatus/
     * sstatus. Resolved by priority below for documentation clarity --
     * same "never a genuine runtime race" reasoning as mepc/mcause/
     * mtval above (core.sv's own Hazards section reasons through why
     * trap-entry and an ordinary mstatus/sstatus write can only ever
     * coincide when that write IS the trapping instruction, in which
     * case i_csr_we is already forced low that cycle).
     */
    localparam int MSTATUS_SIE_BIT  = 1;
    localparam int MSTATUS_MIE_BIT  = 3;
    localparam int MSTATUS_SPIE_BIT = 5;
    localparam int MSTATUS_MPIE_BIT = 7;
    localparam int MSTATUS_SPP_BIT  = 8;
    localparam int MSTATUS_MPP_LSB  = 11;
    localparam int MSTATUS_MPP_MSB  = 12;
    localparam int MSTATUS_MPRV_BIT = 17;   // real storage, inert -- Sv39 seam
    localparam int MSTATUS_SUM_BIT  = 18;   // real storage, inert -- Sv39 seam
    localparam int MSTATUS_MXR_BIT  = 19;   // real storage, inert -- Sv39 seam
    localparam int MSTATUS_TVM_BIT  = 20;   // real storage, not enforced
    localparam int MSTATUS_TW_BIT   = 21;   // real storage, not enforced
    localparam int MSTATUS_TSR_BIT  = 22;   // real storage, not enforced

    /* sstatus's visible/writable subset of mstatus's bits, per spec --
     * MIE/MPIE/MPP/MPRV/TVM/TW/TSR never leak through the sstatus address. */
    localparam logic [(`WORD_SIZE - 1):0] SSTATUS_VIEW_MASK =
        (`WORD_SIZE'(1) << MSTATUS_SIE_BIT)  | (`WORD_SIZE'(1) << MSTATUS_SPIE_BIT) |
        (`WORD_SIZE'(1) << MSTATUS_SPP_BIT)  | (`WORD_SIZE'(1) << MSTATUS_SUM_BIT)  |
        (`WORD_SIZE'(1) << MSTATUS_MXR_BIT);

    /* UXL/SXL: WARL fields fixed at 2 (XLEN=64 for U-mode/S-mode), same
     * single-legal-value treatment misa's own fixed bits already use. */
    localparam logic [(`WORD_SIZE - 1):0] MSTATUS_UXL_FIXED = (`WORD_SIZE'(2) << 32);
    localparam logic [(`WORD_SIZE - 1):0] MSTATUS_SXL_FIXED = (`WORD_SIZE'(2) << 34);

    logic [(`WORD_SIZE - 1):0] mstatus_q;

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            mstatus_q <= '0;
        end else if (i_trap_taken) begin
            if (i_trap_to_s) begin
                mstatus_q[MSTATUS_SPIE_BIT] <= mstatus_q[MSTATUS_SIE_BIT];
                mstatus_q[MSTATUS_SIE_BIT]  <= 1'b0;
                mstatus_q[MSTATUS_SPP_BIT]  <= i_current_priv[0]; // current_priv is always U or S here (never M -- M never delegates)
            end else begin
                mstatus_q[MSTATUS_MPIE_BIT] <= mstatus_q[MSTATUS_MIE_BIT];
                mstatus_q[MSTATUS_MIE_BIT]  <= 1'b0;
                mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] <= i_current_priv;
            end
        end else if (i_mret_taken) begin
            mstatus_q[MSTATUS_MIE_BIT]  <= mstatus_q[MSTATUS_MPIE_BIT];
            mstatus_q[MSTATUS_MPIE_BIT] <= 1'b1;
            mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] <= 2'b00; // MPP resets to U after use, per spec
            // Per spec: an mret/sret that drops privilege below M also clears MPRV
            // (destination priv is the PRE-update MPP here, i.e. the mode MRET is
            // returning to). MRET returning to M itself (MPP==2'b11) leaves MPRV alone.
            if (mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] != 2'b11)
                mstatus_q[MSTATUS_MPRV_BIT] <= 1'b0;
        end else if (i_sret_taken) begin
            mstatus_q[MSTATUS_SIE_BIT]  <= mstatus_q[MSTATUS_SPIE_BIT];
            mstatus_q[MSTATUS_SPIE_BIT] <= 1'b1;
            mstatus_q[MSTATUS_SPP_BIT]  <= 1'b0; // SPP resets to U after use, per spec
            // SPP is 1 bit (U or S only), so SRET's destination is never M --
            // MPRV unconditionally clears, unlike MRET's MPP-dependent check above.
            mstatus_q[MSTATUS_MPRV_BIT] <= 1'b0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_MSTATUS)) begin
            mstatus_q[MSTATUS_SIE_BIT]  <= i_csr_wdata[MSTATUS_SIE_BIT];
            mstatus_q[MSTATUS_MIE_BIT]  <= i_csr_wdata[MSTATUS_MIE_BIT];
            mstatus_q[MSTATUS_SPIE_BIT] <= i_csr_wdata[MSTATUS_SPIE_BIT];
            mstatus_q[MSTATUS_MPIE_BIT] <= i_csr_wdata[MSTATUS_MPIE_BIT];
            mstatus_q[MSTATUS_SPP_BIT]  <= i_csr_wdata[MSTATUS_SPP_BIT];
            mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] <= i_csr_wdata[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB];
            mstatus_q[MSTATUS_MPRV_BIT] <= i_csr_wdata[MSTATUS_MPRV_BIT];
            mstatus_q[MSTATUS_SUM_BIT]  <= i_csr_wdata[MSTATUS_SUM_BIT];
            mstatus_q[MSTATUS_MXR_BIT]  <= i_csr_wdata[MSTATUS_MXR_BIT];
            mstatus_q[MSTATUS_TVM_BIT]  <= i_csr_wdata[MSTATUS_TVM_BIT];
            mstatus_q[MSTATUS_TW_BIT]   <= i_csr_wdata[MSTATUS_TW_BIT];
            mstatus_q[MSTATUS_TSR_BIT]  <= i_csr_wdata[MSTATUS_TSR_BIT];
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_SSTATUS)) begin
            mstatus_q[MSTATUS_SIE_BIT]  <= i_csr_wdata[MSTATUS_SIE_BIT];
            mstatus_q[MSTATUS_SPIE_BIT] <= i_csr_wdata[MSTATUS_SPIE_BIT];
            mstatus_q[MSTATUS_SPP_BIT]  <= i_csr_wdata[MSTATUS_SPP_BIT];
            mstatus_q[MSTATUS_SUM_BIT]  <= i_csr_wdata[MSTATUS_SUM_BIT];
            mstatus_q[MSTATUS_MXR_BIT]  <= i_csr_wdata[MSTATUS_MXR_BIT];
            // MIE/MPIE/MPP/MPRV/TVM/TW/TSR deliberately untouched -- not visible/writable via sstatus.
        end
    end

    /*
     * Debug-mode CSRs (Milestone 3 of the EBREAK/JTAG staged plan). No
     * Debug-Mode halt/resume FSM exists in core.sv yet (Milestone 4) --
     * i_debug_entry stays permanently 0 from core.sv's own instantiation
     * until then, so dcsr_q/dpc_q never actually capture anything outside
     * a testbench driving the side channel directly. Real storage is
     * built now anyway, same "prove the shape before the real consumer
     * exists" precedent satp_q already established for Sv39.
     *
     * dpc_q mirrors mepc_q's own reset -> hardware-event -> ordinary-
     * write priority chain and its bit-0 WARL mask exactly (same
     * instruction-alignment reasoning; i_trap_pc is reused as-is, not a
     * new port -- core.sv already drives it unconditionally every
     * cycle).
     */
    logic [(`WORD_SIZE - 1):0] dpc_q;
    always_ff @(posedge i_clk) begin
        if (i_rst) dpc_q <= '0;
        else if (i_debug_entry) dpc_q <= i_trap_pc;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_DPC)) dpc_q <= {i_csr_wdata[(`WORD_SIZE - 1):1], 1'b0};
    end

    /*
     * dcsr_q: hardware entry only ever touches cause[8:6]/prv[1:0] (per
     * spec) -- everything else (ebreakm/s/u/stepie/step/etc.) persists
     * across entry, ordinary-CSR-writable only, same partial-bit-range
     * nonblocking-assignment idiom mstatus_q's own trap-entry arm already
     * uses above for MPP/SPP. xdebugver[31:28] is WARL-fixed at 4, same
     * "no storage bit, OR'd in at read-mux time" treatment as
     * MSTATUS_UXL_FIXED -- the FULL field is masked out of storage on
     * every software write (not just the bits set in the fixed value
     * itself), so the OR at read time is always correct regardless of
     * what software attempts to write there.
     */
    localparam logic [(`WORD_SIZE - 1):0] DCSR_XDEBUGVER_MASK  = (`WORD_SIZE'(4'hF) << 28);
    localparam logic [(`WORD_SIZE - 1):0] DCSR_XDEBUGVER_FIXED = (`WORD_SIZE'(4)    << 28);

    logic [(`WORD_SIZE - 1):0] dcsr_q;
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            dcsr_q <= '0;
        end else if (i_debug_entry) begin
            dcsr_q[8:6] <= i_debug_cause;
            dcsr_q[1:0] <= i_current_priv;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_DCSR)) begin
            dcsr_q <= i_csr_wdata & ~DCSR_XDEBUGVER_MASK;
        end
    end

    /* dscratch0/dscratch1: plain full read/write, zero side effects --
     * same "vanilla CSR" shape as mscratch_q above, Debug-Mode program-
     * buffer code's own scratch space once one exists. */
    logic [(`WORD_SIZE - 1):0] dscratch0_q, dscratch1_q;
    always_ff @(posedge i_clk) begin
        if (i_rst) dscratch0_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_DSCRATCH0)) dscratch0_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) dscratch1_q <= '0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_DSCRATCH1)) dscratch1_q <= i_csr_wdata;
    end

    /*
     * Trigger Module storage (Milestone 9 groundwork) -- mcontrol6, 2
     * fixed slots. Per-slot fields are individually-named registers
     * (_q0/_q1 suffix), not one packed register per slot, directly
     * extending design/dm.sv's own Milestone 5 precedent
     * (sbaddress0_q..sbaddress3_q, not one packed sbcs_q) -- required
     * here specifically because action's WARL clamp (below) isn't
     * expressible as a static AND-mask the way a "no storage, OR'd in
     * at read time" field is. Every OTHER tdata1 field this core
     * doesn't implement (uncertain/vs/vu/select/size/chain/match/
     * uncertainen/store/load) has no storage bit at all -- hardcoded
     * directly into tdata1_val0/1 below, nothing to reset or mask.
     */
    logic tselect_q;
    logic [(`WORD_SIZE - 1):0] tdata2_q0, tdata2_q1;
    logic tdata1_dmode_q0,   tdata1_dmode_q1;
    logic tdata1_hit1_q0,    tdata1_hit1_q1;
    logic tdata1_hit0_q0,    tdata1_hit0_q1;
    logic [3:0] tdata1_action_q0, tdata1_action_q1;
    logic tdata1_m_q0,       tdata1_m_q1;
    logic tdata1_s_q0,       tdata1_s_q1;
    logic tdata1_u_q0,       tdata1_u_q1;
    logic tdata1_execute_q0, tdata1_execute_q1;

    /* tselect: WARL across exactly 2 legal slots -- storing only bit 0
     * of any write trivially guarantees the readback is always in
     * {0,1} regardless of what was written. Spec-legal: the real
     * tselect field is documented WARL, "writes of values >= the
     * number of supported triggers may result in a different value...
     * than what was written" (riscv-debug-spec xml/hwbp_registers.xml). */
    always_ff @(posedge i_clk) begin
        if (i_rst) tselect_q <= 1'b0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_TSELECT)) tselect_q <= i_csr_wdata[0];
    end

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            tdata2_q0 <= '0; tdata2_q1 <= '0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_TDATA2) && !tselect_q) begin
            tdata2_q0 <= i_csr_wdata;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_TDATA2) && tselect_q) begin
            tdata2_q1 <= i_csr_wdata;
        end
    end

    /* action is the one real tdata1 field needing WARL clamping on
     * write: anything but 0 clamps to 1 (prefers Debug Mode entry --
     * the common hardware-breakpoint use case a real debugger almost
     * always wants -- as the fallback for any unrecognized value). */
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            tdata1_dmode_q0 <= 1'b0; tdata1_dmode_q1 <= 1'b0;
            tdata1_hit1_q0  <= 1'b0; tdata1_hit1_q1  <= 1'b0;
            tdata1_hit0_q0  <= 1'b0; tdata1_hit0_q1  <= 1'b0;
            tdata1_action_q0 <= 4'b0; tdata1_action_q1 <= 4'b0;
            tdata1_m_q0 <= 1'b0; tdata1_m_q1 <= 1'b0;
            tdata1_s_q0 <= 1'b0; tdata1_s_q1 <= 1'b0;
            tdata1_u_q0 <= 1'b0; tdata1_u_q1 <= 1'b0;
            tdata1_execute_q0 <= 1'b0; tdata1_execute_q1 <= 1'b0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_TDATA1) && !tselect_q) begin
            tdata1_dmode_q0   <= i_csr_wdata[59];
            tdata1_hit1_q0    <= i_csr_wdata[25];
            tdata1_hit0_q0    <= i_csr_wdata[22];
            tdata1_action_q0  <= (i_csr_wdata[15:12] == 4'b0) ? 4'b0 : 4'd1;
            tdata1_m_q0       <= i_csr_wdata[6];
            tdata1_s_q0       <= i_csr_wdata[4];
            tdata1_u_q0       <= i_csr_wdata[3];
            tdata1_execute_q0 <= i_csr_wdata[2];
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_TDATA1) && tselect_q) begin
            tdata1_dmode_q1   <= i_csr_wdata[59];
            tdata1_hit1_q1    <= i_csr_wdata[25];
            tdata1_hit0_q1    <= i_csr_wdata[22];
            tdata1_action_q1  <= (i_csr_wdata[15:12] == 4'b0) ? 4'b0 : 4'd1;
            tdata1_m_q1       <= i_csr_wdata[6];
            tdata1_s_q1       <= i_csr_wdata[4];
            tdata1_u_q1       <= i_csr_wdata[3];
            tdata1_execute_q1 <= i_csr_wdata[2];
        end
    end

    /*
     * tdata1_val0/1: full 64-bit composed mcontrol6 value per slot,
     * matching o_dcsr's own "export the full composed register, let
     * the consumer pick bits" precedent. Needed unconditionally for
     * BOTH slots every cycle, independent of tselect_q -- core.sv's
     * hardware comparators watch both slots simultaneously, not just
     * whichever one the CSR read/write window currently points at.
     * Field order top-to-bottom: type[63:60], dmode[59],
     * reserved[58:27] (32b), uncertain[26], hit1[25], vs[24], vu[23],
     * hit0[22], select[21], reserved[20:19] (2b), size[18:16] (3b),
     * action[15:12] (4b), chain[11], match[10:7] (4b), m[6],
     * uncertainen[5], s[4], u[3], execute[2], store[1], load[0].
     */
    wire [(`WORD_SIZE - 1):0] tdata1_val0 = {
        4'd6, tdata1_dmode_q0, 32'b0, 1'b0, tdata1_hit1_q0, 1'b0, 1'b0, tdata1_hit0_q0,
        1'b0, 2'b0, 3'b0, tdata1_action_q0, 1'b0, 4'b0,
        tdata1_m_q0, 1'b0, tdata1_s_q0, tdata1_u_q0, tdata1_execute_q0, 1'b0, 1'b0
    };
    wire [(`WORD_SIZE - 1):0] tdata1_val1 = {
        4'd6, tdata1_dmode_q1, 32'b0, 1'b0, tdata1_hit1_q1, 1'b0, 1'b0, tdata1_hit0_q1,
        1'b0, 2'b0, 3'b0, tdata1_action_q1, 1'b0, 4'b0,
        tdata1_m_q1, 1'b0, tdata1_s_q1, tdata1_u_q1, tdata1_execute_q1, 1'b0, 1'b0
    };

    /*
     * PMP (Physical Memory Protection, Milestone 1 of the PMP+PLIC staged
     * plan). Field layout verified against riscv/riscv-isa-manual's own
     * src/priv/machine.adoc PMP chapter and its pmpcfg.edn/pmpaddr-rv64.edn
     * bytefield diagram sources (not recalled from memory, matching this
     * project's own established discipline -- see the Trigger Module's
     * own mcontrol6 spec-fidelity note above for the precedent). Only 4
     * of the 8 regions pmpcfg0 packs are implemented -- regions 4-7
     * (pmpcfg0 bytes 4-7) have no storage and no write-reacting arm,
     * always reading 0; pmpcfg2 and up, and pmpaddr4-63, are simply
     * never added to the address map at all (see the read mux's own
     * default arm).
     *
     * Storage is flat, individually-named per region (pmpNcfg_*_q,
     * pmpaddrN_q) -- the same "_q0/_q1"-style duplication the Trigger
     * Module above already established for "N parallel slots" in this
     * file, scaled to 4 rather than 2.
     *
     * Granularity G=0 (finest, 4-byte): every one of the 54 implemented
     * pmpaddr bits is a plain, unconditional, WARL-free software-
     * controlled bit regardless of the region's own A encoding -- G>=1
     * would require dynamically masking low address bits on READ
     * depending on A, which this core deliberately avoids needing.
     *
     * Reset default is PERMISSIVE, not deny-by-default, despite most
     * real silicon resetting to deny-all: the real spec requires that
     * the instant ANY PMP region is implemented at all (even sitting at
     * A=OFF), every S/U-mode access fails by default until M-mode
     * software configures at least one permitting region. This
     * project's own existing privilege-mode tests (core_priv_tb.sv,
     * core_priv_toolchain_tb.sv, core_priv_u_ecall_tb.sv,
     * core_interrupt_tb.sv's S-mode case, soc_interrupt_tb.sv/
     * firmware/interrupt_test.s) all run real M->S->U transitions and
     * then execute ordinary S/U-mode load/store/fetch code with no PMP
     * setup at all -- a deny-by-default reset would break every one of
     * them for reasons having nothing to do with PMP itself. The spec
     * leaves PMP reset state entirely platform-defined (WARL, no
     * mandated value), so a permissive reset is fully spec-legal.
     * Region 0 resets to L=0, A=NAPOT, X=W=R=1, pmpaddr0=all-1s -- the
     * standard "match everything representable" NAPOT encoding (an
     * all-1s address under A=NAPOT is the maximum-size encoding per the
     * spec's own pmpcfg-napot table). Regions 1-3 reset to A=OFF, fully
     * inert, the same plain reset-to-0 convention every other CSR in
     * this file uses.
     */
    logic pmp0cfg_l_q, pmp1cfg_l_q, pmp2cfg_l_q, pmp3cfg_l_q;
    logic [1:0] pmp0cfg_a_q, pmp1cfg_a_q, pmp2cfg_a_q, pmp3cfg_a_q;
    logic pmp0cfg_x_q, pmp1cfg_x_q, pmp2cfg_x_q, pmp3cfg_x_q;
    logic pmp0cfg_w_q, pmp1cfg_w_q, pmp2cfg_w_q, pmp3cfg_w_q;
    logic pmp0cfg_r_q, pmp1cfg_r_q, pmp2cfg_r_q, pmp3cfg_r_q;
    logic [63:0] pmpaddr0_q, pmpaddr1_q, pmpaddr2_q, pmpaddr3_q;

    // L-bit locking (norm:pmp_l_bit_write_protection): a locked region's
    // own cfg+addr are write-protected until reset. A region set to TOR
    // whose OWN L bit is set ALSO write-locks the PRECEDING region's
    // pmpaddr (its own lower bound), even though that preceding
    // region's cfg byte may itself be unlocked.
    wire pmp0_locked = pmp0cfg_l_q;
    wire pmp1_locked = pmp1cfg_l_q;
    wire pmp2_locked = pmp2cfg_l_q;
    wire pmp3_locked = pmp3cfg_l_q;
    wire pmpaddr0_locked = pmp0_locked || (pmp1cfg_l_q && (pmp1cfg_a_q == 2'b01));
    wire pmpaddr1_locked = pmp1_locked || (pmp2cfg_l_q && (pmp2cfg_a_q == 2'b01));
    wire pmpaddr2_locked = pmp2_locked || (pmp3cfg_l_q && (pmp3cfg_a_q == 2'b01));
    wire pmpaddr3_locked = pmp3_locked;   // no region 4 implemented to lock it

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            pmp0cfg_l_q <= 1'b0; pmp0cfg_a_q <= 2'b11; pmp0cfg_x_q <= 1'b1;
            pmp0cfg_w_q <= 1'b1; pmp0cfg_r_q <= 1'b1;
            pmp1cfg_l_q <= 1'b0; pmp1cfg_a_q <= 2'b00; pmp1cfg_x_q <= 1'b0;
            pmp1cfg_w_q <= 1'b0; pmp1cfg_r_q <= 1'b0;
            pmp2cfg_l_q <= 1'b0; pmp2cfg_a_q <= 2'b00; pmp2cfg_x_q <= 1'b0;
            pmp2cfg_w_q <= 1'b0; pmp2cfg_r_q <= 1'b0;
            pmp3cfg_l_q <= 1'b0; pmp3cfg_a_q <= 2'b00; pmp3cfg_x_q <= 1'b0;
            pmp3cfg_w_q <= 1'b0; pmp3cfg_r_q <= 1'b0;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_PMPCFG0)) begin
            // R=0,W=1 is a reserved combination (norm:pmp_rwx_warl) -- W
            // only takes effect if R is ALSO being set to 1 in this write.
            if (!pmp0_locked) begin
                pmp0cfg_l_q <= i_csr_wdata[7];
                pmp0cfg_a_q <= i_csr_wdata[4:3];
                pmp0cfg_x_q <= i_csr_wdata[2];
                pmp0cfg_w_q <= i_csr_wdata[1] & i_csr_wdata[0];
                pmp0cfg_r_q <= i_csr_wdata[0];
            end
            if (!pmp1_locked) begin
                pmp1cfg_l_q <= i_csr_wdata[15];
                pmp1cfg_a_q <= i_csr_wdata[12:11];
                pmp1cfg_x_q <= i_csr_wdata[10];
                pmp1cfg_w_q <= i_csr_wdata[9] & i_csr_wdata[8];
                pmp1cfg_r_q <= i_csr_wdata[8];
            end
            if (!pmp2_locked) begin
                pmp2cfg_l_q <= i_csr_wdata[23];
                pmp2cfg_a_q <= i_csr_wdata[20:19];
                pmp2cfg_x_q <= i_csr_wdata[18];
                pmp2cfg_w_q <= i_csr_wdata[17] & i_csr_wdata[16];
                pmp2cfg_r_q <= i_csr_wdata[16];
            end
            if (!pmp3_locked) begin
                pmp3cfg_l_q <= i_csr_wdata[31];
                pmp3cfg_a_q <= i_csr_wdata[28:27];
                pmp3cfg_x_q <= i_csr_wdata[26];
                pmp3cfg_w_q <= i_csr_wdata[25] & i_csr_wdata[24];
                pmp3cfg_r_q <= i_csr_wdata[24];
            end
            // bytes 4-7 (regions 4-7): no write-reacting arm at all -- always 0.
        end
    end

    always_ff @(posedge i_clk) begin
        if (i_rst) pmpaddr0_q <= 64'h003F_FFFF_FFFF_FFFF;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_PMPADDR0) && !pmpaddr0_locked)
            pmpaddr0_q <= {10'b0, i_csr_wdata[53:0]};   // top 10 bits always 0 (spec-fixed reserved field)
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) pmpaddr1_q <= 64'b0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_PMPADDR1) && !pmpaddr1_locked)
            pmpaddr1_q <= {10'b0, i_csr_wdata[53:0]};
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) pmpaddr2_q <= 64'b0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_PMPADDR2) && !pmpaddr2_locked)
            pmpaddr2_q <= {10'b0, i_csr_wdata[53:0]};
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) pmpaddr3_q <= 64'b0;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_PMPADDR3) && !pmpaddr3_locked)
            pmpaddr3_q <= {10'b0, i_csr_wdata[53:0]};
    end

    // Composed pmpcfg0 byte per region, and the full 64-bit register --
    // bytes 4-7 (regions 4-7) are hardcoded 0, never backed by storage.
    wire [7:0] pmp0cfg_val = {pmp0cfg_l_q, 2'b0, pmp0cfg_a_q, pmp0cfg_x_q, pmp0cfg_w_q, pmp0cfg_r_q};
    wire [7:0] pmp1cfg_val = {pmp1cfg_l_q, 2'b0, pmp1cfg_a_q, pmp1cfg_x_q, pmp1cfg_w_q, pmp1cfg_r_q};
    wire [7:0] pmp2cfg_val = {pmp2cfg_l_q, 2'b0, pmp2cfg_a_q, pmp2cfg_x_q, pmp2cfg_w_q, pmp2cfg_r_q};
    wire [7:0] pmp3cfg_val = {pmp3cfg_l_q, 2'b0, pmp3cfg_a_q, pmp3cfg_x_q, pmp3cfg_w_q, pmp3cfg_r_q};
    wire [(`WORD_SIZE - 1):0] pmpcfg0_val = {32'b0, pmp3cfg_val, pmp2cfg_val, pmp1cfg_val, pmp0cfg_val};

    /* mip_effective: MTIP (bit 7), SEIP (bit 9), and MEIP (bit 11) are
     * live combinational functions of i_mtip/i_seip/i_meip, not stored
     * state like every other mip bit. Every mip/sip read arm and o_mip
     * below must go through this wire -- raw mip_q must never leak into
     * a read path again. */
    wire [(`WORD_SIZE - 1):0] mip_effective =
        {mip_q[63:12], i_meip, mip_q[10], i_seip, mip_q[8], i_mtip, mip_q[6:0]};

    /* Control-plane outputs -- see the port-list comment above for why these exist. */
    assign o_mtvec       = mtvec_q;
    assign o_stvec       = stvec_q;
    assign o_mepc        = mepc_q;
    assign o_sepc        = sepc_q;
    assign o_medeleg     = medeleg_q;
    assign o_mstatus_mpp = mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB];
    assign o_mstatus_spp = mstatus_q[MSTATUS_SPP_BIT];
    assign o_mstatus_tsr = mstatus_q[MSTATUS_TSR_BIT];
    assign o_mip         = mip_effective;
    assign o_mie         = mie_q;
    assign o_mideleg     = mideleg_q;
    assign o_mstatus_mie = mstatus_q[MSTATUS_MIE_BIT];
    assign o_mstatus_sie = mstatus_q[MSTATUS_SIE_BIT];
    assign o_dcsr        = dcsr_q | DCSR_XDEBUGVER_FIXED;
    assign o_dpc         = dpc_q;
    assign o_tdata1_0    = tdata1_val0;
    assign o_tdata1_1    = tdata1_val1;
    assign o_tdata2_0    = tdata2_q0;
    assign o_tdata2_1    = tdata2_q1;
    assign o_pmpcfg0      = pmpcfg0_val;
    assign o_pmpaddr0     = pmpaddr0_q;
    assign o_pmpaddr1     = pmpaddr1_q;
    assign o_pmpaddr2     = pmpaddr2_q;
    assign o_pmpaddr3     = pmpaddr3_q;
    assign o_mstatus_mprv = mstatus_q[MSTATUS_MPRV_BIT];
`ifdef RISCV_FORMAL
    assign o_mcause      = mcause_q;
    assign o_scause      = scause_q;
`endif

    /*
     * Combinational read mux. The default arm is both "unmapped
     * address" AND the only place an unmapped address is ever
     * distinguished from a mapped one -- reading as 0 with no separate
     * validity check, matching ECALL's existing "under-implemented,
     * scope excluded" treatment elsewhere in this core.
     */
    always_comb begin: csr_read
        case (i_csr_addr)
            CSR_ADDR_MISA:      o_csr_rdata = MISA_VALUE;
            CSR_ADDR_MVENDORID: o_csr_rdata = MVENDORID_VALUE;
            CSR_ADDR_MARCHID:   o_csr_rdata = MARCHID_VALUE;
            CSR_ADDR_MIMPID:    o_csr_rdata = MIMPID_VALUE;
            CSR_ADDR_MHARTID:   o_csr_rdata = MHARTID_VALUE;
            CSR_ADDR_MSCRATCH:  o_csr_rdata = mscratch_q;
            CSR_ADDR_MCYCLE:    o_csr_rdata = mcycle_q;
            CSR_ADDR_MINSTRET:  o_csr_rdata = minstret_q;

            /* S-mode CSRs -- sstatus/sie/sip are masked VIEWS, not plain reads. */
            CSR_ADDR_SSTATUS:    o_csr_rdata = (mstatus_q & SSTATUS_VIEW_MASK) | MSTATUS_UXL_FIXED;
            CSR_ADDR_SIE:        o_csr_rdata = mie_q & mideleg_q;
            CSR_ADDR_STVEC:      o_csr_rdata = stvec_q;
            CSR_ADDR_SCOUNTEREN: o_csr_rdata = scounteren_q;
            CSR_ADDR_SSCRATCH:   o_csr_rdata = sscratch_q;
            CSR_ADDR_SEPC:       o_csr_rdata = sepc_q;
            CSR_ADDR_SCAUSE:     o_csr_rdata = scause_q;
            CSR_ADDR_STVAL:      o_csr_rdata = stval_q;
            CSR_ADDR_SIP:        o_csr_rdata = mip_effective & mideleg_q;
            CSR_ADDR_SATP:       o_csr_rdata = satp_q;

            /* M-mode trap-control CSRs. */
            CSR_ADDR_MSTATUS:    o_csr_rdata = mstatus_q | MSTATUS_UXL_FIXED | MSTATUS_SXL_FIXED;
            CSR_ADDR_MEDELEG:    o_csr_rdata = medeleg_q;
            CSR_ADDR_MIDELEG:    o_csr_rdata = mideleg_q;
            CSR_ADDR_MIE:        o_csr_rdata = mie_q;
            CSR_ADDR_MTVEC:      o_csr_rdata = mtvec_q;
            CSR_ADDR_MCOUNTEREN: o_csr_rdata = mcounteren_q;
            CSR_ADDR_MEPC:       o_csr_rdata = mepc_q;
            CSR_ADDR_MCAUSE:     o_csr_rdata = mcause_q;
            CSR_ADDR_MTVAL:      o_csr_rdata = mtval_q;
            CSR_ADDR_MIP:        o_csr_rdata = mip_effective;

            /* Debug-mode CSRs (Milestone 3). */
            CSR_ADDR_DCSR:       o_csr_rdata = dcsr_q | DCSR_XDEBUGVER_FIXED;
            CSR_ADDR_DPC:        o_csr_rdata = dpc_q;
            CSR_ADDR_DSCRATCH0:  o_csr_rdata = dscratch0_q;
            CSR_ADDR_DSCRATCH1:  o_csr_rdata = dscratch1_q;

            /* Trigger Module CSRs (Milestone 9). */
            CSR_ADDR_TSELECT: o_csr_rdata = {63'b0, tselect_q};
            CSR_ADDR_TDATA1:  o_csr_rdata = tselect_q ? tdata1_val1 : tdata1_val0;
            CSR_ADDR_TDATA2:  o_csr_rdata = tselect_q ? tdata2_q1 : tdata2_q0;
            CSR_ADDR_TDATA3:  o_csr_rdata = `WORD_SIZE'(0);
            CSR_ADDR_TINFO:   o_csr_rdata = TINFO_VALUE;

            /* PMP CSRs (Milestone 1 of the PMP+PLIC staged plan). */
            CSR_ADDR_PMPCFG0:  o_csr_rdata = pmpcfg0_val;
            CSR_ADDR_PMPADDR0: o_csr_rdata = pmpaddr0_q;
            CSR_ADDR_PMPADDR1: o_csr_rdata = pmpaddr1_q;
            CSR_ADDR_PMPADDR2: o_csr_rdata = pmpaddr2_q;
            CSR_ADDR_PMPADDR3: o_csr_rdata = pmpaddr3_q;

            default:            o_csr_rdata = `WORD_SIZE'(0);
        endcase
    end: csr_read
endmodule: csr_file


/* ------------------------------------------------------------------------- */


/* End of file. */
