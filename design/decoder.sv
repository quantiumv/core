// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_codes.sv"
`include "defaults/instruction_format.sv"
`include "defaults/instructions_and_masks.sv"


/* ------------------------------------------------------------------------- */


/* Check if instruction `instr` is `name`. Example: IS_INSTR(i_instr, ADD). */
`define IS_INSTR(instr, name) ((instr & `INSTR_MASK_``name) == `INSTR_``name)

/* Instruction code from name. Example: INSTR_CODE(ADD) => 'b010100. */
`define INSTR_CODE(name) 'b`INSTR_CODE_``name


/* ------------------------------------------------------------------------- */


/*
 * Create macros to set output for different types of instructions.
 *
 * !! IMPORTANT NOTE !!
 * This depends on the variables in the decoder module! If you modify them,
 * please modify these macros appropriately.
 */

/*
 * NB: these use blocking (=) assignment throughout, matching the
 * always_comb block they're used inside (detect_and_assign, below) --
 * non-blocking (<=) inside always_comb is non-idiomatic and both iverilog
 * and verilator flag it (verilator: COMBDLY). Icarus tolerates it and
 * simulates it correctly, but there's no reason to rely on that leniency.
 *
 * Also NB: `B_IMM_SIZE'(destination) below is an explicit width cast, not
 * a stylistic flourish -- destination is 5 bits (DEST_SIZE) and
 * o_imm_3_or_dest_addr is 13 (B_IMM_SIZE); the implicit zero-extension is
 * correct (a register index is unsigned) but verilator's -Wall flags the
 * implicit width change, so it's made explicit rather than left as a
 * warning to re-triage every time this file is linted.
 */

`define PASS_REG_A_IN_IMM_1(reg_addr)   \
    o_read_gpr_A_sel = reg_addr;        \
    internal_imm_1 = 0;                 \
;

`define PASS_REG_B_IN_IMM_2(reg_addr)   \
    o_read_gpr_B_sel = reg_addr;        \
    internal_imm_2 = 0;                 \
;

`define PASS_IMM_IN_IMM_1(imm)  \
    o_read_gpr_A_sel = 0;       \
    internal_imm_1 = imm;       \
;

`define PASS_IMM_IN_IMM_2(imm)  \
    o_read_gpr_B_sel = 0;       \
    internal_imm_2 = imm;       \
;

`define OUTPUT_R_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_REG_A_IN_IMM_1(source_1);                      \
    `PASS_REG_B_IN_IMM_2(source_2);                      \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);   \
;

/*
 * I-type, general (ADDI/SLTI/.../loads/JALR/ADDIW): imm_i_sext is the
 * 12-bit I-immediate, sign-extended to WORD_SIZE. NOT used for the
 * shift-immediate instructions (SLLI/SRLI/SRAI/SLLIW/SRLIW/SRAIW) -- see
 * OUTPUT_I_SHIFT_TYPE_INSTR/OUTPUT_IW_SHIFT_TYPE_INSTR below, since a
 * shift amount is an unsigned magnitude occupying only part of this same
 * field, not a sign-extended value occupying all of it.
 */
`define OUTPUT_I_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_REG_A_IN_IMM_1(source_1);                      \
    `PASS_IMM_IN_IMM_2(imm_i_sext);                      \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);   \
;

/*
 * I-type, shift-immediate (SLLI/SRLI/SRAI): shamt_zext is just the 6-bit
 * shift-amount field, ZERO-extended (a shift amount is a magnitude, never
 * sign-extended) -- NOT the generic imm_i_sext, which would incorrectly
 * carry the instruction's funct6 bits along as if they were part of a
 * signed immediate.
 */
`define OUTPUT_I_SHIFT_TYPE_INSTR(instr_name)            \
    o_decoded_instruction = `INSTR_CODE(instr_name);     \
    `PASS_REG_A_IN_IMM_1(source_1);                       \
    `PASS_IMM_IN_IMM_2(shamt_zext);                       \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);     \
;

/*
 * I-type, RV64I word-shift-immediate (SLLIW/SRLIW/SRAIW): same idea as
 * OUTPUT_I_SHIFT_TYPE_INSTR, but the shift amount is only 5 bits wide
 * here (word-shifts are always 32-bit, so 5 bits is always enough) --
 * see wshamt_zext.
 */
`define OUTPUT_IW_SHIFT_TYPE_INSTR(instr_name)           \
    o_decoded_instruction = `INSTR_CODE(instr_name);     \
    `PASS_REG_A_IN_IMM_1(source_1);                       \
    `PASS_IMM_IN_IMM_2(wshamt_zext);                      \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);     \
;

/*
 * S-type (stores): imm_s is declared WIDER than its natural 12 bits (see
 * its declaration below) specifically so it already carries a correct
 * sign bit at the same position B-type's imm_b does -- no separate _sext
 * variant needed here, imm_s IS the port-ready, already-sign-extended-by-
 * construction value.
 */
`define OUTPUT_S_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_REG_A_IN_IMM_1(source_1);                      \
    `PASS_REG_B_IN_IMM_2(source_2);                      \
    o_imm_3_or_dest_addr = imm_s;                        \
;

`define OUTPUT_B_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_REG_A_IN_IMM_1(source_1);                      \
    `PASS_REG_B_IN_IMM_2(source_2);                      \
    o_imm_3_or_dest_addr = imm_b;                        \
;

`define OUTPUT_U_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_IMM_IN_IMM_1(imm_u_sext);                      \
    `PASS_IMM_IN_IMM_2(0);                               \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);   \
;

`define OUTPUT_J_TYPE_INSTR(instr_name)                 \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_IMM_IN_IMM_1(imm_j_sext);                      \
    `PASS_IMM_IN_IMM_2(0);                               \
    o_imm_3_or_dest_addr = `B_IMM_SIZE'(destination);   \
;

`define OUTPUT_NONE_TYPE_INSTR(instr_name)              \
    o_decoded_instruction = `INSTR_CODE(instr_name);    \
    `PASS_IMM_IN_IMM_1(0);                               \
    `PASS_IMM_IN_IMM_2(0);                               \
    o_imm_3_or_dest_addr = 0;                            \
;


/* ------------------------------------------------------------------------- */


/*
 * Module: Decoder
 *
 * This needs access to register file to fetch value in registers.
 *
 * Input ports:
 *  i_instruction: The instruction to decode.
 *  i_instruction_address: Address of the instruction to decode.
 *  i_read_gpr_A_data: Data read from register file's port A.
 *  i_read_gpr_B_data: Data read from register file's port B.
 *
 * Output ports:
 *  o_read_gpr_A_sel: Register to read from register file's port A.
 *  o_read_gpr_B_sel: Register to read from register file's port B.
 *  o_decoded_instruction: The internal code for the decoded instruction.
 *  o_instruction_address: Address of the decoded instruction
 *                         (same as i_instruction_address).
 *  o_imm_1: Immediate value (either from instr or from a reg), or 0. Any
 *           immediate here is already sign- or zero-extended to
 *           WORD_SIZE as appropriate (sign-extended for ordinary
 *           immediates, zero-extended for shift amounts -- see
 *           shamt_zext/wshamt_zext below).
 *  o_imm_2: Same as o_imm_1, for the second operand slot.
 *  o_imm_3_or_dest_addr: For S and B type instructions, this is the
 *                        immediate value -- 13 bits (B_IMM_SIZE), with
 *                        the sign bit always at bit 12 regardless of
 *                        which of the two types it came from (see imm_s's
 *                        declaration below for why S-type needs an extra
 *                        bit to make that true). For most other
 *                        instructions, it is the destination register
 *                        index (5 bits, zero-extended into the same
 *                        13-bit port). 0 otherwise. Sign/zero-extending
 *                        this further to WORD_SIZE, when needed, is
 *                        core.sv's job, not the decoder's.
 */
module decoder (
    input logic     [(`INSTR_SIZE - 1):0]   i_instruction,
    input logic     [(`WORD_SIZE - 1):0]    i_instruction_address,
    output logic    [(`WORD_SIZE - 1):0]    o_instruction_address,

    output logic    [(`L2_REG_FILE_SIZE - 1):0] o_read_gpr_A_sel,
    input logic     [(`WORD_SIZE - 1):0]        i_read_gpr_A_data,

    output logic    [(`L2_REG_FILE_SIZE - 1):0] o_read_gpr_B_sel,
    input logic     [(`WORD_SIZE - 1):0]        i_read_gpr_B_data,

    output logic    [(`INSTR_CODE_SIZE - 1):0]  o_decoded_instruction,
    output logic    [(`WORD_SIZE - 1):0]        o_imm_1,
    output logic    [(`WORD_SIZE - 1):0]        o_imm_2,
    output logic    [(`B_IMM_SIZE - 1):0]       o_imm_3_or_dest_addr
);
    /* Pass through the instruction address. */
    assign o_instruction_address = i_instruction_address;

    /*
     * To fetch data in a register, we write to the register file's
     * select lines, which then outputs the value on its read data lines.
     * This entire process is combinational, so whenever we write to the
     * select lines, we will have a data output after a fixed delay, which
     * can be factored into the overall decoder's delay.
     *
     * Since we "decoded" the register address and got the value, we can
     * now just simply pass it through.
     *
     * But if we want to pass an immediate decoded from the instruction
     * directly, we need to stop data entering from the register file.
     * We will check if register select is zero to not use the registers.
     */

    logic [(`WORD_SIZE - 1):0] internal_imm_1;
    logic [(`WORD_SIZE - 1):0] internal_imm_2;
    /*
     * != 0 here (rather than relying on o_read_gpr_A_sel's truth value
     * directly) is explicit about this being a "is this the x0 sentinel"
     * check, not an arithmetic use of the select value -- also avoids a
     * multi-bit-to-1-bit implicit truthiness cast that verilator flags
     * under -Wall (WIDTHTRUNC).
     */
    assign o_imm_1 = (o_read_gpr_A_sel != 0) ? i_read_gpr_A_data : internal_imm_1;
    assign o_imm_2 = (o_read_gpr_B_sel != 0) ? i_read_gpr_B_data : internal_imm_2;

    /*
     * Extract potential constituents from the instruction beforehand
     * for all types.
     */

    logic [(`SRC1_SIZE - 1):0] source_1;
    assign source_1 = i_instruction[`SRC1_MSB:`SRC1_LSB];

    logic [(`SRC2_SIZE - 1):0] source_2;
    assign source_2 = i_instruction[`SRC2_MSB:`SRC2_LSB];

    logic [(`DEST_SIZE - 1):0] destination;
    assign destination = i_instruction[`DEST_MSB:`DEST_LSB];

    logic [(`I_IMM_SIZE - 1):0] imm_i;
    assign imm_i = i_instruction[`I_IMM_MSB:`I_IMM_LSB];

    /* imm_i, sign-extended: bit 11 (imm_i's own MSB) is the sign bit. */
    logic [(`WORD_SIZE - 1):0] imm_i_sext;
    assign imm_i_sext = {{(`WORD_SIZE - `I_IMM_SIZE){imm_i[`I_IMM_SIZE - 1]}}, imm_i};

    /*
     * imm_s is deliberately declared B_IMM_SIZE (13) bits wide, not its
     * "natural" 12 -- one bit wider than the raw S-immediate field, with
     * the extra top bit an explicit copy of the sign bit (instruction bit
     * 31, same sign-bit position I/S/B all share). This puts imm_s's sign
     * bit at position 12, the SAME position imm_b's sign bit naturally
     * lands at (see imm_b below) -- so o_imm_3_or_dest_addr (which is
     * B_IMM_SIZE wide and carries either of these two, depending on
     * instruction type) can be sign-extended by core.sv with a single
     * formula that works for both S and B types, instead of two.
     * Without this, assigning the narrower 12-bit imm_s into that 13-bit
     * port would implicitly ZERO-pad bit 12, silently making every store
     * offset read as non-negative downstream regardless of its true sign.
     */
    logic [(`B_IMM_SIZE - 1):0] imm_s;
    assign imm_s = {i_instruction[`S_IMM_H_MSB],
                    i_instruction[`S_IMM_H_MSB:`S_IMM_H_LSB],
                    i_instruction[`S_IMM_L_MSB:`S_IMM_L_LSB]};

    logic [(`B_IMM_SIZE - 1):0] imm_b;
    assign imm_b = {
        i_instruction[`B_IMM_SIGN_BIT],
        i_instruction[`B_IMM_HIGH_BIT],
        i_instruction[`B_IMM_MID_BITS_MSB:`B_IMM_MID_BITS_LSB],
        i_instruction[`B_IMM_LOW_BITS_MSB:`B_IMM_LOW_BITS_LSB],
        1'b0
    };

    logic [(`U_IMM_SIZE - 1):0] imm_u;
    assign imm_u = i_instruction[`U_IMM_MSB:`U_IMM_LSB];

    /*
     * imm_u, turned into the actual usable upper-immediate value: LUI/
     * AUIPC's 20-bit field is bits [31:12] of the result, not the low 20
     * bits -- shift it into place, THEN sign-extend the resulting 32-bit
     * value out to WORD_SIZE using what is now bit 31 (= imm_u's own bit
     * 19, the field's original top bit). Without the shift, LUI/AUIPC
     * would be numerically wrong even before considering sign at all.
     */
    logic [(`WORD_SIZE - 1):0] imm_u_sext;
    assign imm_u_sext = {{(`WORD_SIZE - 32){imm_u[`U_IMM_SIZE - 1]}}, imm_u, 12'b0};

    logic [(`J_IMM_SIZE - 1):0] imm_j;
    assign imm_j = {
        i_instruction[`J_IMM_MSB],
        i_instruction[`J_IMM_MID_BITS_MSB:`J_IMM_MID_BITS_LSB],
        i_instruction[`J_IMM_POST_MID_BIT],
        i_instruction[`J_IMM_LOW_BITS_MSB:`J_IMM_LOW_BITS_LSB],
        1'b0
    };

    /* imm_j, sign-extended: bit 20 (imm_j's own MSB) is the sign bit. */
    logic [(`WORD_SIZE - 1):0] imm_j_sext;
    assign imm_j_sext = {{(`WORD_SIZE - `J_IMM_SIZE){imm_j[`J_IMM_SIZE - 1]}}, imm_j};

    /*
     * Shift amounts: extracted separately from imm_i on purpose (see
     * OUTPUT_I_SHIFT_TYPE_INSTR/OUTPUT_IW_SHIFT_TYPE_INSTR above) and
     * ZERO-, not sign-, extended -- a shift amount is an unsigned
     * magnitude, not a two's-complement value.
     */
    logic [(`SHAMT_SIZE - 1):0] shamt;
    assign shamt = i_instruction[`SHAMT_MSB:`SHAMT_LSB];
    logic [(`WORD_SIZE - 1):0] shamt_zext;
    assign shamt_zext = {{(`WORD_SIZE - `SHAMT_SIZE){1'b0}}, shamt};

    logic [(`WSHAMT_SIZE - 1):0] wshamt;
    assign wshamt = i_instruction[`WSHAMT_MSB:`WSHAMT_LSB];
    logic [(`WORD_SIZE - 1):0] wshamt_zext;
    assign wshamt_zext = {{(`WORD_SIZE - `WSHAMT_SIZE){1'b0}}, wshamt};


    /* Match the instruction and do appropriate decoding. */
    always_comb begin: detect_and_assign

        /* Upper immediate instructions (U type). */


        if (`IS_INSTR(i_instruction, LUI)) begin: lui_instr
            `OUTPUT_U_TYPE_INSTR(LUI);
        end: lui_instr


        else if (`IS_INSTR(i_instruction, AUIPC)) begin: auipc_instr
            `OUTPUT_U_TYPE_INSTR(AUIPC);
        end: auipc_instr


        /* --------------------------------------------------------- */


        /* Jump instructions (J and I types). */


        else if (`IS_INSTR(i_instruction, JAL)) begin: jal_instr
            `OUTPUT_J_TYPE_INSTR(JAL);
        end: jal_instr


        else if (`IS_INSTR(i_instruction, JALR)) begin: jalr_instr
            `OUTPUT_I_TYPE_INSTR(JALR);
        end: jalr_instr


        /* --------------------------------------------------------- */


        /* Branch instructions (B type). */


        else if (`IS_INSTR(i_instruction, BEQ)) begin: beq_instr
            `OUTPUT_B_TYPE_INSTR(BEQ);
        end: beq_instr


        else if (`IS_INSTR(i_instruction, BNE)) begin: bne_instr
            `OUTPUT_B_TYPE_INSTR(BNE);
        end: bne_instr


        else if (`IS_INSTR(i_instruction, BLT)) begin: blt_instr
            `OUTPUT_B_TYPE_INSTR(BLT);
        end: blt_instr


        else if (`IS_INSTR(i_instruction, BGE)) begin: bge_instr
            `OUTPUT_B_TYPE_INSTR(BGE);
        end: bge_instr


        else if (`IS_INSTR(i_instruction, BLTU)) begin: bltu_instr
            `OUTPUT_B_TYPE_INSTR(BLTU);
        end: bltu_instr


        else if (`IS_INSTR(i_instruction, BGEU)) begin: bgeu_instr
            `OUTPUT_B_TYPE_INSTR(BGEU);
        end: bgeu_instr


        /* --------------------------------------------------------- */


        /* Load instructions (I type). */


        else if (`IS_INSTR(i_instruction, LB)) begin: lb_instr
            `OUTPUT_I_TYPE_INSTR(LB);
        end: lb_instr


        else if (`IS_INSTR(i_instruction, LH)) begin: lh_instr
            `OUTPUT_I_TYPE_INSTR(LH);
        end: lh_instr


        else if (`IS_INSTR(i_instruction, LW)) begin: lw_instr
            `OUTPUT_I_TYPE_INSTR(LW);
        end: lw_instr


        else if (`IS_INSTR(i_instruction, LBU)) begin: lbu_instr
            `OUTPUT_I_TYPE_INSTR(LBU);
        end: lbu_instr


        else if (`IS_INSTR(i_instruction, LHU)) begin: lhu_instr
            `OUTPUT_I_TYPE_INSTR(LHU);
        end: lhu_instr


        /* RV64I-only loads. */


        else if (`IS_INSTR(i_instruction, LWU)) begin: lwu_instr
            `OUTPUT_I_TYPE_INSTR(LWU);
        end: lwu_instr


        else if (`IS_INSTR(i_instruction, LD)) begin: ld_instr
            `OUTPUT_I_TYPE_INSTR(LD);
        end: ld_instr


        /* --------------------------------------------------------- */


        /* Store instructions (S type). */


        else if (`IS_INSTR(i_instruction, SB)) begin: sb_instr
            `OUTPUT_S_TYPE_INSTR(SB);
        end: sb_instr


        else if (`IS_INSTR(i_instruction, SH)) begin: sh_instr
            `OUTPUT_S_TYPE_INSTR(SH);
        end: sh_instr


        else if (`IS_INSTR(i_instruction, SW)) begin: sw_instr
            `OUTPUT_S_TYPE_INSTR(SW);
        end: sw_instr


        /* RV64I-only store. */


        else if (`IS_INSTR(i_instruction, SD)) begin: sd_instr
            `OUTPUT_S_TYPE_INSTR(SD);
        end: sd_instr


        /* --------------------------------------------------------- */


        /* ALU instructions. */


        else if (`IS_INSTR(i_instruction, ADDI)) begin: addi_instr
            `OUTPUT_I_TYPE_INSTR(ADDI);
        end: addi_instr


        else if (`IS_INSTR(i_instruction, ADD)) begin: add_instr
            `OUTPUT_R_TYPE_INSTR(ADD);
        end: add_instr


        else if (`IS_INSTR(i_instruction, SUB)) begin: sub_instr
            `OUTPUT_R_TYPE_INSTR(SUB);
        end: sub_instr


        else if (`IS_INSTR(i_instruction, SLTI)) begin: slti_instr
            `OUTPUT_I_TYPE_INSTR(SLTI);
        end: slti_instr


        else if (`IS_INSTR(i_instruction, SLT)) begin: slt_instr
            `OUTPUT_R_TYPE_INSTR(SLT);
        end: slt_instr


        else if (`IS_INSTR(i_instruction, SLTIU)) begin: sltiu_instr
            `OUTPUT_I_TYPE_INSTR(SLTIU);
        end: sltiu_instr


        else if (`IS_INSTR(i_instruction, SLTU)) begin: sltu_instr
            `OUTPUT_R_TYPE_INSTR(SLTU);
        end: sltu_instr


        else if (`IS_INSTR(i_instruction, XORI)) begin: xori_instr
            `OUTPUT_I_TYPE_INSTR(XORI);
        end: xori_instr


        else if (`IS_INSTR(i_instruction, XOR)) begin: xor_instr
            `OUTPUT_R_TYPE_INSTR(XOR);
        end: xor_instr


        else if (`IS_INSTR(i_instruction, ORI)) begin: ori_instr
            `OUTPUT_I_TYPE_INSTR(ORI);
        end: ori_instr


        else if (`IS_INSTR(i_instruction, OR)) begin: or_instr
            `OUTPUT_R_TYPE_INSTR(OR);
        end: or_instr


        else if (`IS_INSTR(i_instruction, ANDI)) begin: andi_instr
            `OUTPUT_I_TYPE_INSTR(ANDI);
        end: andi_instr


        else if (`IS_INSTR(i_instruction, AND)) begin: and_instr
            `OUTPUT_R_TYPE_INSTR(AND);
        end: and_instr


        else if (`IS_INSTR(i_instruction, SLLI)) begin: slli_instr
            `OUTPUT_I_SHIFT_TYPE_INSTR(SLLI);
        end: slli_instr


        else if (`IS_INSTR(i_instruction, SLL)) begin: sll_instr
            `OUTPUT_R_TYPE_INSTR(SLL);
        end: sll_instr


        else if (`IS_INSTR(i_instruction, SRLI)) begin: srli_instr
            `OUTPUT_I_SHIFT_TYPE_INSTR(SRLI);
        end: srli_instr


        else if (`IS_INSTR(i_instruction, SRL)) begin: srl_instr
            `OUTPUT_R_TYPE_INSTR(SRL);
        end: srl_instr


        else if (`IS_INSTR(i_instruction, SRAI)) begin: srai_instr
            `OUTPUT_I_SHIFT_TYPE_INSTR(SRAI);
        end: srai_instr


        else if (`IS_INSTR(i_instruction, SRA)) begin: sra_instr
            `OUTPUT_R_TYPE_INSTR(SRA);
        end: sra_instr


        /* --------------------------------------------------------- */


        /*
         * RV64I word-width instructions: operate on the low 32 bits of
         * their operands and sign-extend the result back to 64 -- see
         * the comment above SLLW/SRLW/SRAW's `defines in
         * defaults/alu_ops.sv for why the shift variants need dedicated
         * ALU ops rather than reusing SLL/SRL/SRA, and the comment on
         * `is_word_arith`-style write-back muxing (in core.sv) for why
         * ADDW/SUBW/ADDIW instead reuse the plain ADD/SUB ALU ops.
         */


        else if (`IS_INSTR(i_instruction, ADDIW)) begin: addiw_instr
            `OUTPUT_I_TYPE_INSTR(ADDIW);
        end: addiw_instr


        else if (`IS_INSTR(i_instruction, SLLIW)) begin: slliw_instr
            `OUTPUT_IW_SHIFT_TYPE_INSTR(SLLIW);
        end: slliw_instr


        else if (`IS_INSTR(i_instruction, SRLIW)) begin: srliw_instr
            `OUTPUT_IW_SHIFT_TYPE_INSTR(SRLIW);
        end: srliw_instr


        else if (`IS_INSTR(i_instruction, SRAIW)) begin: sraiw_instr
            `OUTPUT_IW_SHIFT_TYPE_INSTR(SRAIW);
        end: sraiw_instr


        else if (`IS_INSTR(i_instruction, ADDW)) begin: addw_instr
            `OUTPUT_R_TYPE_INSTR(ADDW);
        end: addw_instr


        else if (`IS_INSTR(i_instruction, SUBW)) begin: subw_instr
            `OUTPUT_R_TYPE_INSTR(SUBW);
        end: subw_instr


        else if (`IS_INSTR(i_instruction, SLLW)) begin: sllw_instr
            `OUTPUT_R_TYPE_INSTR(SLLW);
        end: sllw_instr


        else if (`IS_INSTR(i_instruction, SRLW)) begin: srlw_instr
            `OUTPUT_R_TYPE_INSTR(SRLW);
        end: srlw_instr


        else if (`IS_INSTR(i_instruction, SRAW)) begin: sraw_instr
            `OUTPUT_R_TYPE_INSTR(SRAW);
        end: sraw_instr


        /* --------------------------------------------------------- */


        /* Control instructions. */


        else if (`IS_INSTR(i_instruction, FENCE)) begin: fence_instr
            /*
             * Executor will be responsible for extracting fm,
             * pred, and succ from the immediate value.
             */
            `OUTPUT_I_TYPE_INSTR(FENCE);
        end: fence_instr


        else if (`IS_INSTR(i_instruction, ECALL)) begin: ecall_instr
            `OUTPUT_NONE_TYPE_INSTR(ECALL);
        end: ecall_instr


        else if (`IS_INSTR(i_instruction, EBREAK)) begin: ebreak_instr
            `OUTPUT_NONE_TYPE_INSTR(EBREAK);
        end: ebreak_instr


        /* --------------------------------------------------------- */


        /* No instruction matched. */

        else begin: invalid_instr
            `OUTPUT_NONE_TYPE_INSTR(INVALID);
        end: invalid_instr


        /* --------------------------------------------------------- */
    end: detect_and_assign
endmodule: decoder


/* ------------------------------------------------------------------------- */


/* End of file. */
