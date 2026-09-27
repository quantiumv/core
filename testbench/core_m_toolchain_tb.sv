// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's M-extension (RV64M, integer multiply/divide) support
 * against a REAL toolchain-assembled and -linked program
 * (firmware/m_test.s), as opposed to testbench/core_m_ext_tb.sv's
 * hand-packed instruction encodings. Same wiring spirit as
 * core_csr_toolchain_tb.sv (a real wb4_sram instance, core wired directly
 * to it as the sole Wishbone master) but even simpler: no UART needed,
 * since m_test.s never issues a load/store -- it's pure register/ALU/
 * divider traffic, same reasoning core_csr_toolchain_tb.sv already
 * documents for itself.
 *
 * wb4_sram.sv's own time-0 initial block unconditionally zero-fills then
 * $readmemh's firmware/crt0.hex (the hello-world image) into its
 * memory -- see that file's header. This testbench doesn't want that
 * image; it wants firmware/m_test.hex instead. Rather than editing
 * wb4_sram.sv (shared by every other testbench), a second $readmemh
 * right here overwrites the SRAM with the real image once wb4_sram's own
 * init is done, before reset is released -- same #1-past-time-0 delay
 * convention core_csr_toolchain_tb.sv uses for the identical reason:
 * guarantee ordering against an unrelated zero-time initial block
 * instead of racing it.
 *
 * Instantiated at wb4_sram's default num_words (4096, 32KB), matching
 * core_csr_toolchain_tb.sv and design/soc.sv's own instantiation -- this
 * test loads a real program linked against firmware/link.ld, which
 * reserves the full 32KB RAM region.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv),
 * same as every testbench written since that environment was built --
 * core_csr_toolchain_tb.sv predates it and hand-duplicates its own
 * check()/fork-wait-timeout shape, but there is no reason for a new file
 * to keep doing that. TIMEOUT_CYCLES_LARGE (3000 cycles), not one of the
 * smaller tiers, because m_test.s runs EIGHT real divide-family
 * instructions (div/divu/rem/remu/divw/divuw/remw/remuw), each a genuine
 * multi-cycle iterative divide (~64-66 cycles per design/divider.sv's own
 * header) -- this file has no white-box multi-cycle-divide check of its
 * own since that property is already proven by core_m_ext_tb.sv; this
 * file's job is purely to confirm a real toolchain-assembled image
 * produces the right answers end to end.
 *
 * firmware/m_test.s provides its own main:, called from crt0.s exactly
 * like hello.c's -- see that file's header/inline comments for the
 * instruction-by-instruction derivation of the expected s0-s11/t3 values
 * below (the same operand pairs already hand-derived and hardware-proven
 * in testbench/core_m_ext_tb.sv). ra/sp/gp/tp are untouched by m_test.s,
 * so `ret` falls back into crt0.s's trailing ebreak, halting the core the
 * same way every other firmware image in this repo does.
 */
module core_m_toolchain_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    // core's own two ports: wbf_* = fetch (read-only), wbm_* = mem.
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err, wbm_lock;

    core dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc),
        .wb_mem_stb_o(wbm_stb), .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err),
        .wb_mem_lock_o(wbm_lock)
    );

    /* core.sv now has separate fetch and mem ports; this merges them onto
     * the harness's single SRAM (wb_* above = what sram0 sees). mem is m1
     * so execute wins ties. Fetch never writes: sel mirrors the old core's
     * 8'hFF-while-fetching, 0-when-idle behavior. */
    wb_arbiter2 fetch_mem_arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(wbf_addr), .m0_dat_i(64'b0), .m0_dat_o(wbf_dat_s2m),
        .m0_sel_i({8{wbf_cyc}}), .m0_we_i(1'b0), .m0_cyc_i(wbf_cyc), .m0_stb_i(wbf_stb),
        .m0_ack_o(wbf_ack), .m0_err_o(wbf_err),
        .m1_addr_i(wbm_addr), .m1_dat_i(wbm_dat_m2s), .m1_dat_o(wbm_dat_s2m),
        .m1_sel_i(wbm_sel), .m1_we_i(wbm_we), .m1_cyc_i(wbm_cyc), .m1_stb_i(wbm_stb),
        .m1_ack_o(wbm_ack), .m1_err_o(wbm_err), .m1_lock_i(wbm_lock),
        .addr_o(wb_addr), .dat_o(wb_dat_m2s), .dat_i(wb_dat_s2m), .sel_o(wb_sel),
        .we_o(wb_we), .cyc_o(wb_cyc), .stb_o(wb_stb), .ack_i(wb_ack), .err_i(wb_err),
        /* verilator lint_off PINCONNECTEMPTY */ .o_grant() /* verilator lint_on PINCONNECTEMPTY */
    );

    wb4_sram sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.trap_taken && dut.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/m_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "EBREAK trap never fired -- is firmware/m_test.hex built?");

        /*
         * Expected values, mechanically identical to the ones
         * testbench/core_m_ext_tb.sv already proved for these same
         * operand pairs -- see firmware/m_test.s's inline comments for
         * the step-by-step derivation. s1-s11 map to gp_registers[9] and
         * [18:27] (NOT a contiguous range: x9 is s1, but x10-x17 are the
         * argument registers a0-a7, and only x18-x27 pick back up as
         * s2-s11, per the standard RV64 calling convention). s0 is
         * gp_registers[8]; t3 (this program's 13th, non-"s" result
         * register, needed since there are only 12 standard callee-saved
         * "s" registers for 13 live results) is gp_registers[28].
         */
        check("MUL    (s1)",  dut.regfile0.gp_registers[9],  64'hFFFFFFFFFFFFFFFE);
        check("MULH   (s2)",  dut.regfile0.gp_registers[18], 64'hFFFFFFFFFFFFFFFF);
        check("MULHSU (s3)",  dut.regfile0.gp_registers[19], 64'hFFFFFFFFFFFFFFFF);
        check("MULHU  (s4)",  dut.regfile0.gp_registers[20], 64'hFFFFFFFFFFFFFFFE);
        check("MULW   (s5)",  dut.regfile0.gp_registers[21], 64'hFFFFFFFFFFFFFFFE);
        check("DIV    (s6)",  dut.regfile0.gp_registers[22], -64'sd14);
        check("DIVU   (s7)",  dut.regfile0.gp_registers[23], 64'h5555555555555555);
        check("REM    (s8)",  dut.regfile0.gp_registers[24], -64'sd2);
        check("REMU   (s9)",  dut.regfile0.gp_registers[25], 64'd2);
        check("DIVW   (s10)", dut.regfile0.gp_registers[26], 64'hFFFFFFFFC0000000);
        check("DIVUW  (s11)", dut.regfile0.gp_registers[27], 64'h0000000055555555);
        check("REMW   (s0)",  dut.regfile0.gp_registers[8],  64'hFFFFFFFFFFFFFFFF);
        check("REMUW  (t3)",  dut.regfile0.gp_registers[28], 64'd2);

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_m_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_m_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
