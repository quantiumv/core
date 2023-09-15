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

`define OUTPUT_R_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= source_1;					\
	o_reg_2 <= source_2;					\
	o_imm_or_reg_3 <= destination;				\
;

`define OUTPUT_I_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= source_1;					\
	o_reg_2 <= destination;					\
	o_imm_or_reg_3 <= imm_i;				\
;

`define OUTPUT_S_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= source_1;					\
	o_reg_2 <= source_2;					\
	o_imm_or_reg_3 <= imm_s;				\
;

`define OUTPUT_B_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= source_1;					\
	o_reg_2 <= source_2;					\
	o_imm_or_reg_3 <= imm_b;				\
;

`define OUTPUT_U_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= 0;						\
	o_reg_2 <= destination;					\
	o_imm_or_reg_3 <= imm_u;				\
;

`define OUTPUT_J_TYPE_INSTR(instr_name)				\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= 0;						\
	o_reg_2 <= destination;					\
	o_imm_or_reg_3 <= imm_j;				\
;

`define OUTPUT_NONE_TYPE_INSTR(instr_name)			\
	o_decoded_instruction <= `INSTR_CODE(instr_name);	\
	o_reg_1 <= 0;						\
	o_reg_2 <= 0;						\
	o_imm_or_reg_3 <= 0;					\
;


/* ------------------------------------------------------------------------- */


/*
 * Module: Decoder
 *
 * Input ports:
 *	i_instruction: The instruction to decode.
 *	i_instruction_address: Address of the instruction to decode.
 *
 * Output ports:
 *	o_decoded_instruction: The internal code for the decoded instruction.
 *	o_instruction_address: Address of the decoded instruction
 *			       (same as i_instruction_address).
 *	o_reg_1: Address of a register.
 *	o_reg_2: Address of a register.
 *	o_imm_or_reg_3: Either an immediate value, or an address of a register.
 */
module decoder (
	input logic	[(`INSTR_SIZE - 1):0]	i_instruction,
	input logic	[(`WORD_SIZE - 1):0]	i_instruction_address,


	output logic	[(`INSTR_CODE_SIZE - 1):0]	o_decoded_instruction,
	output logic	[(`WORD_SIZE - 1):0]		o_instruction_address,
	output logic	[(`L2_REG_FILE_SIZE - 1):0]	o_reg_1,
	output logic	[(`L2_REG_FILE_SIZE - 1):0]	o_reg_2,
	output logic	[(`MAX_IMM_SIZE - 1):0]		o_imm_or_reg_3
);
	/* Pass through the instruction address. */
	assign o_instruction_address = i_instruction_address;

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

	logic [(`S_IMM_SIZE - 1):0] imm_s;
	assign imm_s = {i_instruction[`S_IMM_H_MSB:`S_IMM_H_LSB],
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

	logic [(`J_IMM_SIZE - 1):0] imm_j;
	assign imm_j = {
		i_instruction[`J_IMM_MSB],
		i_instruction[`J_IMM_MID_BITS_MSB:`J_IMM_MID_BITS_LSB],
		i_instruction[`J_IMM_POST_MID_BIT],
		i_instruction[`J_IMM_LOW_BITS_MSB:`J_IMM_LOW_BITS_LSB],
		1'b0
	};


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
			`OUTPUT_I_TYPE_INSTR(SLLI);
		end: slli_instr


		else if (`IS_INSTR(i_instruction, SLL)) begin: sll_instr
			`OUTPUT_R_TYPE_INSTR(SLL);
		end: sll_instr


		else if (`IS_INSTR(i_instruction, SRLI)) begin: srli_instr
			`OUTPUT_I_TYPE_INSTR(SRLI);
		end: srli_instr


		else if (`IS_INSTR(i_instruction, SRL)) begin: srl_instr
			`OUTPUT_R_TYPE_INSTR(SRL);
		end: srl_instr


		else if (`IS_INSTR(i_instruction, SRAI)) begin: srai_instr
			`OUTPUT_I_TYPE_INSTR(SRAI);
		end: srai_instr


		else if (`IS_INSTR(i_instruction, SRA)) begin: sra_instr
			`OUTPUT_R_TYPE_INSTR(SRA);
		end: sra_instr


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
