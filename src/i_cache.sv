module i_cache
(
    input logic clk,
    input logic rst,
    //Master Wishbone interface
    input  logic ACK,
    input  logic ERR,
    input  logic RTY,
    output logic STB,
    output logic CYC,
    output logic [31:0] ADR,
    input  logic [31:0] DAT_I,
    output logic [31:0] DAT_O,
    output logic [2:0]  CTI_O,
    output logic WE,
    //Output Data
    output logic [31:0] INS,
    output logic stall
);



endmodule
