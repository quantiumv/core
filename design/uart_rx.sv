// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: uart_rx
 *
 * A real, addressable Wishbone-slave peripheral -- the receive-side
 * sibling of uart_tx.sv, matching its house style exactly (no baud-rate
 * timing, registered 1-wait-state ack, err_o never asserted). Real
 * serial-line timing is out of scope for this milestone, same as it was
 * for uart_tx.sv -- a byte "arrives" the instant a testbench calls the
 * push_byte backdoor task below, the mirror image of uart_tx.sv's own
 * tx_history capture (that one records what firmware SENT; this one
 * lets a testbench inject what firmware RECEIVES).
 *
 * Lives in soc.sv as a sibling instance to uart0 (uart_tx), sharing the
 * same decoder-facing uart_* port group -- soc.sv itself is responsible
 * for splitting that one Wishbone target between the two instances via
 * a new addr_i[4] sub-decode (0 routes to TX, 1 routes to RX), gating
 * each instance's own cyc_i/stb_i accordingly. From this module's own
 * perspective, addr_i[4] is irrelevant/already decided -- only addr_i[3]
 * is decoded here, exactly matching uart_tx.sv's own "wb_addr_decoder.sv
 * already checked addr_i[15], nothing else needs checking" precedent,
 * generalized one level: soc.sv has already checked addr_i[4] too by the
 * time cyc_i/stb_i ever reach this instance.
 *
 * Register map (within the RX half of the shared UART window):
 *   0x8010  RX_DATA    read: pops the oldest queued byte (zero-extended)
 *                      and advances the queue, but ONLY when sel_i[0]
 *                      is asserted (matching uart_tx.sv's own sel_i[0]
 *                      write gate) -- a probe read that doesn't include
 *                      byte lane 0 (e.g. a sub-word load at a nonzero
 *                      offset within this register's own 8-byte-aligned
 *                      bus window) leaves the queue untouched instead of
 *                      silently discarding a real received byte.
 *                      Reading an empty queue returns 0 without
 *                      underflowing. write: ignored.
 *   0x8018  RX_STATUS  read-only. bit 0 = RX_DATA_READY (1 when the
 *                      queue is non-empty). write: ignored.
 */
module uart_rx (
    input logic clk,
    input logic rst,

    /*
     * Only addr_i[3] (register select) and sel_i[0] (gates the
     * destructive RX_DATA pop below, mirroring uart_tx.sv's own
     * sel_i[0] write gate) are used -- addr_i[4] has already been
     * decided by soc.sv before cyc_i/stb_i ever reach this instance
     * (see header). dat_i is entirely unused: this peripheral never
     * accepts a real write (RX_DATA/RX_STATUS are both read-only from
     * firmware's perspective).
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
    localparam RX_DATA_SEL   = 1'b0;
    localparam RX_STATUS_SEL = 1'b1;

    /*
     * Simulation-only inbound-byte queue, populated via the push_byte
     * backdoor task below and drained by real RX_DATA bus reads -- the
     * mirror image of uart_tx.sv's own tx_history: a fixed array, not a
     * queue/string, to stay on constructs already proven to compile
     * cleanly in this codebase's iverilog flow. Unlike tx_history
     * (append-only, never popped), this genuinely needs FIFO pop
     * semantics, so it carries real head/tail pointers rather than a
     * single running count.
     */
    localparam RX_QUEUE_DEPTH = 256;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] rx_queue [0:(RX_QUEUE_DEPTH - 1)];
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0] rx_head;                       // next index to pop (bus read)
    logic [7:0] rx_tail;                       // next index to push (push_byte)
    /*
     * One bit wider than strictly needed to COUNT (8 bits covers 0-255)
     * so this can also represent the value 256 itself -- "the queue is
     * full" -- without wrapping back to 0. Same convention as
     * uart_tx.sv's own tx_history_count.
     */
    logic [$clog2(RX_QUEUE_DEPTH):0] rx_count;

    /*
     * push_byte: simulation-only backdoor a testbench calls to enqueue a
     * byte as if it had just arrived over the wire. Uses blocking
     * assignment deliberately -- this task runs in the caller's own
     * process (a testbench initial block), not this module's clocked
     * process, so there is no clock edge for a nonblocking assignment to
     * defer to. Call it from a quiet point in the clock (e.g. right as
     * rst drops, before the DUT's first real bus transaction, or off
     * @(negedge clk) like wb_driver.sv's own wb_cycle() does) to avoid
     * racing the read/pop side below, which runs on posedge clk.
     */
    task push_byte(input logic [7:0] b);
        if (rx_count < RX_QUEUE_DEPTH) begin
            rx_queue[rx_tail] = b;
            rx_tail = rx_tail + 8'b1;
            rx_count = rx_count + 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            ack_o    <= 1'b0;
            err_o    <= 1'b0;
            dat_o    <= 64'b0;
            rx_head  <= 8'b0;
            rx_tail  <= 8'b0;
            rx_count <= '0;
        end else if (cyc_i && stb_i) begin
            if (!we_i && (addr_i[3] == RX_DATA_SEL) && sel_i[0] && (rx_count > 0)) begin
                rx_head  <= rx_head + 8'b1;
                rx_count <= rx_count - 1'b1;
            end
            dat_o <= (addr_i[3] == RX_STATUS_SEL) ? {63'b0, (rx_count > 0)}
                   : (rx_count > 0)                ? {56'b0, rx_queue[rx_head]}
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
     * uart_tx.sv's own identical comment: soc.sv's own addr_i[4]
     * sub-decode already guarantees cyc_i/stb_i only ever reach this
     * instance for a genuinely RX-addressed request.
     */

endmodule
