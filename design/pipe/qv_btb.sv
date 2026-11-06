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
 */
module qv_btb #(
    parameter int ENTRIES = 32          // power of two
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

    // training, at commit
    input  logic        i_upd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] i_upd_pc,       // the branch's pc
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        i_upd_taken,
    input  logic        i_upd_cross,    // a 32-bit instruction in the last halfword of its dword
    input  logic [63:0] i_upd_tgt
);
    localparam int IDX_W = $clog2(ENTRIES);

    logic [63:0] tag_q [0:ENTRIES-1];   // dword address (pc[63:3]) of the entry's dword, as {pc[63:3], 3'b0}
    logic [1:0]  off_q [0:ENTRIES-1];
    logic        x_q   [0:ENTRIES-1];
    logic [63:0] tgt_q [0:ENTRIES-1];
    logic        v_q   [0:ENTRIES-1];

    wire [IDX_W-1:0] lk_idx = i_lk_pc[3 +: IDX_W];
    // a crossing branch is filed under the dword that holds its second half
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0]      up_key = i_upd_cross ? i_upd_pc + 64'd2 : i_upd_pc;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [IDX_W-1:0] up_idx = up_key[3 +: IDX_W];

    assign o_hit = v_q[lk_idx] && (tag_q[lk_idx] == {i_lk_pc[63:3], 3'b000}) && (off_q[lk_idx] >= i_lk_pc[2:1]);
    assign o_off = off_q[lk_idx];
    assign o_x   = x_q[lk_idx];
    assign o_tgt = tgt_q[lk_idx];

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
            end else if (own) begin
                v_q[up_idx]   <= 1'b0;
            end
        end
    end
endmodule
