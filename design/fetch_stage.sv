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
    output logic [31:0] INS //Instruction Data
);


reg PC = 0;


endmodule
