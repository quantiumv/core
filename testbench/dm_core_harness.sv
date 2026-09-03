// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dm_core_harness
 *
 * "dm + core + wb4_sram" wiring for Milestone 5's own DMI backdoor
 * testbench (dm_tb.sv) -- extends core_wb4_sram_harness.sv's own
 * "core + wb4_sram only" shape with a real dm0 instance wired to core0's
 * Milestone 4 halt/resume ports and Milestone 5's new Access Register
 * ports. The DMI-facing side is dm0's own plain register interface
 * (i_reg_addr/i_reg_wdata/i_reg_we/o_reg_rdata, see design/dm.sv's own
 * header for why this isn't the literal 41-bit DMI protocol) -- exposed
 * straight through so a testbench can drive it directly with no DMI
 * transport FSM in the way (that's a separate, later Milestone 6
 * concern, design/dm_dmi.sv).
 *
 * NUM_WORDS defaults to 4096, same precedent as core_wb4_sram_harness.sv.
 */
module dm_core_harness #(
    parameter NUM_WORDS = 4096
) (
    input logic clk,
    input logic rst,

    input  logic [6:0]  i_reg_addr,
    input  logic [31:0] i_reg_wdata,
    input  logic        i_reg_we,
    output logic [31:0] o_reg_rdata
);

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    logic o_debug_mode;
    logic debug_halt_req, debug_resume_req;
    logic dm_gpr_we, dm_csr_we;
    logic [4:0]  dm_gpr_sel;
    logic [11:0] dm_csr_addr;
    logic [63:0] dm_gpr_wdata, dm_csr_wdata, dm_gpr_rdata, dm_csr_rdata;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err),
        .o_debug_mode(o_debug_mode),
        .i_debug_halt_req(debug_halt_req), .i_debug_resume_req(debug_resume_req),
        .i_dm_gpr_we(dm_gpr_we), .i_dm_gpr_sel(dm_gpr_sel),
        .i_dm_gpr_wdata(dm_gpr_wdata), .o_dm_gpr_rdata(dm_gpr_rdata),
        .i_dm_csr_we(dm_csr_we), .i_dm_csr_addr(dm_csr_addr),
        .i_dm_csr_wdata(dm_csr_wdata), .o_dm_csr_rdata(dm_csr_rdata)
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    dm dm0 (
        .clk(clk), .rst(rst),
        .i_reg_addr(i_reg_addr), .i_reg_wdata(i_reg_wdata), .i_reg_we(i_reg_we),
        .o_reg_rdata(o_reg_rdata),
        .i_hart_halted(o_debug_mode),
        .o_debug_halt_req(debug_halt_req), .o_debug_resume_req(debug_resume_req),
        .o_dm_gpr_we(dm_gpr_we), .o_dm_gpr_sel(dm_gpr_sel),
        .o_dm_gpr_wdata(dm_gpr_wdata), .i_dm_gpr_rdata(dm_gpr_rdata),
        .o_dm_csr_we(dm_csr_we), .o_dm_csr_addr(dm_csr_addr),
        .o_dm_csr_wdata(dm_csr_wdata), .i_dm_csr_rdata(dm_csr_rdata)
    );

endmodule
