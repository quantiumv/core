// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: core_icache_harness
 *
 * Milestone 2 of the cache-hierarchy rollout (see the session plan for
 * the full staging): core.sv's fetch traffic routed through icache.sv;
 * load/store/AMO traffic still goes straight to wb4_sram, unmodified --
 * D$ doesn't exist yet. Both streams share ONE backing wb4_sram, matching
 * the real eventual soc.sv topology (a single memory, not two separate
 * ones) -- proving I$ composes correctly with ordinary data traffic
 * hitting the exact same SRAM, not just in isolation.
 *
 * The small routing below is temporary, harness-local scaffolding --
 * design/cache_complex.sv (a later milestone) formalizes this routing for
 * real inside soc.sv itself. UNUSED today: no regression test instantiates
 * this harness; it is kept compiling only as historical scaffolding.
 *
 * Since core.sv's fetch/mem port split, icache0 sits directly on core0's
 * fetch port, and fetch_mem_arb0 (design/wb_arbiter2.sv) merges icache0's
 * refill traffic (m0) with core0's mem port (m1, locked across an AMO)
 * onto the one shared sram0 -- replacing the old wb_ifetch-keyed mux.
 *
 * Reached hierarchically exactly like core_wb4_sram_harness.sv's own
 * dut.core0/dut.sram0 -- here also dut.icache0.
 */
module core_icache_harness #(
    parameter NUM_WORDS  = 4096,
    parameter NUM_LINES  = 64,
    parameter LINE_WORDS = 4
) (
    input logic clk,
    input logic rst
);

    // core.sv's fetch-side (read-only) master port -- straight to icache0.
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;

    // core.sv's mem-side master port -- into fetch_mem_arb0's m1.
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err, wbm_lock;
    logic        icache_flush;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock),
        .icache_flush_o(icache_flush)
    );

    // icache's memory-facing (refill) port.
    logic [31:0] ic_mem_addr;
    logic [63:0] ic_mem_dat_i;
    logic [7:0]  ic_mem_sel;
    logic        ic_mem_we, ic_mem_cyc, ic_mem_stb, ic_mem_ack, ic_mem_err;

    icache #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) icache0 (
        .clk(clk), .rst(rst),
        .addr_i(wbf_addr), .dat_o(wbf_dat_s2m), .cyc_i(wbf_cyc), .stb_i(wbf_stb),
        .ack_o(wbf_ack), .err_o(wbf_err), .flush_i(icache_flush),
        .mem_addr_o(ic_mem_addr), .mem_dat_i(ic_mem_dat_i), .mem_sel_o(ic_mem_sel),
        .mem_we_o(ic_mem_we), .mem_cyc_o(ic_mem_cyc), .mem_stb_o(ic_mem_stb),
        .mem_ack_i(ic_mem_ack), .mem_err_i(ic_mem_err)
    );

    // What feeds the shared backing SRAM (fetch_mem_arb0's arbitrated output).
    logic [31:0] sram_addr;
    logic [63:0] sram_dat_m2s, sram_dat_s2m;
    logic [7:0]  sram_sel;
    logic        sram_we, sram_cyc, sram_stb, sram_ack, sram_err;

    // m1_lock_i = wbm_lock: an AMO's read-to-write idle cycle must not
    // hand the SRAM to an I$ refill in between.
    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(ic_mem_addr), .m0_dat_i(64'b0), .m0_dat_o(ic_mem_dat_i),  // icache never writes
        .m0_sel_i(ic_mem_sel), .m0_we_i(ic_mem_we), .m0_cyc_i(ic_mem_cyc), .m0_stb_i(ic_mem_stb),
        .m0_ack_o(ic_mem_ack), .m0_err_o(ic_mem_err), .m0_lock_i(1'b0),
        .m1_addr_i(wbm_addr), .m1_dat_i(wbm_dat_m2s), .m1_dat_o(wbm_dat_s2m),
        .m1_sel_i(wbm_sel), .m1_we_i(wbm_we), .m1_cyc_i(wbm_cyc), .m1_stb_i(wbm_stb),
        .m1_ack_o(wbm_ack), .m1_err_o(wbm_err), .m1_lock_i(wbm_lock),
        .addr_o(sram_addr), .dat_o(sram_dat_m2s), .dat_i(sram_dat_s2m),
        .sel_o(sram_sel), .we_o(sram_we), .cyc_o(sram_cyc), .stb_o(sram_stb),
        .ack_i(sram_ack), .err_i(sram_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(sram_addr), .dat_i(sram_dat_m2s), .dat_o(sram_dat_s2m), .sel_i(sram_sel),
        .ack_o(sram_ack), .err_o(sram_err), .cyc_i(sram_cyc), .stb_i(sram_stb), .we_i(sram_we)
    );

endmodule
