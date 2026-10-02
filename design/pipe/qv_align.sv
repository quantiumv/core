// SPDX-License-Identifier: MIT

/*
 * qv_align -- turns one fetched dword into up to two fe_instr_t entries.
 *
 * Without RVC every instruction is 4-byte aligned, so a dword holds two
 * whole instructions (or one, when the dword was fetched for a redirect
 * target with pc[2]=1 and the low half precedes it) and no instruction
 * ever crosses a dword boundary. RVC, dword crossing, and static
 * prediction all land here later; the output shape stays the same.
 *
 * A bus error on the fetch marks every instruction from that dword as an
 * instruction access fault (cause 1).
 *
 * Pops the fetch buffer only when the IQ can take two entries, even if
 * only one is pushed -- simpler than a 1-vs-2 room check, and costs at
 * most one cycle after a redirect.
 */
module qv_align (
    input  logic              i_buf_valid,
    input  logic [63:0]       i_buf_pc,
    input  logic [63:0]       i_buf_data,
    input  logic              i_buf_err,
    output logic              o_buf_pop,

    output logic              o_push0_valid,
    output qv_pkg::fe_instr_t o_push0_data,
    output logic              o_push1_valid,
    output qv_pkg::fe_instr_t o_push1_data,
    input  logic              i_push_ready
);
    wire high_only = i_buf_pc[2];

    assign o_buf_pop     = i_buf_valid && i_push_ready;
    assign o_push0_valid = o_buf_pop;
    assign o_push1_valid = o_buf_pop && !high_only;

    always_comb begin
        o_push0_data            = '0;
        o_push0_data.pc         = i_buf_pc;
        o_push0_data.raw        = high_only ? i_buf_data[63:32] : i_buf_data[31:0];
        o_push0_data.xcpt       = i_buf_err;
        o_push0_data.xcpt_cause = i_buf_err ? 4'd1 : 4'd0;

        o_push1_data            = '0;
        o_push1_data.pc         = i_buf_pc + 64'd4;
        o_push1_data.raw        = i_buf_data[63:32];
        o_push1_data.xcpt       = i_buf_err;
        o_push1_data.xcpt_cause = i_buf_err ? 4'd1 : 4'd0;
    end
endmodule
