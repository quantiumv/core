// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc -- Pillar 5 of the C-extension plan, the auto-
 * compression regression.
 *
 * Structurally identical to testbench/soc_tb.sv (same soc instantiation,
 * same 14-byte "Hello, World!\n" UART-output check) -- the only
 * difference is WHICH firmware image is loaded. wb4_sram.sv's own
 * time-0 initial block unconditionally $readmemh's firmware/crt0.hex
 * (the canonical, plain -march=rv64i hello-world image); this testbench
 * doesn't want that one. A second $readmemh right here, #1 past time 0
 * (the same core_a_toolchain_tb.sv/core_m_toolchain_tb.sv idiom used
 * throughout this repo for the identical reason -- guarantee ordering
 * against an unrelated zero-time initial block instead of racing it),
 * overwrites the SRAM with firmware/hello_c.hex instead: the SAME
 * crt0.s/hello.c SOURCE, recompiled unmodified under real
 * -march=rv64imac (firmware/Makefile's `hello_c` target) -- no C.xxx
 * mnemonics anywhere in either source, so whatever compression happened
 * is the real assembler/compiler's own automatic instruction selection
 * over ordinary code, not a hand-picked subset (confirmed directly
 * against the real objdump output: `addi t0,t0,1`, `j`, `sd s0,24(sp)`,
 * `bnez a5,...` and more all came out as genuine 2-byte encodings).
 *
 * A byte-identical pass against the SAME expected UART output as
 * soc_tb.sv is the pass criterion -- proving the compressed and
 * uncompressed builds of the IDENTICAL source are behaviorally
 * indistinguishable to this core. This is the strongest available proof
 * that general, non-cherry-picked compressed-code density works end to
 * end through the real fetch/expand/execute pipeline, not just the
 * curated instruction sweeps in testbench/c_encode_check.s or the
 * hand-assembled/hand-written programs in core_c_ext_tb.sv/c_test.s.
 */
module soc_c_regression_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    soc dut (.clk(clk), .rst(rst));

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
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;

    initial begin
        #1; // run after wb4_sram's own time-0 init of crt0.hex
        $readmemh("../firmware/hello_c.hex", dut.sram0.memory);

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (halted === 1'b1);
            begin
                /* Same generous -O0-C-build budget as soc_tb.sv's own --
                 * see that file's comment on why. */
                repeat (3000) @(posedge clk);
                $display("TIMEOUT: EBREAK trap never fired -- is firmware/hello_c.hex built?");
                $finish;
            end
        join_any
        #1;

        check("UART received 14 bytes",   {55'b0, dut.uart0.tx_history_count}, 64'd14);
        check("byte 0  'H'",  {56'b0, dut.uart0.tx_history[0]},  64'h48);
        check("byte 1  'e'",  {56'b0, dut.uart0.tx_history[1]},  64'h65);
        check("byte 2  'l'",  {56'b0, dut.uart0.tx_history[2]},  64'h6C);
        check("byte 3  'l'",  {56'b0, dut.uart0.tx_history[3]},  64'h6C);
        check("byte 4  'o'",  {56'b0, dut.uart0.tx_history[4]},  64'h6F);
        check("byte 5  ','",  {56'b0, dut.uart0.tx_history[5]},  64'h2C);
        check("byte 6  ' '",  {56'b0, dut.uart0.tx_history[6]},  64'h20);
        check("byte 7  'W'",  {56'b0, dut.uart0.tx_history[7]},  64'h57);
        check("byte 8  'o'",  {56'b0, dut.uart0.tx_history[8]},  64'h6F);
        check("byte 9  'r'",  {56'b0, dut.uart0.tx_history[9]},  64'h72);
        check("byte 10 'l'",  {56'b0, dut.uart0.tx_history[10]}, 64'h6C);
        check("byte 11 'd'",  {56'b0, dut.uart0.tx_history[11]}, 64'h64);
        check("byte 12 '!'",  {56'b0, dut.uart0.tx_history[12]}, 64'h21);
        check("byte 13 (LF)", {56'b0, dut.uart0.tx_history[13]}, 64'h0A);

        $display("");
        $display("soc_c_regression_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_c_regression_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
