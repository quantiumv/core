// SPDX-License-Identifier: MIT

`include "defaults/defaults.sv"
`include "defaults/alu_ops.sv"
`include "defaults/instruction_format.sv"

/*
 * qv_decode -- the D stage: decoder.sv plus the uop builder.
 *
 * decoder.sv is reused unmodified with its register-data inputs tied to
 * 0. It computes o_imm_N = (o_read_gpr_N_sel != 0) ? i_read_gpr_N_data :
 * internal_imm_N, so with the data tied off, o_imm_N is the decoded
 * immediate when no register is selected and 0 when one is. That gives
 * "register or immediate" plus the immediate value in one pass; issue
 * supplies the register value later. A source of x0 (sel == 0) reads as
 * the immediate 0, which is architecturally the same thing and means x0
 * never needs a producer-table lookup.
 *
 * Classification mirrors core.sv case by case: alu_op from its
 * alu_op_sel block, rd_wen from its reg_write_control exclusion list
 * (the full list, so adding an instruction later is a new arm, not a new
 * mechanism). Only the codes in `implemented` below actually execute;
 * anything else is marked as an illegal-instruction fault (cause 2) --
 * permanently correct for INVALID, and a "not built yet" marker for the
 * rest until their features land. A fetch fault (cause from align) takes
 * priority. A faulting uop never writes rd.
 *
 * decoder.sv must come before this file in the compile order: the
 * INSTR_CODE macro is defined there, the same requirement core.sv has.
 *
 * Output is registered (a real D/I split): one uop held until issue
 * takes it.
 */
module qv_decode (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_flush,

    input  logic              i_iq_valid,
    // pred_taken/pred_tgt/xcpt_hi aren't consumed until branches and RVC land
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::fe_instr_t i_iq_data,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic              o_iq_pop,

    output logic              o_valid,
    output qv_pkg::uop_t      o_uop,
    input  logic              i_issue_ready
);
    import qv_pkg::*;

    logic [(`L2_REG_FILE_SIZE - 1):0] sel_a, sel_b;
    logic [(`INSTR_CODE_SIZE - 1):0]  code;
    logic [(`WORD_SIZE - 1):0]        imm_1, imm_2;
    // only the rd bits are used until stores/branches need the S/B immediate
    /* verilator lint_off UNUSEDSIGNAL */
    logic [(`B_IMM_SIZE - 1):0]       imm_3_or_dest_addr;
    /* verilator lint_on UNUSEDSIGNAL */

    decoder decoder0 (
        .i_instruction(i_iq_data.raw),
        .i_instruction_address(i_iq_data.pc),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_instruction_address(),
        /* verilator lint_on PINCONNECTEMPTY */
        .o_read_gpr_A_sel(sel_a),
        .i_read_gpr_A_data('0),
        .o_read_gpr_B_sel(sel_b),
        .i_read_gpr_B_data('0),
        .o_decoded_instruction(code),
        .o_imm_1(imm_1),
        .o_imm_2(imm_2),
        .o_imm_3_or_dest_addr(imm_3_or_dest_addr)
    );

    logic [(`ALU_OPSIZE - 1):0] alu_op;
    logic                       implemented;
    always_comb begin: alu_op_sel
        implemented = 1'b1;
        case (code)
            `INSTR_CODE(ADDI), `INSTR_CODE(ADD):   alu_op = `ADD;
            `INSTR_CODE(SUB):                      alu_op = `SUB;
            `INSTR_CODE(SLTI), `INSTR_CODE(SLT):   alu_op = `SLT;
            `INSTR_CODE(SLTIU), `INSTR_CODE(SLTU): alu_op = `SLTU;
            `INSTR_CODE(XORI), `INSTR_CODE(XOR):   alu_op = `XOR;
            `INSTR_CODE(ORI), `INSTR_CODE(OR):     alu_op = `OR;
            `INSTR_CODE(ANDI), `INSTR_CODE(AND):   alu_op = `AND;
            `INSTR_CODE(SLLI), `INSTR_CODE(SLL):   alu_op = `SLL;
            `INSTR_CODE(SRLI), `INSTR_CODE(SRL):   alu_op = `SRL;
            `INSTR_CODE(SRAI), `INSTR_CODE(SRA):   alu_op = `SRA;
            default: begin
                alu_op      = `ADD;
                implemented = 1'b0;
            end
        endcase
    end: alu_op_sel

    logic reg_write_ctrl;
    always_comb begin: reg_write_control
        case (code)
            `INSTR_CODE(SB), `INSTR_CODE(SH), `INSTR_CODE(SW), `INSTR_CODE(SD),
            `INSTR_CODE(BEQ), `INSTR_CODE(BNE), `INSTR_CODE(BLT),
            `INSTR_CODE(BGE), `INSTR_CODE(BLTU), `INSTR_CODE(BGEU),
            `INSTR_CODE(FENCE), `INSTR_CODE(FENCE_I), `INSTR_CODE(ECALL), `INSTR_CODE(EBREAK),
            `INSTR_CODE(MRET), `INSTR_CODE(SRET), `INSTR_CODE(WFI), `INSTR_CODE(SFENCE_VMA),
            `INSTR_CODE(INVALID):
                reg_write_ctrl = 1'b0;
            default:
                reg_write_ctrl = 1'b1;
        endcase
    end: reg_write_control

    uop_t uop_d;
    always_comb begin
        uop_d          = '0;
        uop_d.pc       = i_iq_data.pc;
        uop_d.raw      = i_iq_data.raw;
        uop_d.rvc      = i_iq_data.rvc;
        uop_d.code     = code;
        uop_d.fu       = QV_FU_ALU;
        uop_d.alu_op   = alu_op;
        uop_d.is_word  = 1'b0;
        uop_d.rs1      = sel_a;
        uop_d.rs1_used = (sel_a != '0);
        uop_d.rs2      = sel_b;
        uop_d.rs2_used = (sel_b != '0);
        uop_d.rd       = imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0];
        uop_d.imm1     = imm_1;
        uop_d.imm2     = imm_2;
        if (i_iq_data.xcpt) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = i_iq_data.xcpt_cause;
        end else if (!implemented) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = 4'd2;
        end
        uop_d.rd_wen   = reg_write_ctrl && !uop_d.xcpt;
    end

    logic uop_valid_q;
    uop_t uop_q;

    assign o_iq_pop = i_iq_valid && (!uop_valid_q || i_issue_ready) && !i_flush;
    assign o_valid  = uop_valid_q;
    assign o_uop    = uop_q;

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            uop_valid_q <= 1'b0;
        end else if (o_iq_pop) begin
            uop_valid_q <= 1'b1;
            uop_q       <= uop_d;
        end else if (i_issue_ready) begin
            uop_valid_q <= 1'b0;
        end
    end
endmodule
