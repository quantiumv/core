// SPDX-License-Identifier: MIT

/* Define ALU op bits for internal microarchitecture. */


/* ------------------------------------------------------------------------- */


`define ALU_OPSIZE 4    /* Since we have 14 ops, we need 4 bits. */


/* ------------------------------------------------------------------------- */


/* Standard ISA instructions. */

`define ADD     4'b0000     /* Word addition, overflow ignored */
`define SUB     4'b0001     /* Word subtraction, overflow ignored */

`define OR      4'b0010     /* Bitwise OR */
`define AND     4'b0011     /* Bitwise AND */
`define XOR     4'b0100     /* Bitwise Exclusive OR */

`define SLT     4'b0101     /* Set less than (Y = A < B; signed A, B) */
`define SLTU    4'b0110     /* Set less than unsigned (unsigned A, B) */

`define SLL     4'b0111     /* Shift left (logical) */
`define SRL     4'b1000     /* Shift right (logical) */
`define SRA     4'b1001     /* Shift right (arithmetic) */


/* ------------------------------------------------------------------------- */


/* Custom instructions. */

`define NOT     4'b1010     /* Bitwise NOT / inversion */


/* ------------------------------------------------------------------------- */


/*
 * RV64I word ops (operate on the low 32 bits of the operands, shift amount
 * is always 5 bits regardless of WORD_SIZE, result is sign-extended back to
 * WORD_SIZE bits).
 *
 * These can NOT be synthesized by truncating SLL/SRL/SRA's 64-bit result:
 * unlike add/sub, a shift is not width-agnostic -- shifting a 64-bit operand
 * by a 6-bit amount and then truncating to 32 bits gives a different answer
 * than shifting a 32-bit operand by a 5-bit amount (bits enter/exit from the
 * wrong end once the shift amount's bit 5 differs, and bits above 31 that
 * shouldn't participate at all can leak into the low 32 via SLL). So these
 * get their own dedicated ops instead of reusing SLL/SRL/SRA.
 */

`define SLLW    4'b1011     /* Shift left word: (A[31:0] << B[4:0]), sign-extended */
`define SRLW    4'b1100     /* Shift right word logical: (A[31:0] >> B[4:0]), sign-extended */
`define SRAW    4'b1101     /* Shift right word arithmetic: (A[31:0] >>> B[4:0]), sign-extended */


/* ------------------------------------------------------------------------- */


/* End of file. */
