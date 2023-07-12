// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Define operation codes based on the instruction set (see page 19 and 130).
 *
 * The lower 3 bits are funct3 (bits 14 - 12 in the instruction).
 * The MSB is bit 30 of the instruction.
 */

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


/*
 * Module: ALU
 *
 * Input ports:
 *	i_operand_A: Source 1 (rs1) in instruction.
 *	i_operation: The operation to perform (A op B).
 *	i_operand_B: Source 2 (rs2) in instruction.
 *
 * Output port:
 *	o_result: Result of (A op B).
 */
module alu(
	input logic	[31:0]	i_operand_A,
	input logic	[3:0]	i_operation,
	input logic	[31:0]	i_operand_B,

	output logic	[31:0]	o_result
);
	always_comb begin
		case (i_operation)

		/* Arithmetic operations */
		`ADD:	o_result = i_operand_A + i_operand_B;
		`SUB:	o_result = i_operand_A - i_operand_B;

		/* Bitwise operations */
		`OR:	o_result = i_operand_A | i_operand_B;
		`AND:	o_result = i_operand_A & i_operand_B;
		`XOR:	o_result = i_operand_A ^ i_operand_B;

		/* Comparison operations */
		`SLTU:	o_result = i_operand_A < i_operand_B;
		`SLT:	o_result = (~i_operand_A + 1) < (~i_operand_B + 1);

		/* Shift operations */
		`SLL:	o_result = i_operand_A << i_operand_B;
		`SRL:	o_result = i_operand_A >> i_operand_B;
		`SRA:	o_result = i_operand_A >>> i_operand_B;

		default: o_result = 0;

		endcase
	end
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
