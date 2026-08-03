// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, LUI / AUIPC
 *
 * Adds only the U-type operand-mux subtlety on top of core_alu_ops_tb's
 * plain path -- see the AUIPC comment in core.sv for the full story on
 * why AUIPC needs both ALU operands swapped, not just A.
 */
module core_upper_imm_tb;

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
         * lui x1, 0xFFFFF      x1 = 0xFFFFFFFFFFFFF000  (bit 19 set -> must sign-extend
         *                       negative; the old bug never shifted at all, so this would
         *                       have produced 0x00000000000FFFFF instead)
         * lui x2, 0x00001      x2 = 0x0000000000001000  (bit 19 clear -> stays positive,
         *                       contrasting case)
         * auipc x3, 0x00001    at PC=0x8: x3 = 0x8 + 0x1000 = 0x1008
         * ebreak
         */
        dut.imem0.mem[0] = encode_u(20'hFFFFF, 5'd1, `OPC_LUI);
        dut.imem0.mem[1] = encode_u(20'h00001, 5'd2, `OPC_LUI);
        dut.imem0.mem[2] = encode_u(20'h00001, 5'd3, `OPC_AUIPC);
        dut.imem0.mem[3] = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}; // ebreak

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

        check_reg("x1 (lui, bit19 set -> negative)", 1, 64'hFFFFFFFFFFFFF000);
        check_reg("x2 (lui, bit19 clear -> positive)", 2, 64'h0000000000001000);
        check_reg("x3 (auipc, pc + imm)", 3, 64'h0000000000001008);

        $display("");
        $display("core_upper_imm_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_upper_imm_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
