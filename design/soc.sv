// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: soc
 *
 * Top-level integration: core (Wishbone master) <-> wb_addr_decoder <->
 * {wb4_sram, uart_tx}. Exactly the wiring already proven in
 * testbench/core_wb_tb.sv, promoted to a real module now that all four
 * pieces are independently verified -- this file adds no new logic of
 * its own, only the connections between them.
 *
 * wb4_sram is instantiated at its default num_words (4096, 32KB) --
 * unlike core_wb_tb.sv's deliberately small test instance, this is the
 * real memory map wb_addr_decoder.sv's address split (addr_i[15]) is
 * derived from; see that module's own header comment for why the two
 * aren't independent.
 *
 * No UART pin exists at this level (or anywhere in this design) -- see
 * uart_tx.sv's header for why: this milestone's UART "transmits" via
 * $write in simulation, not real serial timing, so there is nothing for
 * a top-level pin to carry. clk/rst are this module's only ports.
 */
module soc (
    input logic clk,
    input logic rst
);

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    logic [31:0] ram_addr, uart_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i;
    logic [7:0]  ram_sel, uart_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;

    wb_addr_decoder decoder0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .we_i(wb_we), .cyc_i(wb_cyc), .stb_i(wb_stb), .ack_o(wb_ack), .err_o(wb_err),
        .ram_addr_o(ram_addr), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel), .ram_we_o(ram_we), .ram_cyc_o(ram_cyc),
        .ram_stb_o(ram_stb), .ram_ack_i(ram_ack), .ram_err_i(ram_err),
        .uart_addr_o(uart_addr), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel), .uart_we_o(uart_we), .uart_cyc_o(uart_cyc),
        .uart_stb_o(uart_stb), .uart_ack_i(uart_ack), .uart_err_i(uart_err)
    );

    wb4_sram sram0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .ack_o(ram_ack), .err_o(ram_err), .cyc_i(ram_cyc), .stb_i(ram_stb), .we_i(ram_we)
    );

    uart_tx uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_dat_i), .sel_i(uart_sel),
        .ack_o(uart_ack), .err_o(uart_err), .cyc_i(uart_cyc), .stb_i(uart_stb), .we_i(uart_we)
    );

endmodule
