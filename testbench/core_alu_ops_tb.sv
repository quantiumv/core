// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, register-immediate / register-register ALU ops
 *
 * First integration test -- exercises the plain fetch -> decode -> ALU ->
 * writeback path only, no memory or branch/jump complexity yet (those
 * are added one at a time by the testbenches after this one).
 *
 * Instructions are hand-encoded via riscv_encode.sv and poked directly
 * into imem0 -- no riscv64-unknown-elf toolchain dependency for this
 * stage.
 */
module core_alu_ops_tb;

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
         * addi x1, x0, 5        x1 = 5
         * addi x2, x0, -3       x2 = -3  (negative I-immediate sign-extension)
         * add  x3, x1, x2       x3 = 5 + (-3) = 2
         * sub  x4, x1, x2       x4 = 5 - (-3) = 8
         * slti x5, x2, 0        x5 = (x2 < 0) ? 1 : 0 = 1  (signed compare, negative operand)
         * slli x6, x1, 2        x6 = 5 << 2 = 20  (shamt-routing regression: the old bug read
         *                                          the whole imm field as shamt, not just bits[24:20])
         * srai x7, x2, 1        x7 = (-3) >>> 1 = -2  (needs BOTH the shamt fix and the ALU's
         *                                              SRA fix to land on the right answer)
         * ebreak
         */
        dut.imem0.mem[0] = encode_i(32'sd5, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM);
        dut.imem0.mem[1] = encode_i(-32'sd3, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);
        dut.imem0.mem[2] = encode_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, `OPC_OP);
        dut.imem0.mem[3] = encode_r(7'b0100000, 5'd2, 5'd1, 3'b000, 5'd4, `OPC_OP);
        dut.imem0.mem[4] = encode_i(32'sd0, 5'd2, 3'b010, 5'd5, `OPC_OP_IMM);
        dut.imem0.mem[5] = encode_shift64(6'b000000, 6'd2, 5'd1, 3'b001, 5'd6, `OPC_OP_IMM);
        dut.imem0.mem[6] = encode_shift64(6'b010000, 6'd1, 5'd2, 3'b101, 5'd7, `OPC_OP_IMM);
        dut.imem0.mem[7] = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}; // ebreak

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

        check_reg("x1 (addi positive)",    1, 64'd5);
        check_reg("x2 (addi negative)",    2, -64'sd3);
        check_reg("x3 (add)",              3, 64'd2);
        check_reg("x4 (sub)",              4, 64'd8);
        check_reg("x5 (slti, neg < 0)",    5, 64'd1);
        check_reg("x6 (slli shamt route)", 6, 64'd20);
        check_reg("x7 (srai neg, fixed)",  7, -64'sd2);

        $display("");
        $display("core_alu_ops_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_alu_ops_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
