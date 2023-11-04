`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/14/2023 09:34:13 PM
// Design Name: 
// Module Name: wbtoaxilite
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

module wbtoaxilite #(
    // Wishbone B4
    parameter WB_ADDR_WIDTH = 32,
    parameter WB_DATA_WIDTH = 32,
    // AXI4-Lite Parameters
    parameter AXI_DATA_WIDTH = WB_DATA_WIDTH,
    parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH / 8),
    parameter AXI_ADDR_LSB = $clog2(AXI_STRB_WIDTH),
    parameter AXI_ADDR_WIDTH = WB_ADDR_WIDTH + AXI_ADDR_LSB
    )(
    // Wishbone B4
    input wire WB_CLK_I,
    input wire WB_RST_I,
    input wire [WB_ADDR_WIDTH-1:0] WB_ADR_I,
    input wire [WB_DATA_WIDTH-1:0] WB_DAT_I,
    output reg [WB_DATA_WIDTH-1:0] WB_DAT_O,
    input wire WB_WE_I,
    input wire WB_STB_I,
    output reg WB_ACK_O,
    input wire WB_CYC_I,
    output reg WB_ERR_O,
    output reg WB_RTY_O,
    input wire [2:0] WB_CTI_I,
    output reg WB_STALL_O,
    // AXI4-Lite
    // Global signals
    input wire M_AXI_LITE_ACLK,
    input wire M_AXI_LITE_ARESETn,
    // Write address channel
    output reg [AXI_ADDR_WIDTH-1:0] M_AXI_LITE_AWADDR,
    output reg [2:0] M_AXI_LITE_AWPROT,
    output reg M_AXI_LITE_AWVALID,
    input wire M_AXI_LITE_AWREADY,
    // Write data channel
    output reg [AXI_DATA_WIDTH-1:0] M_AXI_LITE_WDATA,
    output reg [AXI_STRB_WIDTH-1:0] M_AXI_LITE_WSTRB,
    output reg M_AXI_LITE_WVALID,
    input wire M_AXI_LITE_WREADY,
    // Write response channel
    input wire [1:0] M_AXI_LITE_BRESP,
    input wire M_AXI_LITE_BVALID,
    output reg M_AXI_LITE_BREADY,
    // Read address channel
    output reg [AXI_ADDR_WIDTH-1:0] M_AXI_LITE_ARADDR,
    output reg [2:0] M_AXI_LITE_ARPROT,
    output reg M_AXI_LITE_ARVALID,
    input wire M_AXI_LITE_ARREADY,
    // Read data channel
    input wire [AXI_DATA_WIDTH-1:0] M_AXI_LITE_RDATA,
    input wire [1:0] M_AXI_LITE_RRESP,
    input wire M_AXI_LITE_RVALID,
    output reg M_AXI_LITE_RREADY
    );

    // RESP Encodings
    localparam RESP_OKAY = 2'b00;
    localparam RESP_SLVERR = 2'b10;
    localparam RESP_DECERR = 2'b11;

    // Cycle type encodings
    localparam CLASSIC = 3'b000;
    localparam CONST = 3'b001;
    localparam INCR = 3'b010;
    localparam EOB = 3'b111;

    wire rst = WB_RST_I | !M_AXI_LITE_ARESETn;

    typedef enum {WB_IDLE, WB_WAIT, WB_DONE} wb_state_t;
    typedef enum {AXI_IDLE, AXI_WRITE, AXI_WWAIT, AXI_READ, AXI_RWAIT} axi_state_t;

    wb_state_t wb_state = WB_IDLE;
    axi_state_t axi_state = AXI_IDLE;

    always_ff @(posedge WB_CLK_I or posedge rst) begin
        if (rst) begin
            WB_DAT_O <= {WB_DATA_WIDTH{1'b0}};
            WB_ACK_O <= 1'b0;
            WB_ERR_O <= 1'b0;
            WB_RTY_O <= 1'b0;
            WB_STALL_O <= 1'b0;
            M_AXI_LITE_AWADDR <= {AXI_ADDR_WIDTH{1'b0}};
            M_AXI_LITE_AWPROT <= 3'b010;
            M_AXI_LITE_AWVALID <= 1'b0;
            M_AXI_LITE_WDATA <= {AXI_DATA_WIDTH{1'b0}};
            M_AXI_LITE_WSTRB <= 4'h0;
            M_AXI_LITE_WVALID <= 1'b0;
            M_AXI_LITE_BREADY <= 1'b0;
            M_AXI_LITE_ARADDR <= {AXI_ADDR_WIDTH{1'b0}};
            M_AXI_LITE_ARPROT <= 3'b010;
            M_AXI_LITE_ARVALID <= 1'b0;
            M_AXI_LITE_RREADY <= 1'b0;
            wb_state <= WB_IDLE;
            axi_state <= AXI_IDLE;
        end
        else begin
            case (wb_state)
                WB_IDLE : begin
                    if (WB_STB_I & WB_CYC_I) begin
                        if (WB_WE_I) begin
                            M_AXI_LITE_AWADDR <= {WB_ADR_I, {AXI_ADDR_LSB{1'b0}}};
                            M_AXI_LITE_AWPROT <= 3'b010;
                            M_AXI_LITE_AWVALID <= 1'b1;
                            M_AXI_LITE_WDATA <= WB_DAT_I;
                            M_AXI_LITE_WSTRB <= 4'hF;
                            M_AXI_LITE_WVALID <= 1'b1;
                            axi_state <= AXI_WRITE;
                            wb_state <= WB_WAIT;
                        end
                        else if (!WB_WE_I) begin
                            M_AXI_LITE_ARADDR <= {WB_ADR_I, 2'b00};
                            M_AXI_LITE_ARPROT <= 3'b010;
                            M_AXI_LITE_ARVALID <= 1'b1;
                            axi_state <= AXI_READ;
                            wb_state <= WB_WAIT;
                        end
                    end
                end
                WB_WAIT : begin
                    
                end
                WB_DONE : begin
                    WB_ERR_O <= 1'b0;
                    WB_RTY_O <= 1'b0;
                    WB_ACK_O <= 1'b0;
                    wb_state <= WB_IDLE;
                end
            endcase
            case (axi_state)
                AXI_IDLE : begin
                    
                end
                AXI_WRITE : begin
                    if ((M_AXI_LITE_AWVALID & M_AXI_LITE_AWREADY) & (M_AXI_LITE_WVALID & M_AXI_LITE_WREADY)) begin
                        M_AXI_LITE_AWVALID <= 1'b0;
                        M_AXI_LITE_WVALID <= 1'b0;
                        M_AXI_LITE_BREADY <= 1'b1;
                        axi_state <= AXI_WWAIT;
                    end
                end
                AXI_WWAIT : begin
                    if (M_AXI_LITE_BREADY & M_AXI_LITE_BVALID) begin
                        if (M_AXI_LITE_BRESP == RESP_OKAY) begin
                            M_AXI_LITE_BREADY <= 1'b0;
                            wb_state <= WB_DONE;
                            WB_ACK_O <= 1'b1;
                            axi_state <= AXI_IDLE;
                        end
                        else begin
                            M_AXI_LITE_RREADY <= 1'b0;
                            wb_state <= WB_DONE;
                            WB_ACK_O <= 1'b1;
                            WB_ERR_O <= 1'b1;
                            WB_RTY_O <= 1'b1;
                            axi_state <= AXI_IDLE;
                        end
                    end
                end
                AXI_READ : begin
                    if (M_AXI_LITE_ARVALID & M_AXI_LITE_ARREADY) begin
                        M_AXI_LITE_ARVALID <= 1'b0;
                        M_AXI_LITE_RREADY <= 1'b1;
                        axi_state <= AXI_RWAIT;
                    end
                end
                AXI_RWAIT : begin
                    if (M_AXI_LITE_RVALID & M_AXI_LITE_RREADY) begin
                        WB_DAT_O <= M_AXI_LITE_RDATA;
                        if (M_AXI_LITE_RRESP == RESP_OKAY) begin
                            M_AXI_LITE_RREADY <= 1'b0;
                            wb_state <= WB_DONE;
                            WB_ACK_O <= 1'b1;
                            axi_state <= AXI_IDLE;
                        end
                        else begin
                            M_AXI_LITE_RREADY <= 1'b0;
                            wb_state <= WB_DONE;
                            WB_ACK_O <= 1'b1;
                            WB_ERR_O <= 1'b1;
                            WB_RTY_O <= 1'b1;
                            axi_state <= AXI_IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire