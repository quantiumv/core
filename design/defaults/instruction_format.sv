// SPDX-License-Identifier: MIT

/*
 * Instruction format related definitions - Positions of bits and fields in
 * the instruction, size of a field, etc.
 *
 * It would be helpful to open page 16 of the RISC-V spec.
 */

/* ------------------------------------------------------------------------- */


/* Common (including R (register) type). */

`define INSTR_SIZE      32
`define L2_INSTR_SIZE   5

`define FUNCT_H_SIZE    7   /* H stands for high. */
`define FUNCT_H_MSB     31
`define FUNCT_H_LSB     25

`define SRC2_SIZE       5
`define SRC2_MSB        24
`define SRC2_LSB        20

`define SRC1_SIZE       5
`define SRC1_MSB        19
`define SRC1_LSB        15

`define FUNCT_L_SIZE    3   /* L stands for low. */
`define FUNCT_L_MSB     14
`define FUNCT_L_LSB     12

`define DEST_SIZE       5
`define DEST_MSB        11
`define DEST_LSB        7

`define OPCODE_SIZE     7
`define OPCODE_MSB      6
`define OPCODE_LSB      0


/* ------------------------------------------------------------------------- */


/* For I (immediate) type. */

`define I_IMM_SIZE  12
`define I_IMM_MSB   31
`define I_IMM_LSB   20


/*
 * Shift amount fields. These overlap the I-immediate's bit range but are
 * NOT sign-extended like a normal I-immediate -- a shift amount is an
 * unsigned magnitude, and under RV64I only its low bits are meaningful
 * (the rest of what would be the I-immediate field is funct6/funct7,
 * fixed by the instruction's mask/pattern, not part of the shift amount).
 *
 * SHAMT (6 bits, instr[25:20]): SLLI/SRLI/SRAI -- full WORD_SIZE shifts,
 * so the amount needs enough bits for log2(64)=6.
 *
 * WSHAMT (5 bits, instr[24:20]): SLLIW/SRLIW/SRAIW -- these are always
 * 32-bit operations regardless of WORD_SIZE, so 5 bits (log2(32)) is
 * always enough, and bit 25 belongs to funct7 for these instead.
 */

`define SHAMT_SIZE  6
`define SHAMT_MSB   25
`define SHAMT_LSB   20

`define WSHAMT_SIZE 5
`define WSHAMT_MSB  24
`define WSHAMT_LSB  20


/* ------------------------------------------------------------------------- */


/* For S (store) type. */

`define S_IMM_SIZE  12

`define S_IMM_H_MSB 31
`define S_IMM_H_LSB 25

`define S_IMM_L_MSB 11
`define S_IMM_L_LSB 7


/* ------------------------------------------------------------------------- */


/*
 * For B (branch) type (Similar to S type).
 *
 * Immediate value encodes branch offsets in multiples of 2.
 * Thus, imm[12:1] is stored as for multiples of 2, last bit is always 0, so
 * there is no point in storing it.
 */

`define B_IMM_SIZE          13

`define B_IMM_SIGN_BIT      31  /* Bit 12. */
`define B_IMM_HIGH_BIT      7   /* Bit 11. */

/* imm[10:5]. */
`define B_IMM_MID_BITS_MSB  30
`define B_IMM_MID_BITS_LSB  25

/* imm[4:1]. */
`define B_IMM_LOW_BITS_MSB  11
`define B_IMM_LOW_BITS_LSB  8


/* ------------------------------------------------------------------------- */


/*
 * For U (upper immediate) type.
 *
 * The instruction contains bits 31 to 12 (= upper 20 bits) of a 32 bit
 * immediate value. Remaining 12 lower bits are typically zeroed out.
 * Equivalent to having (imm_20_bits << 12). So we have imm[31:12].
 */

`define U_IMM_SIZE  20
`define U_IMM_MSB   31
`define U_IMM_LSB   12


/* ------------------------------------------------------------------------- */


/*
 * For J (jump) type (Similar to U type).
 *
 * Equivalent to having (imm_20_bits << 1). So we have imm[20:1] (as there is
 * no need to store last bit which will always be 0).
 */

`define J_IMM_SIZE          21

/* Bit 20. */
`define J_IMM_MSB           31

/* imm[19:12]. */
`define J_IMM_MID_BITS_MSB  19
`define J_IMM_MID_BITS_LSB  12

/* Bit 11. */
`define J_IMM_POST_MID_BIT  20

/* imm[10:1]. */
`define J_IMM_LOW_BITS_MSB  30
`define J_IMM_LOW_BITS_LSB  21


/* ------------------------------------------------------------------------- */


`define MAX_IMM_SIZE    21  /* Maximum width of an immediate possible. */


/* ------------------------------------------------------------------------- */


/* End of file. */
