// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: core_cache_harness
 *
 * Milestone 4 of the cache-hierarchy rollout (see the session plan): both
 * I$ and D$ live simultaneously for the first time, through the real
 * design/cache_complex.sv (not the ad hoc routing mux
 * testbench/core_icache_harness.sv used as Milestone 2's own temporary
 * scaffolding -- that mux's whole job is now cache_complex.sv's for
 * real). This harness is the direct analog of that one and of
 * core_wb4_sram_harness.sv before it: core.sv wired straight through to
 * cache_complex.sv's core-facing port (including wb_ifetch_o ->
 * ifetch_i), cache_complex.sv's single downstream port wired straight to
 * one shared wb4_sram -- exactly soc.sv's own eventual topology once the
 * final cutover milestone splices cache_complex in for real.
 *
 * Reached hierarchically exactly like the other harnesses' own
 * dut.core0/dut.sram0 -- here also dut.cache0.
 */
module core_cache_harness #(
    parameter NUM_WORDS  = 4096,
    parameter NUM_LINES  = 64,
    parameter LINE_WORDS = 4
) (
    input logic clk,
    input logic rst,
    input logic i_mtip = 1'b0
);

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;
    logic        wb_ifetch;
    logic        icache_flush;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err), .wb_ifetch_o(wb_ifetch),
        .icache_flush_o(icache_flush), .i_mtip(i_mtip)
    );

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    cache_complex #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) cache0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .we_i(wb_we), .ifetch_i(wb_ifetch), .cyc_i(wb_cyc), .stb_i(wb_stb),
        .ack_o(wb_ack), .err_o(wb_err), .flush_i(icache_flush),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(mem_dat_m2s), .dat_o(mem_dat_s2m), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

endmodule
