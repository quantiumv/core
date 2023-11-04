`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/14/2023 09:34:13 PM
// Design Name: 
// Module Name: wb_test_master
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module wb_test_master #(
    parameter WB_ADDR_WIDTH = 32,
    parameter WB_DATA_WIDTH = 32
    )(
    // Wishbone B4
    input wire WB_CLK_I,
    input wire WB_RST_I,
    output reg [WB_ADDR_WIDTH-1:0] WB_ADR_O,
    output reg [WB_DATA_WIDTH-1:0] WB_DAT_O,
    input wire [WB_DATA_WIDTH-1:0] WB_DAT_I,
    output reg WB_WE_O,
    output reg WB_STB_O,
    input wire WB_ACK_I,
    output reg WB_CYC_O,
    input wire WB_ERR_I,
    input wire WB_RTY_I,
    output reg [2:0] WB_CTI_O,
    input wire WB_STALL_I
    );

    // Cycle type encodings
    localparam CLASSIC = 3'b000;
    localparam CONST = 3'b001;
    localparam INCR = 3'b010;
    localparam EOB = 3'b111;

    typedef enum reg [2:0] {HOLD, IDLE, WRITE, READ, WRITE_BURST, READ_BURST} state_t;
    state_t wb_state = HOLD;

    reg [WB_ADDR_WIDTH-1:0] addr_counter = {WB_ADDR_WIDTH{1'b0}};

    always@(posedge WB_CLK_I or posedge WB_RST_I) begin
        if (WB_RST_I) begin
            addr_counter <= {WB_ADDR_WIDTH{1'b0}};
            wb_state <= IDLE;
        end
        else begin
            case (wb_state)
                IDLE : begin
                    WB_ADR_O <= addr_counter;
                    WB_DAT_O <= addr_counter;
                    WB_STB_O <= 1'b1;
                    WB_CYC_O <= 1'b1;
                    if (addr_counter == 5) WB_CTI_O <= CONST;
                    else if (addr_counter == 7) WB_CTI_O <= INCR;
                    else if (addr_counter == 9) WB_CTI_O <= EOB;
                    else WB_CTI_O <= CLASSIC;
                    WB_WE_O <= 1'b1;
                    wb_state <= WRITE;
                end
                WRITE : begin
                    if (WB_ACK_I) begin
                        WB_STB_O <= 1'b0;
                        WB_CYC_O <= 1'b0;
                        WB_WE_O <= 1'b0;
                        wb_state <= READ;
                    end
                    else begin
                        WB_STB_O <= 1'b1;
                        WB_CYC_O <= 1'b1;
                        WB_WE_O <= 1'b1;
                    end
                end
                READ : begin
                    if (WB_ACK_I) begin
                        WB_STB_O <= 1'b0;
                        WB_CYC_O <= 1'b0;
                        WB_WE_O <= 1'b0;
                        if (WB_DAT_I == addr_counter) $display("Result correct.");
                        else begin
                            $display("Result incorrect.");
                            //$finish;
                        end
                        addr_counter <= addr_counter + 1;
                        wb_state <= IDLE;
                    end
                    else begin
                        WB_STB_O <= 1'b1;
                        WB_CYC_O <= 1'b1;
                        WB_WE_O <= 1'b0;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire