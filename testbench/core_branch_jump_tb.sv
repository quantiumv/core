// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, branches and jumps
 *
 * Adds the next-PC mux on top of core_alu_ops_tb's plain path.
 *
 * Every "branch taken" case below uses a skip-sentinel-then-escape
 * pattern, not just a skip: the sentinel write happens if the branch is
 * WRONGLY not taken, followed by an unconditional jump PAST the "landed
 * correctly" instruction. Without the escape jump, a branch that never
 * takes at all would still fall through both instructions sequentially
 * and end up looking identical to a correctly-taken branch (the sentinel
 * gets overwritten by the "landed" value either way) -- the escape jump
 * is what makes the two cases actually distinguishable.
 */
module core_branch_jump_tb;

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
         * addr  idx  instruction                    notes
         *  0     0   addi x1,x0,1
         *  4     1   addi x2,x0,1
         *  8     2   beq  x1,x2,12      -> 20        beq IS taken (1==1)
         * 12     3   addi x3,x0,111                  sentinel: reached only if beq wrongly not-taken
         * 16     4   jal  x0,8          -> 24         escape, only reached from idx3
         * 20     5   addi x3,x0,222                  correct landing; falls through to idx6
         * 24     6   addi x4,x0,-1
         * 28     7   addi x5,x0,1
         * 32     8   blt  x4,x5,12      -> 44         blt IS taken (signed -1 < 1)
         * 36     9   addi x6,x0,111                  sentinel
         * 40    10   jal  x0,8          -> 48         escape
         * 44    11   addi x6,x0,222                  correct landing; falls through to idx12
         * 48    12   bltu x4,x5,12      -> 60         bltu is NOT taken (unsigned huge < 1 is false)
         * 52    13   addi x7,x0,222                  correct fallthrough (bltu not taken)
         * 56    14   jal  x0,8          -> 64         escape, only reached from idx13's correct path
         * 60    15   addi x7,x0,111                  wrong-landing zone; reached only if bltu wrongly taken
         * 64    16   jal  x8,8          -> 72         link(x8) = 64+4 = 68
         * 68    17   addi x9,x0,111                  skipped by the jal above
         * 72    18   addi x11,x0,78                  jal lands here
         * 76    19   jalr x10,x11,7     raw=78+7=85(odd) -> cleared 84; link(x10)=76+4=80
         * 80    20   addi x12,x0,111                 skipped
         * 84    21   addi x12,x0,222                 jalr lands here
         * 88    22   ebreak
         */
        dut.imem0.mem[0]  = encode_i(32'sd1, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM);
        dut.imem0.mem[1]  = encode_i(32'sd1, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);
        dut.imem0.mem[2]  = encode_b(32'sd12, 5'd2, 5'd1, 3'b000, `OPC_BRANCH); // beq
        dut.imem0.mem[3]  = encode_i(32'sd111, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);
        dut.imem0.mem[4]  = encode_j(32'sd8, 5'd0, `OPC_JAL);
        dut.imem0.mem[5]  = encode_i(32'sd222, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM);
        dut.imem0.mem[6]  = encode_i(-32'sd1, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM);
        dut.imem0.mem[7]  = encode_i(32'sd1, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM);
        dut.imem0.mem[8]  = encode_b(32'sd12, 5'd5, 5'd4, 3'b100, `OPC_BRANCH); // blt
        dut.imem0.mem[9]  = encode_i(32'sd111, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        dut.imem0.mem[10] = encode_j(32'sd8, 5'd0, `OPC_JAL);
        dut.imem0.mem[11] = encode_i(32'sd222, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM);
        dut.imem0.mem[12] = encode_b(32'sd12, 5'd5, 5'd4, 3'b110, `OPC_BRANCH); // bltu
        dut.imem0.mem[13] = encode_i(32'sd222, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM);
        dut.imem0.mem[14] = encode_j(32'sd8, 5'd0, `OPC_JAL);
        dut.imem0.mem[15] = encode_i(32'sd111, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM);
        dut.imem0.mem[16] = encode_j(32'sd8, 5'd8, `OPC_JAL);
        dut.imem0.mem[17] = encode_i(32'sd111, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM);
        dut.imem0.mem[18] = encode_i(32'sd78, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM);
        dut.imem0.mem[19] = encode_i(32'sd7, 5'd11, 3'b000, 5'd10, `OPC_JALR);
        dut.imem0.mem[20] = encode_i(32'sd111, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM);
        dut.imem0.mem[21] = encode_i(32'sd222, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM);
        dut.imem0.mem[22] = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}; // ebreak

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (60) @(posedge clk);
                $display("TIMEOUT: dut.halted never went high");
                $finish;
            end
        join_any
        #1;

        check_reg("x3 (beq taken)",              3, 64'd222);
        check_reg("x6 (blt taken, signed)",       6, 64'd222);
        check_reg("x7 (bltu not taken, unsigned)",7, 64'd222);
        check_reg("x8 (jal link value)",          8, 64'd68);
        check_reg("x9 (skipped by jal)",          9, 64'd0);
        check_reg("x10 (jalr link value)",       10, 64'd80);
        check_reg("x12 (jalr LSB-clear fix)",    12, 64'd222);

        $display("");
        $display("core_branch_jump_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_branch_jump_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
