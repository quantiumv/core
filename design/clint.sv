// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: clint
 *
 * A real, addressable Wishbone-slave peripheral, timer-only CLINT
 * (mtime/mtimecmp) -- deliberately minimal for this milestone: no msip
 * (single-hart, no IPI use case yet, correctly out of scope until SMP is
 * a milestone).
 *
 * Registered, 1-wait-state ack, matching design/uart_tx.sv's own house
 * style exactly -- see that file for the fuller rationale (bus
 * uniformity: the CPU's wait state doesn't need to know or care which
 * slave it's talking to).
 *
 * Register map (only addr_i[3] is decoded -- everything routed here by
 * wb_addr_decoder.sv already has the right upper address bits set,
 * matching uart_tx.sv's own convention):
 *   CLINT_BASE+0x0  mtime     read-only, free-running 64-bit counter.
 *   CLINT_BASE+0x8  mtimecmp  read/write, compared against mtime_q to
 *                             drive mtip_o.
 *
 * Single 64-bit bus means one LD reads either register atomically -- no
 * hi/lo split-register dance real 32-bit CLINT software needs.
 */
module clint (
    input logic clk,
    input logic rst,

    /*
     * Only addr_i[3] (register select) is used -- addr_i's other 31 bits
     * are genuinely don't-care here, same pattern already used by
     * uart_tx.sv for the same reason. dat_i and sel_i, unlike addr_i,
     * are NOT wrapped the same way: every one of their bits IS
     * genuinely read (dat_i via the byte-lane for-loop below, sel_i via
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
    /*
     * MTIME_SEL is documentation for the register map (and the natural
     * counterpart to MTIMECMP_SEL below), but every actual addr_i[3]
     * test in this module -- write-decode and the read-mux alike -- is
     * phrased as "== MTIMECMP_SEL" with mtime as the implicit else
     * branch, so only one localparam is ever read by RTL. Both
     * decode points testing the SAME select value (rather than one
     * testing MTIME_SEL and the other MTIMECMP_SEL) is what keeps them
     * consistent with each other; MTIME_SEL itself stays unreferenced
     * as a result.
     */
    /* verilator lint_off UNUSEDPARAM */
    localparam MTIME_SEL    = 1'b0;  // addr_i[3]==0 -> mtime    (CLINT_BASE+0x0)
    /* verilator lint_on UNUSEDPARAM */
    localparam MTIMECMP_SEL = 1'b1;  // addr_i[3]==1 -> mtimecmp (CLINT_BASE+0x8)

    logic [63:0] mtime_q;
    logic [63:0] mtimecmp_q;

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
        else if (cyc_i && stb_i && we_i && (addr_i[3] == MTIMECMP_SEL))
            for (int lane = 0; lane < 8; lane++)
                if (sel_i[lane]) mtimecmp_q[(8*lane)+:8] <= dat_i[(8*lane)+:8];
    end

    assign mtip_o = (mtime_q >= mtimecmp_q);

    always @(posedge clk) begin
        if (rst) begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 64'b0;
        end else if (cyc_i && stb_i) begin
            dat_o <= (addr_i[3] == MTIMECMP_SEL) ? mtimecmp_q : mtime_q;
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
