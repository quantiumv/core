// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Internal SRAM With Wishbone BUS
 *
 * Parameters:
 *  num_words: Number of words in the memory (default = 4096).
 *
 */
module sram #(
    parameter num_words = 4096
) (
    input logic clk,
    input logic rst,

    // Wishbone signals
    input  logic [31:0] addr_i,
    input  logic [31:0] dat_i,
    output logic [31:0] dat_o,

    output logic ack_o,
    output logic err_o,
    input logic cyc_i,
    input logic stb_i,
    input logic we_i
);
    reg [31:0] memory [0:(num_words - 1)];

    // For address calculation
    localparam ADDR_WIDTH = $clog2(num_words);
    logic [ADDR_WIDTH-1:0] word_addr;
    logic addr_valid;

    assign word_addr = addr_i[ADDR_WIDTH+1:2]; // Byte to word address
    assign addr_valid = (addr_i[31:ADDR_WIDTH+2] == 0); // Check upper bits are 0

    always @(posedge clk) begin
        if (rst)
        begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 32'b0;
        end 
        else
        begin
            if (cyc_i && stb_i) begin
                if (addr_valid) begin
                    if (we_i)
                    begin
                        memory[word_addr] <= dat_i;
                    end
                    else
                    begin
                        dat_o <= memory[word_addr];
                    end
                    ack_o <= 1'b1;
                    err_o <= 1'b0;
                end 
                else
                begin
                    ack_o <= 1'b0;
                    err_o <= 1'b1;
                end
            end 
            else
            begin
                ack_o <= 1'b0;
                err_o <= 1'b0;
            end
        end
    end
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
