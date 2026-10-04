// SPDX-License-Identifier: MIT

/*
 * qv_rob -- the reorder buffer: allocate in order at the tail, complete
 * in any order by tag, commit in order from the head.
 *
 * Head/tail pointers carry one bit beyond the index (the wrap bit), which
 * tells full from empty and gives every in-flight entry a unique tag;
 * tags are those pointers, zero-extended to qv_pkg::QV_ROB_TAG_W.
 * ROB_DEPTH must be a power of two and no larger than QV_ROB_DEPTH.
 *
 * Storage is parallel per-field arrays, never `array[i].field` on an
 * array of packed structs (iverilog crashes elaborating that).
 *
 * Two lookup ports let issue read a producer's result once it has
 * completed but not yet committed. They reflect registered state only;
 * a result arriving on the writeback bus this same cycle is issue's
 * bypass path's job, not this module's.
 *
 * Each entry is allocated with the frontend's predicted next pc. A
 * writeback flagged mispredict replaces it with the resolved one and
 * marks the entry, so commit redirects when it retires.
 *
 * Flush (a redirect at commit) empties everything behind the head
 * entry, which may itself be committing that cycle. A pop while empty,
 * or an allocation while full, is ignored.
 */
module qv_rob #(
    parameter int ROB_DEPTH = qv_pkg::QV_ROB_DEPTH
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    // allocate (issue)
    input  logic                             i_alloc_valid,
    input  logic [63:0]                      i_alloc_pc,
    input  logic [31:0]                      i_alloc_raw,
    input  logic [4:0]                       i_alloc_rd,
    input  logic                             i_alloc_rd_wen,
    input  logic [63:0]                      i_alloc_next_pc,
    input  qv_pkg::rvfi_shadow_t             i_alloc_shadow,
    input  qv_pkg::rob_ctrl_t                i_alloc_ctrl,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_alloc_tag,
    output logic                             o_alloc_ready,
    output logic                             o_empty,

    // complete: the fast writeback bus (ALU/BRU) and the slow one (LSU);
    // a tag only ever has one producer, so they never hit the same entry
    input  qv_pkg::wb_t                      i_wb,
    // value only: the slow units never redirect
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb2,
    /* verilator lint_on UNUSEDSIGNAL */

    // operand lookups (issue) -- indexing only needs the low bits; the
    // wrap bit matters for tag equality elsewhere, not here
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_lookup1_tag,
    output logic                             o_lookup1_complete,
    output logic [63:0]                      o_lookup1_value,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_lookup2_tag,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_lookup2_complete,
    output logic [63:0]                      o_lookup2_value,

    // head (commit)
    output logic                             o_head_valid,
    output qv_pkg::rob_entry_t               o_head_entry,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_head_tag,
    output qv_pkg::rvfi_shadow_t             o_head_shadow,
    output qv_pkg::rob_ctrl_t                o_head_ctrl,
    input  logic                             i_commit_pop
);
    import qv_pkg::*;

    localparam int IDX_W = $clog2(ROB_DEPTH);
    localparam int PTR_W = IDX_W + 1;

    logic [63:0]        pc_q      [0:ROB_DEPTH-1];
    logic [31:0]        raw_q     [0:ROB_DEPTH-1];
    logic [4:0]         rd_q      [0:ROB_DEPTH-1];
    logic               rd_wen_q  [0:ROB_DEPTH-1];
    logic [63:0]        value_q   [0:ROB_DEPTH-1];
    logic [63:0]        next_pc_q [0:ROB_DEPTH-1];
    logic               mispredict_q[0:ROB_DEPTH-1];
    logic               complete_q[0:ROB_DEPTH-1];
    rvfi_shadow_t       shadow_q  [0:ROB_DEPTH-1];
    rob_ctrl_t          ctrl_q    [0:ROB_DEPTH-1];

    logic [PTR_W-1:0] head_q, tail_q;

    wire [IDX_W-1:0] head_idx = head_q[IDX_W-1:0];
    wire [IDX_W-1:0] tail_idx = tail_q[IDX_W-1:0];

    assign o_empty       = (head_q == tail_q);
    assign o_alloc_ready = !((head_q[IDX_W] != tail_q[IDX_W]) && (head_idx == tail_idx));
    assign o_alloc_tag   = QV_ROB_TAG_W'(tail_q);

    wire alloc = i_alloc_valid && o_alloc_ready && !i_flush;
    wire pop   = i_commit_pop && !o_empty;

    // operand lookups
    wire [IDX_W-1:0] l1_idx = i_lookup1_tag[IDX_W-1:0];
    wire [IDX_W-1:0] l2_idx = i_lookup2_tag[IDX_W-1:0];
    assign o_lookup1_complete = complete_q[l1_idx];
    assign o_lookup1_value    = value_q[l1_idx];
    assign o_lookup2_complete = complete_q[l2_idx];
    assign o_lookup2_value    = value_q[l2_idx];

    // head
    assign o_head_valid = !o_empty;
    assign o_head_tag   = QV_ROB_TAG_W'(head_q);
    always_comb begin
        o_head_entry            = '0;
        o_head_entry.valid      = !o_empty;
        o_head_entry.complete   = complete_q[head_idx];
        o_head_entry.pc         = pc_q[head_idx];
        o_head_entry.raw        = raw_q[head_idx];
        o_head_entry.rd         = rd_q[head_idx];
        o_head_entry.rd_wen     = rd_wen_q[head_idx];
        o_head_entry.value      = value_q[head_idx];
        o_head_entry.next_pc    = next_pc_q[head_idx];
        o_head_entry.mispredict = mispredict_q[head_idx];
    end
    assign o_head_shadow = shadow_q[head_idx];
    assign o_head_ctrl   = ctrl_q[head_idx];

    wire [PTR_W-1:0] head_next = pop ? head_q + PTR_W'(1) : head_q;
    wire [IDX_W-1:0] wb_idx    = i_wb.tag[IDX_W-1:0];
    wire [IDX_W-1:0] wb2_idx   = i_wb2.tag[IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            for (int i = 0; i < ROB_DEPTH; i++) complete_q[i] <= 1'b0;
        end else begin
            head_q <= head_next;
            if (i_flush) begin
                tail_q <= head_next;
            end else if (alloc) begin
                tail_q                 <= tail_q + PTR_W'(1);
                pc_q[tail_idx]         <= i_alloc_pc;
                raw_q[tail_idx]        <= i_alloc_raw;
                rd_q[tail_idx]         <= i_alloc_rd;
                rd_wen_q[tail_idx]     <= i_alloc_rd_wen;
                next_pc_q[tail_idx]    <= i_alloc_next_pc;
                shadow_q[tail_idx]     <= i_alloc_shadow;
                ctrl_q[tail_idx]       <= i_alloc_ctrl;
                complete_q[tail_idx]   <= 1'b0;
                mispredict_q[tail_idx] <= 1'b0;
            end
            if (i_wb.valid && !i_flush) begin
                value_q[wb_idx]    <= i_wb.value;
                complete_q[wb_idx] <= 1'b1;
                if (i_wb.mispredict) begin
                    next_pc_q[wb_idx]    <= i_wb.next_pc;
                    mispredict_q[wb_idx] <= 1'b1;
                end
            end
            if (i_wb2.valid && !i_flush) begin
                value_q[wb2_idx]    <= i_wb2.value;
                complete_q[wb2_idx] <= 1'b1;
            end
        end
    end
endmodule
