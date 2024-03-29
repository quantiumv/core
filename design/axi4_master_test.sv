`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/17/2023 04:04:21 PM
// Design Name: 
// Module Name: axi4_master_test
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

module axi4_master_test #(
    parameter AXI_ID_WIDTH = 4,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32,
    parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH / 8),
    parameter AXI_ADDR_LSB = $clog2(AXI_STRB_WIDTH)
    )(
    // Global signals
    input wire M_AXI_ACLK, // Clock input
    input wire M_AXI_ARESETn, // Reset, active low
    // Write address channel
    output reg [AXI_ID_WIDTH-1:0] M_AXI_AWID,
    output reg [AXI_ADDR_WIDTH-1:0] M_AXI_AWADDR,
    output reg [7:0] M_AXI_AWLEN,
    output reg [2:0] M_AXI_AWSIZE,
    output reg [1:0] M_AXI_AWBURST,
    output reg M_AXI_AWLOCK,
    output reg [3:0] M_AXI_AWCACHE,
    output reg [2:0] M_AXI_AWPROT,
    output reg [3:0] M_AXI_AWQOS,
    output reg [3:0] M_AXI_AWREGION,
    output reg M_AXI_AWVALID,
    input wire M_AXI_AWREADY,
    // Write data channel
    output reg [AXI_DATA_WIDTH-1:0] M_AXI_WDATA,
    output reg [AXI_STRB_WIDTH-1:0] M_AXI_WSTRB,
    output reg M_AXI_WLAST,
    output reg M_AXI_WVALID,
    input wire M_AXI_WREADY,
    // Write response channel
    input wire [AXI_ID_WIDTH-1:0] M_AXI_BID,
    input wire [1:0] M_AXI_BRESP,
    input wire M_AXI_BVALID,
    output reg M_AXI_BREADY,
    // Read address channel
    output reg [AXI_ID_WIDTH-1:0] M_AXI_ARID,
    output reg [AXI_ADDR_WIDTH-1:0] M_AXI_ARADDR,
    output reg [7:0] M_AXI_ARLEN,
    output reg [2:0] M_AXI_ARSIZE,
    output reg [1:0] M_AXI_ARBURST,
    output reg M_AXI_ARLOCK,
    output reg [3:0] M_AXI_ARCACHE,
    output reg [2:0] M_AXI_ARPROT,
    output reg [3:0] M_AXI_ARQOS,
    output reg [3:0] M_AXI_ARREGION,
    output reg M_AXI_ARVALID,
    input wire M_AXI_ARREADY,
    // Read data channel
    input wire [AXI_ID_WIDTH-1:0] M_AXI_RID,
    input wire [AXI_DATA_WIDTH-1:0] M_AXI_RDATA,
    input wire [1:0] M_AXI_RRESP,
    input wire M_AXI_RLAST,
    input wire M_AXI_RVALID,
    output reg M_AXI_RREADY
    );

    // RESP Encodings
    localparam RESP_OKAY = 2'b00; // Success normal, failed exclusive, unsupported exclusive
    localparam RESP_EXOKAY = 2'b01; // Success exclusive
    localparam RESP_SLVERR = 2'b10; // Unsuccessful transaction
    localparam RESP_DECERR = 2'b11; // Interconnect error, recommends routing to default sub to respond

endmodule
`default_nettype wire