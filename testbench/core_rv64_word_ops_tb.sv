// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, RV64I word-arithmetic family (the *W and *IW ops)
 *
 * Newest, most RV64I-specific logic -- run last, since everything it
 * depends on (ALU, decoder, regfile, the whole non-word datapath) is
 * already proven by the earlier testbenches.
 *
 * The decisive technique throughout: build one value in x1 whose full
 * 64-bit form is POSITIVE but whose low 32 bits, read as a 32-bit signed
 * value, are NEGATIVE (-1) -- then run both a *W op and its plain 64-bit
 * equivalent on the SAME source register. If *W is truncating correctly,
 * it sees the negative 32-bit view and its result goes negative; if it
 * were (incorrectly) just an alias for the 64-bit op, it would see the
 * positive 64-bit view instead. The two results landing in different
 * registers, computed from identical inputs, is the proof.
 */
module core_rv64_word_ops_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst = 1;

    core dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    task automatic check_reg(string name, int idx, logic [(`WORD_SIZE-1):0] expected);
        if (dut.regfile0.gp_registers[idx] === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, dut.regfile0.gp_registers[idx]);
        end
    endtask

    initial begin
        /*
         * addi x1,x0,-1     x1 = 0xFFFFFFFFFFFFFFFF
         * slli x1,x1,32     x1 = 0xFFFFFFFF00000000
         * srli x1,x1,32     x1 = 0x00000000FFFFFFFF   (setup: positive 64-bit,
         *                                               low 32 bits = -1 as int32)
         *
         * addw x2,x1,x0     x2 = sext32(lo32(x1) + 0) = sext32(0xFFFFFFFF) = 0xFFFF...FFFF  (negative)
         * add  x3,x1,x0     x3 = x1 + 0             = 0x00000000FFFFFFFF                    (stays positive --
         *                                              proves ADD does NOT truncate the way ADDW does)
         *
         * addi x5,x0,4      x5 = 4  (shift amount register)
         * sraw x6,x1,x5     x6 = sext32(arith_shift(lo32(x1),4)) = sext32(0xFFFFFFFF) = 0xFFFF...FFFF (stays negative)
         * srlw x7,x1,x5     x7 = sext32(logic_shift(lo32(x1),4)) = sext32(0x0FFFFFFF) = 0x000...0FFFFFFF
         *                        (positive -- logical shift zero-filled bit 31 of the 32-bit
         *                         result, and THAT bit is what the final sign-extension uses)
         *
         * addiw x9,x1,1     x9 = sext32(lo32(x1) + 1) = sext32(0xFFFFFFFF + 1) = sext32(0) = 0
         *                        (a buggy "just ADD in 64-bit" implementation would instead give
         *                         0x0000000100000000 -- completely different, easy to catch)
         * ebreak
         */
        dut.imem0.mem[0] = encode_i(-32'sd1, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM);
        dut.imem0.mem[1] = encode_shift64(6'b000000, 6'd32, 5'd1, 3'b001, 5'd1, `OPC_OP_IMM); // slli
        dut.imem0.mem[2] = encode_shift64(6'b000000, 6'd32, 5'd1, 3'b101, 5'd1, `OPC_OP_IMM); // srli
        dut.imem0.mem[3] = encode_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd2, `OPC_OP_32);        // addw
        dut.imem0.mem[4] = encode_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd3, `OPC_OP);           // add
        dut.imem0.mem[5] = encode_i(32'sd4, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);                 // addi x5,x0,4
        dut.imem0.mem[6] = encode_r(7'b0100000, 5'd5, 5'd1, 3'b101, 5'd6, `OPC_OP_32);        // sraw
        dut.imem0.mem[7] = encode_r(7'b0000000, 5'd5, 5'd1, 3'b101, 5'd7, `OPC_OP_32);        // srlw
        dut.imem0.mem[8] = encode_i(32'sd1, 5'd1, 3'b000, 5'd9, `OPC_OP_IMM_32);              // addiw
        dut.imem0.mem[9] = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};                                  // ebreak

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (50) @(posedge clk);
                $display("TIMEOUT: dut.halted never went high");
                $finish;
            end
        join_any
        #1;

        check_reg("x1 (setup: positive 64-bit, negative low32)", 1, 64'h00000000FFFFFFFF);
        check_reg("x2 (addw truncates+resigns -> negative)",      2, 64'hFFFFFFFFFFFFFFFF);
        check_reg("x3 (add does NOT truncate -> stays positive)", 3, 64'h00000000FFFFFFFF);
        check_reg("x6 (sraw stays negative)",                     6, 64'hFFFFFFFFFFFFFFFF);
        check_reg("x7 (srlw -> positive after zero-fill)",        7, 64'h000000000FFFFFFF);
        check_reg("x9 (addiw truncates+resigns -> 0, not 2^32)",  9, 64'h0000000000000000);

        $display("");
        $display("core_rv64_word_ops_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_rv64_word_ops_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
