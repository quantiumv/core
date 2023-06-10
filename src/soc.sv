`timescale 1ps/1ps

`include "debug_def.sv"

module soc
(
    `ifndef __sim__
    input logic clk, 
    input logic rst
    `endif
);

//Internal RAM for BOOT ROM
parameter SDRAM_LENGHT = 4096;

//Wishobne interface
logic        ACK;
logic        ERR;
logic        RTY;
logic        STB;
logic        CYC;
logic [31:0] ADR;
logic [31:0] DAT_I;
logic [31:0] DAT_O;
logic [2:0]  CTI_O;
logic        WE;

//Generated clock signal for out simulation
logic clk_gen = 0;

//Synchronizer for the RST signal to debounce the input signal.
logic rst_gen = 0;
always@(posedge clk_gen)
begin
    rst_gen = ~rst;
end


`ifdef __sim__

logic clk;
logic rst;
initial begin
    $dumpfile("soc.vcd");
    $dumpvars(0,soc);
    $display("Initializing Simulations");
    clk_gen = 0;
    //RST Starts at a value of 1 to simulate the pull up resistor
    //for the inputs in a lot of FPGA boards.
    rst = 1;
    #10
    clk_gen = ~clk_gen;
    rst = 0;
    repeat(10)
    begin
        #10
        begin
            clk_gen = ~clk_gen;
        end
    end
    rst = 1;
    forever begin
        #10
		begin
			clk_gen = ~clk_gen;
    	end
	end
end
`endif

endmodule