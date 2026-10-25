// SPDX-License-Identifier: MIT

/*
 * qv_bht -- the branch history table: a two-bit counter per conditional branch, indexed by the pc.
 *
 * ENTRIES counters, indexed by pc[IDX_W:1] (no tag: two branches that alias share a counter), each with a
 * trained bit. A branch whose counter has never been trained is predicted by the static rule (backward taken),
 * so loops keep their free first prediction; the first retirement sets the counter weakly towards the outcome,
 * after that it counts up when taken and down when not, saturating at 3 and 0. Taken is predicted from 2 up.
 *
 * The aligner looks up the four halfword positions of the dword it is emitting from and the pc of a pending
 * (crossing) instruction at once, and picks the ones it needs; commit trains with architectural outcomes only,
 * one conditional branch a cycle.
 */
module qv_bht #(
    parameter int ENTRIES = 512         // power of two, >= 8
) (
    input  logic        clk,
    input  logic        rst,

    // lookup: the dword (its pc, low three bits ignored) and one more pc
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_base_pc,
    input  logic [63:0] i_pend_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [3:0]  o_known,        // per halfword position of the dword: the counter has been trained
    output logic [3:0]  o_taken,        // ... and says taken
    output logic        o_pend_known,
    output logic        o_pend_taken,

    // training, at commit
    input  logic        i_upd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_upd_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        i_upd_taken
);
    localparam int IDX_W = $clog2(ENTRIES);

    logic [1:0] ctr_q [0:ENTRIES-1];
    logic       v_q   [0:ENTRIES-1];

    for (genvar pg = 0; pg < 4; pg++) begin : g_pos
        wire [1:0]        pos = 2'(pg);
        wire [IDX_W-1:0]  ix  = {i_base_pc[IDX_W:3], pos};
        assign o_known[pg] = v_q[ix];
        assign o_taken[pg] = v_q[ix] && ctr_q[ix][1];
    end
    wire [IDX_W-1:0] pix = i_pend_pc[IDX_W:1];
    assign o_pend_known = v_q[pix];
    assign o_pend_taken = v_q[pix] && ctr_q[pix][1];

    wire [IDX_W-1:0] uix = i_upd_pc[IDX_W:1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ENTRIES; i++) begin v_q[i] <= 1'b0; ctr_q[i] <= 2'b01; end
        end else if (i_upd_valid) begin
            v_q[uix] <= 1'b1;
            if (!v_q[uix])        ctr_q[uix] <= i_upd_taken ? 2'b10 : 2'b01;
            else if (i_upd_taken) ctr_q[uix] <= (ctr_q[uix] == 2'b11) ? 2'b11 : ctr_q[uix] + 2'b01;
            else                  ctr_q[uix] <= (ctr_q[uix] == 2'b00) ? 2'b00 : ctr_q[uix] - 2'b01;
        end
    end
endmodule
