// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, register-immediate / register-register ALU ops
 *
 * First integration test -- exercises the plain fetch -> decode -> ALU ->
 * writeback path only, no branch/jump complexity yet (those are added
 * one at a time by the testbenches after this one).
 *
 * Instructions are hand-encoded via riscv_encode.sv and poked directly
 * into a real wb4_sram instance's memory[] array, packed two 32-bit
 * instructions per 64-bit word (core.sv fetches over the Wishbone bus
 * now, not from a private imem0) -- no riscv64-unknown-elf toolchain
 * dependency for this stage.
 */
module core_alu_ops_tb;

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

    /* No UART/decoder needed -- this test never touches a memory-mapped
     * peripheral, so core is wired straight to a single wb4_sram. */
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

    logic halted = 1'b0;
    always @(posedge clk) if (dut.trap_taken && dut.is_ebreak) halted <= 1'b1;

    initial begin
        #1; // run after wb4_sram's own time-0 init (zero-fill + $readmemh) -- see core_wb_tb.sv

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
        sram0.memory[0] = {encode_i(-32'sd3, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                            encode_i(32'sd5, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        sram0.memory[1] = {encode_r(7'b0100000, 5'd2, 5'd1, 3'b000, 5'd4, `OPC_OP),
                            encode_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, `OPC_OP)};
        sram0.memory[2] = {encode_shift64(6'b000000, 6'd2, 5'd1, 3'b001, 5'd6, `OPC_OP_IMM),
                            encode_i(32'sd0, 5'd2, 3'b010, 5'd5, `OPC_OP_IMM)};
        sram0.memory[3] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // ebreak
                            encode_shift64(6'b010000, 6'd1, 5'd2, 3'b101, 5'd7, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst = 0;

        fork
            wait (halted === 1'b1);
            begin
                repeat (150) @(posedge clk);
                $display("TIMEOUT: EBREAK trap never fired");
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
