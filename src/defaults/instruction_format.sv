// SPDX-License-Identifier: MIT

/*
 * Instruction format related definitions.
 * It would be helpful to open page 16 of the RISC-V spec.
 */

/* ------------------------------------------------------------------------- */


`define INSTR_SIZE		32
`define L2_INSTR_SIZE		5

`define FUNCT_H_SIZE	7
`define FUNCT_H_MSB	31
`define FUNCT_H_LSB	25

`define SRC2_SIZE	5
`define SRC2_MSB	24
`define SRC2_LSB	20

`define SRC1_SIZE	5
`define SRC1_MSB	19
`define SRC1_LSB	15

`define FUNCT_L_SIZE	3
`define FUNCT_L_MSB	14
`define FUNCT_L_LSB	12

`define DEST_SIZE	5
`define DEST_MSB	11
`define DEST_LSB	7

`define OPCODE_SIZE	7
`define OPCODE_MSB	6
`define OPCODE_LSB	0


/* ------------------------------------------------------------------------- */


/* End of file. */
