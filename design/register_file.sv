// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Register file
 *
 * Parameters:
 *  - num_regs: Number of GPRs in the file (default = REG_FILE_SIZE).
 *  - l2_num_regs: log2(num_regs) (default = L2_REG_FILE_SIZE).
 *
 * Features:
 *  - Size = num_regs x WORD_SIZE
 *  - Dual port combinational reads and single port synchronous write.
 *  - x0 always reads as 0, regardless of what (if anything) is ever
 *    written to it -- writes to x0 are simply no-ops, as required by the
 *    ISA. (No PC or dedicated RA/SP ports here -- those live in core.sv;
 *    this module is a plain 32x64 register file.)
 *
 * Input ports:
 *  i_clk: Clock signal (positive edge is used for write).
 *  i_read_gpr_A_sel: Register select #1 for read.
 *  i_read_gpr_B_sel: Register select #2 for read.
 *  i_load_gpr: High to write i_load_gpr_data into the selected register.
 *  i_load_gpr_sel: Register select for write.
 *  i_load_gpr_data: Data to write into the selected register.
 *
 * Output ports:
 *  o_read_gpr_A_data: Data read from the selected register #1.
 *  o_read_gpr_B_data: Data read from the selected register #2.
 */
module register_file #(
    parameter num_regs = `REG_FILE_SIZE,
    parameter l2_num_regs = `L2_REG_FILE_SIZE
) (
    input logic i_clk,

    input logic     [(l2_num_regs - 1):0]   i_read_gpr_A_sel,
    output logic    [(`WORD_SIZE - 1):0]    o_read_gpr_A_data,

    input logic     [(l2_num_regs - 1):0]   i_read_gpr_B_sel,
    output logic    [(`WORD_SIZE - 1):0]    o_read_gpr_B_data,

    input logic                         i_load_gpr,
    input logic [(l2_num_regs - 1):0]   i_load_gpr_sel,
    input logic [(`WORD_SIZE - 1):0]    i_load_gpr_data
);
    /* num_regs general purpose registers, each WORD_SIZE bit wide. */
    logic [(`WORD_SIZE - 1):0]  gp_registers [0:(num_regs - 1)];

    /*
     * Simulation-only zero-fill, same reasoning as imem.sv/dmem.sv: real
     * hardware has no defined power-up register state, but zeroing here
     * keeps waveform/$display output readable and makes "this register
     * was never written" a clean, checkable 0 instead of 'X in
     * testbenches.
     */
    integer init_i;
    initial begin
        for (init_i = 0; init_i < num_regs; init_i = init_i + 1)
            gp_registers[init_i] = '0;
    end

    /*
     * Read at both ports. x0 is forced to 0 here explicitly -- it's never
     * actually written (see below), so without this the array's index-0
     * slot would sit at its uninitialized 'X value for the entire
     * simulation instead of reading as the architectural constant 0.
     */
    assign o_read_gpr_A_data = (i_read_gpr_A_sel == 0) ? '0 : gp_registers[i_read_gpr_A_sel];
    assign o_read_gpr_B_data = (i_read_gpr_B_sel == 0) ? '0 : gp_registers[i_read_gpr_B_sel];


    /* Write. */
    always @(posedge i_clk) begin: write
        /*
         * Write only when the caller asks for one (i_load_gpr) AND targets
         * a real register (i_load_gpr_sel != 0 -- x0 excluded, since
         * writes to it are architecturally no-ops; handled here by simply
         * never writing gp_registers[0], rather than writing it and
         * masking the value back out on read).
         */
        if (i_load_gpr && (i_load_gpr_sel != 0)) begin: load_gpr
            gp_registers[i_load_gpr_sel] <= i_load_gpr_data;
        end: load_gpr
    end: write
endmodule: register_file


/* ------------------------------------------------------------------------- */


/* End of file. */
