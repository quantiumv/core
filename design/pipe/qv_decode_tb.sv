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
module qv_decode_tb #(
    parameter bit CSR_NOSER = 1'b0,     // P10c: tests.list runs both
    parameter bit FPU_EN    = 1'b0      // F/D: tests.list runs both; the FP section needs it
);
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
    logic       pmp_absent;           // errata E7: the PMP CSR at hand does not exist
    logic [1:0] priv = 2'b11;         // the privilege state the illegal-instruction rules read
    logic       tsr = 1'b0, tvm = 1'b0;
    logic       in_debug = 1'b0;      // Debug Mode: the debug and trigger CSRs exist, the triggers do not fire
    logic [63:0] tdata1_0 = '0, tdata2_0 = '0, tdata1_1 = '0, tdata2_1 = '0;   // the two execute triggers
    logic       pb_active = 1'b0;     // a Program Buffer run: its instructions are not PMP-checked
    // PMP state (reset: region 0 NAPOT over everything, rwx) and the pc the next instruction is fed at
    logic [63:0] pmpcfg0 = 64'h1F, pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF, pmpaddr1 = '0, pmpaddr2 = '0, pmpaddr3 = '0;
    logic [63:0] feed_pc = 64'h1000;
    // where the fetched instruction really is (translated fetch), and a fault marker for the second dword of a crossing one
    logic        feed_xl = 1'b0, feed_hi = 1'b0;
    logic [43:0] feed_pg_lo = '0, feed_pg_hi = '0;
    logic [1:0]  fs  = 2'b01;          // F/D: mstatus.FS (Initial) and frm
    logic [2:0]  frm = 3'd0;

    qv_decode #(.CSR_NOSER(CSR_NOSER), .FPU_EN(FPU_EN)) dut (
        .clk(clk), .rst(rst), .i_flush(flush), .i_fs(fs), .i_frm(frm),
        .i_priv(priv), .i_tsr(tsr), .i_tvm(tvm), .i_in_debug(in_debug), .i_pb_active(pb_active),
        .i_tdata1_0(tdata1_0), .i_tdata2_0(tdata2_0), .i_tdata1_1(tdata1_1), .i_tdata2_1(tdata2_1),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1),
        .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
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
        iq_data.pc         = feed_pc;
        iq_data.raw        = rvc ? {16'b0, instr[15:0]} : instr;
        iq_data.rvc        = rvc;
        iq_data.pred_taken = pred;
        iq_data.pred_tgt   = tgt;
        iq_data.xcpt       = xcpt;
        iq_data.xcpt_cause = cause;
        iq_data.xcpt_hi    = feed_hi;
        iq_data.xl         = feed_xl;
        iq_data.pg_lo      = feed_pg_lo;
        iq_data.pg_hi      = feed_pg_hi;
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

    // m/s scratch, epc, cause, tval: written without a flush under CSR_NOSER
    // errata E10: the CSRs that exist, written from Sail's table (verification/reference/probes/csr_table.txt), not
    // from the RTL: Sail's M-mode set under the ACT configs, plus mcycle/minstret (always) and the trigger CSRs
    // 0x7A1-0x7A4 (Debug Mode only, a separate rule); fflags/frm/fcsr only with the FPU
    function automatic logic tb_exists(input logic [11:0] a);
        case (a)
            12'h001, 12'h002, 12'h003: return FPU_EN;
            12'h100, 12'h104, 12'h105, 12'h106, 12'h10A,
            12'h140, 12'h141, 12'h142, 12'h143, 12'h144, 12'h180,
            12'h300, 12'h301, 12'h302, 12'h303, 12'h304, 12'h305, 12'h306, 12'h30A, 12'h320,
            12'h340, 12'h341, 12'h342, 12'h343, 12'h344, 12'h3A0, 12'h3A2,
            12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3, 12'h7A4, 12'h7B0, 12'h7B1, 12'h7B2, 12'h7B3,
            12'hB00, 12'hB02, 12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15: return 1'b1;
            default: return a[11:4] == 8'h3B;                       // pmpaddr0-15
        endcase
    endfunction

    function automatic logic trap_csr(input logic [11:0] a);
        return (a >= 12'h340 && a <= 12'h343) || (a >= 12'h140 && a <= 12'h143);
    endfunction

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
        // every CSR op flushes after it, but with CSR_NOSER (P10c) one that writes nothing or writes a trap CSR
        check({name, ": serialize"}, {63'b0, uop.serialize}, {63'b0, !(CSR_NOSER && (exp_wsup || trap_csr(exp_addr)))});
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

    // DIV/DIVU/REM/REMU and the W forms: routed to the divider, rs1/rs2 both
    // registers, writes rd, op bits {quot, signed} and is_word as given
    task automatic expect_div(input string name, input logic [31:0] instr, input logic [6:0] exp_code,
                              input logic exp_signed, input logic exp_quot, input logic exp_word);
        feed(instr);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": code"}, {57'b0, uop.code}, {57'b0, exp_code});
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_DIV});
        check({name, ": div_signed"}, {63'b0, uop.div_signed}, {63'b0, exp_signed});
        check({name, ": div_quot"}, {63'b0, uop.div_quot}, {63'b0, exp_quot});
        check({name, ": is_word"}, {63'b0, uop.is_word}, {63'b0, exp_word});
        check({name, ": rd"}, {59'b0, uop.rd}, 64'd5);
        check({name, ": rs1"}, {59'b0, uop.rs1}, 64'd7);
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, 64'd1);
        check({name, ": rs2"}, {59'b0, uop.rs2}, 64'd8);
        check({name, ": rs2_used"}, {63'b0, uop.rs2_used}, 64'd1);
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, 64'd1);
        check({name, ": no serialize"}, {63'b0, uop.serialize}, 64'd0);
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
    endtask

    // LR/SC/AMO: routed to the LSU, address rs1 alone, width from the encoding,
    // sign-extending; rd written; rs2 a register for SC and the AMOs (LR has
    // rs2 = x0). is_word marks the .W forms.
    task automatic expect_atomic(input string name, input logic [4:0] funct5, input logic word,
                                 input qv_amo_op_e exp_op, input logic exp_rs2_used);
        feed(encode_amo(funct5, 1'b0, 1'b0, exp_rs2_used ? 5'd8 : 5'd0, 5'd7, word ? `FUNCT3_AMO_W : `FUNCT3_AMO_D, 5'd5, `OPC_AMO));
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": fu"}, {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
        check({name, ": is_atomic"}, {63'b0, uop.is_atomic}, 64'd1);
        check({name, ": amo_op"}, {60'b0, uop.amo_op}, {60'b0, exp_op});
        check({name, ": size"}, {62'b0, uop.mem_size}, word ? 64'd2 : 64'd3);
        check({name, ": is_word"}, {63'b0, uop.is_word}, {63'b0, word});
        check({name, ": not a plain load or store"}, {62'b0, uop.is_load, uop.is_store}, 64'd0);
        check({name, ": rd"}, {59'b0, uop.rd}, 64'd5);
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, 64'd1);
        check({name, ": rs1"}, {59'b0, uop.rs1}, 64'd7);
        check({name, ": rs1_used"}, {63'b0, uop.rs1_used}, 64'd1);
        check({name, ": rs2_used"}, {63'b0, uop.rs2_used}, {63'b0, exp_rs2_used});
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

    // feed one instruction at feed_pc and check its trigger bits, the unit it is sent to and its rd write
    task automatic expect_trig(input string name, input logic [31:0] instr, input logic exp_dbg, input logic exp_exc,
                               input qv_fu_e exp_fu, input logic exp_rd_wen,
                               input logic xcpt_in = 1'b0, input logic [3:0] cause_in = 4'd0, input logic rvc = 1'b0);
        feed(instr, xcpt_in, cause_in, rvc);
        check({name, ": valid"}, {63'b0, valid}, 64'd1);
        check({name, ": trig_debug"}, {63'b0, uop.trig_debug}, {63'b0, exp_dbg});
        check({name, ": trig_exc"}, {63'b0, uop.trig_exc}, {63'b0, exp_exc});
        check({name, ": unit"}, {61'b0, uop.fu}, {61'b0, exp_fu});
        check({name, ": rd_wen"}, {63'b0, uop.rd_wen}, {63'b0, exp_rd_wen});
    endtask

    localparam logic [6:0] OP = `OPC_OP, OPI = `OPC_OP_IMM, OP32 = `OPC_OP_32, OPI32 = `OPC_OP_IMM_32;
    localparam logic [6:0] F7_0 = 7'b0000000, F7_1 = 7'b0100000, F7_M = 7'b0000001;

    logic [11:0] csr_probe [0:9] = '{12'h340, 12'h300, 12'h305, 12'h100, 12'h140, 12'h180, 12'hC00, 12'hC02, 12'h240, 12'hF14};
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

        // ---------------- divide / remainder -> DIV ----------------
        expect_div("DIV",   encode_r(F7_M, 8, 7, 3'b100, 5, OP),   `INSTR_CODE(DIV),   1'b1, 1'b1, 1'b0);
        expect_div("DIVU",  encode_r(F7_M, 8, 7, 3'b101, 5, OP),   `INSTR_CODE(DIVU),  1'b0, 1'b1, 1'b0);
        expect_div("REM",   encode_r(F7_M, 8, 7, 3'b110, 5, OP),   `INSTR_CODE(REM),   1'b1, 1'b0, 1'b0);
        expect_div("REMU",  encode_r(F7_M, 8, 7, 3'b111, 5, OP),   `INSTR_CODE(REMU),  1'b0, 1'b0, 1'b0);
        expect_div("DIVW",  encode_r(F7_M, 8, 7, 3'b100, 5, OP32), `INSTR_CODE(DIVW),  1'b1, 1'b1, 1'b1);
        expect_div("DIVUW", encode_r(F7_M, 8, 7, 3'b101, 5, OP32), `INSTR_CODE(DIVUW), 1'b0, 1'b1, 1'b1);
        expect_div("REMW",  encode_r(F7_M, 8, 7, 3'b110, 5, OP32), `INSTR_CODE(REMW),  1'b1, 1'b0, 1'b1);
        expect_div("REMUW", encode_r(F7_M, 8, 7, 3'b111, 5, OP32), `INSTR_CODE(REMUW), 1'b0, 1'b0, 1'b1);
        // a divide is not a multiply: MUL keeps going to the ALU, unflagged
        feed(encode_r(F7_M, 8, 7, 3'b000, 5, OP));
        check("MUL: still the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("MUL: not a divide", {62'b0, uop.div_signed, uop.div_quot}, 64'd0);
        // x0 as a destination: a divide that writes nothing still runs
        feed(encode_r(F7_M, 8, 7, 3'b100, 0, OP));
        check("DIV x0: still the divider", {61'b0, uop.fu}, {61'b0, QV_FU_DIV});
        check("DIV x0: rd 0", {59'b0, uop.rd}, 64'd0);
        // a fetch fault on a divide encoding is a fault, not a divide
        feed(encode_r(F7_M, 8, 7, 3'b100, 5, OP), 1'b1, 4'd1);
        check("faulted DIV: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("faulted DIV: no rd write", {63'b0, uop.rd_wen}, 64'd0);

        // ---------------- LR / SC / AMO -> LSU ----------------
        for (int w = 0; w < 2; w++) begin
            expect_atomic($sformatf("LR.%s", w ? "W" : "D"),      `FUNCT5_LR,      w[0], QV_AMO_LR,   1'b0);
            expect_atomic($sformatf("SC.%s", w ? "W" : "D"),      `FUNCT5_SC,      w[0], QV_AMO_SC,   1'b1);
            expect_atomic($sformatf("AMOSWAP.%s", w ? "W" : "D"), `FUNCT5_AMOSWAP, w[0], QV_AMO_SWAP, 1'b1);
            expect_atomic($sformatf("AMOADD.%s", w ? "W" : "D"),  `FUNCT5_AMOADD,  w[0], QV_AMO_ADD,  1'b1);
            expect_atomic($sformatf("AMOXOR.%s", w ? "W" : "D"),  `FUNCT5_AMOXOR,  w[0], QV_AMO_XOR,  1'b1);
            expect_atomic($sformatf("AMOAND.%s", w ? "W" : "D"),  `FUNCT5_AMOAND,  w[0], QV_AMO_AND,  1'b1);
            expect_atomic($sformatf("AMOOR.%s", w ? "W" : "D"),   `FUNCT5_AMOOR,   w[0], QV_AMO_OR,   1'b1);
            expect_atomic($sformatf("AMOMIN.%s", w ? "W" : "D"),  `FUNCT5_AMOMIN,  w[0], QV_AMO_MIN,  1'b1);
            expect_atomic($sformatf("AMOMAX.%s", w ? "W" : "D"),  `FUNCT5_AMOMAX,  w[0], QV_AMO_MAX,  1'b1);
            expect_atomic($sformatf("AMOMINU.%s", w ? "W" : "D"), `FUNCT5_AMOMINU, w[0], QV_AMO_MINU, 1'b1);
            expect_atomic($sformatf("AMOMAXU.%s", w ? "W" : "D"), `FUNCT5_AMOMAXU, w[0], QV_AMO_MAXU, 1'b1);
        end
        // aq/rl don't change the decode
        feed(encode_amo(`FUNCT5_AMOADD, 1'b1, 1'b1, 5'd8, 5'd7, `FUNCT3_AMO_D, 5'd5, `OPC_AMO));
        check("AMOADD.aqrl: still AMOADD", {60'b0, uop.amo_op}, {60'b0, QV_AMO_ADD});
        check("AMOADD.aqrl: still an atomic on the LSU", {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
        // rd = x0 still goes to the LSU (the access happens), it just writes nothing
        feed(encode_amo(`FUNCT5_AMOSWAP, 1'b0, 1'b0, 5'd8, 5'd7, `FUNCT3_AMO_W, 5'd0, `OPC_AMO));
        check("AMOSWAP rd=x0: LSU", {61'b0, uop.fu}, {61'b0, QV_FU_LSU});
        check("AMOSWAP rd=x0: rd 0", {59'b0, uop.rd}, 64'd0);
        // plain loads and stores are not atomics
        feed(encode_i(8, 7, 3'b011, 5, `OPC_LOAD));
        check("LD: not atomic", {63'b0, uop.is_atomic}, 64'd0);
        feed(encode_s(8, 6, 7, 3'b011, `OPC_STORE));
        check("SD: not atomic", {63'b0, uop.is_atomic}, 64'd0);
        // a fetch fault on an atomic encoding faults, and is not an atomic
        feed(encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd8, 5'd7, `FUNCT3_AMO_D, 5'd5, `OPC_AMO), 1'b1, 4'd1);
        check("faulted AMO: routed to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("faulted AMO: not an atomic", {63'b0, uop.is_atomic}, 64'd0);

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
        expect_csr("read mconfigptr (RSI 0)", encode_csr(12'hF15, 0, 3'b110, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRSI),
                   QV_CSR_RS, 12'hF15, 0, 0, 64'd0, 1'b1, 5);
        // errata E10: without Zicntr instret does not exist, so even a read is illegal
        expect_fault("read instret (RSI 0)", encode_csr(12'hC02, 0, 3'b110, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("write mhartid",        encode_csr(12'hF14, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRS mhartid, x6",    encode_csr(12'hF14, 6, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRSI cycle, 1",      encode_csr(12'hC00, 1, 3'b110, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("CSRRWI instret, 0",    encode_csr(12'hC02, 0, 3'b101, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        // debug and trigger CSRs: illegal outside debug mode, even to read
        expect_fault("read dcsr",            encode_csr(12'h7B0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read dscratch1",       encode_csr(12'h7B3, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read tselect",         encode_csr(12'h7A0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("read tinfo",           encode_csr(12'h7A4, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        // in Debug Mode the very same CSRs are legal (a Program Buffer reads and writes them) ...
        in_debug = 1'b1;
        expect_csr("read dcsr in debug mode", encode_csr(12'h7B0, 0, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),
                   QV_CSR_RS, 12'h7B0, 0, 0, 0, 1'b1, 5);
        expect_csr("write dscratch0 in debug mode", encode_csr(12'h7B2, 6, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h7B2, 6, 1, 0, 1'b0, 5);
        expect_csr("write dpc in debug mode", encode_csr(12'h7B1, 6, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h7B1, 6, 1, 0, 1'b0, 5);
        expect_csr("read dscratch1 in debug mode", encode_csr(12'h7B3, 0, 3'b010, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRS), QV_CSR_RS, 12'h7B3, 0, 0, 0, 1'b1, 5);
        expect_csr("write tselect in debug mode", encode_csr(12'h7A0, 6, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h7A0, 6, 1, 0, 1'b0, 5);
        expect_csr("write tdata1 in debug mode", encode_csr(12'h7A1, 6, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h7A1, 6, 1, 0, 1'b0, 5);
        expect_csr("write tdata2 in debug mode", encode_csr(12'h7A2, 6, 3'b001, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRW), QV_CSR_RW, 12'h7A2, 6, 1, 0, 1'b0, 5);
        expect_csr("read tinfo in debug mode", encode_csr(12'h7A4, 0, 3'b010, 5, `OPC_SYSTEM),
                   `INSTR_CODE(CSRRS), QV_CSR_RS, 12'h7A4, 0, 0, 0, 1'b1, 5);
        // ... but the ordinary privilege check still applies inside it (addr[9:8] is 11 for every one of them)
        priv = 2'b01;
        expect_fault("read dcsr in debug mode from S",   encode_csr(12'h7B0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("write tdata1 in debug mode from S", encode_csr(12'h7A1, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        priv = 2'b00;
        expect_fault("read dscratch0 in debug mode from U", encode_csr(12'h7B2, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        priv = 2'b11;
        // a read-only CSR write is as illegal in Debug Mode as outside it
        expect_fault("write mhartid in debug mode", encode_csr(12'hF14, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        in_debug = 1'b0;
        expect_fault("read dcsr again outside debug mode", encode_csr(12'h7B0, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        // the neighbours of those ranges do not exist (errata E10): illegal too, in Debug Mode as well
        expect_fault("read 0x7A5", encode_csr(12'h7A5, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("write 0x7B4", encode_csr(12'h7B4, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        in_debug = 1'b1;
        expect_fault("read 0x7A5 in Debug Mode", encode_csr(12'h7A5, 0, 3'b010, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        expect_fault("write 0x7B4 in Debug Mode", encode_csr(12'h7B4, 6, 3'b001, 5, `OPC_SYSTEM), 1'b0, 4'd0, 4'd2);
        in_debug = 1'b0;
        // which CSR writes flush after them (P10c: only the trap CSRs are written without one) -- the neighbours too
        begin : ser_rule
            logic [11:0] wa [0:17];
            wa[0] = 12'h340; wa[1] = 12'h341; wa[2] = 12'h342; wa[3] = 12'h343;
            wa[4] = 12'h140; wa[5] = 12'h141; wa[6] = 12'h142; wa[7] = 12'h143;
            wa[8] = 12'h300; wa[9] = 12'h100; wa[10] = 12'h180; wa[11] = 12'h304; wa[12] = 12'h344;
            wa[13] = 12'h306; wa[14] = 12'h144; wa[15] = 12'h106; wa[16] = 12'h3A0; wa[17] = 12'h305;
            for (int w = 0; w < 18; w++) begin
                expect_csr($sformatf("CSRRW 0x%03h", wa[w]), encode_csr(wa[w], 6, 3'b001, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRW),
                           QV_CSR_RW, wa[w], 6, 1, 0, 1'b0, 5);
                expect_csr($sformatf("CSRRS 0x%03h, x6", wa[w]), encode_csr(wa[w], 6, 3'b010, 5, `OPC_SYSTEM), `INSTR_CODE(CSRRS),
                           QV_CSR_RS, wa[w], 6, 1, 0, 1'b0, 5);
                expect_csr($sformatf("CSRRSI 0x%03h, 0 (read)", wa[w]), encode_csr(wa[w], 0, 3'b110, 5, `OPC_SYSTEM),
                           `INSTR_CODE(CSRRSI), QV_CSR_RS, wa[w], 0, 0, 64'd0, 1'b1, 5);
            end
            // the rule above, spelled out for the ones that matter most
            feed(encode_csr(12'h300, 6, 3'b001, 5, `OPC_SYSTEM));
            check("a write of mstatus always flushes after it", {63'b0, uop.serialize}, 64'd1);
            feed(encode_csr(12'h180, 6, 3'b001, 5, `OPC_SYSTEM));
            check("a write of satp always flushes after it", {63'b0, uop.serialize}, 64'd1);
            feed(encode_csr(12'h141, 6, 3'b001, 5, `OPC_SYSTEM));
            check("a write of sepc flushes after it only without CSR_NOSER", {63'b0, uop.serialize}, {63'b0, !CSR_NOSER});
            feed(encode_csr(12'h300, 0, 3'b010, 5, `OPC_SYSTEM));
            check("a read of mstatus flushes after it only without CSR_NOSER", {63'b0, uop.serialize}, {63'b0, !CSR_NOSER});
        end

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

        // ---------------- privilege: what is illegal where ----------------
        // CSR access above the current privilege (addr[9:8] > priv), through
        // csrrs rd, csr, x0 so the write-suppress rules stay out of it
        for (int pv = 0; pv < 4; pv++) begin
            priv = 2'(pv);
            foreach (csr_probe[i]) begin
                feed(encode_csr(csr_probe[i], 5'd0, `FUNCT3_CSRRS, 5'd5, `OPC_SYSTEM));
                check($sformatf("csr %h at priv %0d: illegal iff addr[9:8] > priv or absent", csr_probe[i], pv),
                      {63'b0, uop.xcpt}, {63'b0, csr_probe[i][9:8] > 2'(pv) || !tb_exists(csr_probe[i])});
                if (uop.xcpt) check($sformatf("csr %h at priv %0d: cause 2", csr_probe[i], pv), {60'b0, uop.xcpt_cause}, 64'd2);
            end
        end
        // errata E7: of the PMP CSRs, RV64 with 16 of them has pmpcfg0, pmpcfg2 and pmpaddr0-15 (readable in M);
        // pmpcfg1, pmpcfg3-15 and pmpaddr16-63 do not exist: illegal, also in M, read or write
        priv = 2'b11;
        for (int a = 12'h3A0; a <= 12'h3EF; a++) begin
            pmp_absent = (a < 12'h3B0) ? (a != 12'h3A0 && a != 12'h3A2) : (a >= 12'h3C0);
            feed(encode_csr(12'(a), 5'd0, `FUNCT3_CSRRS, 5'd5, `OPC_SYSTEM));
            check($sformatf("csrr %h in M: illegal iff absent", a), {63'b0, uop.xcpt}, {63'b0, pmp_absent});
            if (pmp_absent) check($sformatf("csrr %h in M: cause 2", a), {60'b0, uop.xcpt_cause}, 64'd2);
            feed(encode_csr(12'(a), 5'd6, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM));
            check($sformatf("csrw %h in M: illegal iff absent", a), {63'b0, uop.xcpt}, {63'b0, pmp_absent});
        end
        // MRET only in M; SRET not in U, nor in S under TSR; WFI and SFENCE.VMA (bar TVM) anywhere
        for (int pv = 0; pv < 4; pv++)
            for (int ts = 0; ts < 2; ts++)
                for (int tv = 0; tv < 2; tv++) begin
                    priv = 2'(pv); tsr = ts[0]; tvm = tv[0];
                    feed(`INSTR_HEX_MRET);
                    check($sformatf("mret at priv %0d: illegal iff not M", pv), {63'b0, uop.xcpt}, {63'b0, pv != 3});
                    feed(`INSTR_HEX_SRET);
                    check($sformatf("sret at priv %0d tsr %0d: illegal iff U, or S with TSR", pv, ts), {63'b0, uop.xcpt},
                          {63'b0, pv == 0 || (pv == 1 && ts == 1)});
                    feed(`INSTR_HEX_WFI);
                    check($sformatf("wfi at priv %0d: never illegal", pv), {63'b0, uop.xcpt}, 64'd0);
                    feed(encode_r(`FUNCT7_SFENCE_VMA, 5'd8, 5'd7, 3'b000, 5'd0, `OPC_SYSTEM));
                    check($sformatf("sfence.vma at priv %0d tvm %0d: illegal iff S with TVM", pv, tv), {63'b0, uop.xcpt},
                          {63'b0, pv == 1 && tv == 1});
                    feed(encode_csr(12'h180, 5'd0, `FUNCT3_CSRRS, 5'd5, `OPC_SYSTEM));      // satp
                    check($sformatf("satp at priv %0d tvm %0d", pv, tv), {63'b0, uop.xcpt},
                          {63'b0, pv == 0 || (pv == 1 && tv == 1)});
                    feed(encode_csr(12'h100, 5'd0, `FUNCT3_CSRRS, 5'd5, `OPC_SYSTEM));      // sstatus: TVM doesn't touch it
                    check($sformatf("sstatus at priv %0d tvm %0d", pv, tv), {63'b0, uop.xcpt}, {63'b0, pv == 0});
                end
        // a legal SRET / SFENCE.VMA decodes to the system unit
        priv = 2'b01; tsr = 1'b0; tvm = 1'b0;
        feed(`INSTR_HEX_SRET);
        check("sret: fu", {61'b0, uop.fu}, {61'b0, QV_FU_SYS});
        check("sret: op", {61'b0, uop.sys_op}, {61'b0, QV_SYS_SRET});
        check("sret: no rd", {63'b0, uop.rd_wen}, 64'd0);
        check("sret: no serialize needed (it redirects)", {63'b0, uop.serialize}, 64'd0);
        priv = 2'b00;
        feed(encode_r(`FUNCT7_SFENCE_VMA, 5'd8, 5'd7, 3'b000, 5'd0, `OPC_SYSTEM));
        check("sfence.vma (legal from U): fu", {61'b0, uop.fu}, {61'b0, QV_FU_SYS});
        check("sfence.vma: op", {61'b0, uop.sys_op}, {61'b0, QV_SYS_SFENCE_VMA});
        check("sfence.vma: no rd", {63'b0, uop.rd_wen}, 64'd0);
        check("sfence.vma: serializes", {63'b0, uop.serialize}, 64'd1);
        check("sfence.vma: rs1 used", {63'b0, uop.rs1_used}, 64'd1);
        check("sfence.vma: rs2 used", {63'b0, uop.rs2_used}, 64'd1);
        // a non-privileged instruction is unaffected at any privilege
        for (int pv = 0; pv < 4; pv++) begin
            priv = 2'(pv);
            feed(encode_r(F7_0, 8, 7, 3'b000, 5, OP));
            check($sformatf("add at priv %0d", pv), {63'b0, uop.xcpt}, 64'd0);
            feed(encode_i(8, 7, 3'b011, 5, `OPC_LOAD));
            check($sformatf("ld at priv %0d", pv), {63'b0, uop.xcpt}, 64'd0);
        end
        priv = 2'b11; tsr = 1'b0; tvm = 1'b0;

        // ---------------- not implemented / faults ----------------
        expect_fault("all-zero (illegal)",    32'h0000_0000, 1'b0, 4'd0, 4'd2);
        expect_fault("fetch fault on a valid instr", encode_r(F7_0, 8, 7, 3'b000, 5, OP), 1'b1, 4'd1, 4'd1);
        expect_fault("fetch fault beats illegal", 32'h0000_0000, 1'b1, 4'd1, 4'd1);

        // ---------------- PMP on the fetch ----------------
        // Per 2-byte parcel (errata E6): [pc, pc+1], and [pc+2, pc+3] for a 32-bit instruction, each judged on its
        // own; a denial of the second parcel marks the uop xcpt_hi (mtval pc + 2). Region 0: TOR [0, 0x1010), read +
        // execute; the other regions are off. M is never denied by an unlocked region.
        pmpcfg0 = 64'h0D; pmpaddr0 = 64'h1010 >> 2;
        priv = 2'b01;
        feed_pc = 64'h1000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: both parcels inside the region", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h100C; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: the last word of the region", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h100E; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: the second parcel past the top: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... a fetch access fault", {60'b0, uop.xcpt_cause}, 64'd1);
        check("pmp: ... in the second parcel (xcpt_hi)", {63'b0, uop.xcpt_hi}, 64'd1);
        feed_pc = 64'h100E; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);               // c.nop
        check("pmp: a 2-byte instruction in the last parcel: fine", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h1010; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);
        check("pmp: a 2-byte instruction just above: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... in the first parcel", {63'b0, uop.xcpt_hi}, 64'd0);
        // crossing into the next dword: pc[2:1] == 3 and a 32-bit instruction
        feed_pc = 64'h0FFE; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: crossing instruction, both parcels inside", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h1006; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: crossing instruction at 0x1006, both parcels inside", {63'b0, uop.xcpt}, 64'd0);
        pmpaddr0 = 64'h1008 >> 2;                                                    // the top now at the dword edge
        feed_pc = 64'h1006; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: crossing instruction, the second parcel past the top", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... cause 1", {60'b0, uop.xcpt_cause}, 64'd1);
        check("pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        pb_active = 1'b1; in_debug = 1'b1;                                           // the same crossing instruction, in a Program Buffer run
        feed_pc = 64'h1006; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: second parcel denied, but in a Program Buffer run: no fault", {63'b0, uop.xcpt}, 64'd0);
        pb_active = 1'b0; in_debug = 1'b0;
        feed_pc = 64'h1006; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);               // 16-bit at the same pc: no second parcel
        check("pmp: 16-bit instruction at pc[2:1] == 3 has no second parcel", {63'b0, uop.xcpt}, 64'd0);
        // a 32-bit instruction at pc[2:1] == 1: its second parcel is the next word of the same dword
        pmpaddr0 = 64'h1004 >> 2;
        feed_pc = 64'h1002; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: 32-bit at pc[2:1] == 1, the second parcel past the top: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        feed_pc = 64'h1000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: 32-bit at pc[2:1] == 0, the last word: fine", {63'b0, uop.xcpt}, 64'd0);
        pmpaddr0 = 64'h1010 >> 2;
        feed_pc = 64'h1002; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: 32-bit instruction at pc[2:1] == 1 inside", {63'b0, uop.xcpt}, 64'd0);
        // a denied fetch is inert: the real instruction's bits must not leak through
        feed_pc = 64'h1010; feed(encode_s(0, 6, 9, 3'd3, `OPC_STORE));
        check("pmp: denied store is no store", {63'b0, uop.is_store}, 64'd0);
        check("pmp: denied store goes to the ALU", {61'b0, uop.fu}, {61'b0, QV_FU_ALU});
        check("pmp: denied store: no rd write", {63'b0, uop.rd_wen}, 64'd0);
        feed(encode_csr(12'h340, 5'd5, `FUNCT3_CSRRW, 5'd6, `OPC_SYSTEM));
        check("pmp: denied CSR op does not serialize", {63'b0, uop.serialize}, 64'd0);
        check("pmp: denied CSR op is a fault", {63'b0, uop.xcpt}, 64'd1);
        feed(32'h0000_0000);
        check("pmp: beats illegal-instruction", {60'b0, uop.xcpt_cause}, 64'd1);
        feed(encode_i(1, 7, 3'b000, 5, OPI), 1'b1, 4'd12);
        check("pmp: a page-fault marker from the fetch keeps its cause", {60'b0, uop.xcpt_cause}, 64'd12);
        // privilege decides: M is not denied by an unlocked region, privilege 2 is checked like S
        priv = 2'b11; feed_pc = 64'h1010; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: M, outside every region: no denial", {63'b0, uop.xcpt}, 64'd0);
        priv = 2'b10; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: privilege 2 is denied like S", {63'b0, uop.xcpt}, 64'd1);
        priv = 2'b00; feed_pc = 64'h1000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: U inside the region", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h2000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: U outside every region", {63'b0, uop.xcpt}, 64'd1);
        // the execute permission: the same region without X denies S, and a locked one denies M too
        pmpcfg0 = 64'h09; priv = 2'b01; feed_pc = 64'h1000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: no execute permission", {63'b0, uop.xcpt}, 64'd1);
        pmpcfg0 = 64'h89; priv = 2'b11; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: locked region without X denies M", {63'b0, uop.xcpt}, 64'd1);
        pmpcfg0 = 64'h0D; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: unlocked: M fine", {63'b0, uop.xcpt}, 64'd0);
        // nothing configured: below M everything is denied, M is not
        pmpcfg0 = 64'h0; priv = 2'b01; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: no region matches, S denied", {63'b0, uop.xcpt}, 64'd1);
        priv = 2'b11; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: no region matches, M allowed", {63'b0, uop.xcpt}, 64'd0);
        // a Program Buffer run is trusted: the same denied fetch is no fault
        pmpcfg0 = 64'h0; priv = 2'b01; pb_active = 1'b1; in_debug = 1'b1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: S denied everywhere, but in a Program Buffer run: no fault", {63'b0, uop.xcpt}, 64'd0);
        check("pmp: ... the instruction is an ordinary ALU one", {63'b0, uop.rd_wen}, 64'd1);
        pb_active = 1'b0; in_debug = 1'b0;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: the same fetch outside the run is denied again", {63'b0, uop.xcpt}, 64'd1);
        // the second parcel is judged against its own region: region 0 TOR [0, 0x1008), region 2 TOR [0x1008, 0x2000)
        // (region 1 off, its address region 2's bottom)
        pmpaddr0 = 64'h1008 >> 2; pmpaddr1 = 64'h1008 >> 2; pmpaddr2 = 64'h2000 >> 2;
        pmpcfg0 = {32'b0, 8'h00, 8'h0D, 8'h00, 8'h0D};
        feed_pc = 64'h1006; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: the two parcels in two regions, both executable", {63'b0, uop.xcpt}, 64'd0);
        pmpcfg0 = {32'b0, 8'h00, 8'h09, 8'h00, 8'h0D};                      // region 2 without X
        feed_pc = 64'h1006; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: the second parcel's region without X: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        // an execute-denied NA4 word under an executable NAPOT region (errata E5 + E6): the lowest region holding the
        // parcel decides
        pmpcfg0 = {48'b0, 8'h1F, 8'h11}; pmpaddr0 = 64'h1004 >> 2; pmpaddr1 = 64'h3FF;   // 0: NA4 0x1004, R; 1: NAPOT [0, 8 KiB)
        feed_pc = 64'h1000; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: a 32-bit instruction below the NA4 word: fine", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h1002; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);
        check("pmp: a 16-bit one right below it: fine", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h1002; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: a 32-bit one reaching into it: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        feed_pc = 64'h1004; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);
        check("pmp: a 16-bit one in it: denied", {63'b0, uop.xcpt}, 64'd1);
        check("pmp: ... the first parcel", {63'b0, uop.xcpt_hi}, 64'd0);
        priv = 2'b11;
        feed_pc = 64'h1004; feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);
        check("pmp: ... but M is not limited by the unlocked NA4 region", {63'b0, uop.xcpt}, 64'd0);
        priv = 2'b01;
        // a reserved compressed encoding at a denied pc is still a fetch fault, not an illegal instruction
        pmpcfg0 = 64'h0D; pmpaddr0 = 64'h1010 >> 2; pmpaddr1 = '0; pmpaddr2 = '0;
        feed_pc = 64'h1010; feed({16'b0, 16'h0000}, 1'b0, 4'd0, 1'b1);
        check("pmp: beats a reserved compressed encoding", {60'b0, uop.xcpt_cause}, 64'd1);
        // the lower regions also feed the first parcel: region 1 alone permits this fetch
        pmpcfg0 = {48'b0, 8'h0D, 8'h00};                                    // 0: OFF (its address is region 1's lower bound); 1: TOR
        pmpaddr0 = 64'h1000 >> 2; pmpaddr1 = 64'h1010 >> 2;
        feed_pc = 64'h1008; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: region 1 (TOR over region 0's address) permits the fetch", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h0FFC; feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("pmp: below region 1's lower bound", {63'b0, uop.xcpt}, 64'd1);
        // back to the reset state for the rest
        pmpcfg0 = 64'h1F; pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF; pmpaddr1 = '0; pmpaddr2 = '0; feed_pc = 64'h1000; priv = 2'b11;

        // ---------------- PMP on a translated fetch ----------------
        // the parcels' addresses are physical: {pg_lo, pc[11:0]} for the first, and pc + 2 on pg_hi for the second
        // of a crossing instruction (pg_lo otherwise) -- the virtual pc decides nothing. Same region as above:
        // TOR [0, 0x1010), r-x.
        pmpcfg0 = 64'h0D; pmpaddr0 = 64'h1010 >> 2;
        priv = 2'b01;
        feed_xl = 1'b1;
        feed_pc = 64'h4000_0000; feed_pg_lo = 44'h1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: the virtual pc is outside the region, the physical page is inside: fine", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h1000; feed_pg_lo = 44'h80;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: the virtual pc is inside the region, the physical page is outside: denied", {63'b0, uop.xcpt}, 64'd1);
        check("xl pmp: ... cause 1", {60'b0, uop.xcpt_cause}, 64'd1);
        feed_pc = 64'h4000_000C; feed_pg_lo = 44'h1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: physical [0x100C, 0x100F] inside", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h4000_000E; feed_pg_lo = 44'h1; feed_pg_hi = 44'h1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: physical second parcel 0x1010 above the top: denied", {63'b0, uop.xcpt}, 64'd1);
        check("xl pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        // not crossing (pc[2:1] == 2 or 1): the second parcel is in the first dword's page, whatever pg_hi says
        feed_pc = 64'h4000_0004; feed_pg_lo = 44'h1; feed_pg_hi = 44'h80;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: pc[2:1] == 2 does not cross: the second parcel 0x1006 on pg_lo, inside", {63'b0, uop.xcpt}, 64'd0);
        feed_pc = 64'h4000_000A;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: pc[2:1] == 1 does not cross: the second parcel 0x100C on pg_lo, inside", {63'b0, uop.xcpt}, 64'd0);
        // a crossing instruction: the second parcel is in another page, at its offset 0
        feed_pc = 64'h4000_0FFE; feed_pg_lo = 44'h0; feed_pg_hi = 44'h1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: crossing, physical parcels 0xFFE and 0x1000 both inside", {63'b0, uop.xcpt}, 64'd0);
        pmpaddr0 = 64'h1000 >> 2;                                          // the region now ends at the page edge
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: crossing, the second parcel 0x1000 above a region ending there: denied", {63'b0, uop.xcpt}, 64'd1);
        check("xl pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        pmpaddr0 = 64'h1010 >> 2;
        feed_pg_hi = 44'h80;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: crossing, the second page outside the region: denied", {63'b0, uop.xcpt}, 64'd1);
        check("xl pmp: ... cause 1", {60'b0, uop.xcpt_cause}, 64'd1);
        check("xl pmp: ... xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd1);
        feed_pg_lo = 44'h80; feed_pg_hi = 44'h1;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: crossing, the first page outside the region: denied", {63'b0, uop.xcpt}, 64'd1);
        check("xl pmp: ... the first parcel", {63'b0, uop.xcpt_hi}, 64'd0);
        feed_pg_lo = 44'h0; feed_pg_hi = 44'h80;
        feed({16'b0, 16'h0001}, 1'b0, 4'd0, 1'b1);                                    // 16-bit at the same pc: no second parcel
        check("xl pmp: a 16-bit instruction at pc[2:1] == 3 has no second parcel", {63'b0, uop.xcpt}, 64'd0);
        // a Program Buffer run is not checked at all
        pb_active = 1'b1; in_debug = 1'b1;
        feed_pc = 64'h1000; feed_pg_lo = 44'h80; feed_pg_hi = 44'h80;
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl pmp: Program Buffer run: no fault", {63'b0, uop.xcpt}, 64'd0);
        pb_active = 1'b0; in_debug = 1'b0;
        // fault markers: a page-fault marker keeps its cause and says if it was in the second dword ...
        feed_pc = 64'h4000_0FFE; feed_pg_lo = 44'h0; feed_pg_hi = '0; feed_hi = 1'b1;
        feed(32'h0, 1'b1, 4'd12);
        check("xl marker: a page fault in the high dword: cause 12", {60'b0, uop.xcpt_cause}, 64'd12);
        check("xl marker: ... marked as the high dword's", {63'b0, uop.xcpt_hi}, 64'd1);
        check("xl marker: ... a fault", {63'b0, uop.xcpt}, 64'd1);
        // ... but ref_core.sv looks at the first parcel first: if the PMP denies it, the fetch ends there
        feed_pg_lo = 44'h80;
        feed(32'h0, 1'b1, 4'd12);
        check("xl marker: the first parcel denied: an access fault (cause 1) instead of the page fault", {60'b0, uop.xcpt_cause}, 64'd1);
        check("xl marker: ... still a fault", {63'b0, uop.xcpt}, 64'd1);
        check("xl marker: ... of the first parcel", {63'b0, uop.xcpt_hi}, 64'd0);
        // ... and the second parcel is not looked at for a marker of the high dword: that dword's translation failed
        feed_pc = 64'h4000_0FFE; feed_pg_lo = 44'h0; feed_pg_hi = 44'h80; feed_hi = 1'b1;
        feed(32'h0, 1'b1, 4'd12);
        check("xl marker: the second parcel (meaningless here) is not checked: cause 12 stands", {60'b0, uop.xcpt_cause}, 64'd12);
        feed_pg_hi = '0;
        // a marker for the dword the instruction starts in is not overridden: its own translation failed, nothing was fetched
        feed_hi = 1'b0; feed_pg_lo = 44'h80;
        feed(32'h0, 1'b1, 4'd12);
        check("xl marker: not for the high dword: cause 12 whatever the (meaningless) page says", {60'b0, uop.xcpt_cause}, 64'd12);
        check("xl marker: ... not marked high", {63'b0, uop.xcpt_hi}, 64'd0);
        // a plain instruction carries no xcpt_hi
        feed(encode_i(1, 7, 3'b000, 5, OPI));
        check("xl: an ordinary instruction has no xcpt_hi", {63'b0, uop.xcpt_hi}, 64'd0);
        feed_xl = 1'b0; feed_pg_lo = '0; feed_pg_hi = '0; feed_hi = 1'b0;
        pmpcfg0 = 64'h1F; pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF; pmpaddr1 = '0; pmpaddr2 = '0; feed_pc = 64'h1000; priv = 2'b11;

        // ---------------- execute triggers ----------------
        // tdata1: [15:12] action (1 Debug Mode entry, 0 breakpoint exception), [6] M, [4] S, [3] U, [2] execute
        priv = 2'b11; in_debug = 1'b0; feed_pc = 64'h2000;
        tdata2_0 = 64'h2000;
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("action 1 on an addi", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        check("action 1 on an addi: still has its operands", {59'b0, uop.rs1}, 64'd6);
        check("action 1 on an addi: rs1_used kept", {63'b0, uop.rs1_used}, 64'd1);
        check("action 1 on an addi: no fault marker", {63'b0, uop.xcpt}, 64'd0);
        check("action 1 on an addi: rd kept for RVFI", {59'b0, uop.rd}, 64'd7);
        // action 0: a breakpoint exception, not a debug entry
        tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("action 0 on an addi", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b1, QV_FU_ALU, 1'b0);
        // no match: the execute bit clear, another pc, the high bits of the pc, no enable for the privilege
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6);
        expect_trig("execute bit clear", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        tdata2_0 = 64'h2004;
        expect_trig("another pc", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        tdata2_0 = 64'h1_0000_2000;
        expect_trig("pc differs in the high bits", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        tdata2_0 = 64'h2000;
        // the privilege enables: M bit 6, S bit 4, U bit 3, and privilege 2'b10 takes the U bit
        tdata1_0 = (64'd1 << 12) | (64'd1 << 4) | (64'd1 << 3) | (64'd1 << 2);      // S and U, not M
        priv = 2'b11;
        expect_trig("M, only S/U enabled", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        priv = 2'b01;
        expect_trig("S, S enabled", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        priv = 2'b00;
        expect_trig("U, U enabled", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        priv = 2'b10;
        expect_trig("privilege 2 follows the U bit", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 4) | (64'd1 << 2);      // M and S, not U
        priv = 2'b00;
        expect_trig("U, only M/S enabled", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        priv = 2'b10;
        expect_trig("privilege 2, U bit clear", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        priv = 2'b01;
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 3) | (64'd1 << 2);      // M and U, not S
        expect_trig("S, S bit clear", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        priv = 2'b11;
        // never in Debug Mode
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        in_debug = 1'b1;
        expect_trig("action 1 in Debug Mode", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("action 0 in Debug Mode", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        in_debug = 1'b0;
        // slot 1, and a debug match beats an exception one wherever they sit
        tdata1_0 = '0; tdata2_0 = '0;
        tdata2_1 = 64'h2000; tdata1_1 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("slot 1, action 1", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        tdata1_1 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("slot 1, action 0", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b1, QV_FU_ALU, 1'b0);
        tdata2_0 = 64'h2000; tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        tdata1_1 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("slot 0 action 0 + slot 1 action 1: the debug entry wins", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        tdata1_1 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("slot 0 action 1 + slot 1 action 0: the debug entry wins", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        tdata1_1 = (64'd1 << 12) | (64'd1 << 6);                                    // slot 1 with the execute bit clear
        tdata1_0 = '0; tdata2_0 = '0; tdata2_1 = 64'h2000;
        expect_trig("slot 1, execute bit clear", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);
        tdata1_1 = '0; tdata2_1 = '0;

        // fault markers: an action-1 match goes over them, an action-0 one gives way
        tdata2_0 = 64'h2000;
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("action 1 over a fetch fault", encode_i(5, 6, 3'b000, 7, OPI), 1'b1, 1'b0, QV_FU_ALU, 1'b0, 1'b1, 4'd1);
        check("action 1 over a fetch fault: the marker stays", {63'b0, uop.xcpt}, 64'd1);
        check("action 1 over a fetch fault: the cause stays", {60'b0, uop.xcpt_cause}, 64'd1);
        expect_trig("action 1 over an illegal instruction", 32'h0000_0000, 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        check("action 1 over an illegal instruction: the marker stays", {60'b0, uop.xcpt_cause}, 64'd2);
        tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("action 0 under a fetch fault", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b0, 1'b1, 4'd1);
        check("action 0 under a fetch fault: the marker stays", {60'b0, uop.xcpt_cause}, 64'd1);
        expect_trig("action 0 under an illegal instruction", 32'h0000_0000, 1'b0, 1'b0, QV_FU_ALU, 1'b0);
        check("action 0 under an illegal instruction: the marker stays", {60'b0, uop.xcpt_cause}, 64'd2);

        // a compressed instruction matches on its own pc
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        feed_pc = 64'h2000; tdata2_0 = 64'h2002;
        expect_trig("compressed at the other halfword: no match", {16'b0, encode_c_addi(1, 8)}, 1'b0, 1'b0, QV_FU_ALU, 1'b1,
                    1'b0, 4'd0, 1'b1);
        feed_pc = 64'h2002;
        expect_trig("compressed at the matching halfword", {16'b0, encode_c_addi(1, 8)}, 1'b1, 1'b0, QV_FU_ALU, 1'b0,
                    1'b0, 4'd0, 1'b1);
        feed_pc = 64'h2000; tdata2_0 = 64'h2000;

        // every kind of instruction is neutralised: it must reach commit as an ALU no-op that writes nothing, with
        // its operands and its memory/atomic flags (the LR/SC reservation) untouched
        expect_trig("lw", encode_i(8, 6, 3'b010, 7, `OPC_LOAD), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        check("lw: still a load", {63'b0, uop.is_load}, 64'd1);
        expect_trig("sd", encode_s(16, 7, 6, 3'b011, `OPC_STORE), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        check("sd: still a store", {63'b0, uop.is_store}, 64'd1);
        check("sd: rs2 kept", {63'b0, uop.rs2_used}, 64'd1);
        expect_trig("sc.d", encode_amo(5'b00011, 1'b0, 1'b0, 5'd8, 5'd7, `FUNCT3_AMO_D, 5'd5, `OPC_AMO), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        check("sc.d: still an atomic", {63'b0, uop.is_atomic}, 64'd1);
        expect_trig("divu", encode_r(F7_M, 8, 7, 3'b101, 5, OP), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("csrrw", encode_csr(12'h340, 6, 3'b001, 5, `OPC_SYSTEM), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("beq", encode_b(16, 7, 6, 3'b000, `OPC_BRANCH), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("jal", encode_j(64, 1, `OPC_JAL), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("jalr", encode_i(0, 6, 3'b000, 1, `OPC_JALR), 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("mret", `INSTR_HEX_MRET, 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("ecall", 32'h0000_0073, 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        expect_trig("fence.i", 32'h0000_100F, 1'b1, 1'b0, QV_FU_ALU, 1'b0);
        // the same under an action-0 trigger
        tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("lw, action 0", encode_i(8, 6, 3'b010, 7, `OPC_LOAD), 1'b0, 1'b1, QV_FU_ALU, 1'b0);
        expect_trig("amoadd.w, action 0", encode_amo(5'b00000, 1'b0, 1'b0, 5'd8, 5'd7, `FUNCT3_AMO_W, 5'd5, `OPC_AMO), 1'b0, 1'b1, QV_FU_ALU, 1'b0);
        check("amoadd.w, action 0: still an atomic", {63'b0, uop.is_atomic}, 64'd1);
        expect_trig("sret, action 0", 32'h1020_0073, 1'b0, 1'b1, QV_FU_ALU, 1'b0);

        // an EBREAK keeps its identity (with dcsr.ebreak* it enters Debug Mode ahead of the trigger)
        tdata1_0 = (64'd1 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("ebreak, action 1", 32'h0010_0073, 1'b1, 1'b0, QV_FU_SYS, 1'b0);
        check("ebreak, action 1: sys_op EBREAK", {61'b0, uop.sys_op}, {61'b0, QV_SYS_EBREAK});
        tdata1_0 = (64'd0 << 12) | (64'd1 << 6) | (64'd1 << 2);
        expect_trig("ebreak, action 0", 32'h0010_0073, 1'b0, 1'b1, QV_FU_SYS, 1'b0);
        check("ebreak, action 0: sys_op EBREAK", {61'b0, uop.sys_op}, {61'b0, QV_SYS_EBREAK});
        // ... and a compressed EBREAK
        feed_pc = 64'h2002; tdata2_0 = 64'h2002;
        expect_trig("c.ebreak, action 0", 32'h0000_9002, 1'b0, 1'b1, QV_FU_SYS, 1'b0, 1'b0, 4'd0, 1'b1);
        feed_pc = 64'h1000;
        tdata1_0 = '0; tdata2_0 = '0; priv = 2'b11; in_debug = 1'b0;

        // an instruction that is not near any trigger is untouched
        expect_trig("no trigger armed", encode_i(5, 6, 3'b000, 7, OPI), 1'b0, 1'b0, QV_FU_ALU, 1'b1);

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

        if (FPU_EN) fp_section();

        $display("");
        $display("qv_decode_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_decode_tb: FAILURES PRESENT");
        $finish;
    end

    // ---------------- F/D (FPU_EN) ----------------
    function automatic logic [31:0] fpr(input logic [6:0] f7, input logic [4:0] rs2, input logic [4:0] rs1,
                                        input logic [2:0] f3, input logic [4:0] rd);
        return {f7, rs2, rs1, f3, rd, 7'b1010011};
    endfunction

    // the uop of one FP instruction: unit, operands (number, used, FP), destination, FPU op/fmt/rm
    task automatic expect_fp(input string name, input logic [31:0] instr, input qv_fu_e exp_fu,
                             input logic [4:0] r1, input logic u1, input logic f1,
                             input logic [4:0] r2, input logic u2, input logic f2, input logic u3,
                             input logic [4:0] rd, input logic wen, input logic rdf,
                             input qv_fp_op_e op, input logic fmt, input logic [2:0] rm, input logic rvc = 1'b0);
        feed(instr, 1'b0, 4'd0, rvc);
        check({name, ": no fault"}, {63'b0, uop.xcpt}, 64'd0);
        check({name, ": unit"}, 64'(uop.fu), 64'(exp_fu));
        check({name, ": rs1"}, {57'b0, uop.rs1, uop.rs1_used, uop.rs1_fp}, {57'b0, r1, u1, f1});
        check({name, ": rs2"}, {57'b0, uop.rs2, uop.rs2_used, uop.rs2_fp}, {57'b0, r2, u2, f2});
        check({name, ": rs3 used"}, {63'b0, uop.rs3_used}, {63'b0, u3});
        check({name, ": rd"}, {57'b0, uop.rd, uop.rd_wen, uop.rd_fp}, {57'b0, rd, wen, rdf});
        if (exp_fu == QV_FU_FPU)
            check({name, ": op/fmt/rm"}, {55'b0, uop.fp_op, uop.fp_fmt, uop.fp_rm}, {55'b0, 5'(op), fmt, rm});
    endtask

    task automatic expect_fp_illegal(input string name, input logic [31:0] instr);
        feed(instr);
        check({name, ": illegal"}, {59'b0, uop.xcpt, uop.xcpt_cause}, {59'b0, 1'b1, 4'd2});
        check({name, ": reads nothing, writes nothing"},
              {60'b0, uop.rs1_used, uop.rs2_used, uop.rd_wen, uop.rd_fp}, 64'd0);
    endtask

    task automatic fp_section();
        priv = 2'b11; in_debug = 1'b0; tdata1_0 = '0; tdata1_1 = '0; feed_xl = 1'b0; feed_hi = 1'b0;
        fs = 2'b01; frm = 3'd2;
        expect_fp("fadd.d f3,f1,f2,rtz", fpr(7'b0000001, 2, 1, 3'b001, 3), QV_FU_FPU,
                  1, 1, 1, 2, 1, 1, 0, 3, 1, 1, QV_FP_ADD, 1'b1, 3'd1);
        expect_fp("fmadd.s f4,f1,f2,f3,dyn (frm 2)", {5'd3, 2'b00, 5'd2, 5'd1, 3'b111, 5'd4, 7'b1000011}, QV_FU_FPU,
                  1, 1, 1, 2, 1, 1, 1, 4, 1, 1, QV_FP_MADD, 1'b0, 3'd2);
        expect_fp("feq.d x5,f1,f2: an integer rd", fpr(7'b1010001, 2, 1, 3'b010, 5), QV_FU_FPU,
                  1, 1, 1, 2, 1, 1, 0, 5, 1, 0, QV_FP_EQ, 1'b1, 3'd2);
        expect_fp("fcvt.d.w f6,x7: an integer source, rs2 holds the type", fpr(7'b1101001, 0, 7, 3'b000, 6),
                  QV_FU_FPU, 7, 1, 0, 0, 0, 0, 0, 6, 1, 1, QV_FP_I2F, 1'b1, 3'd0);
        expect_fp("fcvt.lu.d x8,f9,rdn: rs2 (type 3) is not a register", fpr(7'b1100001, 3, 9, 3'b010, 8),
                  QV_FU_FPU, 9, 1, 1, 0, 0, 0, 0, 8, 1, 0, QV_FP_F2I, 1'b1, 3'd2);
        expect_fp("fsqrt.s f0,f31: f0 is a destination", fpr(7'b0101100, 0, 31, 3'b000, 0), QV_FU_FPU,
                  31, 1, 1, 0, 0, 0, 0, 0, 1, 1, QV_FP_SQRT, 1'b0, 3'd0);
        expect_fp("flw f10,8(x11): the LSU", {12'd8, 5'd11, 3'b010, 5'd10, 7'b0000111}, QV_FU_LSU,
                  11, 1, 0, 0, 0, 0, 0, 10, 1, 1, QV_FP_ADD, 1'b0, 3'd0);
        check("flw: a word load, offset as operand b", {59'b0, uop.is_load, uop.mem_size, uop.is_store, 1'b0},
              {59'b0, 1'b1, 2'd2, 1'b0, 1'b0});
        check("flw: offset", uop.imm2, 64'd8);
        expect_fp("fsd f12,-16(x13): an FP store source", {7'h7F, 5'd12, 5'd13, 3'b011, 5'b10000, 7'b0100111},
                  QV_FU_LSU, 13, 1, 0, 12, 1, 1, 0, 16, 0, 0, QV_FP_ADD, 1'b0, 3'd0);   // (rd: offset bits, no write)
        check("fsd: store offset", uop.imm3, -64'sd16);
        expect_fp("c.fld f8,8(x9) expands to fld", {16'b0, 3'b001, 3'b001, 3'b001, 2'b00, 3'b000, 2'b00}, QV_FU_LSU,
                  9, 1, 0, 0, 0, 0, 0, 8, 1, 1, QV_FP_ADD, 1'b0, 3'd0, 1'b1);
        expect_fp_illegal("fadd.d, rm 5 (reserved)", fpr(7'b0000001, 2, 1, 3'b101, 3));
        expect_fp_illegal("fadd.h (no Zfh)", fpr(7'b0000010, 2, 1, 3'b000, 3));
        frm = 3'd5;
        expect_fp_illegal("fadd.d, dyn with frm 5", fpr(7'b0000001, 2, 1, 3'b111, 3));
        frm = 3'd4;
        expect_fp("fadd.d, dyn with frm 4", fpr(7'b0000001, 2, 1, 3'b111, 3), QV_FU_FPU,
                  1, 1, 1, 2, 1, 1, 0, 3, 1, 1, QV_FP_ADD, 1'b1, 3'd4);
        fs = 2'b00;
        expect_fp_illegal("FS Off: fadd.d", fpr(7'b0000001, 2, 1, 3'b000, 3));
        expect_fp_illegal("FS Off: flw", {12'd8, 5'd11, 3'b010, 5'd10, 7'b0000111});
        feed({12'h001, 5'd0, 3'b010, 5'd14, 7'b1110011});          // csrr x14, fflags
        check("FS Off: csrr fflags is illegal", {59'b0, uop.xcpt, uop.xcpt_cause}, {59'b0, 1'b1, 4'd2});
        feed({12'h003, 5'd0, 3'b010, 5'd14, 7'b1110011});          // frcsr x14
        check("FS Off: frcsr is illegal", {59'b0, uop.xcpt, uop.xcpt_cause}, {59'b0, 1'b1, 4'd2});
        fs = 2'b10;
        feed({12'h002, 5'd0, 3'b010, 5'd14, 7'b1110011});          // frrm x14
        check("FS Clean: frrm is legal", {63'b0, uop.xcpt}, 64'd0);
        // an action-1 trigger on an FP op: neutralised, no FP destination either
        feed_pc = 64'h2000;
        tdata2_0 = 64'h2000;
        tdata1_0 = (64'd2 << 60) | (64'd1 << 12) | (64'd1 << 6) | 64'd4;   // mcontrol6, action 1, M, execute
        feed(fpr(7'b0000001, 2, 1, 3'b000, 3));
        check("trigger on fadd.d: debug entry", {63'b0, uop.trig_debug}, 64'd1);
        check("trigger on fadd.d: ALU, no rd, no FP rd", {61'b0, uop.fu == QV_FU_ALU, uop.rd_wen, uop.rd_fp},
              {61'b0, 1'b1, 1'b0, 1'b0});
        tdata1_0 = '0;
        feed_pc = 64'h1000;
        fs = 2'b01;
    endtask

    initial begin
        #100000;
        $display("TIMEOUT: qv_decode_tb");
        $finish;
    end
endmodule
