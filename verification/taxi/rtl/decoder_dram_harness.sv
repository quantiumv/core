// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: decoder_dram_harness
 *
 * Shared "decoder + real slaves, no core" wiring, mirroring
 * testbench/decoder_clint_harness.sv exactly, but with all FOUR real
 * slaves this time (RAM/UART/CLINT/DRAM) -- Verilator-only, unlike that
 * file, since dram_model.sv instantiates a SystemVerilog `interface`
 * internally (drives a real taxi_axi_ram over AXI4), which iverilog
 * cannot parse at all (see verification/taxi/README.md). Living under
 * verification/taxi/ rather than testbench/ for exactly that reason --
 * never add this file to the iverilog-based design/testbench regression
 * file lists, it will not compile there.
 *
 * Re-exposes the decoder's entire CPU-facing Wishbone port as its own
 * top-level ports, one-for-one, for an external testbench to drive
 * directly via wb_cycle() -- same shape as decoder_clint_harness.sv.
 *
 * NOT a full soc.sv fidelity claim, same caveat as decoder_clint_harness.sv:
 * soc.sv routes its RAM leg through cache_complex (a 5th module), which
 * this harness omits -- sram0 hangs directly off decoder0's ram_* ports.
 * UART/CLINT/DRAM legs ARE wired exactly as soc.sv has (or, for DRAM,
 * WOULD have, if soc.sv could ever instantiate it directly -- see
 * design/soc.sv's own header comment for why it can't).
 *
 * dram0's ADDR_W(15) must exactly match wb_addr_decoder.sv's 32KB DRAM
 * window (0x0001_8000-0x0001_FFFF) -- all other dram_model parameters
 * are left at their real defaults (ACCESS_LATENCY_CYCLES=4,
 * REFRESH_INTERVAL_CYCLES=256, REFRESH_BUSY_CYCLES=16), since this
 * harness's own testbench (decoder_dram_tb.sv) is testing ROUTING
 * correctness, not timing correctness (already separately proven by
 * verification/taxi/tb/dram_model_tb.sv's own cycle-delta method).
 */
module decoder_dram_harness (
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

    logic [31:0] ram_addr, uart_addr, clint_addr, dram_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i, clint_dat_o, clint_dat_i, dram_dat_o, dram_dat_i;
    logic [7:0]  ram_sel, uart_sel, clint_sel, dram_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;
    logic        clint_we, clint_cyc, clint_stb, clint_ack, clint_err;
    logic        dram_we, dram_cyc, dram_stb, dram_ack, dram_err;

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
        .clint_stb_o(clint_stb), .clint_ack_i(clint_ack), .clint_err_i(clint_err),
        .dram_addr_o(dram_addr), .dram_dat_o(dram_dat_o), .dram_dat_i(dram_dat_i),
        .dram_sel_o(dram_sel), .dram_we_o(dram_we), .dram_cyc_o(dram_cyc),
        .dram_stb_o(dram_stb), .dram_ack_i(dram_ack), .dram_err_i(dram_err)
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

    dram_model #(.ADDR_W(15)) dram0 (
        .clk(clk), .rst(rst),
        .addr_i(dram_addr), .dat_i(dram_dat_o), .dat_o(dram_dat_i), .sel_i(dram_sel),
        .ack_o(dram_ack), .err_o(dram_err), .cyc_i(dram_cyc), .stb_i(dram_stb), .we_i(dram_we)
    );

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
