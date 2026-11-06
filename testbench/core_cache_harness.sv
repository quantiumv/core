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
 * cache_complex.sv's core-facing ports, cache_complex.sv's single
 * downstream port wired straight to one shared wb4_sram -- exactly
 * soc.sv's own topology.
 *
 * Pipelining P2: core.sv's fetch port wires straight to cache0.fetch_*
 * and its mem port straight to cache0.data_* (as in soc.sv) -- no
 * arbiter here, since cache_complex.sv's own downstream arbiter already
 * owns contention for the single sram0.
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

    logic [31:0] wb_fetch_addr;
    logic [63:0] wb_fetch_dat;
    logic        wb_fetch_cyc, wb_fetch_stb, wb_fetch_ack, wb_fetch_err;

    logic [31:0] wb_mem_addr;
    logic [63:0] wb_mem_dat_m2s, wb_mem_dat_s2m;
    logic [7:0]  wb_mem_sel;
    logic        wb_mem_we, wb_mem_cyc, wb_mem_stb, wb_mem_ack, wb_mem_err;
    logic        icache_flush;

    // wb_mem_lock_o left unconnected, as wb_lock_o was before: there is
    // no second master on cache0's data port for it to lock out.
    core core0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wb_fetch_addr), .wb_fetch_cyc_o(wb_fetch_cyc),
        .wb_fetch_stb_o(wb_fetch_stb), .wb_fetch_dat_i(wb_fetch_dat),
        .wb_fetch_ack_i(wb_fetch_ack), .wb_fetch_err_i(wb_fetch_err),
        .wb_mem_addr_o(wb_mem_addr), .wb_mem_dat_o(wb_mem_dat_m2s), .wb_mem_dat_i(wb_mem_dat_s2m),
        .wb_mem_sel_o(wb_mem_sel), .wb_mem_we_o(wb_mem_we), .wb_mem_cyc_o(wb_mem_cyc),
        .wb_mem_stb_o(wb_mem_stb), .wb_mem_ack_i(wb_mem_ack), .wb_mem_err_i(wb_mem_err),
        .icache_flush_o(icache_flush), .i_mtip(i_mtip)
    );

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    cache_complex #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) cache0 (
        .clk(clk), .rst(rst),
        .fetch_addr_i(wb_fetch_addr), .fetch_cyc_i(wb_fetch_cyc), .fetch_stb_i(wb_fetch_stb),
        .fetch_dat_o(wb_fetch_dat), .fetch_ack_o(wb_fetch_ack), .fetch_err_o(wb_fetch_err),
        .data_addr_i(wb_mem_addr), .data_dat_i(wb_mem_dat_m2s), .data_dat_o(wb_mem_dat_s2m),
        .data_sel_i(wb_mem_sel), .data_we_i(wb_mem_we), .data_cyc_i(wb_mem_cyc), .data_stb_i(wb_mem_stb),
        .data_ack_o(wb_mem_ack), .data_err_o(wb_mem_err), .flush_i(icache_flush),
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
