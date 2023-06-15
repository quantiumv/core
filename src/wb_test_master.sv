module wb_test_master
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
    output logic WE
);

typedef enum logic [1:0] { IDDLE, WEITE, READ } state_t;
state_t state = IDDLE;

initial begin
    ADR <= 0;
end

always@(posedge clk)
begin
    case (state)
        IDDLE:
        begin
            STB <= 1'b0;
            CYC <= 1'b0;
            CTI_O <= 3'b0; //Classic cycle
            ADR <= ADR; 
            state <= WEITE;
            WE <= 1'b0;
        end
        WEITE:
        begin            
            CTI_O <= 3'b0; //Classic cycle
            ADR <= ADR; //Write 0 because address is latched in this example
            if(ACK)
            begin
                state <= READ;
                STB <= 1'b0;
                CYC <= 1'b0;
                WE <= 1'b0; //Setup WE for READ cycle. It's just nicer to look at         
            end
            else
            begin
                STB <= 1'b1;
                CYC <= 1'b1;
                WE <= 1'b1; //Write Signal        
            end
        end
        READ:
        begin
            CTI_O <= 3'b0; //Classic cycle
            if(ACK)
            begin
                ADR <= ADR + 32'b1; //Before going to IDDLE increment address 
                state <= IDDLE;
                STB <= 1'b0;
                CYC <= 1'b0;
                if(DAT_I == ADR)
                begin
                    $display("Successful READ/WEITE");
                end
                else
                begin
                    $display("Fail READ/WEITE");
                end
            end
            else
            begin
                STB <= 1'b1;
                CYC <= 1'b1;
                WE <= 1'b0; //WE 0 is a read        
            end
        end
        default:
        begin
            STB <= 1'b0;
            CYC <= 1'b0;
            WE <= 1'b0; //WE 0 is a read
            CTI_O <= 3'b0;        
            state <= IDDLE;
        end 
    endcase
end

assign DAT_O = ADR;


endmodule