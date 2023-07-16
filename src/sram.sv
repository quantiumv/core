// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`define WORD_SIZE		32
`define L2_WORD_SIZE		5

`define DEFAULT_NUM_WORDS	4096	/* 16 kB memory. */
`define L2_DEFAULT_NUM_WORDS	12


/* ------------------------------------------------------------------------- */


/*
 * Module: Internal SRAM
 *
 * Parameters:
 *	num_words: Number of words in the memory.
 *	l2_num_words: log2(num_words).
 *
 * Input ports:
 *	i_clk: Clock signal (positive edge is used for trigger).
 *	i_read_enable_A: High to write at an address (#1).
 *	i_addr_read_A: Address #1 to read from.
 *	i_read_enable_B: High to write at an address (#2).
 *	i_addr_read_B: Address #2 to read from.
 *	i_write_enable: High to write at a memory location.
 *	i_addr_write: Address to write at.
 *	i_data_to_write: Data to write at the specified location.
 *
 * Output port:
 *	o_data_read_A: Data read from location / address #1.
 *	o_data_read_B: Data read from location / address #2.
 */
module sram #(
	parameter num_words = `DEFAULT_NUM_WORDS,
	parameter l2_num_words = `L2_DEFAULT_NUM_WORDS
) (
	input logic				i_clk,

	input logic				i_read_enable_A,
	input logic	[(l2_num_words - 1):0]	i_addr_read_A,
	output logic	[(`WORD_SIZE - 1):0]	o_data_read_A,

	input logic				i_read_enable_B,
	input logic	[(l2_num_words - 1):0]	i_addr_read_B,
	output logic	[(`WORD_SIZE - 1):0]	o_data_read_B,

	input logic				i_write_enable,
	input logic	[(l2_num_words - 1):0]	i_addr_write,
	input logic	[(`WORD_SIZE - 1):0]	i_data_to_write

);
	/* num_words memory locations, each WORD_SIZE bits wide. */
	reg [(`WORD_SIZE - 1):0]	memory [0:(num_words - 1)];

	always @(posedge i_clk) begin
		if (i_write_enable)
			memory[i_addr_write] <= i_data_to_write;

		if (i_read_enable_A)
			o_data_read_A <= memory[i_addr_read_A];

		if (i_read_enable_B)
			o_data_read_B <= memory[i_addr_read_B];
	end
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
