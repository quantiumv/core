`timescale 1ps/1ps


module tb();

//Internal RAM for BOOT ROM
parameter SDRAM_LENGHT = 4096;

//Wishobne interface
logic [31:0] wb_addr;
logic [31:0] wb_dat_i; //Master Side naming.
logic [31:0] wb_dat_o; //Master Side naming.
logic wb_ack;
logic wb_err;
logic wb_cyc;
logic wb_stb;
logic wb_we;


logic rst;

//Generated clock signal for out simulation
logic clk_gen = 0;

//Synchronizer for the RST signal to debounce the input signal.
logic rst_gen = 0;
always@(posedge clk_gen)
begin
    rst_gen = ~rst;
end

initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0,tb);
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


core core0
(
    //Clock is shared with WB4 BUS
    .clk(clk_gen),
    .rst(rst_gen),

    //Wishbone signals
    .addr_o(wb_addr),
    .dat_i(wb_dat_i),
    .dat_o(wb_dat_o),

    .ack_i(wb_ack),
    .err_i(wb_err),
    .cyc_o(wb_cyc),
    .stb_o(wb_stb),
    .we_o(wb_we)

);

wb4_sram sram0 (
    .clk(clk_gen),
    .rst(rst_gen),
    // Wishbone signals
    .addr_i(wb_addr),
    .dat_i(wb_dat),
    .dat_o(wb_dat),
    .ack_o(wb_ack),
    .err_o(wb_err),
    .cyc_i(wb_cyc),
    .stb_i(wb_stb),
    .we_i(wb_we)
);



endmodule