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
    task automatic feed(input logic [31:0] instr, input logic xcpt = 1'b0, input logic [3:0] cause = 4'd0,
                        input logic rvc = 1'b0, input logic pred = 1'b0, input logic [63:0] tgt = '0);
        @(negedge clk);
        issue_ready        = 1'b1;
        iq_valid           = 1'b1;
        iq_data            = '0;
        iq_data.pc         = 64'h1000;
        iq_data.raw        = rvc ? {16'b0, instr[15:0]} : instr;
        iq_data.rvc        = rvc;
        iq_data.pred_taken = pred;
        iq_data.pred_tgt   = tgt;
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

    // a compressed instruction: decoded as its expansion, raw kept as {16'b0, hw}
    task automatic expect_c_alu(
        input string name, input logic [15:0] hw, input logic [6:0] exp_code,
        input logic [4:0] exp_rd, input logic [4:0] exp_rs1, input logic exp_rs1_used,
        input logic [4:0] exp_rs2, input logic exp_rs2_used, input logic [63:0] golden
    );
        feed({16'b0, hw}, 1'b0, 4'd0, 1'b1);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": rd"}, {59'b0, uop.rd}, {59'b0, exp_rd});
        check({name, ": rs1"}, {59'b0, uop.rs1}, {59'b0, exp_rs1});
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, {63'b0, exp_rs1_used});
        check({name, ": rs2"}, {59'b0, uop.rs2}, {59'b0, exp_rs2});
        check({name, ": rs2_used"}, {63'b0, uop.rs2_used}, {63'b0, exp_rs2_used});
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, 64'd1);
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check({name, ": rvc"}, {63'b0, uop.rvc}, 64'd1);
        check({name, ": raw keeps the halfword"}, {32'b0, uop.raw}, {48'b0, hw});
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
        check({name, ": result"}, result, golden);
    endtask

    task automatic expect_bru(
        input string name, input logic [31:0] instr, input logic [6:0] exp_code, input qv_bru_op_e exp_op,
        input logic [4:0] exp_rs1, input logic exp_rs1_used, input logic [4:0] exp_rs2, input logic exp_rs2_used,
        input logic exp_rd_wen, input logic [4:0] exp_rd, input logic [63:0] exp_imm2, input logic [63:0] exp_imm3
    );
        feed(instr);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_BRU});
        check({name, ": bru_op"}, {61'b0, uop.bru_op}, {61'b0, exp_op});
        check({name, ": rs1"}, {59'b0, uop.rs1}, {59'b0, exp_rs1});
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, {63'b0, exp_rs1_used});
        check({name, ": rs2"}, {59'b0, uop.rs2}, {59'b0, exp_rs2});
        check({name, ": rs2_used"}, {63'b0, uop.rs2_used}, {63'b0, exp_rs2_used});
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, {63'b0, exp_rd_wen});
        if (exp_rd_wen) check({name, ": rd"}, {59'b0, uop.rd}, {59'b0, exp_rd});
        if (!exp_rs2_used) check({name, ": imm2"}, uop.imm2, exp_imm2);
        if (exp_op != QV_BR_JALR) check({name, ": imm3"}, uop.imm3, exp_imm3);   // JALR doesn't use imm3
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
    endtask

    task automatic expect_csr(
        input string name, input logic [31:0] instr, input logic [6:0] exp_code, input qv_csr_op_e exp_op,
        input logic [11:0] exp_addr, input logic [4:0] exp_rs1, input logic exp_rs1_used,
        input logic [63:0] exp_imm1, input logic exp_wsup, input logic [4:0] exp_rd
    );
        feed(instr);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_CSR});
        check({name, ": csr_op"}, {62'b0, uop.csr_op}, {62'b0, exp_op});
        check({name, ": csr_addr"}, {52'b0, uop.csr_addr}, {52'b0, exp_addr});
        check({name, ": rs1"}, {59'b0, uop.rs1}, {59'b0, exp_rs1});
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, {63'b0, exp_rs1_used});
        if (!exp_rs1_used) check({name, ": imm1 (uimm)"}, uop.imm1, exp_imm1);
        check({name, ": no rs2"}, {63'b0, uop.rs2_used}, 64'd0);
        check({name, ": imm2 zeroed (ALU pass = source + 0)"}, uop.imm2, 64'd0);
        check({name, ": alu_op ADD"}, {59'b0, uop.alu_op}, {59'b0, `ADD});
        check({name, ": csr_wsup"}, {63'b0, uop.csr_wsup}, {63'b0, exp_wsup});
        check({name, ": serialize"}, {63'b0, uop.serialize}, 64'd1);
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, 64'd1);
        check({name, ": rd"}, {59'b0, uop.rd}, {59'b0, exp_rd});
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
    endtask

    task automatic expect_sys(input string name, input logic [31:0] instr, input logic [6:0] exp_code,
                              input qv_sys_op_e exp_op);
        feed(instr);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_SYS});
        check({name, ": sys_op"}, {61'b0, uop.sys_op}, {61'b0, exp_op});
        check({name, ": no rd write"}, {63'b0, uop.rd_wen}, 64'd0);
        check({name, ": no serialize"}, {63'b0, uop.serialize}, 64'd0);
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
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
    // reserved compressed encodings (c_expand.sv flags each illegal)
    logic [15:0] c_res [0:7] = '{16'h0000, 16'h0008, 16'h6101, 16'h2001,
                                  16'h4002, 16'h6002, 16'h8002, 16'h8000};

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

        // ---------------- branches, JAL, JALR -> BRU ----------------
        // B offsets at both ends of their range; branches never write rd
        expect_bru("BEQ +16",     encode_b(16, 8, 7, 3'b000, `OPC_BRANCH), `INSTR_CODE(BEQ), QV_BR_BEQ,
                   7, 1, 8, 1, 1'b0, 0, 0, 64'd16);
        expect_bru("BNE -4096",   encode_b(-4096, 8, 7, 3'b001, `OPC_BRANCH), `INSTR_CODE(BNE), QV_BR_BNE,
                   7, 1, 8, 1, 1'b0, 0, 0, -64'd4096);
        expect_bru("BLT +4094",   encode_b(4094, 6, 9, 3'b100, `OPC_BRANCH), `INSTR_CODE(BLT), QV_BR_BLT,
                   9, 1, 6, 1, 1'b0, 0, 0, 64'd4094);
        expect_bru("BGE -2",      encode_b(-2, 6, 9, 3'b101, `OPC_BRANCH), `INSTR_CODE(BGE), QV_BR_BGE,
                   9, 1, 6, 1, 1'b0, 0, 0, -64'd2);
        expect_bru("BLTU rs2=x0", encode_b(32, 0, 9, 3'b110, `OPC_BRANCH), `INSTR_CODE(BLTU), QV_BR_BLTU,
                   9, 1, 0, 0, 1'b0, 0, 0, 64'd32);
        expect_bru("BGEU rs1=x0", encode_b(-32, 9, 0, 3'b111, `OPC_BRANCH), `INSTR_CODE(BGEU), QV_BR_BGEU,
                   0, 0, 9, 1, 1'b0, 0, 0, -64'd32);
        // J offsets at both ends; JAL writes the link
        expect_bru("JAL +1048574",  encode_j(1048574, 1, `OPC_JAL), `INSTR_CODE(JAL), QV_BR_JAL,
                   0, 0, 0, 0, 1'b1, 1, 0, 64'd1048574);
        expect_bru("JAL -1048576",  encode_j(-1048576, 5, `OPC_JAL), `INSTR_CODE(JAL), QV_BR_JAL,
                   0, 0, 0, 0, 1'b1, 5, 0, -64'd1048576);
        // JALR: rs1 + I offset (on imm2), writes the link
        expect_bru("JALR -2048(x7)", encode_i(-2048, 7, 3'b000, 5, `OPC_JALR), `INSTR_CODE(JALR), QV_BR_JALR,
                   7, 1, 0, 0, 1'b1, 5, -64'd2048, 0);
        expect_bru("JALR 2047(x7)",  encode_i(2047, 7, 3'b000, 7, `OPC_JALR), `INSTR_CODE(JALR), QV_BR_JALR,
                   7, 1, 0, 0, 1'b1, 7, 64'd2047, 0);
        // a fetch-faulted jump must not reach the BRU, so it can never redirect
        feed(encode_j(64, 1, `OPC_JAL), 1'b1, 4'd1);
        check("faulted JAL: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("faulted JAL: fault", {63'b0, uop.xcpt}, 64'd1);
        check("faulted JAL: no rd write", {63'b0, uop.rd_wen}, 64'd0);

        // ---------------- Zicsr -> CSR ----------------
        expect_csr("CSRRW",  encode_csr(12'h340, 6, 3'b001, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRW),  QV_CSR_RW,
                   12'h340, 6, 1, 0, 1'b0, 5);
        expect_csr("CSRRW rs1=x0 (still writes)", encode_csr(12'h340, 0, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h340, 0, 0, 0, 1'b0, 5);
        expect_csr("CSRRS",  encode_csr(12'h304, 6, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),  QV_CSR_RS,
                   12'h304, 6, 1, 0, 1'b0, 5);
        expect_csr("CSRRS rs1=x0 (read)", encode_csr(12'h304, 0, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),
                   QV_CSR_RS, 12'h304, 0, 0, 0, 1'b1, 5);
        expect_csr("CSRRC",  encode_csr(12'h304, 9, 3'b011, 0, `OPC_SYSTEM), `INSTR_CODE(CSRRC),  QV_CSR_RC,
                   12'h304, 9, 1, 0, 1'b0, 0);
        expect_csr("CSRRC rs1=x0 (read)", encode_csr(12'h304, 0, 3'b011, 7, `OPC_SYSTEM), `INSTR_CODE(CSRRC),
                   QV_CSR_RC, 12'h304, 0, 0, 0, 1'b1, 7);
        expect_csr("CSRRWI", encode_csr(12'h340, 31, 3'b101, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRWI), QV_CSR_RW,
                   12'h340, 0, 0, 64'd31, 1'b0, 5);
        expect_csr("CSRRWI 0 (still writes)", encode_csr(12'h340, 0, 3'b101, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRWI), QV_CSR_RW, 12'h340, 0, 0, 64'd0, 1'b0, 5);
        expect_csr("CSRRSI", encode_csr(12'h344, 17, 3'b110, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRSI), QV_CSR_RS,
                   12'h344, 0, 0, 64'd17, 1'b0, 5);
        expect_csr("CSRRSI 0 (read)", encode_csr(12'h344, 0, 3'b110, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRSI),
                   QV_CSR_RS, 12'h344, 0, 0, 64'd0, 1'b1, 5);
        expect_csr("CSRRCI 0 (read)", encode_csr(12'h344, 0, 3'b111, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRCI),
                   QV_CSR_RC, 12'h344, 0, 0, 64'd0, 1'b1, 5);
        // read-only CSRs: reading is fine, a real write is illegal
        expect_csr("read mhartid", encode_csr(12'hF14, 0, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),
                   QV_CSR_RS, 12'hF14, 0, 0, 0, 1'b1, 5);
        expect_csr("read instret (RSI 0)", encode_csr(12'hC02, 0, 3'b110, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRSI),
                   QV_CSR_RS, 12'hC02, 0, 0, 64'd0, 1'b1, 5);
        expect_fault("write mhartid",        encode_csr(12'hF14, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRS mhartid, x6",    encode_csr(12'hF14, 6, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRSI cycle, 1",      encode_csr(12'hC00, 1, 3'b110, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRWI instret, 0",    encode_csr(12'hC02, 0, 3'b101, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        // debug and trigger CSRs: illegal outside debug mode, even to read
        expect_fault("read dcsr",            encode_csr(12'h7B0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read dscratch1",       encode_csr(12'h7B3, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read tselect",         encode_csr(12'h7A0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read tinfo",           encode_csr(12'h7A4, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        // the neighbours of those ranges are ordinary (unbacked) CSRs
        expect_csr("read 0x7A5", encode_csr(12'h7A5, 0, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),
                   QV_CSR_RS, 12'h7A5, 0, 0, 0, 1'b1, 5);
        expect_csr("write 0x7B4", encode_csr(12'h7B4, 6, 3'b001, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRW),
                   QV_CSR_RW, 12'h7B4, 6, 1, 0, 1'b0, 5);
        // a fetch-faulted CSR op must never reach the CSR file
        feed(encode_csr(12'h340, 6, 3'b001, 5, `OPC_SYSTEM), 1'b1, 4'd1);
        check("faulted CSRRW: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("faulted CSRRW: fault", {63'b0, uop.xcpt}, 64'd1);

        // ---------------- system -> SYS ----------------
        expect_sys("ECALL",  32'h0000_0073, `INSTR_CODE(ECALL),  QV_SYS_ECALL);
        expect_sys("EBREAK", 32'h0010_0073, `INSTR_CODE(EBREAK), QV_SYS_EBREAK);
        expect_sys("MRET",   `INSTR_HEX_MRET, `INSTR_CODE(MRET), QV_SYS_MRET);
        expect_sys("WFI",    `INSTR_HEX_WFI,  `INSTR_CODE(WFI),  QV_SYS_WFI);
        feed(32'h0000_0073, 1'b1, 4'd1);
        check("faulted ECALL: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("faulted ECALL: keeps the fetch cause", {60'b0, uop.xcpt_cause}, 64'd1);

        // ---------------- RVC: expanded by c_expand.sv ----------------
        // compressed registers x8..x15 are R[8..15]; R[8] = -5, R[9] = 0xFFFFFFFF, R[10] = pattern
        expect_c_alu("C.ADDI", encode_c_addi(-3, 8), `INSTR_CODE(ADDI), 8, 8, 1, 0, 0, R[8] - 64'd3);
        expect_c_alu("C.LI", encode_c_li(-32, 11), `INSTR_CODE(ADDI), 11, 0, 0, 0, 0, -64'd32);
        expect_c_alu("C.LUI", encode_c_lui(6'b100001, 12), `INSTR_CODE(LUI), 12, 0, 0, 0, 0,
                     64'hFFFF_FFFF_FFFE_1000);
        expect_c_alu("C.ADDIW", encode_c_addiw(1, 9), `INSTR_CODE(ADDIW), 9, 9, 1, 0, 0, sx32(R[9] + 64'd1));
        expect_c_alu("C.SLLI 33", encode_c_slli(6'd33, 10), `INSTR_CODE(SLLI), 10, 10, 1, 0, 0, R[10] << 33);
        expect_c_alu("C.SRAI 63", encode_c_srai(6'd63, 3'd0), `INSTR_CODE(SRAI), 8, 8, 1, 0, 0,
                     64'($signed(R[8]) >>> 63));
        expect_c_alu("C.ANDI", encode_c_andi(-6, 3'd2), `INSTR_CODE(ANDI), 10, 10, 1, 0, 0, R[10] & -64'd6);
        expect_c_alu("C.MV", encode_c_mv(13, 10), `INSTR_CODE(ADD), 13, 0, 0, 10, 1, R[10]);
        expect_c_alu("C.ADD", encode_c_add(14, 7), `INSTR_CODE(ADD), 14, 14, 1, 7, 1, R[14] + R[7]);
        expect_c_alu("C.SUB", encode_c_ca(1'b0, 2'b00, 3'd1, 3'd2), `INSTR_CODE(SUB), 9, 9, 1, 10, 1,
                     R[9] - R[10]);
        expect_c_alu("C.SUBW", encode_c_ca(1'b1, 2'b00, 3'd0, 3'd1), `INSTR_CODE(SUBW), 8, 8, 1, 9, 1,
                     sx32(R[8] - R[9]));
        // control flow and EBREAK
        feed({16'b0, encode_c_j(-64)}, 1'b0, 4'd0, 1'b1);
        check("C.J: BRU", {61'b0, uop.fu}, {61'b0, QV_FU_BRU});
        check("C.J: JAL op", {61'b0, uop.bru_op}, {61'b0, QV_BR_JAL});
        check("C.J: offset", uop.imm3, -64'd64);
        check("C.J: no link (rd x0)", {59'b0, uop.rd}, 64'd0);
        check("C.J: rvc", {63'b0, uop.rvc}, 64'd1);
        feed({16'b0, encode_c_beqz(-16, 3'd3)}, 1'b0, 4'd0, 1'b1);
        check("C.BEQZ: BRU", {61'b0, uop.fu}, {61'b0, QV_FU_BRU});
        check("C.BEQZ: BEQ op", {61'b0, uop.bru_op}, {61'b0, QV_BR_BEQ});
        check("C.BEQZ: rs1 x11", {59'b0, uop.rs1}, 64'd11);
        check("C.BEQZ: offset", uop.imm3, -64'd16);
        feed({16'b0, encode_c_jalr(5'd7)}, 1'b0, 4'd0, 1'b1);
        check("C.JALR: JALR op", {61'b0, uop.bru_op}, {61'b0, QV_BR_JALR});
        check("C.JALR: links x1", {59'b0, uop.rd}, 64'd1);
        check("C.JALR: rs1 x7", {59'b0, uop.rs1}, 64'd7);
        feed({16'b0, `INSTR_C_EBREAK}, 1'b0, 4'd0, 1'b1);
        check("C.EBREAK: SYS", {61'b0, uop.fu}, {61'b0, QV_FU_SYS});
        check("C.EBREAK: op", {61'b0, uop.sys_op}, {61'b0, QV_SYS_EBREAK});
        check("C.EBREAK: no fault", {63'b0, uop.xcpt}, 64'd0);
        // reserved encodings trap, decoding as the placeholder (no register reads)
        for (int i = 0; i < 8; i++) begin
            feed({16'b0, c_res[i]}, 1'b0, 4'd0, 1'b1);
            check($sformatf("reserved C %04h: fault", c_res[i]), {63'b0, uop.xcpt}, 64'd1);
            check($sformatf("reserved C %04h: cause 2", c_res[i]), {60'b0, uop.xcpt_cause}, 64'd2);
            check($sformatf("reserved C %04h: no rd write", c_res[i]), {63'b0, uop.rd_wen}, 64'd0);
            check($sformatf("reserved C %04h: rs1 0", c_res[i]), {59'b0, uop.rs1}, 64'd0);
            check($sformatf("reserved C %04h: rs2 0", c_res[i]), {59'b0, uop.rs2}, 64'd0);
            check($sformatf("reserved C %04h: raw kept", c_res[i]), {32'b0, uop.raw}, {48'b0, c_res[i]});
            check($sformatf("reserved C %04h: routed to the ALU", c_res[i]), {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        end
        // a fetch fault on a compressed slot keeps cause 1
        feed({16'b0, encode_c_addi(1, 8)}, 1'b1, 4'd1, 1'b1);
        check("faulted C.ADDI: cause 1", {60'b0, uop.xcpt_cause}, 64'd1);
        check("faulted C.ADDI: placeholder, no rs1", {59'b0, uop.rs1}, 64'd0);

        // ---------------- loads, stores, FENCE ----------------
        for (int f3 = 0; f3 < 7; f3++) begin                // LB LH LW LD LBU LHU LWU
            feed(encode_i(-24, 9, 3'(f3), 12, `OPC_LOAD));
            check($sformatf("load f3=%0d: LSU", f3), {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
            check($sformatf("load f3=%0d: is_load", f3), {63'b0, uop.is_load}, 64'd1);
            check($sformatf("load f3=%0d: not a store", f3), {63'b0, uop.is_store}, 64'd0);
            check($sformatf("load f3=%0d: size", f3), {62'b0, uop.mem_size}, 64'(f3 % 4));
            check($sformatf("load f3=%0d: signed", f3), {63'b0, uop.mem_signed}, 64'(f3 < 4));
            check($sformatf("load f3=%0d: base rs1", f3), {59'b0, uop.rs1}, 64'd9);
            check($sformatf("load f3=%0d: rs1 used", f3), {63'b0, uop.rs1_used}, 64'd1);
            check($sformatf("load f3=%0d: offset on imm2", f3), uop.imm2, -64'd24);
            check($sformatf("load f3=%0d: no rs2", f3), {63'b0, uop.rs2_used}, 64'd0);
            check($sformatf("load f3=%0d: writes rd", f3), {63'b0, uop.rd_wen}, 64'd1);
            check($sformatf("load f3=%0d: rd", f3), {59'b0, uop.rd}, 64'd12);
            check($sformatf("load f3=%0d: no fault", f3), {63'b0, uop.xcpt}, 64'd0);
        end
        expect_fault("load f3=7 (reserved)", encode_i(0, 9, 3'd7, 12, `OPC_LOAD), 1'b0, 4'd0, 4'd2);
        for (int f3 = 0; f3 < 4; f3++) begin                // SB SH SW SD
            feed(encode_s(-2048, 6, 9, 3'(f3), `OPC_STORE));
            check($sformatf("store f3=%0d: LSU", f3), {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
            check($sformatf("store f3=%0d: is_store", f3), {63'b0, uop.is_store}, 64'd1);
            check($sformatf("store f3=%0d: not a load", f3), {63'b0, uop.is_load}, 64'd0);
            check($sformatf("store f3=%0d: size", f3), {62'b0, uop.mem_size}, 64'(f3));
            check($sformatf("store f3=%0d: base rs1", f3), {59'b0, uop.rs1}, 64'd9);
            check($sformatf("store f3=%0d: data rs2", f3), {59'b0, uop.rs2}, 64'd6);
            check($sformatf("store f3=%0d: rs2 used", f3), {63'b0, uop.rs2_used}, 64'd1);
            check($sformatf("store f3=%0d: offset on imm3", f3), uop.imm3, -64'd2048);
            check($sformatf("store f3=%0d: no rd write", f3), {63'b0, uop.rd_wen}, 64'd0);
        end
        feed(encode_s(2047, 0, 9, 3'd3, `OPC_STORE));
        check("store x0 data: offset +2047", uop.imm3, 64'd2047);
        check("store x0 data: rs2 not a register", {63'b0, uop.rs2_used}, 64'd0);
        check("store x0 data: stores 0", uop.imm2, 64'd0);
        feed({16'b0, encode_c_lw(7'd8, 3'd1, 3'd2)}, 1'b0, 4'd0, 1'b1);   // c.lw x10, 8(x9)
        check("C.LW: LSU", {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
        check("C.LW: word, signed", {61'b0, uop.mem_signed, uop.mem_size}, 64'b110);
        check("C.LW: offset", uop.imm2, 64'd8);
        feed({16'b0, encode_c_sd(8'd16, 3'd1, 3'd2)}, 1'b0, 4'd0, 1'b1);  // c.sd x10, 16(x9)
        check("C.SD: LSU", {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
        check("C.SD: dword store", {61'b0, uop.is_store, uop.mem_size}, 64'b111);
        check("C.SD: offset", uop.imm3, 64'd16);
        feed(32'h0FF0_000F);                                // fence iorw, iorw
        check("FENCE: ALU no-op", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("FENCE: no rd write", {63'b0, uop.rd_wen}, 64'd0);
        check("FENCE: no fault", {63'b0, uop.xcpt}, 64'd0);
        check("FENCE: no serialize", {63'b0, uop.serialize}, 64'd0);

        feed(32'h0000_100F);                                // fence.i
        check("FENCE.I: SYS", {61'b0, uop.fu}, {61'b0, QV_FU_SYS});
        check("FENCE.I: sys op", {61'b0, uop.sys_op}, {61'b0, QV_SYS_FENCE_I});
        check("FENCE.I: serializes", {63'b0, uop.serialize}, 64'd1);
        check("FENCE.I: no rd write", {63'b0, uop.rd_wen}, 64'd0);
        check("FENCE.I: no fault", {63'b0, uop.xcpt}, 64'd0);
        feed(encode_i(8, 7, 3'b010, 5, `OPC_LOAD), 1'b1, 4'd1);
        check("faulted LW: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});

        // ---------------- the frontend's prediction rides along ----------------
        feed(encode_j(-64, 1, `OPC_JAL), 1'b0, 4'd0, 1'b0, 1'b1, 64'h0FC0);
        check("predicted JAL: pred_taken", {63'b0, uop.pred_taken}, 64'd1);
        check("predicted JAL: pred_tgt", uop.pred_tgt, 64'h0FC0);
        feed({16'b0, encode_c_beqz(-8, 3'd0)}, 1'b0, 4'd0, 1'b1, 1'b1, 64'h0FF8);
        check("predicted C.BEQZ: pred_taken", {63'b0, uop.pred_taken}, 64'd1);
        check("predicted C.BEQZ: pred_tgt", uop.pred_tgt, 64'h0FF8);
        feed(encode_b(8, 1, 2, 3'b000, `OPC_BRANCH));
        check("unpredicted BEQ: pred_taken", {63'b0, uop.pred_taken}, 64'd0);

        // ---------------- not implemented / faults ----------------
        expect_fault("SRET (not built yet)",  `INSTR_HEX_SRET, 1'b0, 4'd0, 4'd2);
        expect_fault("DIV (not built yet)",   encode_r(F7_M, 8, 7, 3'b100, 5, OP), 1'b0, 4'd0, 4'd2);
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
