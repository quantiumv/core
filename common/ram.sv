module ram #(
    parameter SIZE = 4096,
    parameter WB_ADDR_WIDTH = 32,
    parameter WB_DATA_WIDTH = 32
)(
    // Wishbone B4
    input wire  WB_CLK_I,
    input wire  WB_RST_I,
    input wire  [WB_ADDR_WIDTH-1:0] WB_ADR_I,
    output reg  [WB_DATA_WIDTH-1:0] WB_DAT_O,
    input  wire [WB_DATA_WIDTH-1:0] WB_DAT_I,
    input  wire WB_WE_I,
    output reg  WB_ACK_O,
    output reg  WB_ERR_O,
    output reg  WB_RTY_O,
    input  wire [2:0] WB_CTI_I,
    input  wire WB_STB_I,
    input  wire WB_CYC_I,
    output reg  WB_STALL_O
);


reg [31:0] mem [SIZE-1:0];

    // Cycle type encodings
localparam CLASSIC = 3'b000;
localparam CONST = 3'b001;
localparam INCR = 3'b010;
localparam EOB = 3'b111;

initial begin
//   $readmemh("firmware/ROM.hex", mem);
    WB_DAT_O = 0;
end

typedef enum logic [1:0] { IDDLE, END_CYCLE, CYCLE_BURST } state_t;
state_t state = IDDLE;
always_ff @(posedge WB_CLK_I or posedge WB_RST_I)
begin
    if(WB_RST_I)
    begin
        state <= IDDLE;
    end
    else
    begin
        case(state)
            IDDLE:
            begin
                if(WB_CYC_I & WB_STB_I)
                begin
                    //Asserting cycle as soon as the next cycle PERMISSION 4.40 WB4 Spec
                    WB_ACK_O <= 1'b1;   
                    WB_RTY_O <= 1'b0;   
                    WB_ERR_O <= 1'b0;   
                    if(WB_WE_I)
                    begin
                        mem[WB_ADR_I[31:2]] <= WB_DAT_I;            
                    end
                    else
                    begin
                        WB_DAT_O <= mem[WB_ADR_I[31:2]];             
                    end
                    //Handle Burst Cases
                    if(WB_CTI_I == CONST || WB_CTI_I == INCR)
                    begin
                        state <= CYCLE_BURST;
                    end
                    else
                    begin
                        //Classic Cycle
                        state <= END_CYCLE;
                    end
                end
                else
                begin                
                    WB_ACK_O <= 1'b0;   
                    WB_RTY_O <= 1'b0;   
                    WB_ERR_O <= 1'b0;    
                end
            end
            CYCLE_BURST:
            begin
                if(WB_CYC_I)
                begin
                    //Stay on burst mode even if the device is not being addresses
                    state <= CYCLE_BURST;
                    if(WB_STB_I)
                    begin
                        //Stay on Cycle
                        state <= CYCLE_BURST;
                        //PERMISSION 4.45 Slave may assert termination as soon as the next cycle starts
                        WB_ACK_O <= 1'b1;   
                        WB_RTY_O <= 1'b0;   
                        WB_ERR_O <= 1'b0;  
                        //Perform READ/WRITE operations
                        if(WB_WE_I)
                        begin
                            mem[WB_ADR_I[31:2]] <= WB_DAT_I;            
                        end
                        else
                        begin
                            WB_DAT_O <= mem[WB_ADR_I[31:2]];             
                        end
                        //End Cycle, set termination to 0 in next cycle
                        if(WB_CTI_I == EOB)
                        begin
                            state <= END_CYCLE;
                        end
                    end
                    else
                    begin
                        WB_ACK_O <= 1'b0;   
                        WB_RTY_O <= 1'b0;   
                        WB_ERR_O <= 1'b0;   
                    end
                end
                else
                begin
                   //The moment CYC goes low the cycle ends event if the EOB on CTI has not been set.
                    state <= END_CYCLE; 
                end
            end
            //Goes directly to END Cycle because it knows it's not a burst operation
            END_CYCLE:
            begin
                WB_ACK_O <= 1'b0;   
                WB_RTY_O <= 1'b0;   
                WB_ERR_O <= 1'b0;    
                state <= IDDLE;           
            end
        endcase
    end
end


endmodule
