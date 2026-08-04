// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: wb_addr_decoder
 *
 * Routes the CPU's single Wishbone master port to one of two slaves --
 * design/wb4_sram.sv (RAM) or design/uart_tx.sv (UART) -- based on
 * address. One master, two fixed slaves: hand-written rather than a
 * general N-slave interconnect, since that generality isn't needed here.
 *
 * Address map: RAM occupies 0x0000_0000-0x0000_7FFF (wb4_sram.sv's
 * default num_words=4096 x 8 bytes/word = 32KB), UART is anything with
 * bit 15 set (0x8000 upward). Since RAM's size is a power of two
 * starting at address 0, "address >= 0x8000" and "bit 15 set" are the
 * same condition -- this is a single bit test, not a shortcut that skips
 * a real range compare. NB: this bit position is DERIVED from wb4_sram's
 * num_words parameter, not independent of it -- if that default ever
 * changes, this decode bit needs revisiting too.
 *
 * The "remember which slave" problem: both slaves are registered
 * (1-wait-state) Wishbone slaves, so a response arrives one cycle after
 * the request that triggered it -- by the time ack_i/dat_i actually need
 * routing back to the CPU, addr_i may already reflect a *different*,
 * newer request (or none). So which slave an outstanding transaction
 * belongs to is latched at the moment the request is issued
 * (sel_uart_q), not re-derived from addr_i when the response shows up.
 */
module wb_addr_decoder (
    input logic clk,
    input logic rst,

    // CPU-facing port -- this module is a slave from the CPU's side.
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    // RAM-facing port -- this module is the master here.
    output logic [31:0] ram_addr_o,
    output logic [63:0] ram_dat_o,
    input  logic [63:0] ram_dat_i,
    output logic [7:0]  ram_sel_o,
    output logic        ram_we_o,
    output logic        ram_cyc_o,
    output logic        ram_stb_o,
    input  logic        ram_ack_i,
    input  logic        ram_err_i,

    // UART-facing port.
    output logic [31:0] uart_addr_o,
    output logic [63:0] uart_dat_o,
    input  logic [63:0] uart_dat_i,
    output logic [7:0]  uart_sel_o,
    output logic        uart_we_o,
    output logic        uart_cyc_o,
    output logic        uart_stb_o,
    input  logic        uart_ack_i,
    input  logic        uart_err_i
);
    wire sel_uart = addr_i[15];

    /*
     * Gate cyc/stb per slave; broadcast everything else (addr/dat/sel/we)
     * to both -- harmless, since a slave with cyc=0 ignores the rest of
     * the bus regardless of what's sitting on it.
     */
    assign ram_cyc_o  = cyc_i && !sel_uart;
    assign ram_stb_o  = stb_i && !sel_uart;
    assign uart_cyc_o = cyc_i && sel_uart;
    assign uart_stb_o = stb_i && sel_uart;

    assign ram_addr_o  = addr_i;
    assign uart_addr_o = addr_i;
    assign ram_dat_o   = dat_i;
    assign uart_dat_o  = dat_i;
    assign ram_sel_o   = sel_i;
    assign uart_sel_o  = sel_i;
    assign ram_we_o    = we_i;
    assign uart_we_o   = we_i;

    /*
     * Latched at the cycle a request is actually issued (cyc_i && stb_i),
     * held until the next request overwrites it -- see the module header
     * for why this can't just re-check addr_i when the response arrives.
     */
    logic sel_uart_q;
    always_ff @(posedge clk) begin
        if (rst)
            sel_uart_q <= 1'b0;
        else if (cyc_i && stb_i)
            sel_uart_q <= sel_uart;
    end

    assign ack_o = sel_uart_q ? uart_ack_i : ram_ack_i;
    assign err_o = sel_uart_q ? uart_err_i : ram_err_i;
    assign dat_o = sel_uart_q ? uart_dat_i : ram_dat_i;
endmodule
