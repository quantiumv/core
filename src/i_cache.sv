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
    output logic stall
);


typedef enum logic [1:0] { 
    IDDLE, 
    CACHE_HIT, 
    CACHE_MISS, 
    CACHE_LOAD_MISSALIGNED_B1,
    CACHE_LOAD_MISSALIGNED_B2,
    CACHE_WRITE_BACK_B1
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
reg [28:0] TAG_LVL1 [127:0];
reg [28:0] TAG_LVL2 [127:0];
reg [28:0] TAG_LVL3 [127:0];
reg [28:0] TAG_LVL4 [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];
reg V_BIT [127:0];


always@(posedge clk or posedge rst)
begin
    
end

endmodule
