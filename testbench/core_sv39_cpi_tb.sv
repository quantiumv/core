// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: what Sv39 costs, in cycles, on the same loop. One loop of
 * 300 iterations (ALU, a load, a store, a branch: 8 instructions each) at VA = PA
 * 0x400, run twice via core_wb4_sram_harness (flat memory):
 *   A. in M-mode, nothing translated;
 *   B. in S-mode under Sv39, an identity map made of one 1 GiB leaf (the loop's
 *      code and data are all inside it), the TLBs warm after the first
 *      iteration.
 * The cycles between the first loop instruction retiring and the EBREAK trap are
 * counted for both and printed. A pipelined core pays an extra cycle per
 * translated fetch dword and per translated access (the answer is registered
 * before it is used); the FSM translates inside its states. The only check is
 * that both programs ran (same result registers) and that translation does
 * not cost more than double, so a gross regression shows; the numbers are for
 * the README's CPI table.
 */
module core_sv39_cpi_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    function automatic logic [31:0] enc_or(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000000, rs2, rs1, 3'b110, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_add(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000000, rs2, rs1, 3'b000, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_xor(input logic [4:0] rd, rs1, rs2);
        return encode_r(7'b0000000, rs2, rs1, 3'b100, rd, `OPC_OP);
    endfunction
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b000, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_slli(input logic [4:0] rd, rs1, input logic [5:0] shamt);
        return encode_shift64(6'b0, shamt, rs1, 3'b001, rd, `OPC_OP_IMM);
    endfunction
    function automatic logic [31:0] enc_csrrw(input logic [11:0] csr, input logic [4:0] rs1);
        return encode_csr(csr, rs1, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM);
    endfunction
    function automatic logic [31:0] enc_lui(input logic [4:0] rd, input logic [19:0] imm20);
        return {imm20, rd, `OPC_LUI};
    endfunction
    function automatic logic [31:0] enc_ld(input logic [4:0] rd, rs1, input int imm);
        return encode_i(imm, rs1, 3'b011, rd, `OPC_LOAD);
    endfunction
    function automatic logic [31:0] enc_sd(input logic [4:0] rs2, rs1, input int imm);
        return encode_s(imm, rs2, rs1, 3'b011, `OPC_STORE);
    endfunction
    function automatic logic [31:0] enc_blt(input logic [4:0] rs1, rs2, input int imm);
        return encode_b(imm, rs2, rs1, 3'b100, `OPC_BRANCH);
    endfunction
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input int imm);
        return encode_j(imm, rd, `OPC_JAL);
    endfunction
    localparam logic [31:0] EBREAK_INSN = {11'b0, 1'b1, 13'b0, `OPC_SYSTEM};
    localparam logic [31:0] NOP_INSN    = 32'h00000013;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    core_wb4_sram_harness #(.NUM_WORDS(8192)) dut_a (.clk(clk), .rst(rst));
    core_wb4_sram_harness #(.NUM_WORDS(8192)) dut_b (.clk(clk), .rst(rst));
    logic halted_a = 1'b0, halted_b = 1'b0;
    // (an EBREAK is a trap to mtvec = 0, where the program starts over: the results are read at the first one)
    logic [63:0] a_x10, a_x5, b_x10, b_x5;
    always @(posedge clk) if (!halted_a && dut_a.core0.trap_taken && dut_a.core0.is_ebreak) begin
        halted_a <= 1'b1; a_x10 <= dut_a.core0.regfile0.gp_registers[10]; a_x5 <= dut_a.core0.regfile0.gp_registers[5];
    end
    always @(posedge clk) if (!halted_b && dut_b.core0.trap_taken && dut_b.core0.is_ebreak) begin
        halted_b <= 1'b1; b_x10 <= dut_b.core0.regfile0.gp_registers[10]; b_x5 <= dut_b.core0.regfile0.gp_registers[5];
    end
    wire halted = halted_a && halted_b;
    `include "halt_wait.sv"

    // cycles from the first retirement of the loop's first instruction to the EBREAK trap
    int cyc = 0;
    int start_a = -1, start_b = -1, end_a = -1, end_b = -1;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (start_a < 0 && dut_a.core0.commit_now && dut_a.core0.pc == 64'h40C) start_a <= cyc;
        if (start_b < 0 && dut_b.core0.commit_now && dut_b.core0.pc == 64'h40C) start_b <= cyc;
        if (end_a   < 0 && dut_a.core0.trap_taken && dut_a.core0.is_ebreak)     end_a   <= cyc;
        if (end_b   < 0 && dut_b.core0.trap_taken && dut_b.core0.is_ebreak)     end_b   <= cyc;
    end

    // the loop: 300 iterations of 8 instructions, at 0x400
    task automatic loop_code(input int which);
        logic [63:0] w [0:5];
        w[0] = {enc_addi(5'd11,5'd0,300), enc_addi(5'd10,5'd0,0)};              // x10 = i, x11 = N
        w[1] = {enc_addi(5'd1,5'd1,1), enc_lui(5'd12,20'h8)};                    // x12 = 0x8000 (data) ; loop: x1++
        w[2] = {enc_xor(5'd3,5'd2,5'd1), enc_add(5'd2,5'd1,5'd1)};
        w[3] = {enc_add(5'd5,5'd4,5'd3), enc_ld(5'd4,5'd12,0)};
        w[4] = {enc_addi(5'd10,5'd10,1), enc_sd(5'd5,5'd12,8)};
        w[5] = {EBREAK_INSN, enc_blt(5'd10,5'd11,-28)};                          // loop back to 0x40C ; then the EBREAK at 0x42C
        for (int i = 0; i < 6; i++) begin
            if (which == 0) dut_a.sram0.memory[128 + i] = w[i]; else dut_b.sram0.memory[128 + i] = w[i];
        end
        if (which == 0) dut_a.sram0.memory[4096] = 64'h0123_4567_89AB_CDEF; else dut_b.sram0.memory[4096] = 64'h0123_4567_89AB_CDEF;
    endtask

    initial begin
        rst = 1;
        #1;
        // A: M-mode, straight to the loop
        dut_a.sram0.memory[0] = {NOP_INSN, enc_jal(5'd0, 1024)};
        loop_code(0);
        // B: M-mode setup, then S-mode under Sv39 with an identity gigapage
        // (x13..x15 and x4 are the setup's; the loop's registers x1..x5, x10..x12 are not touched)
        dut_b.sram0.memory[0] = {enc_slli(5'd13,5'd13,6'd60), enc_addi(5'd13,5'd0,8)};
        dut_b.sram0.memory[1] = {enc_or(5'd13,5'd13,5'd14), enc_addi(5'd14,5'd0,1)};
        dut_b.sram0.memory[2] = {enc_addi(5'd15,5'd0,1), enc_csrrw(`CSR_SATP,5'd13)};
        dut_b.sram0.memory[3] = {enc_csrrw(`CSR_MSTATUS,5'd15), enc_slli(5'd15,5'd15,6'd11)};
        dut_b.sram0.memory[4] = {NOP_INSN, enc_addi(5'd4,5'd0,1024)};
        dut_b.sram0.memory[5] = {NOP_INSN, enc_csrrw(`CSR_MEPC,5'd4)};
        dut_b.sram0.memory[6] = {NOP_INSN, `INSTR_HEX_MRET};
        dut_b.sram0.memory[512 + 0] = 64'h0000_0000_0000_00CF;                  // root[0]: a 1 GiB leaf at PA 0, RWX AD, U=0
        loop_code(1);

        @(posedge clk); #1;
        rst = 0;
        wait_halted_or_timeout(30000, "Sv39 CPI test never halted");
        #1;

        check("A: the loop ran 300 times", a_x10, 64'd300);
        check("B: the loop ran 300 times", b_x10, 64'd300);
        check("B: and computed the same", b_x5, a_x5);
        $display("Sv39 cost: loop of %0d instructions: %0d cycles in M-mode, %0d cycles in S-mode under Sv39 (%0d.%02d x)",
                 300 * 8, end_a - start_a, end_b - start_b,
                 (100 * (end_b - start_b)) / (end_a - start_a) / 100, (100 * (end_b - start_b)) / (end_a - start_a) % 100);
        check("translation costs less than double", 64'((end_b - start_b) < 2 * (end_a - start_a)), 64'd1);
        check("translation does not make it faster", 64'((end_b - start_b) >= (end_a - start_a)), 64'd1);
`ifndef QV_REF_AS_CORE
        // before the store buffer this loop took 5113 cycles under Sv39 on the shared bus; the store buffer alone made it
        // 5404, because a load reached the ROB head in the very cycle fetch's translated request began its bus beat
        check("the store buffer does not slow the translated loop (5113 cycles before it)", 64'((end_b - start_b) <= 5200), 64'd1);
        // P10a: fetch keeps the page of its last translation, so the loop's dwords skip their translation phase (5106
        // cycles before, 4216 with it)
        if (`QV_PIPE_FETCH_PAGE_REUSE)
            check("fetch reuses its translated page (5106 cycles without)", 64'((end_b - start_b) <= 4300), 64'd1);
`endif

        $display("");
        $display("core_sv39_cpi_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sv39_cpi_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
