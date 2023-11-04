module fetch_stage_tb();

logic clk;
logic rst;
logic [31:0] ADR_O;
logic [31:0] DAT_I;
logic [31:0] DAT_O;
logic WE_O;
logic STB_O;
logic ACK_I;
logic CYC_O;
logic ERR_I;
logic RTY_I;
logic [2:0] CTI_O = 0;

logic [31:0] ins_o; //instruction data
logic [31:0] pc_o;
logic stall_o;
logic [31:0] jmp_addr_i = 0;
logic jmp_i = 0;

initial begin
    $dumpfile("fetch_stage_tb.vcd");
    $dumpvars(0,fetch_stage_tb);
    $display("Initializing Simulations");
    clk = 0;
    rst = 0;
    #10
    clk = ~clk;
    rst = 1;
    repeat(10)
    begin
        #10
        begin
            clk = ~clk;
        end
    end
    rst = 0;
    forever begin
        #10
		begin
			clk = ~clk;
    	end
	end
end

fetch_stage fetch_stage_0
(
    .clk(clk),
    .rst(rst),
    //Master Wishbone interface
    .ACK_I(ACK_I),
    .ERR_I(ERR_I),
    .RTY_I(RTY_I),
    .STB_O(STB_O),
    .CYC_O(CYC_O),
    .ADR_O(ADR_O),
    .DAT_I(DAT_I),
    .DAT_O(DAT_O),
    .WE_O(WE_O),
    //Stage Outputs
    .ins_o(ins_o), //instruction data
    .pc_o(pc_o),
    .stall_o(stall_o),
    //jump instruction signals
    .jmp_addr_i(jmp_addr_i),
    .jmp_i(jmp_i)
);

ram ram_0
(
    .WB_CLK_I(clk),
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
    .WB_CTI_I(CTI_O)
);

endmodule