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
 *
 * (O3) A kill (a mispredict recovered at execute) drops every entry younger
 * than i_kill_tag: the tail goes back to the entry after it, nothing is
 * allocated in that cycle (the tail's update puts the kill before the
 * allocation), and o_kill_vec marks every killed tag so the
 * units, the station and the load/store queue drop what they hold for them
 * in the same cycle (the next allocations reuse those tags). A flush beats a
 * kill. A mispredict written back with i_wb_recover is marked recovered, so
 * commit retires it without a second redirect.
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
    input  qv_pkg::rob_ctrl_t                i_alloc_ctrl,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_alloc_tag,
    output logic                             o_alloc_ready,
    output logic                             o_empty,
    // O4: a second allocation in the same cycle (the younger uop, behind the first), only with o_alloc_ready2: room
    // for two; its tag is o_alloc_tag1
    input  logic                             i_alloc2_valid = 1'b0,
    input  logic [63:0]                      i_alloc2_pc = 64'b0,
    input  logic [31:0]                      i_alloc2_raw = 32'b0,
    input  logic [4:0]                       i_alloc2_rd = 5'b0,
    input  logic                             i_alloc2_rd_wen = 1'b0,
    input  logic [63:0]                      i_alloc2_next_pc = 64'b0,
    input  qv_pkg::rob_ctrl_t                i_alloc2_ctrl = '0,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_alloc_tag1,
    output logic                             o_alloc_ready2,

    // complete: the fast writeback bus (ALU/BRU) and the slow ones (LSU,
    // divider); a tag only ever has one producer, so they never hit the
    // same entry
    input  qv_pkg::wb_t                      i_wb,
    // value only: the slow units never redirect
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb2,
    input  qv_pkg::wb_t                      i_wb3,
    /* verilator lint_on UNUSEDSIGNAL */
    // F/D: the FPU's writeback (value and exception flags)
    input  qv_pkg::wb_fp_t                   i_wb4 = '0,
    // O4d: the second ALU port's (value only: it takes no branch)
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb5 = '0,
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
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_lookup3_tag = '0,     // F/D: the FMA's third source
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_lookup3_complete,
    output logic [63:0]                      o_lookup3_value,
    // O4: the second dispatching uop's two sources
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_lookup4_tag = '0,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_lookup5_tag = '0,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_lookup4_complete,
    output logic [63:0]                      o_lookup4_value,
    output logic                             o_lookup5_complete,
    output logic [63:0]                      o_lookup5_value,

    // head (commit)
    output logic                             o_head_valid,
    output qv_pkg::rob_entry_t               o_head_entry,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_head_tag,
    output qv_pkg::rob_ctrl_t                o_head_ctrl,
    input  logic                             i_commit_pop,
    // O4: the entry behind the head (valid when there are two), and a second pop (with the first) that retires it too
    output logic                             o_head1_valid,
    output qv_pkg::rob_entry_t               o_head1_entry,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_head1_tag,
    output qv_pkg::rob_ctrl_t                o_head1_ctrl,
    input  logic                             i_commit_pop2 = 1'b0,

    // (O3) kill everything younger than i_kill_tag; which tags that is
    input  logic                             i_kill = 1'b0,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_kill_tag = '0,
    output logic [(1<<qv_pkg::QV_ROB_TAG_W)-1:0] o_kill_vec,
    input  logic                             i_wb_recover = 1'b0     // i_wb's mispredict is recovered at execute
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
    logic [4:0]         fflags_q  [0:ROB_DEPTH-1];
    rob_ctrl_t          ctrl_q    [0:ROB_DEPTH-1];
    logic               recovered_q[0:ROB_DEPTH-1];

    logic [PTR_W-1:0] head_q, tail_q;

    wire [IDX_W-1:0] head_idx = head_q[IDX_W-1:0];
    wire [IDX_W-1:0] tail_idx = tail_q[IDX_W-1:0];

    assign o_empty       = (head_q == tail_q);
    assign o_alloc_ready = !((head_q[IDX_W] != tail_q[IDX_W]) && (head_idx == tail_idx));
    assign o_alloc_tag   = QV_ROB_TAG_W'(tail_q);

    wire alloc = i_alloc_valid && o_alloc_ready && !i_flush;
    // (O4) room for two, and the second's slot
    wire [PTR_W-1:0] tail1_q   = tail_q + PTR_W'(1);
    wire [IDX_W-1:0] tail1_idx = tail1_q[IDX_W-1:0];
    assign o_alloc_tag1   = QV_ROB_TAG_W'(tail1_q);
    assign o_alloc_ready2 = (tail_q - head_q) <= PTR_W'(ROB_DEPTH - 2);
    wire alloc2 = alloc && i_alloc2_valid && o_alloc_ready2;
    wire pop   = i_commit_pop && !o_empty;
    wire [PTR_W-1:0] count = tail_q - head_q;
    assign o_head1_valid = count >= PTR_W'(2);
    wire pop2  = pop && i_commit_pop2 && o_head1_valid;

    // (O3) the killed tags: from the entry after the branch up to the tail, in the ROB's pointer width (a tag with a
    // bit above it is no pointer of this ROB)
    wire [PTR_W-1:0] kill_from = i_kill_tag[PTR_W-1:0] + PTR_W'(1);
    always_comb
        for (int k = 0; k < (1 << QV_ROB_TAG_W); k++)
            o_kill_vec[k] = i_kill && ((k >> PTR_W) == 0)
                            && (qv_rob_dist(QV_ROB_TAG_W'(k), QV_ROB_TAG_W'(kill_from), PTR_W)
                                < qv_rob_dist(QV_ROB_TAG_W'(tail_q), QV_ROB_TAG_W'(kill_from), PTR_W));

    // operand lookups
    wire [IDX_W-1:0] l1_idx = i_lookup1_tag[IDX_W-1:0];
    wire [IDX_W-1:0] l2_idx = i_lookup2_tag[IDX_W-1:0];
    assign o_lookup1_complete = complete_q[l1_idx];
    assign o_lookup1_value    = value_q[l1_idx];
    assign o_lookup2_complete = complete_q[l2_idx];
    assign o_lookup2_value    = value_q[l2_idx];
    wire [IDX_W-1:0] l3_idx = i_lookup3_tag[IDX_W-1:0];
    assign o_lookup3_complete = complete_q[l3_idx];
    assign o_lookup3_value    = value_q[l3_idx];
    wire [IDX_W-1:0] l4_idx = i_lookup4_tag[IDX_W-1:0];
    wire [IDX_W-1:0] l5_idx = i_lookup5_tag[IDX_W-1:0];
    assign o_lookup4_complete = complete_q[l4_idx];
    assign o_lookup4_value    = value_q[l4_idx];
    assign o_lookup5_complete = complete_q[l5_idx];
    assign o_lookup5_value    = value_q[l5_idx];

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
        o_head_entry.fflags     = fflags_q[head_idx];
        o_head_entry.recovered  = recovered_q[head_idx];
    end
    assign o_head_ctrl   = ctrl_q[head_idx];

    wire [PTR_W-1:0] head1_q   = head_q + PTR_W'(1);
    wire [IDX_W-1:0] head1_idx = head1_q[IDX_W-1:0];
    assign o_head1_tag = QV_ROB_TAG_W'(head1_q);
    always_comb begin
        o_head1_entry            = '0;
        o_head1_entry.valid      = o_head1_valid;
        o_head1_entry.complete   = complete_q[head1_idx];
        o_head1_entry.pc         = pc_q[head1_idx];
        o_head1_entry.raw        = raw_q[head1_idx];
        o_head1_entry.rd         = rd_q[head1_idx];
        o_head1_entry.rd_wen     = rd_wen_q[head1_idx];
        o_head1_entry.value      = value_q[head1_idx];
        o_head1_entry.next_pc    = next_pc_q[head1_idx];
        o_head1_entry.mispredict = mispredict_q[head1_idx];
        o_head1_entry.fflags     = fflags_q[head1_idx];
        o_head1_entry.recovered  = recovered_q[head1_idx];
    end
    assign o_head1_ctrl  = ctrl_q[head1_idx];

    wire [PTR_W-1:0] head_next = head_q + PTR_W'(pop) + PTR_W'(pop2);
    wire [IDX_W-1:0] wb_idx    = i_wb.tag[IDX_W-1:0];
    wire [IDX_W-1:0] wb2_idx   = i_wb2.tag[IDX_W-1:0];
    wire [IDX_W-1:0] wb3_idx   = i_wb3.tag[IDX_W-1:0];
    wire [IDX_W-1:0] wb4_idx   = i_wb4.tag[IDX_W-1:0];
    wire [IDX_W-1:0] wb5_idx   = i_wb5.tag[IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            for (int i = 0; i < ROB_DEPTH; i++) complete_q[i] <= 1'b0;
        end else begin
            head_q <= head_next;
            if (i_flush) begin
                tail_q <= head_next;
            end else if (i_kill) begin
                tail_q <= kill_from;
            end else if (alloc) begin
                tail_q                 <= tail_q + PTR_W'(1);
                pc_q[tail_idx]         <= i_alloc_pc;
                raw_q[tail_idx]        <= i_alloc_raw;
                rd_q[tail_idx]         <= i_alloc_rd;
                rd_wen_q[tail_idx]     <= i_alloc_rd_wen;
                next_pc_q[tail_idx]    <= i_alloc_next_pc;
                ctrl_q[tail_idx]       <= i_alloc_ctrl;
                complete_q[tail_idx]   <= 1'b0;
                mispredict_q[tail_idx] <= 1'b0;
                fflags_q[tail_idx]     <= 5'b0;
                recovered_q[tail_idx]  <= 1'b0;
                if (alloc2) begin
                    tail_q                  <= tail_q + PTR_W'(2);
                    pc_q[tail1_idx]         <= i_alloc2_pc;
                    raw_q[tail1_idx]        <= i_alloc2_raw;
                    rd_q[tail1_idx]         <= i_alloc2_rd;
                    rd_wen_q[tail1_idx]     <= i_alloc2_rd_wen;
                    next_pc_q[tail1_idx]    <= i_alloc2_next_pc;
                    ctrl_q[tail1_idx]       <= i_alloc2_ctrl;
                    complete_q[tail1_idx]   <= 1'b0;
                    mispredict_q[tail1_idx] <= 1'b0;
                    fflags_q[tail1_idx]     <= 5'b0;
                    recovered_q[tail1_idx]  <= 1'b0;
                end
            end
            if (i_wb.valid && !i_flush) begin
                value_q[wb_idx]    <= i_wb.value;
                complete_q[wb_idx] <= 1'b1;
                if (i_wb.mispredict) begin
                    next_pc_q[wb_idx]    <= i_wb.next_pc;
                    mispredict_q[wb_idx] <= 1'b1;
                    recovered_q[wb_idx]  <= i_wb_recover;
                end
            end
            if (i_wb2.valid && !i_flush) begin
                value_q[wb2_idx]    <= i_wb2.value;
                complete_q[wb2_idx] <= 1'b1;
            end
            if (i_wb3.valid && !i_flush) begin
                value_q[wb3_idx]    <= i_wb3.value;
                complete_q[wb3_idx] <= 1'b1;
            end
            if (i_wb4.valid && !i_flush) begin
                value_q[wb4_idx]    <= i_wb4.value;
                fflags_q[wb4_idx]   <= i_wb4.flags;
                complete_q[wb4_idx] <= 1'b1;
            end
            if (i_wb5.valid && !i_flush) begin
                value_q[wb5_idx]    <= i_wb5.value;
                complete_q[wb5_idx] <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // (O3) a kill names an entry the ROB holds, and never cuts below this cycle's retirements (the branch retires
    // at the most as the last of them: commit pairs nothing behind a mispredicted head)
    wire [QV_ROB_TAG_W-1:0] k_dist = qv_rob_dist(QV_ROB_TAG_W'(kill_from), QV_ROB_TAG_W'(head_q), PTR_W);
    always @(posedge clk) if (!rst && i_kill && !i_flush) begin
        if (k_dist == '0 || k_dist > qv_rob_dist(QV_ROB_TAG_W'(tail_q), QV_ROB_TAG_W'(head_q), PTR_W))
            $error("qv_rob: kill behind a tag the ROB does not hold");
        if (qv_rob_dist(QV_ROB_TAG_W'(head_next), QV_ROB_TAG_W'(head_q), PTR_W) > k_dist)
            $error("qv_rob: kill below this cycle's retirements");
    end
`endif
endmodule
