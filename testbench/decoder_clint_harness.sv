// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: decoder_clint_harness
 *
 * Shared "decoder + real slaves, no core" wiring: a real wb_addr_decoder
 * fanned out to real wb4_sram (RAM), uart_tx (UART), and clint (CLINT)
 * instances. Deliberate omission, not an oversight: this harness is for
 * a bus-level test that drives raw Wishbone cycles directly at the
 * decoder's own CPU-facing port (via testbench/wb_driver.sv's wb_cycle()
 * task, the same way design/wb4_sram_tb.sv and design/wb_addr_decoder_tb.sv
 * already do), not a firmware/instruction-level test that assembles and
 * runs real RISC-V instructions through core.sv.
 *
 * NOT a full soc.sv fidelity claim: soc.sv actually routes its RAM leg
 * through cache_complex between the decoder and wb4_sram (a 5th module),
 * which this harness omits entirely -- sram0 below hangs directly off
 * decoder0's ram_* ports. The UART and CLINT legs ARE wired exactly as
 * soc.sv has them (both sit downstream of the decoder with no cache in
 * between, same as here). So this harness's RAM-window tests only prove
 * decoder<->SRAM routing, not the real decoder<->cache<->SRAM path --
 * that combination is only exercised by testbench/core_cache_harness.sv.
 *
 * Unlike testbench/core_wb4_sram_harness.sv (which only exposes clk/rst,
 * since core0 drives the internal Wishbone bus itself), this harness has
 * no bus master of its own -- so it re-exposes the decoder's entire
 * CPU-facing Wishbone port as its own top-level ports, one-for-one, for
 * an external testbench to drive directly.
 *
 * wb4_sram is instantiated at its default num_words (4096, 32KB), the
 * same real memory-map size soc.sv uses -- see wb_addr_decoder.sv's own
 * header comment for why the RAM/UART address split is derived from
 * that size.
 */
module decoder_clint_harness (
    input logic clk,
    input logic rst,

    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o
);

    logic [31:0] ram_addr, uart_addr, clint_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i, clint_dat_o, clint_dat_i;
    logic [7:0]  ram_sel, uart_sel, clint_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;
    logic        clint_we, clint_cyc, clint_stb, clint_ack, clint_err;

    wb_addr_decoder decoder0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel_i),
        .we_i(we_i), .cyc_i(cyc_i), .stb_i(stb_i), .ack_o(ack_o), .err_o(err_o),
        .ram_addr_o(ram_addr), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel), .ram_we_o(ram_we), .ram_cyc_o(ram_cyc),
        .ram_stb_o(ram_stb), .ram_ack_i(ram_ack), .ram_err_i(ram_err),
        .uart_addr_o(uart_addr), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel), .uart_we_o(uart_we), .uart_cyc_o(uart_cyc),
        .uart_stb_o(uart_stb), .uart_ack_i(uart_ack), .uart_err_i(uart_err),
        .clint_addr_o(clint_addr), .clint_dat_o(clint_dat_o), .clint_dat_i(clint_dat_i),
        .clint_sel_o(clint_sel), .clint_we_o(clint_we), .clint_cyc_o(clint_cyc),
        .clint_stb_o(clint_stb), .clint_ack_i(clint_ack), .clint_err_i(clint_err)
    );

    wb4_sram #(.num_words(4096)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .ack_o(ram_ack), .err_o(ram_err), .cyc_i(ram_cyc), .stb_i(ram_stb), .we_i(ram_we)
    );

    uart_tx uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_dat_i), .sel_i(uart_sel),
        .ack_o(uart_ack), .err_o(uart_err), .cyc_i(uart_cyc), .stb_i(uart_stb), .we_i(uart_we)
    );

    clint clint0 (
        .clk(clk), .rst(rst),
        .addr_i(clint_addr), .dat_i(clint_dat_o), .dat_o(clint_dat_i), .sel_i(clint_sel),
        .ack_o(clint_ack), .err_o(clint_err), .cyc_i(clint_cyc), .stb_i(clint_stb), .we_i(clint_we),
        .mtip_o()
    );

endmodule
