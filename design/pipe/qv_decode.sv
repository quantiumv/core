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
 * alu_op_sel block (branches, JAL and JALR go to the BRU instead, with
 * imm3 = the B or J offset), rd_wen from its reg_write_control exclusion list
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
    // pred_taken/pred_tgt/xcpt_hi aren't consumed until prediction and RVC land
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
    logic [(`B_IMM_SIZE - 1):0]       imm_3_or_dest_addr;   // rd, or a branch's B offset

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
    logic                       is_alu;
    always_comb begin: alu_op_sel
        is_alu = 1'b1;
        case (code)
            // LUI: imm1 + imm2(=0). AUIPC: pc + imm, see uop_d below.
            `INSTR_CODE(ADDI), `INSTR_CODE(ADD),
            `INSTR_CODE(ADDIW), `INSTR_CODE(ADDW),
            `INSTR_CODE(LUI), `INSTR_CODE(AUIPC):    alu_op = `ADD;
            `INSTR_CODE(SUB), `INSTR_CODE(SUBW):     alu_op = `SUB;
            `INSTR_CODE(SLTI), `INSTR_CODE(SLT):     alu_op = `SLT;
            `INSTR_CODE(SLTIU), `INSTR_CODE(SLTU):   alu_op = `SLTU;
            `INSTR_CODE(XORI), `INSTR_CODE(XOR):     alu_op = `XOR;
            `INSTR_CODE(ORI), `INSTR_CODE(OR):       alu_op = `OR;
            `INSTR_CODE(ANDI), `INSTR_CODE(AND):     alu_op = `AND;
            `INSTR_CODE(SLLI), `INSTR_CODE(SLL):     alu_op = `SLL;
            `INSTR_CODE(SRLI), `INSTR_CODE(SRL):     alu_op = `SRL;
            `INSTR_CODE(SRAI), `INSTR_CODE(SRA):     alu_op = `SRA;
            `INSTR_CODE(SLLIW), `INSTR_CODE(SLLW):   alu_op = `SLLW;
            `INSTR_CODE(SRLIW), `INSTR_CODE(SRLW):   alu_op = `SRLW;
            `INSTR_CODE(SRAIW), `INSTR_CODE(SRAW):   alu_op = `SRAW;
            `INSTR_CODE(MUL), `INSTR_CODE(MULW):     alu_op = `MUL;
            `INSTR_CODE(MULH):                       alu_op = `MULH;
            `INSTR_CODE(MULHSU):                     alu_op = `MULHSU;
            `INSTR_CODE(MULHU):                      alu_op = `MULHU;
            default: begin
                alu_op = `ADD;
                is_alu = 1'b0;
            end
        endcase
    end: alu_op_sel

    logic       is_bru;
    qv_bru_op_e bru_op;
    always_comb begin: bru_op_sel
        is_bru = 1'b1;
        case (code)
            `INSTR_CODE(BEQ):  bru_op = QV_BR_BEQ;
            `INSTR_CODE(BNE):  bru_op = QV_BR_BNE;
            `INSTR_CODE(BLT):  bru_op = QV_BR_BLT;
            `INSTR_CODE(BGE):  bru_op = QV_BR_BGE;
            `INSTR_CODE(BLTU): bru_op = QV_BR_BLTU;
            `INSTR_CODE(BGEU): bru_op = QV_BR_BGEU;
            `INSTR_CODE(JAL):  bru_op = QV_BR_JAL;
            `INSTR_CODE(JALR): bru_op = QV_BR_JALR;
            default: begin
                bru_op = QV_BR_BEQ;
                is_bru = 1'b0;
            end
        endcase
    end: bru_op_sel

    logic       is_csr, csr_imm;
    qv_csr_op_e csr_op;
    always_comb begin: csr_op_sel
        is_csr  = 1'b1;
        csr_imm = 1'b0;
        case (code)
            `INSTR_CODE(CSRRW):  csr_op = QV_CSR_RW;
            `INSTR_CODE(CSRRS):  csr_op = QV_CSR_RS;
            `INSTR_CODE(CSRRC):  csr_op = QV_CSR_RC;
            `INSTR_CODE(CSRRWI): begin csr_op = QV_CSR_RW; csr_imm = 1'b1; end
            `INSTR_CODE(CSRRSI): begin csr_op = QV_CSR_RS; csr_imm = 1'b1; end
            `INSTR_CODE(CSRRCI): begin csr_op = QV_CSR_RC; csr_imm = 1'b1; end
            default: begin
                csr_op = QV_CSR_RW;
                is_csr = 1'b0;
            end
        endcase
    end: csr_op_sel

    logic       is_sys;
    qv_sys_op_e sys_op;
    always_comb begin: sys_op_sel
        is_sys = 1'b1;
        case (code)
            `INSTR_CODE(ECALL):  sys_op = QV_SYS_ECALL;
            `INSTR_CODE(EBREAK): sys_op = QV_SYS_EBREAK;
            `INSTR_CODE(MRET):   sys_op = QV_SYS_MRET;
            `INSTR_CODE(WFI):    sys_op = QV_SYS_WFI;
            default: begin
                sys_op = QV_SYS_NONE;
                is_sys = 1'b0;
            end
        endcase
    end: sys_op_sel

    wire implemented = is_alu || is_bru || is_csr || is_sys;

    // The CSR address arrives on imm_2. Write suppression and illegality
    // mirror core.sv's csr_write_suppress / is_illegal_instr for M-mode:
    // RS/RC suppress on the rs1 FIELD being x0, the I forms on uimm == 0;
    // a non-suppressed write to a read-only CSR (addr[11:10] == 11) and
    // any access to the debug (0x7B0-0x7B3) or trigger (0x7A0-0x7A4)
    // CSRs outside debug mode are illegal. Privilege checks arrive with
    // U/S modes.
    wire [11:0] csr_addr = imm_2[11:0];
    wire csr_wsup = (csr_op != QV_CSR_RW) && (csr_imm ? (imm_1 == '0) : (sel_a == '0));
    wire csr_illegal = is_csr && ((!csr_wsup && csr_addr[11:10] == 2'b11)
                                  || csr_addr[11:2] == 10'h1EC
                                  || csr_addr[11:2] == 10'h1E8 || csr_addr == 12'h7A4);

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

    // ADDW/SUBW/ADDIW/MULW reuse the 64-bit op and get truncated after;
    // the *W shifts have their own 32-bit ALU ops (core.sv's is_word_arith)
    wire is_word = (code == `INSTR_CODE(ADDW)) || (code == `INSTR_CODE(SUBW))
                || (code == `INSTR_CODE(ADDIW)) || (code == `INSTR_CODE(MULW));
    wire is_auipc = (code == `INSTR_CODE(AUIPC));
    wire is_jal   = (code == `INSTR_CODE(JAL));

    wire [(`WORD_SIZE - 1):0] imm_b_sext =
        {{(`WORD_SIZE - `B_IMM_SIZE){imm_3_or_dest_addr[`B_IMM_SIZE - 1]}}, imm_3_or_dest_addr};

    uop_t uop_d;
    always_comb begin
        uop_d          = '0;
        uop_d.pc       = i_iq_data.pc;
        uop_d.raw      = i_iq_data.raw;
        uop_d.rvc      = i_iq_data.rvc;
        uop_d.code     = code;
        uop_d.alu_op   = alu_op;
        uop_d.bru_op   = bru_op;
        uop_d.is_word  = is_word;
        uop_d.rs1      = sel_a;
        uop_d.rs1_used = (sel_a != '0);
        uop_d.rs2      = sel_b;
        uop_d.rs2_used = (sel_b != '0);
        uop_d.rd       = imm_3_or_dest_addr[(`L2_REG_FILE_SIZE - 1):0];
        // AUIPC uses no registers, so pc can ride in as an immediate. A
        // CSR op's ALU pass gives just its source (rs1 or uimm) + 0.
        uop_d.imm1     = is_auipc ? i_iq_data.pc : imm_1;
        uop_d.imm2     = is_auipc ? imm_1 : is_csr ? '0 : imm_2;
        uop_d.imm3     = is_jal ? imm_1 : imm_b_sext;
        uop_d.sys_op   = sys_op;
        uop_d.csr_op   = csr_op;
        uop_d.csr_addr = csr_addr;
        uop_d.csr_wsup = csr_wsup;
        // a CSR's rd value exists only at commit, so nothing younger may
        // run ahead on it -- flushing after every CSR op covers that too
        uop_d.serialize = is_csr;
        if (i_iq_data.xcpt) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = i_iq_data.xcpt_cause;
        end else if (!implemented || csr_illegal) begin
            uop_d.xcpt       = 1'b1;
            uop_d.xcpt_cause = 4'd2;
        end
        uop_d.rd_wen   = reg_write_ctrl && !uop_d.xcpt;
        // a faulting uop goes through the ALU as a no-op for commit to
        // trap on; it must never redirect or touch a CSR
        if (uop_d.xcpt)  uop_d.fu = QV_FU_ALU;
        else if (is_bru) uop_d.fu = QV_FU_BRU;
        else if (is_csr) uop_d.fu = QV_FU_CSR;
        else if (is_sys) uop_d.fu = QV_FU_SYS;
        else             uop_d.fu = QV_FU_ALU;
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
