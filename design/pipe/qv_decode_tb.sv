// SPDX-License-Identifier: MIT

`include "riscv_encode.sv"

/*
 * qv_decode_tb -- standalone test for design/pipe/qv_decode.sv.
 *
 * Two layers of checking per instruction:
 *   - structural: the decoder code, alu_op, rs1/rs2/rd selects, the
 *     *_used flags, rd_wen and the fault fields;
 *   - semantic: operands resolved from the uop against a model register
 *     file (rsN_used ? R[rsN] : immN -- exactly what issue will do), run
 *     through a real alu.sv plus qv_exu_alu's is_word truncation, and
 *     compared against a golden result
 *     computed from the instruction's architectural meaning. This checks
 *     that imm1/imm2 carry the right value (sign extension, shift
 *     amounts) without the test depending on decoder.sv's internal
 *     immediate representation.
 */
module qv_decode_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic      iq_valid = 1'b0;
    fe_instr_t iq_data  = '0;
    logic      iq_pop;
    logic      valid;
    uop_t      uop;
    logic      issue_ready = 1'b1;
    logic      flush = 1'b0;

    qv_decode dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_iq_valid(iq_valid), .i_iq_data(iq_data), .o_iq_pop(iq_pop),
        .o_valid(valid), .o_uop(uop), .i_issue_ready(issue_ready)
    );

    // ---------------- semantic check: model regfile + real ALU ----------------
    logic [63:0] R [0:31];
    function automatic logic [63:0] sx32(input logic [63:0] x);
        return {{32{x[31]}}, x[31:0]};
    endfunction

    logic [63:0] op_a, op_b, alu_y, result;
    assign op_a = uop.rs1_used ? R[uop.rs1] : uop.imm1;
    assign op_b = uop.rs2_used ? R[uop.rs2] : uop.imm2;
    alu alu0 (.i_operand_A(op_a), .i_operation(uop.alu_op), .i_operand_B(op_b), .o_result(alu_y));
    assign result = uop.is_word ? sx32(alu_y) : alu_y;

    // feed one instruction, let decode register it, leave it held in the slot
    task automatic feed(input logic [31:0] instr, input logic xcpt = 1'b0, input logic [3:0] cause = 4'd0);
        @(negedge clk);
        issue_ready        = 1'b1;
        iq_valid           = 1'b1;
        iq_data            = '0;
        iq_data.pc         = 64'h1000;
        iq_data.raw        = instr;
        iq_data.xcpt       = xcpt;
        iq_data.xcpt_cause = cause;
        @(posedge clk);
        #1;
        iq_valid = 1'b0;
    endtask

    task automatic expect_alu(
        input string name, input logic [31:0] instr, input logic [6:0] exp_code,
        input logic [4:0] exp_rd, input logic [4:0] exp_rs1, input logic exp_rs1_used,
        input logic [4:0] exp_rs2, input logic exp_rs2_used, input logic [63:0] golden
    );
        feed(instr);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": rd"}, {59'b0, uop.rd}, {59'b0, exp_rd});
        check({name, ": rs1"}, {59'b0, uop.rs1}, {59'b0, exp_rs1});
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, {63'b0, exp_rs1_used});
        check({name, ": rs2"}, {59'b0, uop.rs2}, {59'b0, exp_rs2});
        check({name, ": rs2_used"}, {63'b0, uop.rs2_used}, {63'b0, exp_rs2_used});
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, 64'd1);
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
        check({name, ": pc"}, uop.pc, 64'h1000);
        check({name, ": raw"}, {32'b0, uop.raw}, {32'b0, instr});
        check({name, ": result"}, result, golden);
    endtask

    task automatic expect_fault(input string name, input logic [31:0] instr,
                                input logic xcpt_in, input logic [3:0] cause_in, input logic [3:0] exp_cause);
        feed(instr, xcpt_in, cause_in);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": fault"}, {63'b0, uop.xcpt}, 64'd1);
        check({name, ": cause"}, {60'b0, uop.xcpt_cause}, {60'b0, exp_cause});
        check({name, ": no rd write"}, {63'b0, uop.rd_wen}, 64'd0);
    endtask

    localparam logic [6:0] OP = `OPC_OP, OPI = `OPC_OP_IMM, OP32 = `OPC_OP_32, OPI32 = `OPC_OP_IMM_32;
    localparam logic [6:0] F7_0 = 7'b0000000, F7_1 = 7'b0100000, F7_M = 7'b0000001;

    logic [63:0]  a, b;
    logic [127:0] prod;
    int imm;

    initial begin
        for (int i = 0; i < 32; i++) R[i] = 64'h0123_4567_89AB_CDEF ^ (64'(i) * 64'h9E37_79B9_7F4A_7C15);
        R[0]  = '0;
        R[6]  = 64'h8000_0000_0000_0010;      // negative
        R[7]  = 64'd100;
        R[8]  = -64'd5;
        R[9]  = 64'h0000_0000_FFFF_FFFF;
        R[10] = 64'h00F0_0F00_F00F_0FF0;

        repeat (2) @(posedge clk);
        #1 rst = 1'b0;

        // ---------------- R-type ----------------
        a = R[7];  b = R[8];
        expect_alu("ADD",  encode_r(F7_0, 8, 7, 3'b000, 5, OP), `INSTR_CODE(ADD),  5, 7, 1, 8, 1, a + b);
        expect_alu("SUB",  encode_r(F7_1, 8, 7, 3'b000, 5, OP), `INSTR_CODE(SUB),  5, 7, 1, 8, 1, a - b);
        a = R[6];  b = R[7];
        expect_alu("SLT",  encode_r(F7_0, 7, 6, 3'b010, 11, OP), `INSTR_CODE(SLT),  11, 6, 1, 7, 1,
                   64'($signed(a) < $signed(b)));
        expect_alu("SLTU", encode_r(F7_0, 7, 6, 3'b011, 11, OP), `INSTR_CODE(SLTU), 11, 6, 1, 7, 1,
                   64'(a < b));
        a = R[9];  b = R[10];
        expect_alu("XOR",  encode_r(F7_0, 10, 9, 3'b100, 12, OP), `INSTR_CODE(XOR), 12, 9, 1, 10, 1, a ^ b);
        expect_alu("OR",   encode_r(F7_0, 10, 9, 3'b110, 12, OP), `INSTR_CODE(OR),  12, 9, 1, 10, 1, a | b);
        expect_alu("AND",  encode_r(F7_0, 10, 9, 3'b111, 12, OP), `INSTR_CODE(AND), 12, 9, 1, 10, 1, a & b);
        a = R[6];  b = R[7];                                   // shift amount = 100 & 63 = 36
        expect_alu("SLL",  encode_r(F7_0, 7, 6, 3'b001, 13, OP), `INSTR_CODE(SLL), 13, 6, 1, 7, 1, a << b[5:0]);
        expect_alu("SRL",  encode_r(F7_0, 7, 6, 3'b101, 13, OP), `INSTR_CODE(SRL), 13, 6, 1, 7, 1, a >> b[5:0]);
        expect_alu("SRA",  encode_r(F7_1, 7, 6, 3'b101, 13, OP), `INSTR_CODE(SRA), 13, 6, 1, 7, 1,
                   64'($signed(a) >>> b[5:0]));
        // x0 as a source reads as the immediate 0, never a register
        a = R[7];
        expect_alu("ADD rs2=x0", encode_r(F7_0, 0, 7, 3'b000, 14, OP), `INSTR_CODE(ADD), 14, 7, 1, 0, 0, a);
        expect_alu("SUB rs1=x0", encode_r(F7_1, 7, 0, 3'b000, 14, OP), `INSTR_CODE(SUB), 14, 0, 0, 7, 1, -a);
        // dest x0 still decodes as a writing instruction (regfile ignores x0)
        expect_alu("ADD rd=x0", encode_r(F7_0, 8, 7, 3'b000, 0, OP), `INSTR_CODE(ADD), 0, 7, 1, 8, 1, R[7] + R[8]);

        // ---------------- I-type ----------------
        a = R[7];
        imm = -3;
        expect_alu("ADDI neg", encode_i(imm, 7, 3'b000, 15, OPI), `INSTR_CODE(ADDI), 15, 7, 1, 0, 0, a + 64'(imm));
        imm = 2047;
        expect_alu("ADDI max", encode_i(imm, 7, 3'b000, 15, OPI), `INSTR_CODE(ADDI), 15, 7, 1, 0, 0, a + 64'(imm));
        imm = -2048;
        expect_alu("ADDI x0 (li)", encode_i(imm, 0, 3'b000, 15, OPI), `INSTR_CODE(ADDI), 15, 0, 0, 0, 0, 64'(imm));
        a = R[6];
        imm = -1;
        expect_alu("SLTI",  encode_i(imm, 6, 3'b010, 16, OPI), `INSTR_CODE(SLTI),  16, 6, 1, 0, 0,
                   64'($signed(a) < imm));
        expect_alu("SLTIU", encode_i(imm, 6, 3'b011, 16, OPI), `INSTR_CODE(SLTIU), 16, 6, 1, 0, 0,
                   64'(a < 64'(imm)));                     // -1 sign-extends to all ones, compared unsigned
        a = R[10];
        imm = -1366;                                       // 0xAAA, bit 11 set
        expect_alu("XORI", encode_i(imm, 10, 3'b100, 17, OPI), `INSTR_CODE(XORI), 17, 10, 1, 0, 0, a ^ 64'(imm));
        expect_alu("ORI",  encode_i(imm, 10, 3'b110, 17, OPI), `INSTR_CODE(ORI),  17, 10, 1, 0, 0, a | 64'(imm));
        expect_alu("ANDI", encode_i(imm, 10, 3'b111, 17, OPI), `INSTR_CODE(ANDI), 17, 10, 1, 0, 0, a & 64'(imm));
        a = R[6];
        expect_alu("SLLI 37", encode_shift64(6'b000000, 6'd37, 6, 3'b001, 18, OPI), `INSTR_CODE(SLLI), 18, 6, 1, 0, 0,
                   a << 37);
        expect_alu("SRLI 37", encode_shift64(6'b000000, 6'd37, 6, 3'b101, 18, OPI), `INSTR_CODE(SRLI), 18, 6, 1, 0, 0,
                   a >> 37);
        expect_alu("SRAI 37", encode_shift64(6'b010000, 6'd37, 6, 3'b101, 18, OPI), `INSTR_CODE(SRAI), 18, 6, 1, 0, 0,
                   64'($signed(a) >>> 37));
        expect_alu("SRAI 63", encode_shift64(6'b010000, 6'd63, 6, 3'b101, 18, OPI), `INSTR_CODE(SRAI), 18, 6, 1, 0, 0,
                   64'($signed(a) >>> 63));

        // ---------------- *W forms ----------------
        // operands chosen so the 64-bit result differs from the 32-bit one
        a = R[9];  b = R[7];                                   // 0xFFFFFFFF + 100 carries out of bit 31
        expect_alu("ADDW", encode_r(F7_0, 7, 9, 3'b000, 19, OP32), `INSTR_CODE(ADDW), 19, 9, 1, 7, 1, sx32(a + b));
        a = R[7];  b = R[6];
        expect_alu("SUBW", encode_r(F7_1, 6, 7, 3'b000, 19, OP32), `INSTR_CODE(SUBW), 19, 7, 1, 6, 1, sx32(a - b));
        a = R[10];
        imm = 16;                                              // 0xF00F0FF0 + 16: bit 31 set -> negative
        expect_alu("ADDIW", encode_i(imm, 10, 3'b000, 19, OPI32), `INSTR_CODE(ADDIW), 19, 10, 1, 0, 0,
                   sx32(a + 64'(imm)));
        a = R[10]; b = R[7];                                   // shift amount = 100 & 31 = 4
        expect_alu("SLLW", encode_r(F7_0, 7, 10, 3'b001, 20, OP32), `INSTR_CODE(SLLW), 20, 10, 1, 7, 1,
                   sx32(64'(a[31:0] << b[4:0])));
        expect_alu("SRLW", encode_r(F7_0, 7, 10, 3'b101, 20, OP32), `INSTR_CODE(SRLW), 20, 10, 1, 7, 1,
                   sx32(64'(a[31:0] >> b[4:0])));
        expect_alu("SRAW", encode_r(F7_1, 7, 10, 3'b101, 20, OP32), `INSTR_CODE(SRAW), 20, 10, 1, 7, 1,
                   sx32(64'($signed(a[31:0]) >>> b[4:0])));
        expect_alu("SRLW by 0 (sign of bit 31)", encode_r(F7_0, 0, 10, 3'b101, 20, OP32), `INSTR_CODE(SRLW),
                   20, 10, 1, 0, 0, sx32(a));
        expect_alu("SLLIW 31", encode_shift32w(F7_0, 5'd31, 7, 3'b001, 21, OPI32), `INSTR_CODE(SLLIW),
                   21, 7, 1, 0, 0, sx32(64'(R[7][31:0] << 31)));
        expect_alu("SRLIW 0", encode_shift32w(F7_0, 5'd0, 10, 3'b101, 21, OPI32), `INSTR_CODE(SRLIW),
                   21, 10, 1, 0, 0, sx32(a));
        expect_alu("SRAIW 31", encode_shift32w(F7_1, 5'd31, 10, 3'b101, 21, OPI32), `INSTR_CODE(SRAIW),
                   21, 10, 1, 0, 0, sx32(64'($signed(a[31:0]) >>> 31)));

        // ---------------- LUI / AUIPC ----------------
        expect_alu("LUI neg", encode_u(20'h80001, 22, `OPC_LUI), `INSTR_CODE(LUI), 22, 0, 0, 0, 0,
                   64'hFFFF_FFFF_8000_1000);
        expect_alu("LUI pos", encode_u(20'h12345, 22, `OPC_LUI), `INSTR_CODE(LUI), 22, 0, 0, 0, 0,
                   64'h0000_0000_1234_5000);
        expect_alu("AUIPC pos", encode_u(20'h12345, 23, `OPC_AUIPC), `INSTR_CODE(AUIPC), 23, 0, 0, 0, 0,
                   64'h1000 + 64'h1234_5000);
        expect_alu("AUIPC neg", encode_u(20'hFFFFE, 23, `OPC_AUIPC), `INSTR_CODE(AUIPC), 23, 0, 0, 0, 0,
                   64'h1000 - 64'h2000);

        // ---------------- multiply ----------------
        a = R[6];  b = R[8];                                   // negative x negative
        prod = $signed({{64{a[63]}}, a}) * $signed({{64{b[63]}}, b});
        expect_alu("MUL",    encode_r(F7_M, 8, 6, 3'b000, 24, OP), `INSTR_CODE(MUL),    24, 6, 1, 8, 1, a * b);
        expect_alu("MULH",   encode_r(F7_M, 8, 6, 3'b001, 24, OP), `INSTR_CODE(MULH),   24, 6, 1, 8, 1, prod[127:64]);
        prod = {{64{a[63]}}, a} * {64'b0, b};
        expect_alu("MULHSU", encode_r(F7_M, 8, 6, 3'b010, 24, OP), `INSTR_CODE(MULHSU), 24, 6, 1, 8, 1, prod[127:64]);
        prod = {64'b0, a} * {64'b0, b};
        expect_alu("MULHU",  encode_r(F7_M, 8, 6, 3'b011, 24, OP), `INSTR_CODE(MULHU),  24, 6, 1, 8, 1, prod[127:64]);
        a = R[9];  b = R[10];
        expect_alu("MULW",   encode_r(F7_M, 10, 9, 3'b000, 25, OP32), `INSTR_CODE(MULW), 25, 9, 1, 10, 1, sx32(a * b));

        // ---------------- not implemented / faults ----------------
        expect_fault("LW (not built yet)",    encode_i(8, 7, 3'b010, 5, `OPC_LOAD), 1'b0, 4'd0, 4'd2);
        expect_fault("DIV (not built yet)",   encode_r(F7_M, 8, 7, 3'b100, 5, OP), 1'b0, 4'd0, 4'd2);
        expect_fault("BEQ (not built yet)",   encode_b(8, 8, 7, 3'b000, `OPC_BRANCH), 1'b0, 4'd0, 4'd2);
        expect_fault("all-zero (illegal)",    32'h0000_0000, 1'b0, 4'd0, 4'd2);
        expect_fault("fetch fault on a valid instr", encode_r(F7_0, 8, 7, 3'b000, 5, OP), 1'b1, 4'd1, 4'd1);
        expect_fault("fetch fault beats illegal", 32'h0000_0000, 1'b1, 4'd1, 4'd1);

        // ---------------- pipeline register behavior ----------------
        // held while issue isn't ready; IQ not popped meanwhile
        feed(encode_i(1, 7, 3'b000, 20, OPI));
        @(negedge clk);
        issue_ready = 1'b0;
        iq_valid    = 1'b1;
        iq_data.raw = encode_i(2, 7, 3'b000, 21, OPI);
        #1;
        check("stall: no IQ pop while full and issue not ready", {63'b0, iq_pop}, 64'd0);
        @(posedge clk); #1;
        check("stall: held uop unchanged", {59'b0, uop.rd}, 64'd20);
        @(negedge clk);
        issue_ready = 1'b1;
        #1;
        check("drain+refill: IQ popped the same cycle issue takes the slot", {63'b0, iq_pop}, 64'd1);
        @(posedge clk); #1;
        check("drain+refill: next uop loaded", {59'b0, uop.rd}, 64'd21);
        check("drain+refill: still valid", {63'b0, valid}, 64'd1);
        iq_valid = 1'b0;
        @(posedge clk); #1;
        check("drain: empty once issue takes it and IQ is empty", {63'b0, valid}, 64'd0);
        // flush clears a held uop
        feed(encode_i(3, 7, 3'b000, 22, OPI));
        @(negedge clk);
        issue_ready = 1'b0;
        flush       = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        check("flush: slot cleared", {63'b0, valid}, 64'd0);

        $display("");
        $display("qv_decode_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_decode_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: qv_decode_tb");
        $finish;
    end
endmodule
