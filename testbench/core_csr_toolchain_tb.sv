// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's Zicsr support against a REAL toolchain-assembled and
 * -linked program (firmware/csr_test.s), as opposed to core_zicsr_tb.sv's
 * hand-packed instruction encodings. Same wiring spirit as core_wb_tb.sv/
 * core_zicsr_tb.sv (real wb4_sram instance, core's fetch/mem ports merged
 * onto it by fetch_mem_arb0) but even simpler: no wb_addr_decoder/uart_tx
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
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    logic halted = 1'b0;
    always @(posedge clk) if (dut.trap_taken && dut.is_ebreak) halted <= 1'b1;

    initial begin
        #1; // see header comment: run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/csr_test.hex", sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (halted === 1'b1);
            begin
                repeat (300) @(posedge clk);
                $display("TIMEOUT: EBREAK trap never fired -- is firmware/csr_test.hex built?");
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

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_csr_toolchain_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_csr_toolchain_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
