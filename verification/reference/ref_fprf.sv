// SPDX-License-Identifier: MIT

/*
 * ref_fprf -- the F/D register file: 32 x 64 bits, f0 a register like the others (unlike x0), three combinational read
 * ports (rs1, rs2, rs3: the FMA reads three) and one synchronous write port. A single is stored NaN-boxed, as written.
 *
 * The array is named fp_registers in both cores (the lockstep harness compares it by that name at the end of a run).
 * The Debug Module's abstract FPR access is muxed onto read port 3 and the write port by the caller, as register_file's
 * read port B and write port are for GPRs. Reset clears them to 0, as Sail does: the spec leaves their reset value
 * unspecified, but an ACT test (ExceptionsZc, an FSD of a register that only a faulting C.FLD was meant to load)
 * reads one before writing it, and its signature has Sail's 0.
 */
module ref_fprf (
    input  logic        clk,
    input  logic        rst,
    input  logic [4:0]  i_rs1,
    input  logic [4:0]  i_rs2,
    input  logic [4:0]  i_rs3,
    output logic [63:0] o_rs1_data,
    output logic [63:0] o_rs2_data,
    output logic [63:0] o_rs3_data,
    input  logic        i_we,
    input  logic [4:0]  i_wsel,
    input  logic [63:0] i_wdata
);
    logic [63:0] fp_registers [0:31];

    assign o_rs1_data = fp_registers[i_rs1];
    assign o_rs2_data = fp_registers[i_rs2];
    assign o_rs3_data = fp_registers[i_rs3];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int r = 0; r < 32; r++) fp_registers[r] <= 64'b0;
        end else if (i_we) begin
            fp_registers[i_wsel] <= i_wdata;
        end
    end
endmodule
