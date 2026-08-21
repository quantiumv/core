// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's A-extension (RV64A, atomics) support against a REAL
 * toolchain-assembled and -linked program (firmware/a_test.s), as opposed
 * to testbench/core_a_ext_tb.sv's hand-packed instruction encodings.
 * Same wiring spirit as core_m_toolchain_tb.sv (a real wb4_sram instance,
 * core wired directly to it as the sole Wishbone master, no UART needed).
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

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;

    core dut (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err)
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
