// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: core_wb4_sram_harness
 *
 * Shared "core + wb4_sram only" wiring, factored out of the 2-module
 * subset of design/soc.sv's topology that a plain unit/instruction-level
 * testbench needs -- no wb_addr_decoder, no uart_tx, because a test that
 * only pokes/reads a single flat memory has no use for either. Reached
 * hierarchically exactly like soc_tb.sv already reaches dut.core0/
 * dut.uart0 -- here it's dut.core0/dut.sram0.
 *
 * NUM_WORDS defaults to 4096 (soc.sv's real memory-map size) but is
 * expected to be overridden down for small synthetic programs, matching
 * the range of ad hoc sizes (64, 256, ...) the testbenches this harness
 * replaces already hand-picked at their own call sites.
 *
 * Use design/soc.sv instead whenever a test actually needs UART output
 * or address-decoder routing -- this harness deliberately omits both.
 */
module core_wb4_sram_harness #(
    parameter NUM_WORDS = 4096
) (
    input logic clk,
    input logic rst,
    input logic i_mtip = 1'b0
);

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err), .i_mtip(i_mtip)
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

endmodule
