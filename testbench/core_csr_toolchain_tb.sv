// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's Zicsr support against a REAL toolchain-assembled and
 * -linked program (firmware/csr_test.s), as opposed to core_zicsr_tb.sv's
 * hand-packed instruction encodings. Same wiring spirit as core_wb_tb.sv/
 * core_zicsr_tb.sv (real wb4_sram instance, core wired directly to it as
 * the sole Wishbone master) but even simpler: no wb_addr_decoder/uart_tx
 * needed, since csr_test.s never issues a load/store -- it's pure
 * register/CSR traffic, same reasoning core_zicsr_tb.sv already documents
 * for itself.
 *
 * wb4_sram.sv's own time-0 initial block unconditionally zero-fills then
 * $readmemh's firmware/crt0.hex (the hello-world image) into its memory --
 * see that file's header. This testbench doesn't want that image; it
 * wants firmware/csr_test.hex instead. Rather than editing wb4_sram.sv
 * (shared by every other testbench), a second $readmemh right here
 * overwrites the SRAM with the real image once wb4_sram's own init is
 * done, before reset is released -- same #1-past-time-0 delay convention
 * core_wb_tb.sv/core_zicsr_tb.sv already use for their own hierarchical
 * pokes, for the same reason: guarantee ordering against an unrelated
 * zero-time initial block instead of racing it.
 *
 * Instantiated at wb4_sram's default num_words (4096, 32KB) rather than
 * the reduced size core_wb_tb.sv/core_zicsr_tb.sv use -- those hand-pack
 * a handful of words directly and shrink the array purely for simulation
 * speed. This test loads a real program linked against firmware/link.ld,
 * which reserves the full 32KB RAM region (crt0.s's _stack_top sits at
 * the very top of it) -- matching design/soc.sv's own wb4_sram
 * instantiation is the faithful choice here.
 *
 * firmware/csr_test.s provides its own main:, called from crt0.s exactly
 * like hello.c's -- see that file's header/inline comments for the full
 * instruction-by-instruction derivation of the expected s1-s11/mscratch
 * values below. ra/sp/gp/tp are untouched by csr_test.s, so `ret` falls
 * back into crt0.s's trailing ebreak, halting the core the same way
 * every other firmware image in this repo does.
 */
module core_csr_toolchain_tb;

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
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/csr_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (300) @(posedge clk);
                $display("TIMEOUT: dut.halted never went high -- is firmware/csr_test.hex built?");
                $finish;
            end
        join_any
        #1;

        /*
         * Expected values, mechanically derived from the chained
         * mscratch read/write/set/clear sequence in firmware/csr_test.s
         * (see that file's inline comments for the step-by-step
         * derivation). s1-s11 map to gp_registers[9] and [18:27] --
         * NOT a contiguous [9:27] range: x9 is s1, but x10-x17 are the
         * argument registers a0-a7, and only x18-x27 pick back up as
         * s2-s11, per the standard RV64 calling convention.
         * s8/s9/s10 are the three rd==rs1 aliasing steps.
         */
        check("s1  (csrr, initial mscratch)",            dut.regfile0.gp_registers[9],  64'h0000_0000_0000_0003);
        check("s2  (csrrci, old value)",                 dut.regfile0.gp_registers[18], 64'h0000_0000_0000_0003);
        check("s3  (csrrsi, old value)",                 dut.regfile0.gp_registers[19], 64'h0000_0000_0000_0002);
        check("s4  (csrrwi, old value)",                 dut.regfile0.gp_registers[20], 64'h0000_0000_0000_0006);
        check("s5  (csrrw, old value)",                  dut.regfile0.gp_registers[21], 64'h0000_0000_0000_0002);
        check("s6  (csrrc, old value)",                  dut.regfile0.gp_registers[22], 64'h0000_0000_0bad_1dea);
        check("s7  (csrrs, old value)",                  dut.regfile0.gp_registers[23], 64'h0000_0000_0bad_0000);
        check("s8  (csrrw, rd==rs1 aliasing, old value)", dut.regfile0.gp_registers[24], 64'h0000_0000_0bad_beef);
        check("s9  (csrrc, rd==rs1 aliasing, old value)", dut.regfile0.gp_registers[25], 64'h0000_0000_0bad_1dea);
        check("s10 (csrrs, rd==rs1 aliasing, old value)", dut.regfile0.gp_registers[26], 64'h0000_0000_0bad_0000);
        check("s11 (csrr, final mscratch)",              dut.regfile0.gp_registers[27], 64'h0000_0000_0bad_beef);

        check("mscratch_q final value (register-independent confirmation)",
              dut.csr_file0.mscratch_q, 64'h0000_0000_0bad_beef);

        check("core halted (ebreak reached)", {63'b0, dut.halted}, 64'd1);

        $display("");
        $display("core_csr_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_csr_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
