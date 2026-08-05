// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: csr_file
 *
 * Machine-mode CSR storage and read/write port for the Zicsr extension.
 * No parameters (unlike register_file.sv's num_regs -- this CSR set is
 * architecturally fixed for this milestone).
 *
 * One address port serves both read and write, since a CSR instruction's
 * read and write always target the same address -- unlike GPRs' two
 * independent read ports, there is no dual-address case here.
 *
 * Only 8 CSR addresses are backed at all (see the address map below);
 * every other address reads 0 and ignores writes (see the read mux's
 * default arm, and the read-only-enforcement note below). Of those 8:
 * misa/mvendorid/marchid/mimpid/mhartid are fixed constants with no
 * storage; mscratch is a plain read/write register; mcycle/minstret
 * are free-running/retirement counters that are read-only for this
 * milestone (deferring writability avoids designing the
 * write-vs-auto-increment interaction for no current benefit).
 *
 * Read-only enforcement is structural, not a flag check: only
 * mscratch_q's always_ff block below has a write-reacting arm at all.
 * A write aimed at any other address -- including misa (a WARL field
 * with exactly one legal value, so "writes accepted but have no
 * effect" is spec-conformant, not a shortcut) and unmapped addresses
 * -- simply has no always_ff arm to land in.
 *
 * No privilege-level enforcement (CSR address bits[9:8]) -- no
 * privilege-mode concept exists anywhere in this core yet, so every
 * access is currently permitted. That check belongs in core.sv (or a
 * future privilege unit), not here, once privilege modes exist.
 *
 * Input ports:
 *  i_clk: Clock signal (positive edge is used for all state updates).
 *  i_rst: Synchronous reset -- zeroes mscratch_q/mcycle_q/minstret_q.
 *  i_csr_addr: CSR address, shared by both the read and the write.
 *  i_csr_we: High to write i_csr_wdata into the CSR at i_csr_addr. A
 *    bare enable -- core.sv computes *why* externally (rs1==x0/uimm==0
 *    write-suppression, etc.), same division of responsibility as
 *    register_file.sv's i_load_gpr.
 *  i_csr_wdata: Data to write into the CSR at i_csr_addr, when enabled.
 *  i_instr_retired: Pulses once per retired instruction (any
 *    instruction, not just CSR ones) -- drives minstret_q. Independent
 *    of i_csr_we/i_csr_addr: a CSR instruction that doesn't otherwise
 *    write anything still retires and still increments minstret.
 *
 * Output port:
 *  o_csr_rdata: Data read from the CSR at i_csr_addr, combinationally.
 */
module csr_file (
    input  logic i_clk,
    input  logic i_rst,
    input  logic [(`CSR_ADDR_SIZE - 1):0] i_csr_addr,
    output logic [(`WORD_SIZE - 1):0]     o_csr_rdata,
    input  logic                          i_csr_we,
    input  logic [(`WORD_SIZE - 1):0]     i_csr_wdata,
    input  logic                          i_instr_retired   // drives minstret; independent of i_csr_we/addr
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
     * Real storage -- exactly 3 flip-flops, one per writable/counting
     * CSR. No [0:4095]-style address-indexed array: every other mapped
     * CSR above is a constant, and every unmapped address reads 0 via
     * the read mux's default arm below, so there is nothing else to
     * back with real state.
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
            default:            o_csr_rdata = `WORD_SIZE'(0);
        endcase
    end: csr_read
endmodule: csr_file


/* ------------------------------------------------------------------------- */


/* End of file. */
