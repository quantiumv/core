// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: soc -- the actual "hello world over iverilog" milestone
 *
 * Unlike core_wb_tb.sv (hand-assembled instructions poked directly into
 * the SRAM), this instantiates the real top-level design/soc.sv and
 * relies entirely on wb4_sram.sv's own $readmemh of firmware/crt0.hex --
 * i.e. this exercises the REAL toolchain-built firmware image, not a
 * synthetic one. Must be run from a directory one level below the repo
 * root (e.g. design/) so wb4_sram.sv's hardcoded "../firmware/crt0.hex"
 * path resolves -- see that file's own $readmemh call.
 *
 * If firmware/crt0.hex doesn't exist yet (firmware/Makefile hasn't been
 * run), $readmemh prints a non-fatal ERROR and the simulation continues
 * with SRAM still zero-filled. An all-zero instruction word doesn't
 * match any defined opcode (see testbench/riscv_encode.sv's OPC_* list --
 * none of them are 7'b0000000), so the core just decodes INVALID forever
 * and pc free-runs without ever reaching ebreak -- this test times out
 * rather than false-passing, which is the correct/honest outcome: there
 * was no real firmware to have printed anything.
 */
module soc_tb;

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

    initial begin
        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.core0.halted === 1'b1);
            begin
                repeat (300) @(posedge clk);
                $display("TIMEOUT: dut.core0.halted never went high -- is firmware/crt0.hex built?");
                $finish;
            end
        join_any
        #1;

        check("UART received 14 bytes",   {56'b0, dut.uart0.tx_history_count}, 64'd14);
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
        $display("soc_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("soc_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
