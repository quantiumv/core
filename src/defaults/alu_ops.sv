// SPDX-License-Identifier: MIT

/*
 * Define operation codes based on the instruction set (see page 19 and 130).
 *
 * The lower 3 bits are funct3 (bits 14 - 12 in the instruction).
 * The MSB is bit 30 of the instruction.
 */


/* ------------------------------------------------------------------------- */


`define ALU_OPSIZE 4		/* Since we have 9 ops, we need 4 bits. */

`define ADD	4'b0_000	/* Word addition, overflow ignored */
`define SUB	4'b1_000	/* Word subtraction, overflow ignored */

`define SLL	4'b0_001	/* Shift left (logical) */
`define SLT	4'b0_010	/* Set less than (Y = A < B; signed A, B) */
`define SLTU	4'b0_011	/* Set less than unsigned (unsigned A, B) */
`define XOR	4'b0_100	/* Bitwise Exclusive OR */

`define SRL	4'b0_101	/* Shift right (logical) */
`define SRA	4'b1_101	/* Shift right (arithmetic) */

`define OR	4'b0_110	/* Bitwise OR */
`define AND	4'b0_111	/* Bitwise AND */


/* ------------------------------------------------------------------------- */
