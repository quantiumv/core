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
logic [31:0] ADR_O;
logic [31:0] DAT_O;
logic [31:0] DAT_I;
logic WE_O;
logic STB_O;
logic ACK_I;
logic CYC_O;
logic ERR_I;
logic RTY_I;
logic [2:0] CTI_O;
logic STALL_I;

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



wb_test_master wb_test_master_0
(
    .WB_CLK_I(clk_gen),
    .WB_RST_I(rst_gen),
    .WB_ADR_O(ADR_O),
    .WB_DAT_O(DAT_O),
    .WB_DAT_I(DAT_I),
    .WB_WE_O(WE_O),
    .WB_STB_O(STB_O),
    .WB_ACK_I(ACK_I),
    .WB_CYC_O(CYC_O),
    .WB_ERR_I(ERR_I),
    .WB_RTY_I(RTY_I),
    .WB_CTI_O(CTI_O),
    .WB_STALL_I(STALL_I)
);

ram ram_0
(
    .WB_CLK_I(clk_gen),
    .WB_RST_I(rst_gen),
    .WB_ADR_I(ADR_O),
    .WB_DAT_O(DAT_I),
    .WB_DAT_I(DAT_O),
    .WB_WE_I(WE_O),
    .WB_STB_I(STB_O),
    .WB_ACK_O(ACK_I),
    .WB_CYC_I(CYC_O),
    .WB_ERR_O(ERR_I),
    .WB_RTY_O(RTY_I),
    .WB_CTI_I(CTI_O),
    .WB_STALL_O(STALL_I)
);



endmodule