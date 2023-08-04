// SPDX-License-Identifier: MIT

/*
 * Instruction and their masks for all instructions.
 *
 * The instructions assume other things in between as masked to 0.
 *
 * It would be helpful to open page 130 of the RISC-V spec.
 */

/* ------------------------------------------------------------------------- */


/* Upper immediate instructions. */

`define INSTR_LUI		32'b0110111
`define INSTR_MASK_LUI		32'b1111111

`define INSTR_AUIPC		32'b0010111
`define INSTR_MASK_AUIPC	32'b1111111


/* ------------------------------------------------------------------------- */


/* Jump instructions. */

`define INSTR_JAL	32'b1101111
`define INSTR_MASK_JAL	32'b1111111

`define INSTR_JALR	{17'b0, 3'b000, 5'b0, 7'b1100111}
`define INSTR_MASK_JALR	{17'b0, 3'b111, 5'b0, 7'b1111111}


/* ------------------------------------------------------------------------- */


/* Branch instructions. */

`define BRANCH_INSTR_CREATE(funct3)	{17'b0, funct3, 5'b0, 7'b1100011}
`define BRANCH_INSTRS_MASK		{17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_BEQ	`BRANCH_INSTR_CREATE(3'b000)
`define INSTR_MASK_BEQ	`BRANCH_INSTRS_MASK

`define INSTR_BNE	`BRANCH_INSTR_CREATE(3'b001)
`define INSTR_MASK_BNE	`BRANCH_INSTRS_MASK

`define INSTR_BLT	`BRANCH_INSTR_CREATE(3'b100)
`define INSTR_MASK_BLT	`BRANCH_INSTRS_MASK

`define INSTR_BGE	`BRANCH_INSTR_CREATE(3'b101)
`define INSTR_MASK_BGE	`BRANCH_INSTRS_MASK

`define INSTR_BLTU	`BRANCH_INSTR_CREATE(3'b110)
`define INSTR_MASK_BLTU	`BRANCH_INSTRS_MASK

`define INSTR_BGEU	`BRANCH_INSTR_CREATE(3'b111)
`define INSTR_MASK_BGEU	`BRANCH_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef BRANCH_INSTR_CREATE
`undef BRANCH_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Load instructions. */

`define LOAD_INSTR_CREATE(funct3)	{17'b0, funct3, 5'b0, 7'b0000011}
`define LOAD_INSTRS_MASK		{17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_LB	`LOAD_INSTR_CREATE(3'b000)
`define INSTR_MASK_LB	`LOAD_INSTRS_MASK

`define INSTR_LH	`LOAD_INSTR_CREATE(3'b001)
`define INSTR_MASK_LH	`LOAD_INSTRS_MASK

`define INSTR_LW	`LOAD_INSTR_CREATE(3'b010)
`define INSTR_MASK_LW	`LOAD_INSTRS_MASK

`define INSTR_LBU	`LOAD_INSTR_CREATE(3'b100)
`define INSTR_MASK_LBU	`LOAD_INSTRS_MASK

`define INSTR_LHU	`LOAD_INSTR_CREATE(3'b101)
`define INSTR_MASK_LHU	`LOAD_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef LOAD_INSTR_CREATE
`undef LOAD_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Store instructions. */

`define STORE_INSTR_CREATE(funct3)	{17'b0, funct3, 5'b0, 7'b0100011}
`define STORE_INSTRS_MASK		{17'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_SB	`STORE_INSTR_CREATE(3'b000)
`define INSTR_MASK_SB	`STORE_INSTRS_MASK

`define INSTR_SH	`STORE_INSTR_CREATE(3'b001)
`define INSTR_MASK_SH	`STORE_INSTRS_MASK

`define INSTR_SW	`STORE_INSTR_CREATE(3'b010)
`define INSTR_MASK_SW	`STORE_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef STORE_INSTR_CREATE
`undef STORE_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Immediate ALU instructions. */


/* Non-shift instructions. */

`define IMM_AL_INSTR_CREATE(funct3)	{17'b0, funct3, 5'b0, 7'b0010011}
`define IMM_AL_INSTRS_MASK		{17'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_ADDI		`IMM_AL_INSTR_CREATE(3'b000)
`define INSTR_MASK_ADDI		`IMM_AL_INSTRS_MASK

`define INSTR_SLTI		`IMM_AL_INSTR_CREATE(3'b010)
`define INSTR_MASK_SLTI		`IMM_AL_INSTRS_MASK

`define INSTR_SLTIU		`IMM_AL_INSTR_CREATE(3'b011)
`define INSTR_MASK_SLTIU	`IMM_AL_INSTRS_MASK

`define INSTR_XORI		`IMM_AL_INSTR_CREATE(3'b100)
`define INSTR_MASK_XORI		`IMM_AL_INSTRS_MASK

`define INSTR_ORI		`IMM_AL_INSTR_CREATE(3'b110)
`define INSTR_MASK_ORI		`IMM_AL_INSTRS_MASK

`define INSTR_ANDI		`IMM_AL_INSTR_CREATE(3'b111)
`define INSTR_MASK_ANDI		`IMM_AL_INSTRS_MASK


/* Shift instructions. */

`define IMM_SHIFT_INSTR_CREATE(bit30, funct3) \
	{1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0010011}
`define IMM_SHIFT_INSTRS_MASK	{7'b1111111, 10'b0, 3'b111, 5'b0, 7'b1111111}

`define INSTR_SLLI	`IMM_SHIFT_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLLI	`IMM_SHIFT_INSTRS_MASK

`define INSTR_SRLI	`IMM_SHIFT_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRLI	`IMM_SHIFT_INSTRS_MASK

`define INSTR_SRAI	`IMM_SHIFT_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRAI	`IMM_SHIFT_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef IMM_AL_INSTR_CREATE
`undef IMM_AL_INSTRS_MASK
`undef IMM_SHIFT_INSTR_CREATE
`undef IMM_SHIFT_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* Non-immediate (3 register operands) ALU instructions. */

`define ALU_INSTR_CREATE(bit30, funct3) \
	{1'b0, bit30, 15'b0, funct3, 5'b0, 7'b0110011}
`define ALU_INSTRS_MASK	{7'b1111111, 10'b0, 3'b111, 5'b0, 7'b1111111}


`define INSTR_ADD	`ALU_INSTR_CREATE(1'b0, 3'b000)
`define INSTR_MASK_ADD	`ALU_INSTRS_MASK

`define INSTR_SUB	`ALU_INSTR_CREATE(1'b1, 3'b000)
`define INSTR_MASK_SUB	`ALU_INSTRS_MASK

`define INSTR_SLL	`ALU_INSTR_CREATE(1'b0, 3'b001)
`define INSTR_MASK_SLL	`ALU_INSTRS_MASK

`define INSTR_SLT	`ALU_INSTR_CREATE(1'b0, 3'b010)
`define INSTR_MASK_SLT	`ALU_INSTRS_MASK

`define INSTR_SLTU	`ALU_INSTR_CREATE(1'b0, 3'b011)
`define INSTR_MASK_SLTU	`ALU_INSTRS_MASK

`define INSTR_XOR	`ALU_INSTR_CREATE(1'b0, 3'b100)
`define INSTR_MASK_XOR	`ALU_INSTRS_MASK

`define INSTR_SRL	`ALU_INSTR_CREATE(1'b0, 3'b101)
`define INSTR_MASK_SRL	`ALU_INSTRS_MASK

`define INSTR_SRA	`ALU_INSTR_CREATE(1'b1, 3'b101)
`define INSTR_MASK_SRA	`ALU_INSTRS_MASK

`define INSTR_OR	`ALU_INSTR_CREATE(1'b0, 3'b110)
`define INSTR_MASK_OR	`ALU_INSTRS_MASK

`define INSTR_AND	`ALU_INSTR_CREATE(1'b0, 3'b111)
`define INSTR_MASK_AND	`ALU_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef ALU_INSTR_CREATE
`undef ALU_INSTRS_MASK


/* ------------------------------------------------------------------------- */


`define INSTR_FENCE		{17'b0, 3'b000, 5'b0, 7'b0001111}
`define INSTR_MASK_FENCE	{17'b0, 3'b111, 5'b0, 7'b0001111}


/* ------------------------------------------------------------------------- */


/* Environment instructions. */

`define ENV_INSTR_CREATE(bit20)	{11'b0, bit20, 13'b0, 7'b1110011}
`define ENV_INSTRS_MASK		32'hFFFFFFFF


`define INSTR_ECALL		`ENV_INSTR_CREATE(1'b0)
`define INSTR_MASK_ECALL	`ENV_INSTRS_MASK

`define INSTR_EBREAK		`ENV_INSTR_CREATE(1'b1)
`define INSTR_MASK_EBREAK	`ENV_INSTRS_MASK


/* Don't expose temporary macros used for readability / generation outside. */

`undef ENV_INSTR_CREATE
`undef ENV_INSTRS_MASK


/* ------------------------------------------------------------------------- */


/* End of file. */
