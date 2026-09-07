// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dm_core_harness
 *
 * "dm + core + wb4_sram" wiring for Milestone 5's own DMI backdoor
 * testbench (dm_tb.sv) -- extends core_wb4_sram_harness.sv's own
 * "core + wb4_sram only" shape with a real dm0 instance wired to core0's
 * Milestone 4 halt/resume ports, Milestone 5's Access Register ports,
 * Milestone 7's Program Buffer ports, and -- Milestone 8 -- dm0's own
 * System Bus Access master port, arbitrated against core0's ordinary
 * master port via design/wb_arbiter2.sv before either ever reaches
 * sram0 (mirrors soc.sv's own real topology exactly, just with wb4_sram
 * directly behind the arbiter instead of wb_addr_decoder -> cache ->
 * sram -- this harness has never modeled the decoder/cache stage,
 * matching core_wb4_sram_harness.sv's own precedent, and System Bus
 * Access doesn't need it to prove arbitration correctness). The
 * DMI-facing side is dm0's own plain register interface (i_reg_addr/
 * i_reg_wdata/i_reg_we/i_reg_re/o_reg_rdata, see design/dm.sv's own
 * header for why this isn't the literal 41-bit DMI protocol) -- exposed
 * straight through so a testbench can drive it directly with no DMI
 * transport FSM in the way (that's design/dm_dmi.sv, a separate
 * Milestone 6 concern, exercised for real by jtag_dmi_e2e_tb.sv instead
 * of this harness). i_reg_re (Milestone 10a) is ANSI-defaulted 1'b0, same
 * as on dm.sv's own port, so every pre-existing test driving this
 * harness without knowing it exists is unaffected.
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
    input  logic        i_reg_re = 1'b0,
    output logic [31:0] o_reg_rdata
);

    logic [31:0] core_wb_addr;
    logic [63:0] core_wb_dat_m2s, core_wb_dat_s2m;
    logic [7:0]  core_wb_sel;
    logic        core_wb_we, core_wb_cyc, core_wb_stb, core_wb_ack, core_wb_err;
    logic        core_wb_lock;

    logic o_debug_mode;
    logic debug_halt_req, debug_resume_req;
    logic dm_gpr_we, dm_csr_we;
    logic [4:0]  dm_gpr_sel;
    logic [11:0] dm_csr_addr;
    logic [63:0] dm_gpr_wdata, dm_csr_wdata, dm_gpr_rdata, dm_csr_rdata;
    logic        progbuf_start, progbuf_done, progbuf_abort;
    logic [3:0]  progbuf_pc;
    logic [31:0] progbuf_data;
    logic [31:0] sba_addr;
    logic [63:0] sba_dat_m2s, sba_dat_s2m;
    logic [7:0]  sba_sel;
    logic        sba_we, sba_cyc, sba_stb, sba_ack, sba_err;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(core_wb_addr), .wb_dat_o(core_wb_dat_m2s), .wb_dat_i(core_wb_dat_s2m),
        .wb_sel_o(core_wb_sel), .wb_we_o(core_wb_we), .wb_cyc_o(core_wb_cyc), .wb_stb_o(core_wb_stb),
        .wb_ack_i(core_wb_ack), .wb_err_i(core_wb_err), .wb_lock_o(core_wb_lock),
        .o_debug_mode(o_debug_mode),
        .i_debug_halt_req(debug_halt_req), .i_debug_resume_req(debug_resume_req),
        .i_dm_gpr_we(dm_gpr_we), .i_dm_gpr_sel(dm_gpr_sel),
        .i_dm_gpr_wdata(dm_gpr_wdata), .o_dm_gpr_rdata(dm_gpr_rdata),
        .i_dm_csr_we(dm_csr_we), .i_dm_csr_addr(dm_csr_addr),
        .i_dm_csr_wdata(dm_csr_wdata), .o_dm_csr_rdata(dm_csr_rdata),
        .i_progbuf_start(progbuf_start), .o_progbuf_pc(progbuf_pc),
        .i_progbuf_data(progbuf_data), .o_progbuf_done(progbuf_done),
        .o_progbuf_abort(progbuf_abort)
    );

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    wb_arbiter2 arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(core_wb_addr), .m0_dat_i(core_wb_dat_m2s), .m0_dat_o(core_wb_dat_s2m),
        .m0_sel_i(core_wb_sel), .m0_we_i(core_wb_we), .m0_cyc_i(core_wb_cyc), .m0_stb_i(core_wb_stb),
        .m0_ack_o(core_wb_ack), .m0_err_o(core_wb_err), .m0_lock_i(core_wb_lock),
        .m1_addr_i(sba_addr), .m1_dat_i(sba_dat_m2s), .m1_dat_o(sba_dat_s2m),
        .m1_sel_i(sba_sel), .m1_we_i(sba_we), .m1_cyc_i(sba_cyc), .m1_stb_i(sba_stb),
        .m1_ack_o(sba_ack), .m1_err_o(sba_err), .m1_lock_i(1'b0),
        .addr_o(mem_addr), .dat_o(mem_dat_m2s), .dat_i(mem_dat_s2m),
        .sel_o(mem_sel), .we_o(mem_we), .cyc_o(mem_cyc), .stb_o(mem_stb),
        .ack_i(mem_ack), .err_i(mem_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()  // unused here -- no cache/ifetch signal in this harness to gate (see soc.sv for that consumer)
        /* verilator lint_on PINCONNECTEMPTY */
    );

    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(mem_dat_m2s), .dat_o(mem_dat_s2m), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

    dm dm0 (
        .clk(clk), .rst(rst),
        .i_reg_addr(i_reg_addr), .i_reg_wdata(i_reg_wdata), .i_reg_we(i_reg_we),
        .i_reg_re(i_reg_re),
        .o_reg_rdata(o_reg_rdata),
        .i_hart_halted(o_debug_mode),
        .o_debug_halt_req(debug_halt_req), .o_debug_resume_req(debug_resume_req),
        .o_dm_gpr_we(dm_gpr_we), .o_dm_gpr_sel(dm_gpr_sel),
        .o_dm_gpr_wdata(dm_gpr_wdata), .i_dm_gpr_rdata(dm_gpr_rdata),
        .o_dm_csr_we(dm_csr_we), .o_dm_csr_addr(dm_csr_addr),
        .o_dm_csr_wdata(dm_csr_wdata), .i_dm_csr_rdata(dm_csr_rdata),
        .o_progbuf_start(progbuf_start), .i_progbuf_pc(progbuf_pc),
        .o_progbuf_data(progbuf_data), .i_progbuf_done(progbuf_done),
        .i_progbuf_abort(progbuf_abort),
        .o_sba_addr(sba_addr), .o_sba_dat(sba_dat_m2s), .i_sba_dat(sba_dat_s2m),
        .o_sba_sel(sba_sel), .o_sba_we(sba_we), .o_sba_cyc(sba_cyc), .o_sba_stb(sba_stb),
        .i_sba_ack(sba_ack), .i_sba_err(sba_err)
    );

endmodule
