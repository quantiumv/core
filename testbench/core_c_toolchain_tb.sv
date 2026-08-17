// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's C-extension (RV64 Zca, compressed instructions)
 * support against a REAL toolchain-assembled and -linked program
 * (firmware/c_test.s), as opposed to testbench/core_c_ext_tb.sv's
 * hand-packed instruction encodings. Same wiring spirit as
 * core_a_toolchain_tb.sv/core_m_toolchain_tb.sv (a real wb4_sram
 * instance, core wired directly to it as the sole Wishbone master, no
 * UART needed).
 *
 * firmware/c_test.s is deliberately ordinary RISC-V assembly (no c.xxx
 * mnemonics) -- under -march=rv64imac the real assembler automatically
 * compressed most of it (confirmed directly against the real objdump
 * output: `add a0,a0,a0`/`ret`/`mv`/`li`/`addi`/`add s5,s5,s6` all came
 * out as genuine 2-byte encodings; `jal ra,sub1` stayed 4 bytes since
 * RV64 has no compressed form for a jump-and-link with a real
 * destination register, and `bnez s3,loop`/`li s6,100` stayed 4 bytes
 * too since s3/s6 (x19/x22) fall outside the x8-x15 "popular register"
 * range C.BNEZ needs and 100 exceeds C.LI's 6-bit signed range) -- this
 * is real, representative, non-cherry-picked compressed-code density,
 * not a synthetic all-compressed or all-uncompressed program.
 *
 * wb4_sram.sv's own time-0 initial block unconditionally zero-fills then
 * $readmemh's firmware/crt0.hex (the hello-world image) into its
 * memory -- see that file's header. This testbench doesn't want that
 * image; it wants firmware/c_test.hex instead. A second $readmemh right
 * here overwrites the SRAM with the real image once wb4_sram's own init
 * is done, before reset is released -- same #1-past-time-0 delay
 * convention every other *_toolchain_tb.sv uses for the identical
 * reason: guarantee ordering against an unrelated zero-time initial
 * block instead of racing it.
 *
 * Instantiated at wb4_sram's default num_words (4096, 32KB), matching
 * every other *_toolchain_tb.sv and design/soc.sv's own instantiation --
 * this test loads a real program linked against firmware/link.ld, which
 * reserves the full 32KB RAM region.
 *
 * TIMEOUT_CYCLES_LARGE: generous headroom, not a tightly-reasoned
 * minimum -- this program is short (a handful of instructions plus a
 * 5-iteration loop), nowhere near needing the full 3000-cycle budget,
 * but there's no cost to the safety margin.
 *
 * firmware/c_test.s provides its own main:, called from crt0.s exactly
 * like hello.c's/a_test.s's/m_test.s's -- see that file's header/inline
 * comments for the full derivation of the expected s1/s2/s4/s5 values
 * below. The header there also explains why this specific program (a
 * real jal-with-link paired with a real compressed return) is the
 * strongest available proof that pc_plus_len is computed correctly
 * against genuinely linked addresses, not just hand-picked ones.
 * ra/sp/gp/tp are untouched by c_test.s outside the sub1 call (which
 * restores ra via its own return before main's own trailing ret), so
 * `ret` falls back correctly into crt0.s's trailing ebreak, halting the
 * core the same way every other firmware image in this repo does.
 */
module core_c_toolchain_tb;

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

    wire halted = dut.halted;
    `include "halt_wait.sv"

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/c_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_LARGE, "dut.halted never went high -- is firmware/c_test.hex built?");

        /*
         * Expected values -- see firmware/c_test.s's inline comments for
         * the step-by-step derivation. s1=gp_registers[9], s2=[18],
         * s3=[19], s4=[20], s5=[21], s6=[22] (standard RV64 calling
         * convention: x9=s1, then x18-x27 pick back up as s2-s11).
         */
        check("store/load round trip (s1)",       dut.regfile0.gp_registers[9],  64'd123);
        check("jal+ret return value (s2)",         dut.regfile0.gp_registers[18], 64'd42);
        check("loop terminated correctly (s3)",    dut.regfile0.gp_registers[19], 64'd0);
        check("loop iteration count (s4)",         dut.regfile0.gp_registers[20], 64'd5);
        check("post-return arithmetic (s5)",       dut.regfile0.gp_registers[21], 64'd93); // -7 + 100

        check("core halted (ebreak reached)", {63'b0, dut.halted}, 64'd1);

        $display("");
        $display("core_c_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_c_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
