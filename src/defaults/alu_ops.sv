// SPDX-License-Identifier: MIT

/* Define ALU op bits for internal microarchitecture. */


/* ------------------------------------------------------------------------- */


`define ALU_OPSIZE 4		/* Since we have 10 ops, we need 4 bits. */


/* ------------------------------------------------------------------------- */


/* Standard ISA instructions. */

`define ADD	4'b0000		/* Word addition, overflow ignored */
`define SUB	4'b0001		/* Word subtraction, overflow ignored */

`define OR	4'b0010		/* Bitwise OR */
`define AND	4'b0011		/* Bitwise AND */
`define XOR	4'b0100		/* Bitwise Exclusive OR */

`define SLT	4'b0101		/* Set less than (Y = A < B; signed A, B) */
`define SLTU	4'b0110		/* Set less than unsigned (unsigned A, B) */

`define SLL	4'b0111		/* Shift left (logical) */
`define SRL	4'b1000		/* Shift right (logical) */
`define SRA	4'b1001		/* Shift right (arithmetic) */


/* ------------------------------------------------------------------------- */


/* Custom instructions. */

`define NOT	4'b1010		/* Bitwise NOT / inversion */


/* ------------------------------------------------------------------------- */


/* End of file. */
