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

    input  logic                          i_trap_taken,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_cause,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_val,
    input  logic [(`WORD_SIZE - 1):0]     i_trap_pc,
    input  logic                          i_trap_to_s,
    input  logic                          i_mret_taken,
    input  logic                          i_sret_taken,

    output logic [(`WORD_SIZE - 1):0]     o_mtvec,
    output logic [(`WORD_SIZE - 1):0]     o_stvec,
    output logic [(`WORD_SIZE - 1):0]     o_mepc,
    output logic [(`WORD_SIZE - 1):0]     o_sepc,
    output logic [(`WORD_SIZE - 1):0]     o_medeleg,
    output logic [1:0]                    o_mstatus_mpp,
    output logic                          o_mstatus_spp,
    output logic                          o_mstatus_tsr
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
            mip_q <= i_csr_wdata;
        end else if (i_csr_we && (i_csr_addr == CSR_ADDR_SIP)) begin
            mip_q <= (mip_q & ~mideleg_q) | (i_csr_wdata & mideleg_q);
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

    always_ff @(posedge i_clk) begin
        if (i_rst) mepc_q <= '0;
        else if (i_trap_taken && !i_trap_to_s) mepc_q <= i_trap_pc;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_MEPC)) mepc_q <= i_csr_wdata;
    end
    always_ff @(posedge i_clk) begin
        if (i_rst) sepc_q <= '0;
        else if (i_trap_taken && i_trap_to_s) sepc_q <= i_trap_pc;
        else if (i_csr_we && (i_csr_addr == CSR_ADDR_SEPC)) sepc_q <= i_csr_wdata;
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

    /* Control-plane outputs -- see the port-list comment above for why these exist. */
    assign o_mtvec       = mtvec_q;
    assign o_stvec       = stvec_q;
    assign o_mepc        = mepc_q;
    assign o_sepc        = sepc_q;
    assign o_medeleg     = medeleg_q;
    assign o_mstatus_mpp = mstatus_q[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB];
    assign o_mstatus_spp = mstatus_q[MSTATUS_SPP_BIT];
    assign o_mstatus_tsr = mstatus_q[MSTATUS_TSR_BIT];

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
            CSR_ADDR_SIP:        o_csr_rdata = mip_q & mideleg_q;
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
            CSR_ADDR_MIP:        o_csr_rdata = mip_q;

            default:            o_csr_rdata = `WORD_SIZE'(0);
        endcase
    end: csr_read
endmodule: csr_file


/* ------------------------------------------------------------------------- */


/* End of file. */
