// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, loads and stores
 *
 * Adds the memory subsystem (dmem, byte-enable writes) on top of
 * core_alu_ops_tb's plain path.
 *
 * The negative-offset SW case is the important one: SW's address comes
 * from imm_s (S-type), which had the 12-vs-13-bit zero-pad bug -- LW's
 * address comes from imm_i (I-type), which never had that bug. So
 * storing at a negative S-type offset and reading back from the SAME
 * negative I-type offset is a real regression check: if SW's offset
 * decode is still broken, the two addresses land in different places and
 * the load-back reads back 0 (uninitialized), not the stored value.
 */
module core_load_store_tb;

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
         * addi x1, x0, 0x100    base address for the byte test
         * addi x2, x0, -1       x2 = 0xFFFF...FFFF (low byte = 0xFF)
         * sb   x2, 0(x1)        mem[0x100] = 0xFF
         * lb   x3, 0(x1)        x3 = sext8(0xFF)  = 0xFFFF...FFFF  (signed read)
         * lbu  x4, 0(x1)        x4 = zext8(0xFF)  = 0x0000...00FF  (unsigned read of the SAME byte)
         * sd   x2, 8(x1)        mem[0x108..0x10F] = 0xFFFF...FFFF
         * ld   x5, 8(x1)        x5 = 0xFFFF...FFFF  (full 64-bit round trip)
         *
         * addi x7, x0, 0x200    base address for the negative-offset test
         * addi x8, x0, 0x555    test value
         * sw   x8, -4(x7)       mem[0x1FC] = 0x555  (S-type negative offset -- the regression)
         * lw   x9, -4(x7)       x9 = mem[0x1FC]  (I-type negative offset -- independently correct,
         *                        used here as the check)
         * ebreak
         */
        dut.imem0.mem[0]  = encode_i(32'sh100, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM);
        dut.imem0.mem[1]  = encode_i(-32'sd1, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM);
        dut.imem0.mem[2]  = encode_s(32'sd0, 5'd2, 5'd1, 3'b000, `OPC_STORE);
        dut.imem0.mem[3]  = encode_i(32'sd0, 5'd1, 3'b000, 5'd3, `OPC_LOAD);
        dut.imem0.mem[4]  = encode_i(32'sd0, 5'd1, 3'b100, 5'd4, `OPC_LOAD);
        dut.imem0.mem[5]  = encode_s(32'sd8, 5'd2, 5'd1, 3'b011, `OPC_STORE);
        dut.imem0.mem[6]  = encode_i(32'sd8, 5'd1, 3'b011, 5'd5, `OPC_LOAD);
        dut.imem0.mem[7]  = encode_i(32'sh200, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM);
        dut.imem0.mem[8]  = encode_i(32'sh555, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM);
        dut.imem0.mem[9]  = encode_s(-32'sd4, 5'd8, 5'd7, 3'b010, `OPC_STORE);
        dut.imem0.mem[10] = encode_i(-32'sd4, 5'd7, 3'b010, 5'd9, `OPC_LOAD);
        dut.imem0.mem[11] = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}; // ebreak

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

        check_reg("x3 (lb, signed read of 0xFF)",   3, 64'hFFFFFFFFFFFFFFFF);
        check_reg("x4 (lbu, unsigned read of 0xFF)", 4, 64'h00000000000000FF);
        check_reg("x5 (sd/ld round trip)",           5, 64'hFFFFFFFFFFFFFFFF);
        check_reg("x9 (sw negative offset, verified via lw)", 9, 64'h0000000000000555);

        $display("");
        $display("core_load_store_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_load_store_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
