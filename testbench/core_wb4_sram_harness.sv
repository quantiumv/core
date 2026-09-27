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
    input logic i_mtip = 1'b0,
    input logic i_meip = 1'b0,
    input logic i_seip = 1'b0,
    input logic i_debug_halt_req = 1'b0,
    input logic i_debug_resume_req = 1'b0,
    output logic o_debug_mode
);

    // Arbitrated bus: what sram0 actually sees.
    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    // core0's fetch-side (read-only) master port.
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;

    // core0's mem-side master port.
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err;
    logic        wbm_lock;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock),
        .i_mtip(i_mtip),
        .i_meip(i_meip), .i_seip(i_seip),
        .i_debug_halt_req(i_debug_halt_req), .i_debug_resume_req(i_debug_resume_req),
        .o_debug_mode(o_debug_mode)
    );

    /*
     * core.sv now has separate fetch and mem ports; this merges them onto
     * the harness's single SRAM (so stores stay visible to later fetches).
     * mem is m1 so execute wins ties. Fetch never writes: sel mirrors the
     * old core's 8'hFF-while-fetching, 0-when-idle behavior.
     */
    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbf_addr), .m0_dat_i(64'b0), .m0_dat_o(wbf_dat_s2m),
        .m0_sel_i({8{wbf_cyc}}), .m0_we_i(1'b0), .m0_cyc_i(wbf_cyc), .m0_stb_i(wbf_stb),
        .m0_ack_o(wbf_ack), .m0_err_o(wbf_err),
        .m1_addr_i(wbm_addr), .m1_dat_i(wbm_dat_m2s), .m1_dat_o(wbm_dat_s2m),
        .m1_sel_i(wbm_sel), .m1_we_i(wbm_we), .m1_cyc_i(wbm_cyc), .m1_stb_i(wbm_stb),
        .m1_ack_o(wbm_ack), .m1_err_o(wbm_err), .m1_lock_i(wbm_lock),
        .addr_o(wb_addr), .dat_o(wb_dat_m2s), .dat_i(wb_dat_s2m),
        .sel_o(wb_sel), .we_o(wb_we), .cyc_o(wb_cyc), .stb_o(wb_stb),
        .ack_i(wb_ack), .err_i(wb_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

endmodule
