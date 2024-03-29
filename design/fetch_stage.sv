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
    input  logic ACK_I,
    input  logic ERR_I,
    input  logic RTY_I,
    output logic STB_O,
    output logic CYC_O,
    output logic [31:0] ADR_O,
    input  logic [31:0] DAT_I,
    output logic [31:0] DAT_O,
    output logic [2:0]  CTI_O,
    output logic WE_O,
    //Stage Outputs
    output logic [31:0] ins_o, //instruction data
    output logic [31:0] pc_o,
    output logic stall_o,
    //jump instruction signals
    input  logic [31:0] jmp_addr_i,
    input  logic jmp_i
);

//For future implementation. Currently we are running on a dummy cache/direct memory access.
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

typedef enum logic [2:0] { 
    CACHE_LOAD_W1,
    CACHE_LOAD_W2,
    CACHE_WRITE_BACK_B1,
    CACHE_WRITE_BACK_B2,
    FINISH_CYCLE
} cache_state_t;

cache_state_t cache_state = CACHE_LOAD_W1;

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
reg [31:0] PC;

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
assign ins_o = aligned_data;

always@(posedge clk or posedge rst)
begin
    if(rst)
    begin
        STB_O <= 0;
        CYC_O <= 0;
        ADR_O <= 0;
        DAT_O <= 0;
        CTI_O <= 0;
        WE_O <= 0;
        DATA_0 <= 0;
        DATA_1 <= 0;
        cache_state <= CACHE_LOAD_W1;
        PC <= 0; //Reset Vector
        pc_o <= 0;
        //Initially the cache should be empty, so we start with the pipeline stalled.
        stall_o <= 1;
    end
    else if(jmp_i)
    begin
        //Finish cycle without incrementing PC
        //Set next PC to fetch
        ADR_O <= jmp_addr_i;
        cache_state = CACHE_LOAD_W1;
        //Finish Cycle
        STB_O <= 1'b0;
        CYC_O <= 1'b0;
        PC <= jmp_addr_i;
    end
    else
    begin
        case(cache_state)
            CACHE_LOAD_W1:
            begin
                if(ACK_I)
                begin
                    DATA_0 <= DAT_I;
                    //Check if missaligned
                    if(PC [1:0] != 0)
                    begin
                        cache_state <= CACHE_LOAD_W2;
                        //Set Strobe down to start new transaction
                        STB_O <= 0;
                        //Set next address to fetch
                        ADR_O <= PC + 32'h4;
                    end
                    else
                    begin
                        cache_state <= FINISH_CYCLE;
                    end
                end
                //Start Cycle
                STB_O <= 1'b1;
                CYC_O <= 1'b1;
                stall_o <= 1'b1;
            end
            CACHE_LOAD_W2:
            begin
                if(ACK_I)
                begin
                    DATA_1 <= DAT_I;
                end
                //Start Cycle
                STB_O <= 1'b1;
                CYC_O <= 1'b1;
                stall_o <= 1'b1;
            end
            FINISH_CYCLE:
            begin
                //Set next PC to fetch
                ADR_O <= PC;
                cache_state = CACHE_LOAD_W1;
                //Finish Cycle
                STB_O <= 1'b0;
                CYC_O <= 1'b0;
                //Set PC for pipeline, and increment internal PC
                pc_o <= PC;
                PC <= PC + 32'h4;
                stall_o <= 1'b0;
            end
        endcase
    end
end



endmodule
