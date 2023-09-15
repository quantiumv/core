// SPDX-License-Identifier: MIT

/*
 * Instruction codes for micro-architecture.
 *
 * We need a way to convey the decoded instruction from the decoder to the
 * executor in order to execute the appropriate operation on the next clock
 * cycle.
 *
 * Thus, we will define codes here for each instruction.
 */


/* Width of the codes. */
`define INSTR_CODE_SIZE	6

/* Code for signifying invalid instruction. */
`define INSTR_CODE_INVALID	000000


/* ------------------------------------------------------------------------- */


/* Upper immediate instructions. */

`define INSTR_CODE_LUI		000001
`define INSTR_CODE_AUIPC	000010


/* ------------------------------------------------------------------------- */


/* Jump instructions. */

`define INSTR_CODE_JAL	000011
`define INSTR_CODE_JALR	000100


/* ------------------------------------------------------------------------- */


/* Branch instructions. */

`define INSTR_CODE_BEQ	000101
`define INSTR_CODE_BNE	000110
`define INSTR_CODE_BLT	000111
`define INSTR_CODE_BGE	001000
`define INSTR_CODE_BLTU	001001
`define INSTR_CODE_BGEU	001010


/* ------------------------------------------------------------------------- */


/* Load instructions. */

`define INSTR_CODE_LB	001011
`define INSTR_CODE_LH	001100
`define INSTR_CODE_LW	001101
`define INSTR_CODE_LBU	001110
`define INSTR_CODE_LHU	001111


/* ------------------------------------------------------------------------- */


/* Store instructions. */

`define INSTR_CODE_SB	010000
`define INSTR_CODE_SH	010001
`define INSTR_CODE_SW	010010


/* ------------------------------------------------------------------------- */


/* ALU instructions. */

`define INSTR_CODE_ADDI		010011
`define INSTR_CODE_ADD		010100

`define INSTR_CODE_SUB		010101

`define INSTR_CODE_SLTI		010110
`define INSTR_CODE_SLT		010111

`define INSTR_CODE_SLTIU	011000
`define INSTR_CODE_SLTU		011001

`define INSTR_CODE_XORI		011010
`define INSTR_CODE_XOR		011011

`define INSTR_CODE_ORI		011100
`define INSTR_CODE_OR		011101

`define INSTR_CODE_ANDI		011110
`define INSTR_CODE_AND		011111

`define INSTR_CODE_SLLI		100000
`define INSTR_CODE_SLL		100001

`define INSTR_CODE_SRLI		100010
`define INSTR_CODE_SRL		100011

`define INSTR_CODE_SRAI		100100
`define INSTR_CODE_SRA		100101


/* ------------------------------------------------------------------------- */


/* Control instructions. */

`define INSTR_CODE_FENCE	100110
`define INSTR_CODE_ECALL	100111
`define INSTR_CODE_EBREAK	101000


/* ------------------------------------------------------------------------- */


/* End of file. */
