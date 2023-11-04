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
 *	- Dual port combinational reads and single port synchronous write.
 *	- Program counter read (comb) and write (sync).
 *	- Dedicated return address (r1) and stack pointer (r2) outputs.
 *
 * Input ports:
 *	i_clk: Clock signal (positive edge is used for write).
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
	input logic	[(`WORD_SIZE - 1):0]	i_load_gpr_data
);
	/* num_regs general purpose registers, each WORD_SIZE bit wide. */
	logic [(`WORD_SIZE - 1):0]	gp_registers [0:(num_regs - 1)];


	/* Read at both ports (NB: r0 is hardwired to 0). */
	assign o_read_gpr_A_data = gp_registers[i_read_gpr_A_sel];
	assign o_read_gpr_B_data = gp_registers[i_read_gpr_B_sel];


	/* Write. */
	always @(posedge i_clk) begin: write
		/*
		 * Load GPR.
		 * NB: We don't write at r0. Thus, select must be non-zero.
		 */
		if (i_load_gpr_sel) begin: load_gpr
			if (i_load_gpr)
				gp_registers[0] <= 0;
			else
				gp_registers[i_load_gpr_sel] <= i_load_gpr_data;
		end: load_gpr
	end: write
endmodule: register_file

/* ------------------------------------------------------------------------- */


/* End of file. */
