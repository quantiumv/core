// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/alu_ops.sv"


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
module alu (
	input logic	[(`WORD_SIZE - 1):0]	i_operand_A,
	input logic	[(`ALU_OPSIZE - 1):0]	i_operation,
	input logic	[(`WORD_SIZE - 1):0]	i_operand_B,

	output logic	[(`WORD_SIZE - 1):0]	o_result
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
