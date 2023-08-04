// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Register file
 *
 * Parameters:
 *	- num_regs: Number of GPRs in the file (default = REG_FILE_SIZE).
 *	- l2_num_regs: log2(num_regs) (default = L2_REG_FILE_SIZE).
 *
 * Features:
 *	- Size = num_regs x WORD_SIZE
 *	- Dual port reads and single port write.
 *	- Program counter read and write.
 *	- Dedicated link register (r1) and stack pointer (r2) outputs.
 *
 * Input ports:
 *	i_clk: Clock signal (positive edge is used for trigger).
 *	i_read_gpr_A_sel: Register select #1 for read.
 *	i_read_gpr_B_sel: Register select #2 for read.
 *	i_load_gpr: High to load into a register (r1 to r31 only).
 *	i_load_gpr_sel: Register select for load/write.
 *	i_load_gpr_data: Data to load into the selected register.
 *	i_load_pc: High to load into program counter (preferred).
 *	i_load_pc_data: Data to load in the program counter.
 *
 * Output ports:
 *	o_read_gpr_A_data: Data read from the selected register #1.
 *	o_read_gpr_B_data: Data read from the selected register #2.
 *	o_program_counter: Data read from the program counter.
 *	o_link_register: Data read from the conventional link register (r1).
 *	o_stack_pointer: Data read from the conventional stack pointer (r2).
 */
module register_file #(
	parameter num_regs = `REG_FILE_SIZE,
	parameter l2_num_regs = `L2_REG_FILE_SIZE
) (
	input logic				i_clk,

	input logic	[(l2_num_regs - 1):0]	i_read_gpr_A_sel,
	output logic	[(`WORD_SIZE - 1):0]	o_read_gpr_A_data,

	input logic	[(l2_num_regs - 1):0]	i_read_gpr_B_sel,
	output logic	[(`WORD_SIZE - 1):0]	o_read_gpr_B_data,

	input logic				i_load_gpr,
	input logic	[(l2_num_regs - 1):0]	i_load_gpr_sel,
	input logic	[(`WORD_SIZE - 1):0]	i_load_gpr_data,

	input logic				i_load_pc,
	input logic	[(`WORD_SIZE - 1):0]	i_load_pc_data,
	output logic	[(`WORD_SIZE - 1):0]	o_program_counter,

	output logic	[(`WORD_SIZE - 1):0]	o_link_register,
	output logic	[(`WORD_SIZE - 1):0]	o_stack_pointer
);
	/*
	 * num_regs general purpose registers, each WORD_SIZE bit wide.
	 *
	 * r0 is to be hardwired to 0 (ref. page 13 of RISC-V spec).
	 * Thus, just make one register less. (for eg. [0:30] and not [0:31]).
	 * Thus, subtract 2 from num_regs in the initialisation.
	 */
	reg [(`WORD_SIZE - 1):0]	gp_registers [0:(num_regs - 2)];


	/* r1 is link register, r2 is stack pointer (ref. page 14). */
	assign o_link_register = gp_registers[0];
	assign o_stack_pointer = gp_registers[1];


	/* Program counter is an additional register (ref. page 13, 14). */
	reg [(`WORD_SIZE - 1):0] program_counter;
	assign o_program_counter = program_counter;


	/* Read at both ports (NB: r0 is hardwired to 0). */
	assign o_read_gpr_A_data = i_read_gpr_A_sel ?
				gp_registers[i_read_gpr_A_sel - 1] : 'b0;
	assign o_read_gpr_B_data = i_read_gpr_B_sel ?
				gp_registers[i_read_gpr_B_sel - 1] : 'b0;


	/* Write. */
	always @(posedge i_clk) begin: write
		if (i_load_pc)
			program_counter <= i_load_pc_data;

		/* Don't write at r0. Decrement select to offset for r0. */
		if (i_load_gpr && i_load_gpr_sel)
			gp_registers[i_load_gpr_sel - 1] <= i_load_gpr_data;
	end: write
endmodule: register_file

/* ------------------------------------------------------------------------- */


/* End of file. */
