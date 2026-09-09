// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: clint
 *
 * A real, addressable Wishbone-slave peripheral, now a real (if
 * single-hart) SiFive-CLINT-compatible timer+software-interrupt block --
 * CLINT/UART standards-compliance plan Milestone 1. Widened from the
 * original mtime/mtimecmp-only, 32KB-windowed layout (see git history)
 * to the real spec offsets below, with a new msip register, so an
 * unmodified OpenSBI `platform/generic`/Linux CLINT driver can address
 * this block without any bespoke platform port.
 *
 * Registered, 1-wait-state ack, matching design/uart_tx.sv's/
 * design/plic.sv's own house style exactly -- see clint.sv's own git
 * history for the fuller rationale (bus uniformity: the CPU's wait state
 * doesn't need to know or care which slave it's talking to).
 *
 * Register map -- real per-hart CLINT offsets (this is a single-hart
 * model, so only hart 0's own offsets exist; a real multi-hart CLINT
 * would repeat msip/mtimecmp per hart, mtime shared). Only addr_i[15:0]
 * is decoded -- everything routed here by wb_addr_decoder.sv already has
 * the right upper address bits set (addr_i[26]=1, addr_i[22]=0,
 * addr_i[16]=1), matching this file's own prior convention of trusting
 * upstream routing rather than re-checking it:
 *   CLINT_BASE+0x0000  msip      read/write. Real spec field is bit 0
 *                             only (a software-triggered inter-hart
 *                             interrupt request) -- plain RW storage,
 *                             drives nothing further. No real IPI exists
 *                             or is needed with exactly one hart
 *                             (correctly out of scope until SMP is a
 *                             milestone, matching this project's own
 *                             established precedent for single-hart
 *                             gaps elsewhere); this is NOT W1C (some
 *                             non-RISC-V CLINT-alike IP treats msip as
 *                             write-1-to-clear -- confirmed against
 *                             primary references that the real RISC-V
 *                             CLINT's msip is plain RW, so a software
 *                             write of 0 genuinely clears it here, no
 *                             special-casing needed).
 *   CLINT_BASE+0x4000  mtimecmp  read/write, compared against mtime_q to
 *                             drive mtip_o. Unchanged semantics from
 *                             this file's prior revision, relocated.
 *   CLINT_BASE+0xBFF8  mtime     read-only, free-running 64-bit counter.
 *                             Unchanged semantics, relocated.
 * Every other address in the 64KB window this file's own addr_i[15:0]
 * range spans reads 0 and ignores writes -- a real, harmless reserved-
 * space convention (not an aliasing shortcut the way the narrower
 * pre-widening window used, since three non-power-of-two-related offsets
 * can no longer be told apart by a single address bit the way the old
 * two-register mtime/mtimecmp pair could).
 *
 * Single 64-bit bus means one LD reads any one of the three registers
 * atomically -- no hi/lo split-register dance real 32-bit CLINT software
 * needs for mtime/mtimecmp; msip's own real field (bit 0) trivially fits
 * in a single 64-bit access too.
 */
module clint (
    input logic clk,
    input logic rst,

    /*
     * Only addr_i[15:0] (register select within the 64KB window) is
     * used -- addr_i's other bits are genuinely don't-care here, same
     * pattern already used by uart_tx.sv/plic.sv for the same reason.
     * dat_i and sel_i, unlike addr_i, are NOT wrapped the same way:
     * every one of their bits IS genuinely read (dat_i via the byte-lane
     * for-loop below for mtimecmp and via dat_i[0] for msip, sel_i via
     * sel_i[lane] gating each byte) -- wrapping them too would be a
     * stale pragma making a false claim, not just a harmless no-op one.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic         we_i,
    input  logic         cyc_i,
    input  logic         stb_i,
    output logic         ack_o,
    output logic         err_o,

    output logic mtip_o
);
    localparam logic [15:0] MSIP_OFF     = 16'h0000;
    localparam logic [15:0] MTIMECMP_OFF = 16'h4000;
    localparam logic [15:0] MTIME_OFF    = 16'hBFF8;

    wire sel_msip     = (addr_i[15:0] == MSIP_OFF);
    wire sel_mtimecmp = (addr_i[15:0] == MTIMECMP_OFF);
    wire sel_mtime    = (addr_i[15:0] == MTIME_OFF);

    logic [63:0] mtime_q;
    logic [63:0] mtimecmp_q;
    logic        msip_q;

    always_ff @(posedge clk) begin
        if (rst) mtime_q <= 64'b0;
        else     mtime_q <= mtime_q + 64'b1;   // free-running, same precedent as csr_file.sv's mcycle_q
    end

    /*
     * mtimecmp resets to all-ones, NOT zero -- resetting to 0 would make
     * mip.MTIP read pending immediately at power-on before software ever
     * programs a real deadline. Harmless for an actual taken interrupt
     * since mie.MTIE also resets to 0, but surprising for anything that
     * inspects mip before arming the timer. mtime itself is read-only
     * (no write path) -- matches csr_file.sv's mcycle/minstret precedent
     * (deferring writability, no current need).
     */
    always_ff @(posedge clk) begin
        if (rst)
            mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;
        else if (cyc_i && stb_i && we_i && sel_mtimecmp)
            for (int lane = 0; lane < 8; lane++)
                if (sel_i[lane]) mtimecmp_q[(8*lane)+:8] <= dat_i[(8*lane)+:8];
    end

    /*
     * msip: plain RW storage, real field is bit 0 only -- gated on
     * sel_i[0] (the byte lane bit 0 lives in), same byte-enable
     * discipline as mtimecmp's own per-lane write above, just for a
     * single real bit rather than a full 64-bit value. Not W1C -- see
     * this file's own header for why that's the confirmed-correct real
     * spec behavior, not an oversight.
     */
    always_ff @(posedge clk) begin
        if (rst)
            msip_q <= 1'b0;
        else if (cyc_i && stb_i && we_i && sel_msip && sel_i[0])
            msip_q <= dat_i[0];
    end

    assign mtip_o = (mtime_q >= mtimecmp_q);

    always @(posedge clk) begin
        if (rst) begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 64'b0;
        end else if (cyc_i && stb_i) begin
            dat_o <= sel_mtimecmp ? mtimecmp_q
                   : sel_mtime    ? mtime_q
                   : sel_msip     ? {63'b0, msip_q}
                   : 64'b0;
            ack_o <= 1'b1;
            err_o <= 1'b0;
        end else begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
        end
    end
    /*
     * err_o is intentionally never asserted -- no error conditions are
     * defined for this minimal peripheral, same reasoning as
     * uart_tx.sv's own "err_o is intentionally never asserted" comment:
     * wb_addr_decoder.sv is the only thing that ever routes a request
     * here.
     */

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
