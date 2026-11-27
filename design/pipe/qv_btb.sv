// SPDX-License-Identifier: MIT

/*
 * qv_btb -- the branch target buffer: for a fetched dword, where a taken branch or jump in it goes.
 *
 * Direct-mapped on the dword address, one entry per dword, a full tag. An entry names the halfword the
 * branch starts at and its target. A 32-bit branch that starts in the last halfword of a dword and ends in the
 * first of the next is filed under that next dword, halfword 0, with the crossing flag (x): fetch has to
 * fetch that dword anyway, and it is there that the aligner completes the instruction. Fetch looks up the dword it is about to request; a hit whose branch is at
 * or after the first halfword it will use makes fetch's next request the target at once, with no bubble. The
 * entry is only a hint: the aligner decodes the instruction at that halfword when the dword arrives and
 * confirms or corrects it, and the branch unit checks the outcome, so a stale or aliased entry costs time and
 * never correctness. Nothing flushes it.
 *
 * Training happens at commit, with architectural outcomes only: a taken branch or jump writes (or replaces)
 * the entry of its dword; a conditional branch that falls through removes the entry if it is its own.
 *
 * CTR (O8c, QV_PIPE_BTB_CTR): an entry also keeps whether its branch is conditional and a 2-bit direction counter.
 * A taken branch that is not the entry's own replaces it with the counter at 2 (weakly taken); a taken one that is
 * counts up (to 3), a conditional one that falls through counts down (to 0) and keeps the entry; a conditional
 * entry steers fetch only while its counter says taken (2 or 3). A loop branch that falls through once then keeps
 * its entry for the next time the loop runs; one that mostly falls through stops steering fetch past code it runs.
 *
 * (W3b) A second lookup (i_lk2_pc, o_*2) for the other dword of a 16-byte fetch block: the same rule, the same table.
 * The two dwords of an aligned block are adjacent dwords, so they never share an entry, and a block holds a branch
 * per dword: two per 16-byte block.
 */
module qv_btb #(
    parameter int ENTRIES = 32,         // power of two
    parameter bit CTR     = 1'b0        // (O8c) a direction counter per entry
) (
    input  logic        clk,
    input  logic        rst,

    // lookup: the pc of the dword request about to be issued (the start pc, which can be mid-dword)
    /* verilator lint_off UNUSEDSIGNAL */      // (bit 0 of a pc is always 0)
    input  logic [63:0] i_lk_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        o_hit,          // an entry for this dword, its branch at or after the start halfword
    output logic [1:0]  o_off,          // the branch's halfword within the dword
    output logic        o_x,            // ... it is the second half of a crossing 32-bit branch (then o_off is 0)
    output logic [63:0] o_tgt,
    // (W3b) the second lookup: the upper dword of a 16-byte block, from its halfword 0
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_lk2_pc = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        o_hit2,
    output logic [1:0]  o_off2,
    output logic        o_x2,
    output logic [63:0] o_tgt2,

    // training, at commit
    input  logic        i_upd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_upd_pc,       // the branch's pc
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        i_upd_taken,
    input  logic        i_upd_cross,    // a 32-bit instruction in the last halfword of its dword
    input  logic [63:0] i_upd_tgt,
    input  logic        i_upd_cond = 1'b0   // (CTR) a conditional branch
);
    localparam int IDX_W = $clog2(ENTRIES);

    logic [63:0] tag_q [0:ENTRIES-1];   // dword address (pc[63:3]) of the entry's dword, as {pc[63:3], 3'b0}
    logic [1:0]  off_q [0:ENTRIES-1];
    logic        x_q   [0:ENTRIES-1];
    logic [63:0] tgt_q [0:ENTRIES-1];
    logic        v_q   [0:ENTRIES-1];
    logic        c_q   [0:ENTRIES-1];   // (CTR) a conditional branch's entry
    logic [1:0]  ctr_q [0:ENTRIES-1];   // (CTR) its direction: 2 and 3 taken

    wire [IDX_W-1:0] lk_idx = i_lk_pc[3 +: IDX_W];
    // a crossing branch is filed under the dword that holds its second half
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0]      up_key = i_upd_cross ? i_upd_pc + 64'd2 : i_upd_pc;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [IDX_W-1:0] up_idx = up_key[3 +: IDX_W];

    assign o_hit = v_q[lk_idx] && (tag_q[lk_idx] == {i_lk_pc[63:3], 3'b000}) && (off_q[lk_idx] >= i_lk_pc[2:1])
                   && (!CTR || !c_q[lk_idx] || ctr_q[lk_idx][1]);
    assign o_off = off_q[lk_idx];
    assign o_x   = x_q[lk_idx];
    assign o_tgt = tgt_q[lk_idx];

    wire [IDX_W-1:0] lk2_idx = i_lk2_pc[3 +: IDX_W];
    assign o_hit2 = v_q[lk2_idx] && (tag_q[lk2_idx] == {i_lk2_pc[63:3], 3'b000}) && (off_q[lk2_idx] >= i_lk2_pc[2:1])
                    && (!CTR || !c_q[lk2_idx] || ctr_q[lk2_idx][1]);
    assign o_off2 = off_q[lk2_idx];
    assign o_x2   = x_q[lk2_idx];
    assign o_tgt2 = tgt_q[lk2_idx];

    wire own = v_q[up_idx] && (tag_q[up_idx] == {up_key[63:3], 3'b000}) && (off_q[up_idx] == up_key[2:1])
               && (x_q[up_idx] == i_upd_cross);

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ENTRIES; i++) v_q[i] <= 1'b0;
        end else if (i_upd_valid) begin
            if (i_upd_taken) begin
                v_q[up_idx]   <= 1'b1;
                tag_q[up_idx] <= {up_key[63:3], 3'b000};
                off_q[up_idx] <= up_key[2:1];
                x_q[up_idx]   <= i_upd_cross;
                tgt_q[up_idx] <= i_upd_tgt;
                c_q[up_idx]   <= i_upd_cond;
                ctr_q[up_idx] <= !own ? 2'd2 : (ctr_q[up_idx] == 2'd3) ? 2'd3 : ctr_q[up_idx] + 2'd1;
            end else if (own) begin
                if (!CTR)                           v_q[up_idx]   <= 1'b0;
                else if (ctr_q[up_idx] != 2'd0)     ctr_q[up_idx] <= ctr_q[up_idx] - 2'd1;
            end
        end
    end
endmodule
