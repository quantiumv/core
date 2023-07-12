// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: Register file
 *
 * Input ports:
 *	i_clk: Clock signal (negative edge is used for trigger).
 *	i_select: Register select (0 to 31).
 *	i_load: High: Load data; Low: Read data.
 *	i_data_to_load: Data to load at the selected register (i_load = high).
 *
 * Output port:
 *	o_extracted_data: Data read from the selected register (i_load = low).
 */
module register_file(
	input logic		i_clk,

	input logic	[4:0]	i_select,

	input logic		i_load,
	input logic	[31:0]	i_data_to_load,

	output logic	[31:0]	o_extracted_data
);
	/* 32 registers, each 32 bit wide. */
	reg [31:0] registers [0:31];

	always @(negedge i_clk) begin
		if (i_load)
			registers[i_select] <= i_data_to_load;
		else
			o_extracted_data <= registers[i_select];
	end
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
