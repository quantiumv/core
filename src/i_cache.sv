// SPDX-License-Identifier: MIT

//4 Way associative Cache
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
    output logic stall,
    //Program Counter
    input logic [31:0] PC
);


typedef enum logic [2:0] { 
    IDDLE, 
    CACHE_HIT, 
    CACHE_MISS, 
    CACHE_LOAD_W1,
    CACHE_LOAD_W2,
    CACHE_WRITE_BACK_B1,
    CACHE_WRITE_BACK_B2
} cache_state_t;

//Associative Table Entry
//+---+---+-----+---------------+
//| V | D | TAG | DATA 32 Bytes |
//+---+---+-----+---------------+

//      Addressing
//+--------+-----+-----+
//|  TAG   | ATI | WA  |
//+--+-----+-----+-----+
//
// WA  - Word Address. 3 bits. Ignored in Cache logic.
// ATI - Associative Table Index. 2 bits.
// TAG - 28 bit

//1KB per table
// reg [28:0] TAG_LVL1 [127:0];
// reg [28:0] TAG_LVL2 [127:0];
// reg [28:0] TAG_LVL3 [127:0];
// reg [28:0] TAG_LVL4 [127:0];
// reg V_BIT_1 [127:0];
// reg V_BIT_2 [127:0];
// reg V_BIT_3 [127:0];
// reg V_BIT_4 [127:0];
// reg D_BIT_1 [127:0];
// reg D_BIT_2 [127:0];
// reg D_BIT_3 [127:0];
// reg D_BIT_4 [127:0];

cache_state_t cache_state = IDDLE;

//Hardwired value for dummy cache implementation.
wire hit;
assign hit = 1'b0;

/*
 * Combinational data alignment logic. DATA_0 and DATA_1 registers
 * will be loaded with the required data in order
 * to extract misaligned data in between two words.
 */
reg [31:0] DATA_0;
reg [31:0] DATA_1;

wire [7:0] access_window [7:0];
assign access_window [0] = DATA_0 [7:0];
assign access_window [1] = DATA_0 [15:8];
assign access_window [2] = DATA_0 [23:16];
assign access_window [3] = DATA_0 [31:24];
assign access_window [4] = DATA_1 [7:0];
assign access_window [5] = DATA_1 [15:8];
assign access_window [6] = DATA_1 [23:16];
assign access_window [7] = DATA_1 [31:24];

wire [31:0] aligned_data;
assign aligned_data [7:0] = access_window [PC [1:0] + 0];
assign aligned_data [15:8] = access_window [PC [1:0] + 1];
assign aligned_data [23:16] = access_window [PC [1:0] + 2];
assign aligned_data [31:24] = access_window [PC [1:0] + 3];
assign INS = aligned_data;

always@(posedge clk or posedge rst)
begin
    if(rst)
    begin
        cache_state <= IDDLE;
        WE <= 0;
        DAT_O <= 0;
        //We stall the pipeline initally since we don't have any data ready.
        stall <= 1'b1;
        STB <= 0;
        CYC <= 0;
        DATA_0 <= 0;
        DATA_1 <= 0;
        CTI_O <= 0;
        ADR <= 0;
    end
    else
    begin
        case(cache_state)
            IDDLE:
            begin
                /*
                 * Since we don't have real cache memory yet, every memory access is considered a miss. 
                 */
                if(!hit)
                begin
                    //Load first WORD.
                    cache_state <= CACHE_LOAD_W1;
                    //Try to fetch address at PC;
                    ADR <= PC;
                    //Read cycle
                    WE <= 1'b0;
                    //Begin cycle for access
                    STB <= 1'b1;
                    CYC <= 1'b1;
                    //Stall stage while we do a memory access
                    stall <= 1'b1;
                end
            end
            CACHE_LOAD_W1:
            begin
                if(ACK)
                begin
                    //Determine if we have a missaligned address.
                    if(PC[1:0] != 0)
                    begin
                        DATA_0 <= DAT_I;
                        cache_state <= CACHE_LOAD_W2;
                        //We stall the pipeline until DATA_1 word is fetched.
                        stall <= 1'b1;
                        //Prepare address BUS to fetch next word
                        ADR <= PC + 32'b100; // PC + 4
                        //Set strobe down to start another READ cycle.
                        STB <= 1'b0;
                    end
                    else
                    begin
                        DATA_0 <= DAT_I;
                        //Unstall stage since data is already fetched.
                        stall <= 1'b0;
                        cache_state <= IDDLE;
                        //Finish Cycle
                        STB <= 1'b0;
                        CYC <= 1'b0;
                    end
                end
                else if(ERR)
                begin
                    //We don't do nothing for now. In the future we want to trigger an
                    //exemtion in order to hadle this through software.
                end
                else if(RTY)
                begin
                    //We stay in the current state until ACK is valid.
                    cache_state <= CACHE_LOAD_W1;
                end
            end
            CACHE_LOAD_W2:
            begin
                if(ACK)
                begin
                    //Once DATA_1 is latched, the data alignment combinational logic should align data for us.
                    DATA_1 <= DAT_I;
                    //We can go into iddle state in order to fetch next intruction.
                    stall <= 1'b0;
                    cache_state <= IDDLE;
                    //Finish Cycle
                    STB <= 1'b0;
                    CYC <= 1'b0;
                end
                else if(ERR)
                begin
                    //We don't do nothing for now. In the future we want to trigger an
                    //exemtion in order to hadle this through software.
                end
                else if(RTY)
                begin
                    //We stay in the current state until ACK is valid.
                    cache_state <= CACHE_LOAD_W1;
                end
            end
        endcase
    end
end

endmodule
