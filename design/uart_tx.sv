// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: uart_tx
 *
 * A real, addressable Wishbone-slave peripheral, not a testbench-only
 * shortcut -- deliberately minimal for this milestone (transmit only, no
 * baud-rate timing) but structured as something later work can grow real
 * serial timing into, rather than something to throw away.
 *
 * Internally this "transmits" via $write immediately on a register write
 * -- there is no bit-banged serial output and no baud-rate model at all.
 * That's a deliberate simplification, not an oversight: the goal for
 * this milestone is a real program printing real characters in an
 * iverilog run, not hardware-accurate timing.
 *
 * Same registered, 1-wait-state ack timing as wb4_sram.sv, purely for
 * bus uniformity -- the CPU's wait state doesn't need to know or care
 * which slave it's talking to. A combinational/zero-wait UART would also
 * be legal Wishbone and work correctly with core.sv's FSM (which just
 * watches ack_i each edge regardless of latency), but mixed timing
 * across slaves on one bus is more surface area to get wrong for no
 * benefit here.
 *
 * Register map (only addr_i[3] is decoded -- everything routed here by
 * wb_addr_decoder.sv already has addr_i[15] set, nothing else needs
 * checking):
 *   0x8000  TX_DATA    write: low byte is "printed" immediately.
 *                      read: always 0.
 *   0x8008  TX_STATUS  read-only. bit 0 = TX_READY, hardwired 1 -- this
 *                      model has no timing, so it's trivially always
 *                      ready. Exists so firmware can use a realistic
 *                      poll-then-write pattern even though polling
 *                      never actually has to wait yet.
 */
module uart_tx (
    input logic clk,
    input logic rst,

    /*
     * Only addr_i[3] (register select), dat_i[7:0] (the byte to print),
     * and sel_i[0] (byte-enable for that same byte) are used -- this is
     * a byte-wide peripheral behind a 64-bit bus, so the rest of these
     * ports' bits are genuinely don't-care by design, same pattern
     * already used for wb4_sram.sv's/dmem.sv's address ports.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    input  logic [7:0]  sel_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] dat_o,

    output logic ack_o,
    output logic err_o,
    input  logic cyc_i,
    input  logic stb_i,
    input  logic we_i
);
    localparam TX_DATA_SEL   = 1'b0;
    localparam TX_STATUS_SEL = 1'b1;

    /*
     * Simulation-only capture of every transmitted character, for
     * testbench-side checking via a hierarchical reference (e.g.
     * dut.uart0.tx_history) -- same spirit as the single-cycle
     * milestone's core_*_tb.sv tests reading dut.regfile0.gp_registers
     * directly. A fixed array + count, not a queue/string, to stay on
     * constructs already proven to compile cleanly in this codebase's
     * iverilog flow rather than reach for new ones.
     */
    localparam TX_HISTORY_DEPTH = 256;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] tx_history [0:(TX_HISTORY_DEPTH - 1)];
    /* verilator lint_on UNUSEDSIGNAL */
    /*
     * One bit wider than strictly needed to INDEX the array (8 bits
     * covers indices 0-255) so this can also represent the value 256
     * itself -- i.e. "the buffer is now full" -- without wrapping back
     * to 0. The tx_history_count < TX_HISTORY_DEPTH guard below means
     * the array is only ever actually indexed with values 0-255, so the
     * 9th bit is dropped explicitly (tx_history_count[7:0]) at the one
     * place that indexes the array, rather than left as an implicit
     * (and lint-flagged) truncation.
     */
    logic [$clog2(TX_HISTORY_DEPTH):0] tx_history_count;

    always @(posedge clk) begin
        if (rst) begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 64'b0;
            tx_history_count <= '0;
        end else if (cyc_i && stb_i) begin
            if (we_i && (addr_i[3] == TX_DATA_SEL) && sel_i[0]) begin
                $write("%c", dat_i[7:0]);
                $fflush;
                if (tx_history_count < TX_HISTORY_DEPTH) begin
                    tx_history[tx_history_count[7:0]] <= dat_i[7:0];
                    tx_history_count <= tx_history_count + 1'b1;
                end
            end
            dat_o <= (addr_i[3] == TX_STATUS_SEL) ? 64'h1 : 64'h0;
            ack_o <= 1'b1;
            err_o <= 1'b0;
        end else begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
        end
    end
    /*
     * err_o is intentionally never asserted -- no error conditions are
     * defined for this minimal peripheral (e.g. no address-range check
     * the way wb4_sram.sv has one, since wb_addr_decoder.sv is the only
     * thing that ever routes a request here and it already only does so
     * for addresses with bit 15 set).
     */

endmodule
