module core
(
    //Clock is shared with WB4 BUS
    input logic clk,
    input logic rst,


    //Wishbone signals
    output logic [31:0] addr_o,
    input  logic [31:0] dat_i,
    output logic [31:0] dat_o,

    input  logic ack_i,
    input  logic err_i,
    output logic cyc_o,
    output logic stb_o,
    output logic we_o

);
  
typedef enum logic [1:0] { FETCH, EXECUTE } exec_state_t;

exec_state_t current_state = FETCH;

logic [64:0] IR = 0;

wire [6:0]  funct7   = IR[31:25];
wire [4:0]  rs2      = IR[24:20];
wire [4:0]  rs1      = IR[19:15];
wire [2:0]  funct3   = IR[14:12];
wire [4:0]  rd       = IR[11:7];
wire [6:0]  opcode   = IR[6:0];

wire [11:0] imm      = IR[31:20];

wire [6:0]  imm_11_5 = IR[31:25];
wire [4:0]  imm_4_0  = IR[11:7];

wire [19:0] imm_31_12 = IR[31:12];

//Main state machine for the instruction execution cycle.
always@(posedge clk)
begin
    case (current_state)
    FETCH:;
        //TODO: Implement Fetch From Wishbone 4 interface. Synchronous Mode.
        //Illustration 4-2: WISHBONE Classic synchronous cycle terminated burst
        //https://cdn.opencores.org/downloads/wbspec_b4.pdf
        //Page: 66

    EXECUTE:;
        //TODO: Implement ALU Execution

        //TODO: Implement Memory Write

        //TODO: Implement Memory Reads

        //TODO: Implement Branch Instructions

        //NOTES: The state machine can have nested states to accommodate wishbone BUS logic.

    default:;
    endcase
end


endmodule
