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
 * Access doesn't need it to prove arbitration correctness). Since
 * core.sv's fetch/mem port split, arb0 arbitrates core0's MEM port vs.
 * SBA, and a second wb_arbiter2 (fetch_mem_arb0) merges core0's FETCH
 * port in below it, at lower priority than both -- preserving the old
 * "SBA beats ALL core traffic" behavior (soc.sv merges fetch in at the
 * memory level too, via cache_complex.sv). The
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
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock),
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

    // arb0's arbitrated output (core0 mem port vs. SBA), into fetch_mem_arb0's m1.
    logic [31:0] l1_addr;
    logic [63:0] l1_dat_m2s, l1_dat_s2m;
    logic [7:0]  l1_sel;
    logic        l1_we, l1_cyc, l1_stb, l1_ack, l1_err;

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    wb_arbiter2 arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbm_addr), .m0_dat_i(wbm_dat_m2s), .m0_dat_o(wbm_dat_s2m),
        .m0_sel_i(wbm_sel), .m0_we_i(wbm_we), .m0_cyc_i(wbm_cyc), .m0_stb_i(wbm_stb),
        .m0_ack_o(wbm_ack), .m0_err_o(wbm_err), .m0_lock_i(wbm_lock),
        .m1_addr_i(sba_addr), .m1_dat_i(sba_dat_m2s), .m1_dat_o(sba_dat_s2m),
        .m1_sel_i(sba_sel), .m1_we_i(sba_we), .m1_cyc_i(sba_cyc), .m1_stb_i(sba_stb),
        .m1_ack_o(sba_ack), .m1_err_o(sba_err), .m1_lock_i(1'b0),
        .addr_o(l1_addr), .dat_o(l1_dat_m2s), .dat_i(l1_dat_s2m),
        .sel_o(l1_sel), .we_o(l1_we), .cyc_o(l1_cyc), .stb_o(l1_stb),
        .ack_i(l1_ack), .err_i(l1_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()  // unused, as in soc.sv
        /* verilator lint_on PINCONNECTEMPTY */
    );

    /*
     * fetch_mem_arb0: merges core0's fetch port (m0, read-only) under
     * arb0's output (m1), so SBA keeps priority over ALL core traffic as
     * before the port split. m1_lock_i = wbm_lock keeps an AMO's
     * read-to-write idle cycle locked at this level too.
     */
    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbf_addr), .m0_dat_i(64'b0), .m0_dat_o(wbf_dat_s2m),
        .m0_sel_i({8{wbf_cyc}}), .m0_we_i(1'b0), .m0_cyc_i(wbf_cyc), .m0_stb_i(wbf_stb),
        .m0_ack_o(wbf_ack), .m0_err_o(wbf_err), .m0_lock_i(1'b0),
        .m1_addr_i(l1_addr), .m1_dat_i(l1_dat_m2s), .m1_dat_o(l1_dat_s2m),
        .m1_sel_i(l1_sel), .m1_we_i(l1_we), .m1_cyc_i(l1_cyc), .m1_stb_i(l1_stb),
        .m1_ack_o(l1_ack), .m1_err_o(l1_err), .m1_lock_i(wbm_lock),
        .addr_o(mem_addr), .dat_o(mem_dat_m2s), .dat_i(mem_dat_s2m),
        .sel_o(mem_sel), .we_o(mem_we), .cyc_o(mem_cyc), .stb_o(mem_stb),
        .ack_i(mem_ack), .err_i(mem_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_grant()
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
