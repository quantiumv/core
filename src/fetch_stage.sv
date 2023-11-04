 /*
 * ++============================================================
 * || ++============================================++     +----+
 * || ||                           +-+   +------+   ||     |    |
 * || ||                           |4|==>| A    |   ||     |    |
 * || ||                           +-+   | +    |===++     |    |
 * || ||                           ++===>| B    |          |    |
 * || ||                           ||    +------+          |    |
 * || ||                           ||                      |    |
 * || ||    +------+    +------+   ||    +-----------+     | IF |
 * || ++===>| 0    |    |      |   ||    |           |     |    |
 * ||       | MUX  |===>|  PC  |===++===>|  I Cache  |====>|    |
 * ++======>| 1    |    |      |  ADDR   |           |     |    |
 *          +------+    +------+         +-----------+     |    |
 *                                       |  AXI/Wb4  |     |    |
 *                                       +-----------+     |    |
 *                                             /\          |    |
 *                                             || I BUS    |    |
 *                                             \/          +----+
 */

module fetch_stage
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
    //Stage Outputs
    output logic [31:0] INS_O, //Instruction Data
    output logic [31:0] PC_ADDR,
    output logic stall_ff,
    //Jump instruction signals
    input  logic [31:0] PC_JMP,
    input  logic jmp_s
);

wire stall;

initial
begin
    CTI_O = 0; //Cycle Type to 0 for now
    INS_O = 0;
    PC_ADDR = 0;
end

//Initial state of PC is the reset vector.
reg [31:0] PC = 0;


//Program Counter Logic
always @(posedge clk or posedge rst)
begin
    if(rst)
    begin
        PC <= 32'h0; //Reset Vector is 0x0000 for now.
    end
    else
    begin
        //If processor is not stalled, then proceed to increment to next instruction.
        if(!stall)
        begin
            if(jmp_s)
            begin
                PC <= PC_JMP; //Load JMP instruction address.
            end
            else
            begin
                PC <= PC + 32'h4;
            end
        end
        else
        begin
            //Don't change state
            PC <= PC;
        end
    end
end


//Signals comming off the the cache
wire [31:0] cache_ins;

i_cache i_cache_0
(
    .clk(clk),
    .rst(rst),
    //Master Wishbone interface
    .ACK(ACK),
    .ERR(ERR),
    .RTY(RTY),
    .STB(STB),
    .CYC(CYC),
    .ADR(ADR),
    .DAT_I(DAT_I),
    .DAT_O(DAT_O),
    .WE(WE),

    //Output Data
    .INS(cache_ins),
    //The stall signal is passed through
    .stall(stall),
    //Program Counter
    .PC(PC)
);

//Latch stage state on every clock cycle unless stalled.
always@(posedge clk)
begin
    if(!stall)
    begin
        INS_O = cache_ins;
        PC_ADDR = PC;
    end
    stall_ff <= stall;
end


endmodule
