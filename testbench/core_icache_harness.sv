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
 * The small routing mux below (sram_*, gated on wb_ifetch) is temporary,
 * harness-local scaffolding -- design/cache_complex.sv (a later milestone)
 * formalizes this exact routing for real inside soc.sv itself, at which
 * point this harness's mux logic becomes redundant with that module, not
 * a permanent second copy of it. core.sv's own bus master port is never
 * driven by two sources at once: wb_ifetch (core.sv's new wb_ifetch_o,
 * see that port's own header comment in core.sv) is high only during
 * S_FETCH/S_FETCH_HI, exactly when icache0's core-facing port is live and
 * wb4_sram's direct connection is idle, and low only during S_MEM/
 * S_AMO_WRITE, the reverse -- core.sv's single-issue FSM guarantees these
 * never overlap.
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

    // core.sv's single shared bus master port.
    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;
    logic        wb_ifetch;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err), .wb_ifetch_o(wb_ifetch)
    );

    // icache's core-facing port -- read-only, so wb_dat_m2s/wb_we/wb_sel
    // are never relevant to it (a fetch is always a read).
    logic [63:0] ic_dat_o;
    logic        ic_ack, ic_err;

    // icache's memory-facing port.
    logic [31:0] ic_mem_addr;
    logic [63:0] ic_mem_dat_i;
    logic [7:0]  ic_mem_sel;
    logic        ic_mem_we, ic_mem_cyc, ic_mem_stb, ic_mem_ack, ic_mem_err;

    icache #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) icache0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_o(ic_dat_o), .cyc_i(wb_cyc && wb_ifetch), .stb_i(wb_stb && wb_ifetch),
        .ack_o(ic_ack), .err_o(ic_err),
        .mem_addr_o(ic_mem_addr), .mem_dat_i(ic_mem_dat_i), .mem_sel_o(ic_mem_sel),
        .mem_we_o(ic_mem_we), .mem_cyc_o(ic_mem_cyc), .mem_stb_o(ic_mem_stb),
        .mem_ack_i(ic_mem_ack), .mem_err_i(ic_mem_err)
    );

    // Route to the shared backing SRAM: icache's own refill traffic while
    // a fetch is in flight, core's direct mem/AMO traffic otherwise --
    // same select/mux idiom design/wb_addr_decoder.sv already establishes
    // for routing one master's traffic by a control signal.
    logic [31:0] sram_addr;
    logic [63:0] sram_dat_m2s, sram_dat_s2m;
    logic [7:0]  sram_sel;
    logic        sram_we, sram_cyc, sram_stb, sram_ack, sram_err;

    assign sram_addr    = wb_ifetch ? ic_mem_addr : wb_addr;
    assign sram_dat_m2s = wb_ifetch ? 64'b0       : wb_dat_m2s; // icache never writes
    assign sram_sel     = wb_ifetch ? ic_mem_sel  : wb_sel;
    assign sram_we      = wb_ifetch ? ic_mem_we   : wb_we;
    assign sram_cyc     = wb_ifetch ? ic_mem_cyc  : wb_cyc;
    assign sram_stb     = wb_ifetch ? ic_mem_stb  : wb_stb;

    assign ic_mem_dat_i = sram_dat_s2m;
    assign ic_mem_ack   = wb_ifetch ? sram_ack : 1'b0;
    assign ic_mem_err   = wb_ifetch ? sram_err : 1'b0;

    assign wb_dat_s2m = wb_ifetch ? ic_dat_o : sram_dat_s2m;
    assign wb_ack     = wb_ifetch ? ic_ack   : sram_ack;
    assign wb_err     = wb_ifetch ? ic_err   : sram_err;

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(sram_addr), .dat_i(sram_dat_m2s), .dat_o(sram_dat_s2m), .sel_i(sram_sel),
        .ack_o(sram_ack), .err_o(sram_err), .cyc_i(sram_cyc), .stb_i(sram_stb), .we_i(sram_we)
    );

endmodule
