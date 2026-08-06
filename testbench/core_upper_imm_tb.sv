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

    wb4_sram #(.num_words(128)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .ack_o(wb_ack), .err_o(wb_err), .cyc_i(wb_cyc), .stb_i(wb_stb), .we_i(wb_we)
    );

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
        #1; // run after wb4_sram's own time-0 init (zero-fill + $readmemh) -- see core_wb_tb.sv

        /*
         * lui x1, 0xFFFFF      x1 = 0xFFFFFFFFFFFFF000  (bit 19 set -> must sign-extend
         *                       negative; the old bug never shifted at all, so this would
         *                       have produced 0x00000000000FFFFF instead)
         * lui x2, 0x00001      x2 = 0x0000000000001000  (bit 19 clear -> stays positive,
         *                       contrasting case)
         * auipc x3, 0x00001    at PC=0x8: x3 = 0x8 + 0x1000 = 0x1008
         * ebreak
         */
        sram0.memory[0] = {encode_u(20'h00001, 5'd2, `OPC_LUI),
                            encode_u(20'hFFFFF, 5'd1, `OPC_LUI)};
        sram0.memory[1] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // ebreak
                            encode_u(20'h00001, 5'd3, `OPC_AUIPC)};

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (dut.halted === 1'b1);
            begin
                repeat (150) @(posedge clk);
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
