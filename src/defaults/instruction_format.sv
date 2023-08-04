// SPDX-License-Identifier: MIT

/*
 * Instruction format related definitions - Positions of bits and fields in
 * the instruction, size of a field, etc.
 *
 * It would be helpful to open page 16 of the RISC-V spec.
 */

/* ------------------------------------------------------------------------- */


/* Common. */

`define INSTR_SIZE		32
`define L2_INSTR_SIZE		5

`define FUNCT_H_SIZE	7	/* H stands for high. */
`define FUNCT_H_MSB	31
`define FUNCT_H_LSB	25

`define SRC2_SIZE	5
`define SRC2_MSB	24
`define SRC2_LSB	20

`define SRC1_SIZE	5
`define SRC1_MSB	19
`define SRC1_LSB	15

`define FUNCT_L_SIZE	3	/* L stands for low. */
`define FUNCT_L_MSB	14
`define FUNCT_L_LSB	12

`define DEST_SIZE	5
`define DEST_MSB	11
`define DEST_LSB	7

`define OPCODE_SIZE	7
`define OPCODE_MSB	6
`define OPCODE_LSB	0


/* ------------------------------------------------------------------------- */


/* For I type. */

`define I_IMM_SIZE	12
`define I_IMM_MSB	31
`define I_IMM_LSB	20


/* ------------------------------------------------------------------------- */


/* For S type. */

`define S_IMM_SIZE	12

`define S_IMM_H_MSB	31
`define S_IMM_H_LSB	25

`define S_IMM_L_MSB	11
`define S_IMM_L_LSB	7


/* ------------------------------------------------------------------------- */


/*
 * For B type (Similar to S type).
 *
 * Immediate value encodes branch offsets in multiples of 2.
 * Thus, imm[12:1] is stored as for multiples of 2, last bit is always 0, so
 * there is no point in storing it.
 */

`define B_IMM_SIZE	12

`define B_IMM_SIGN_BIT	31	/* Bit 12. */
`define B_IMM_HIGH_BIT	7	/* Bit 11. */

/* imm[10:5]. */
`define B_IMM_MID_BITS_MSB	30
`define B_IMM_MID_BITS_LSB	25

/* imm[4:1]. */
`define B_IMM_LOW_BITS_MSB	11
`define B_IMM_LOW_BITS_LSB	8


/* ------------------------------------------------------------------------- */


/*
 * For U type.
 *
 * The instruction contains bits 31 to 12 (= upper 20 bits) of a 32 bit
 * immediate value. Remaining 12 lower bits are typically zeroed out.
 * Equivalent to having (imm_20_bits << 12). So we have imm[31:12].
 */

`define U_IMM_SIZE	20
`define U_IMM_MSB	31
`define U_IMM_LSB	12


/* ------------------------------------------------------------------------- */


/*
 * For J type (Similar to U type).
 *
 * Equivalent to having (imm_20_bits << 1). So we have imm[20:1].
 */

`define B_IMM_SIZE	20

/* Bit 20. */
`define B_IMM_MSB		31

/* imm[19:12]. */
`define B_IMM_LOW_BITS_MSB	19
`define B_IMM_LOW_BITS_LSB	12

/* Bit 11. */
`define B_IMM_MID_BIT		20

/* imm[10:1]. */
`define B_IMM_MID_BITS_MSB	30
`define B_IMM_MID_BITS_LSB	21


/* ------------------------------------------------------------------------- */


/* End of file. */
