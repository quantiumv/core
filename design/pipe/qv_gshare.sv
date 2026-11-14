// SPDX-License-Identifier: MIT

/*
 * qv_gshare -- (O8a) a global-history direction predictor for the aligner's conditional branches.
 *
 * 2^BITS two-bit counters, each with a trained bit, indexed by the branch's pc[BITS:1] XOR the global history (the
 * last H conditional outcomes, the newest in bit 0, XORed into the index's low bits). A counter is set weakly towards
 * the first outcome it is trained with, then counts up when taken and down when not, saturating; taken from 2 up.
 * A counter is known (o_known) only while it is strong, 0 or 3: core.sv takes its direction then, and the branch history
 * table's (qv_bht) while it is weak or untrained (a counter the history has just moved to, trained once, would
 * otherwise overrule a table that already predicts the branch right).
 *
 * Two histories:
 *   - the speculative one (o_hist), the one the aligner looks up with: every conditional branch the aligner sends out
 *     shifts in its predicted direction (i_cond, i_pred: the aligner sends out at most one conditional a cycle, so one
 *     history serves every position it looks up in a cycle). Each instruction carries the history from before it
 *     (core.sv puts it in the instruction's ras_snap_t), and a recovery at execute puts it back as the mispredicted
 *     branch left it: its own history, then its real direction if it is a conditional (the opposite of the
 *     predicted one: a conditional's target is fixed, so a mispredict is its direction). A flush from commit copies the
 *     committed history (as this cycle's retirement leaves it).
 *   - the committed one (o_hist_c): every conditional branch that retires shifts in its outcome. Commit trains the
 *     counter at the retiring branch's pc XOR the committed history; on the right path that is the history the branch
 *     was predicted with (core.sv asserts it).
 * Priority: flush, then restore, then the aligner's shift. Only architectural outcomes train.
 */
module qv_gshare #(
    parameter int H    = 12,            // history bits, 1..12 (qv_pkg::ras_snap_t carries 12)
    parameter int BITS = 12             // log2 of the counters, >= H, >= 3
) (
    input  logic        clk,
    input  logic        rst,

    // lookup (as qv_bht's): the head dword's four halfword positions, the dword behind it, a pending instruction
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_base_pc,
    input  logic [63:0] i_base1_pc,
    input  logic [63:0] i_pend_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [3:0]  o_known,
    output logic [3:0]  o_taken,
    output logic [3:0]  o_known1,
    output logic [3:0]  o_taken1,
    output logic        o_pend_known,
    output logic        o_pend_taken,
    output logic [H-1:0] o_hist,        // the speculative history

    // the conditional branch the aligner sends out this cycle (at most one), and its predicted direction
    input  logic        i_cond,
    input  logic        i_pred,

    // recovery
    input  logic        i_flush,        // from commit: the committed history
    input  logic        i_restore,      // a recovery at execute: the mispredicted branch's history
    input  logic [H-1:0] i_restore_h,   // ... from before it
    input  logic        i_restore_cond, // ... it is a conditional branch
    input  logic        i_restore_pred, // ... predicted this way (it went the other)

    // training, at commit (one conditional branch a cycle)
    input  logic        i_upd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_upd_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        i_upd_taken,
    output logic [H-1:0] o_hist_c       // the committed history
);
    localparam int ENTRIES = 1 << BITS;

    logic [1:0]   ctr_q [0:ENTRIES-1];
    logic         v_q   [0:ENTRIES-1];
    logic [H-1:0] h_q, hc_q;

    /* verilator lint_off UNUSEDSIGNAL */      // (the oldest bit shifts out)
    function automatic logic [H-1:0] shift(input logic [H-1:0] h, input logic b);
        return (H == 1) ? H'(b) : {h[H-2:0], b};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    // the index of a branch at (pc >> 1) under history h
    function automatic logic [BITS-1:0] idx(input logic [BITS-1:0] pc_hw, input logic [H-1:0] h);
        return pc_hw ^ BITS'(h);
    endfunction

    for (genvar pg = 0; pg < 4; pg++) begin : g_pos
        wire [BITS-1:0] ix  = idx({i_base_pc[BITS:3], 2'(pg)}, h_q);
        wire [BITS-1:0] ix1 = idx({i_base1_pc[BITS:3], 2'(pg)}, h_q);
        assign o_known[pg]  = v_q[ix] && (ctr_q[ix] == 2'b00 || ctr_q[ix] == 2'b11);
        assign o_taken[pg]  = v_q[ix] && ctr_q[ix][1];
        assign o_known1[pg] = v_q[ix1] && (ctr_q[ix1] == 2'b00 || ctr_q[ix1] == 2'b11);
        assign o_taken1[pg] = v_q[ix1] && ctr_q[ix1][1];
    end
    wire [BITS-1:0] pix = idx(i_pend_pc[BITS:1], h_q);
    assign o_pend_known = v_q[pix] && (ctr_q[pix] == 2'b00 || ctr_q[pix] == 2'b11);
    assign o_pend_taken = v_q[pix] && ctr_q[pix][1];
    assign o_hist   = h_q;
    assign o_hist_c = hc_q;

    wire [BITS-1:0] uix     = idx(i_upd_pc[BITS:1], hc_q);
    wire [H-1:0]    hc_next = i_upd_valid ? shift(hc_q, i_upd_taken) : hc_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ENTRIES; i++) begin v_q[i] <= 1'b0; ctr_q[i] <= 2'b01; end
            h_q  <= '0;
            hc_q <= '0;
        end else begin
            hc_q <= hc_next;
            if (i_flush)        h_q <= hc_next;
            else if (i_restore) h_q <= i_restore_cond ? shift(i_restore_h, !i_restore_pred) : i_restore_h;
            else if (i_cond)    h_q <= shift(h_q, i_pred);
            if (i_upd_valid) begin
                v_q[uix] <= 1'b1;
                if (!v_q[uix])        ctr_q[uix] <= i_upd_taken ? 2'b10 : 2'b01;
                else if (i_upd_taken) ctr_q[uix] <= (ctr_q[uix] == 2'b11) ? 2'b11 : ctr_q[uix] + 2'b01;
                else                  ctr_q[uix] <= (ctr_q[uix] == 2'b00) ? 2'b00 : ctr_q[uix] - 2'b01;
            end
        end
    end

`ifndef SYNTHESIS
    initial if (H < 1 || H > 12 || BITS < H || BITS < 3) $error("qv_gshare: H %0d, BITS %0d out of range", H, BITS);
`endif
endmodule
