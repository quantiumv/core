// SPDX-License-Identifier: MIT

/*
 * qv_issue -- in-order issue: operand resolution, ROB allocation and
 * functional-unit dispatch, one uop per cycle.
 *
 * Each source operand resolves, in order:
 *   1. not a register (rsN_used=0, which includes x0)  -> the immediate;
 *   2. no in-flight producer                          -> regfile0;
 *   3. producer's result on the writeback bus now     -> bypass (BYPASS_EN);
 *   4. producer completed, waiting in the ROB         -> the ROB entry;
 *   5. otherwise                                      -> stall this cycle.
 *
 * The producer table holds, per architectural register, whether an
 * in-flight instruction will write it and that instruction's ROB tag. It
 * is set at issue and cleared when that same instruction commits -- the
 * tag compare matters: if a younger instruction has since claimed the
 * register, the older one's commit must leave the claim alone. x0 is
 * never claimed. On a same-cycle clear and claim of one register, the
 * claim (the younger) wins. A flush clears every claim: everything in
 * flight is dead and regfile0 holds the architectural state.
 *
 * Source values for RVFI are captured here and carried in the ROB:
 * regfile0's two read ports belong to whatever is issuing, so they can't
 * be re-read for an older instruction at commit.
 *
 * Debug knobs: SERIALIZE=1 issues only into an empty ROB (one
 * instruction in flight); BYPASS_EN=0 drops path 3, turning a back-to-
 * back dependence into a one-cycle stall.
 */
module qv_issue #(
    parameter bit SERIALIZE = 1'b0,
    parameter bit BYPASS_EN = 1'b1
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    input  logic                             i_uop_valid,
    // fu/code (routing to more than one unit) and xcpt (carried to the
    // ROB for commit to trap on) aren't consumed until those land
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::uop_t                     i_uop,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                             o_issue,

    output logic [4:0]                       o_rs1_sel,
    output logic [4:0]                       o_rs2_sel,
    input  logic [63:0]                      i_rs1_data,
    input  logic [63:0]                      i_rs2_data,

    output logic                             o_alloc_valid,
    output logic [63:0]                      o_alloc_pc,
    output logic [31:0]                      o_alloc_raw,
    output logic [4:0]                       o_alloc_rd,
    output logic                             o_alloc_rd_wen,
    output logic [63:0]                      o_alloc_next_pc,
    output qv_pkg::rvfi_shadow_t             o_alloc_shadow,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_alloc_tag,
    input  logic                             i_alloc_ready,
    input  logic                             i_rob_empty,

    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup1_tag,
    input  logic                             i_lookup1_complete,
    input  logic [63:0]                      i_lookup1_value,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup2_tag,
    input  logic                             i_lookup2_complete,
    input  logic [63:0]                      i_lookup2_value,

    input  qv_pkg::wb_t                      i_wb,
    output qv_pkg::fu_req_t                  o_fu_req,

    input  logic                             i_commit_valid,
    input  logic [4:0]                       i_commit_rd,
    input  logic                             i_commit_rd_wen,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_commit_tag
);
    import qv_pkg::*;

    // ---------------- producer table ----------------
    logic                    prod_busy_q [0:31];
    logic [QV_ROB_TAG_W-1:0] prod_tag_q  [0:31];

    wire                    p1_busy = prod_busy_q[i_uop.rs1];
    wire [QV_ROB_TAG_W-1:0] p1_tag  = prod_tag_q[i_uop.rs1];
    wire                    p2_busy = prod_busy_q[i_uop.rs2];
    wire [QV_ROB_TAG_W-1:0] p2_tag  = prod_tag_q[i_uop.rs2];

    assign o_rs1_sel     = i_uop.rs1;
    assign o_rs2_sel     = i_uop.rs2;
    assign o_lookup1_tag = p1_tag;
    assign o_lookup2_tag = p2_tag;

    // ---------------- operand resolution ----------------
    logic        a_ready, b_ready;
    logic [63:0] opa, opb;

    always_comb begin
        a_ready = 1'b1;
        opa     = i_uop.imm1;
        if (i_uop.rs1_used) begin
            if (!p1_busy)                                          opa = i_rs1_data;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == p1_tag) opa = i_wb.value;
            else if (i_lookup1_complete)                           opa = i_lookup1_value;
            else                                                   a_ready = 1'b0;
        end

        b_ready = 1'b1;
        opb     = i_uop.imm2;
        if (i_uop.rs2_used) begin
            if (!p2_busy)                                          opb = i_rs2_data;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == p2_tag) opb = i_wb.value;
            else if (i_lookup2_complete)                           opb = i_lookup2_value;
            else                                                   b_ready = 1'b0;
        end
    end

    assign o_issue = i_uop_valid && a_ready && b_ready && i_alloc_ready
                  && (!SERIALIZE || i_rob_empty) && !i_flush;

    // ---------------- ROB allocation ----------------
    assign o_alloc_valid   = o_issue;
    assign o_alloc_pc      = i_uop.pc;
    assign o_alloc_raw     = i_uop.raw;
    assign o_alloc_rd      = i_uop.rd;
    assign o_alloc_rd_wen  = i_uop.rd_wen;
    assign o_alloc_next_pc = i_uop.pc + (i_uop.rvc ? 64'd2 : 64'd4);

    always_comb begin
        o_alloc_shadow           = '0;
        o_alloc_shadow.rs1_addr  = i_uop.rs1;
        o_alloc_shadow.rs1_rdata = i_uop.rs1_used ? opa : 64'b0;
        o_alloc_shadow.rs2_addr  = i_uop.rs2;
        o_alloc_shadow.rs2_rdata = i_uop.rs2_used ? opb : 64'b0;
    end

    // ---------------- dispatch ----------------
    always_comb begin
        o_fu_req       = '0;
        o_fu_req.valid = o_issue;
        o_fu_req.tag   = i_alloc_tag;
        o_fu_req.op    = i_uop.alu_op;
        o_fu_req.a     = opa;
        o_fu_req.b     = opb;
    end

    // ---------------- producer table update ----------------
    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            for (int r = 0; r < 32; r++) prod_busy_q[r] <= 1'b0;
        end else begin
            if (i_commit_valid && i_commit_rd_wen && i_commit_rd != 5'd0
                    && prod_busy_q[i_commit_rd] && prod_tag_q[i_commit_rd] == i_commit_tag)
                prod_busy_q[i_commit_rd] <= 1'b0;
            if (o_issue && i_uop.rd_wen && i_uop.rd != 5'd0) begin
                prod_busy_q[i_uop.rd] <= 1'b1;
                prod_tag_q[i_uop.rd]  <= i_alloc_tag;
            end
        end
    end
endmodule
