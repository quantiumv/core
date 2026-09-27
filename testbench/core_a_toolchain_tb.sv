// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's A-extension (RV64A, atomics) support against a REAL
 * toolchain-assembled and -linked program (firmware/a_test.s), as opposed
 * to testbench/core_a_ext_tb.sv's hand-packed instruction encodings.
 * Same wiring spirit as core_m_toolchain_tb.sv (a real wb4_sram instance,
 * core's fetch/mem ports merged onto it by fetch_mem_arb0, no UART needed).
 *
 * Unlike m_test.s (pure register/ALU/divider traffic), a_test.s genuinely
 * needs real memory -- every LR/SC/AMO instruction operates on an actual
 * address -- so this is the first *_toolchain_tb.sv in this repo whose
 * firmware image carries real, non-zero .data content (link.ld's existing
 * .data section, reused with zero linker changes; see a_test.s's own
 * header). The full 32KB RAM region a real link.ld-linked program expects
 * is why sram0 is instantiated at wb4_sram's default num_words (4096),
 * matching core_m_toolchain_tb.sv/core_csr_toolchain_tb.sv/design/soc.sv.
 *
 * wb4_sram.sv's own time-0 initial block unconditionally zero-fills then
 * $readmemh's firmware/crt0.hex (the hello-world image) into its memory
 * -- see that file's header. This testbench doesn't want that image; it
 * wants firmware/a_test.hex instead. A second $readmemh right here
 * overwrites the SRAM with the real image once wb4_sram's own init is
 * done, before reset is released -- same #1-past-time-0 delay convention
 * every other *_toolchain_tb.sv uses for the identical reason: guarantee
 * ordering against an unrelated zero-time initial block instead of racing
 * it.
 *
 * Uses the shared testbench/ infrastructure (check_lib.sv, halt_wait.sv).
 * TIMEOUT_CYCLES_LARGE (3000 cycles): a_test.s issues 22 real memory
 * transactions (LR/SC's single read-or-write, or an AMO's read-then-write
 * pair), none divide-family, so this is generous headroom rather than a
 * tightly-reasoned minimum -- consistent with this project's convention
 * of picking the safe tier rather than the exact one for a memory-heavy
 * real-toolchain firmware test.
 *
 * firmware/a_test.s provides its own main:, called from crt0.s exactly
 * like hello.c's/m_test.s's -- see that file's header/inline comments for
 * the instruction-by-instruction derivation of the expected register
 * values below (the SAME operand pairs already hand-derived and
 * hardware-proven in testbench/core_a_ext_tb.sv, reused here deliberately
 * so a mismatch points at the real assembler/linker/fetch-decode path,
 * not at fresh arithmetic). ra/sp/gp/tp are untouched by a_test.s, so
 * `ret` falls back into crt0.s's trailing ebreak, halting the core the
 * same way every other firmware image in this repo does.
 */
module core_a_toolchain_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    // Arbitrated bus -- what sram0 actually sees.
    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    // core's fetch port (wbf_*) and mem port (wbm_*).
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
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err), .wb_mem_lock_o(wbm_lock)
    );

    // core.sv now has separate fetch/mem ports; this merges them onto the
    // harness's single SRAM (fetch and data must share one memory). Mem is
    // m1 so execute wins ties, matching cache_complex.sv's dcache-wins policy.
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
        $readmemh("../firmware/a_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "EBREAK trap never fired -- is firmware/a_test.hex built?");

        /*
         * Expected values, mechanically identical to the ones
         * testbench/core_a_ext_tb.sv already proved for these same
         * operand pairs -- see firmware/a_test.s's inline comments for
         * the step-by-step derivation. s1/s2-s11 map to gp_registers[9]
         * and [18:27] (NOT contiguous: x9 is s1, but x10-x17 are the
         * argument registers a0-a7, and only x18-x27 pick back up as
         * s2-s11, per the standard RV64 calling convention). a0-a7 map to
         * gp_registers[10:17]; t4/t5/t6 (the 3 extra results beyond the
         * 11 "s"/8 "a" registers used) map to gp_registers[29:31].
         */
        check("LR.W          (s1)",  dut.regfile0.gp_registers[9],  64'hFFFFFFFF80000001);
        check("LR.D          (s2)",  dut.regfile0.gp_registers[18], -64'sd16);
        check("SC success    (s3)",  dut.regfile0.gp_registers[19], 64'd0);
        check("SC no-LR fail (s4)",  dut.regfile0.gp_registers[20], 64'd1);

        check("AMOSWAP.W old (s5)",  dut.regfile0.gp_registers[21], 64'h10);
        check("AMOSWAP.D old (s6)",  dut.regfile0.gp_registers[22], 64'd100);
        check("AMOADD.W  old (s7)",  dut.regfile0.gp_registers[23], 64'h7FFFFFFF);
        check("AMOADD.D  old (s8)",  dut.regfile0.gp_registers[24], 64'd5);
        check("AMOXOR.W  old (s9)",  dut.regfile0.gp_registers[25], 64'd6);
        check("AMOXOR.D  old (s10)", dut.regfile0.gp_registers[26], 64'd6);
        check("AMOOR.W   old (s11)", dut.regfile0.gp_registers[27], 64'd6);
        check("AMOOR.D   old (a0)",  dut.regfile0.gp_registers[10], 64'd6);
        check("AMOAND.W  old (a1)",  dut.regfile0.gp_registers[11], 64'd6);
        check("AMOAND.D  old (a2)",  dut.regfile0.gp_registers[12], 64'd6);
        check("AMOMIN.W  old (a3)",  dut.regfile0.gp_registers[13], 64'd3);
        check("AMOMIN.D  old (a4)",  dut.regfile0.gp_registers[14], 64'd30);
        check("AMOMAX.W  old (a5)",  dut.regfile0.gp_registers[15], 64'hFFFFFFFFFFFFFFFB);
        check("AMOMAX.D  old (a6)",  dut.regfile0.gp_registers[16], -64'sd50);
        check("AMOMINU.W old (a7)",  dut.regfile0.gp_registers[17], 64'hFFFFFFFFFFFFFFFB);
        check("AMOMINU.D old (t4)",  dut.regfile0.gp_registers[29], -64'sd50);
        check("AMOMAXU.W old (t5)",  dut.regfile0.gp_registers[30], 64'd3);
        check("AMOMAXU.D old (t6)",  dut.regfile0.gp_registers[31], 64'd30);

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_a_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_a_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
