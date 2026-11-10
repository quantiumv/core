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
 * RVFI's source registers are carried in the ROB; their values are the
 * operands the uop's unit takes, which core.sv keeps by ROB index.
 *
 * Debug knobs: SERIALIZE=1 issues only into an empty ROB (one
 * instruction in flight); BYPASS_EN=0 drops path 3, turning a back-to-
 * back dependence into a one-cycle stall.
 *
 * F/D: an operand that is an FP register (rs1_fp, rs2_fp; rs3 always) resolves the same way through a second
 * producer table, the FP register file (fprf0) and the ROB; f0 is claimed like any other register. Path 3 also
 * takes the FPU's writeback bus. FPU ops go to qv_exu_fpu; a divide or square root waits for its side unit to be
 * free. RVFI reports an FP source as register 0 (RVFI's rs fields are integer registers).
 *
 * LSU_BYPASS (O2d): path 3 also takes the LSU's writeback, so an op that needs a load's value issues in the cycle
 * the load completes rather than a cycle later from the ROB. (It is a long path, from the memory port's data input
 * through the LSU's extension into the operand registers; nothing here measures clock rate.)
 *
 * CSR_LATE (P10c): a CSR op's rd value is made at commit (its ROB value and
 * its writeback are only the ALU's pass of its source), so its claim is
 * marked late: paths 3 and 4 never apply to it, and a dependent waits until
 * the claim clears at the commit, then reads regfile0. (Without it, every CSR
 * op serializes and nothing younger survives to read the claim.)
 *
 * RS_DEPTH (O1): a reservation station (qv_rs) of that many entries. Dispatch (ROB allocation, the claim, the
 * operands resolved as above) stays in order, one uop a cycle; what changes is that a uop which cannot go to its unit
 * in the dispatch cycle -- an operand at step 5, or its unit's port taken -- goes into the station instead of
 * stalling dispatch, and leaves it when its operands exist and its unit is free, possibly before older uops. A uop
 * goes straight to its unit, exactly as without the station, when its operands are ready, its unit is free and the
 * station does not take that unit's port in this cycle (for a divide or an FP divide/square root: holds none of its
 * kind, so those keep program order). The station takes in every writeback bus and the commit bus (i_wbc: commit's
 * regfile write, which is what wakes a late operand). Memory ops do not use it. Without LSQ_WAIT they still dispatch
 * only with their operands ready and the LSU (or the load/store queue) free; with LSQ_WAIT (O1c: the station and the
 * queue both there) a memory op needs only room in the queue, and its operands (o_lsu_opa, o_lsu_opb, in the station's
 * form) wait there. RS_DEPTH 0 is the core without it, cycle for cycle.
 *
 * DISPATCH_W 2 (O4c): a second uop (i_uop1, the next instruction behind i_uop) dispatches in the same cycle when the
 * pair rules allow: slot 0 dispatches; there is ROB room for two; it is not a SERIALIZE build or a Program Buffer run;
 * neither is a CSR, system, FENCE, serializing, divide, FP divide/square root or atomic uop, or carries a fault or a
 * trigger mark (those dispatch alone); at most one is a memory op (one push into the queue), and at most one touches
 * FP state (one FP claim, the FP register file's three read ports and the third ROB lookup serve that one). Slot 1's
 * sources resolve as slot 0's do, from its own read ports (rs1b, rs2b) and ROB lookups (4, 5), except a source that
 * is slot 0's destination: that value cannot exist in this cycle, so the operand waits for slot 0's tag (never late:
 * slot 0 is no CSR op), and slot 1 cannot go straight to its unit -- it goes into the station, or waits in the queue,
 * or the pair splits. The ports go to the station's picks first, then slot 0, then slot 1. Slot 1's claim comes after
 * slot 0's, so it wins a register both write.
 */
module qv_issue #(
    parameter bit SERIALIZE = 1'b0,
    parameter bit BYPASS_EN = 1'b1,
    parameter bit CSR_LATE  = 1'b0,
    parameter bit LSU_BYPASS = 1'b0,            // path 3 also takes the LSU's writeback (O2d)
    parameter int RS_DEPTH  = 0,                // reservation-station entries (O1); 0: none
    parameter bit LSQ_WAIT  = 1'b0,             // a memory op's operands may wait in the load/store queue (O1c)
    parameter int DISPATCH_W = 1                // O4c: 2 dispatches a second uop in the same cycle when it may
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_flush,

    input  logic                             i_uop_valid,
    // code is kept for debugging only
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
    output qv_pkg::rob_ctrl_t                o_alloc_ctrl,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_alloc_tag,
    input  logic                             i_alloc_ready,
    input  logic                             i_rob_empty,

    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup1_tag,
    input  logic                             i_lookup1_complete,
    input  logic [63:0]                      i_lookup1_value,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup2_tag,
    input  logic                             i_lookup2_complete,
    input  logic [63:0]                      i_lookup2_value,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup3_tag,
    input  logic                             i_lookup3_complete = 1'b0,
    input  logic [63:0]                      i_lookup3_value = 64'b0,

    // F/D: the FP register file's read ports, the FPU's writeback (bypass), the FPU's request port
    output logic [4:0]                       o_frs1_sel,
    output logic [4:0]                       o_frs2_sel,
    output logic [4:0]                       o_frs3_sel,
    input  logic [63:0]                      i_frs1_data = 64'b0,
    input  logic [63:0]                      i_frs2_data = 64'b0,
    input  logic [63:0]                      i_frs3_data = 64'b0,
    // flags are for the ROB
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_fp_t                   i_wbf = '0,
    // (LSU_BYPASS) the LSU's writeback: a load's value in its completion cycle
    input  qv_pkg::wb_t                      i_wbl = '0,
    // (RS_DEPTH) the divider's writeback and the commit bus (commit's regfile write and the committing tag): they
    // wake the station's operands
    input  qv_pkg::wb_t                      i_wbd = '0,
    input  qv_pkg::wb_t                      i_wbc = '0,
    /* verilator lint_on UNUSEDSIGNAL */
    output qv_pkg::fpu_req_t                 o_fpu_req,
    input  logic                             i_fpu_ds_free = 1'b1,   // registered: one divide/sqrt at a time

    // bypass needs only valid/tag/value; next_pc/mispredict are for the ROB
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::wb_t                      i_wb,
    /* verilator lint_on UNUSEDSIGNAL */
    output qv_pkg::fu_req_t                  o_alu_req,
    output qv_pkg::fu_req_t                  o_bru_req,
    output qv_pkg::fu_req_t                  o_lsu_req,
    output qv_pkg::rs_opnd_t                 o_lsu_opa,    // (LSQ_WAIT) its operands: ready, or the producer's tag
    output qv_pkg::rs_opnd_t                 o_lsu_opb,
    input  logic                             i_lsu_free,   // registered: one memory op at a time
    output qv_pkg::fu_req_t                  o_div_req,
    input  logic                             i_div_free,   // registered: one divide at a time

    input  logic                             i_commit_valid,
    input  logic [4:0]                       i_commit_rd,
    input  logic                             i_commit_rd_wen,
    input  logic                             i_commit_rd_fp = 1'b0,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_commit_tag,
    // O4: a second retirement in the same cycle (the younger of the two): its claim is cleared the same way
    input  logic                             i_commit2_valid = 1'b0,
    input  logic [4:0]                       i_commit2_rd = 5'b0,
    input  logic                             i_commit2_rd_wen = 1'b0,
    input  logic                             i_commit2_rd_fp = 1'b0,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_commit2_tag = '0,

    // O4c: the second dispatching uop (slot 1), and what it needs of its own; the defaults are a one-wide core
    input  logic                             i_uop1_valid = 1'b0,
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::uop_t                     i_uop1 = '0,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                             i_pb_active = 1'b0,
    output logic                             o_issue2,
    output logic [4:0]                       o_rs1b_sel,
    output logic [4:0]                       o_rs2b_sel,
    input  logic [63:0]                      i_rs1b_data = 64'b0,
    input  logic [63:0]                      i_rs2b_data = 64'b0,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup4_tag,
    input  logic                             i_lookup4_complete = 1'b0,
    input  logic [63:0]                      i_lookup4_value = 64'b0,
    output logic [qv_pkg::QV_ROB_TAG_W-1:0]  o_lookup5_tag,
    input  logic                             i_lookup5_complete = 1'b0,
    input  logic [63:0]                      i_lookup5_value = 64'b0,
    output logic                             o_alloc2_valid,
    output logic [63:0]                      o_alloc2_pc,
    output logic [31:0]                      o_alloc2_raw,
    output logic [4:0]                       o_alloc2_rd,
    output logic                             o_alloc2_rd_wen,
    output logic [63:0]                      o_alloc2_next_pc,
    output qv_pkg::rob_ctrl_t                o_alloc2_ctrl,
    input  logic [qv_pkg::QV_ROB_TAG_W-1:0]  i_alloc_tag1 = '0,
    input  logic                             i_alloc_ready2 = 1'b0,
    // each slot's operands as resolved (ready with the value, or the producer), for RVFI's source values (core.sv)
    output qv_pkg::rs_opnd_t                 o_src0_a,
    output qv_pkg::rs_opnd_t                 o_src0_b,
    output qv_pkg::rs_opnd_t                 o_src1_a,
    output qv_pkg::rs_opnd_t                 o_src1_b
);
    import qv_pkg::*;

    // ---------------- producer table ----------------
    logic                    prod_busy_q [0:31];
    logic [QV_ROB_TAG_W-1:0] prod_tag_q  [0:31];
    logic                    prod_late_q [0:31];     // (CSR_LATE) the producer's value is made at its commit

    // F/D: the FP registers' producers (never late: no CSR op writes an FP register)
    logic                    fprod_busy_q [0:31];
    logic [QV_ROB_TAG_W-1:0] fprod_tag_q  [0:31];

    wire                    p1_busy = i_uop.rs1_fp ? fprod_busy_q[i_uop.rs1] : prod_busy_q[i_uop.rs1];
    wire [QV_ROB_TAG_W-1:0] p1_tag  = i_uop.rs1_fp ? fprod_tag_q[i_uop.rs1] : prod_tag_q[i_uop.rs1];
    wire                    p1_late = !i_uop.rs1_fp && prod_late_q[i_uop.rs1];
    wire                    p2_busy = i_uop.rs2_fp ? fprod_busy_q[i_uop.rs2] : prod_busy_q[i_uop.rs2];
    wire [QV_ROB_TAG_W-1:0] p2_tag  = i_uop.rs2_fp ? fprod_tag_q[i_uop.rs2] : prod_tag_q[i_uop.rs2];
    wire                    p2_late = !i_uop.rs2_fp && prod_late_q[i_uop.rs2];
    wire                    p3_busy = fprod_busy_q[i_uop.rs3];
    wire [QV_ROB_TAG_W-1:0] p3_tag  = fprod_tag_q[i_uop.rs3];
    wire [63:0]             r1_data = i_uop.rs1_fp ? i_frs1_data : i_rs1_data;
    wire [63:0]             r2_data = i_uop.rs2_fp ? i_frs2_data : i_rs2_data;

    // (O4c) what touches FP state: FP sources, an FP destination, the FPU (its flags). At most one slot of a pair does,
    // and the FP read ports and the third lookup serve it (slot 1 only when it is that one).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic touches_fp(input uop_t u);
        return (u.rs1_used && u.rs1_fp) || (u.rs2_used && u.rs2_fp) || u.rs3_used || (u.rd_wen && u.rd_fp)
            || (u.fu == QV_FU_FPU);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    wire fp_s0 = touches_fp(i_uop);
    wire fp_s1 = (DISPATCH_W > 1) && touches_fp(i_uop1) && !fp_s0;

    // (O4c) slot 1's producers: the tables, or slot 0 when slot 0 writes that register (it is being allocated now)
    wire s0_wr_x = i_uop.rd_wen && !i_uop.rd_fp && (i_uop.rd != 5'd0);
    wire s0_wr_f = i_uop.rd_wen && i_uop.rd_fp;
    wire q1_hit  = i_uop1.rs1_used && (i_uop1.rs1_fp ? s0_wr_f : s0_wr_x) && (i_uop1.rs1 == i_uop.rd);
    wire q2_hit  = i_uop1.rs2_used && (i_uop1.rs2_fp ? s0_wr_f : s0_wr_x) && (i_uop1.rs2 == i_uop.rd);
    wire q3_hit  = i_uop1.rs3_used && s0_wr_f && (i_uop1.rs3 == i_uop.rd);
    wire                    q1_busy = q1_hit || (i_uop1.rs1_fp ? fprod_busy_q[i_uop1.rs1] : prod_busy_q[i_uop1.rs1]);
    wire [QV_ROB_TAG_W-1:0] q1_tag  = q1_hit ? i_alloc_tag
                                    : i_uop1.rs1_fp ? fprod_tag_q[i_uop1.rs1] : prod_tag_q[i_uop1.rs1];
    wire                    q1_late = !q1_hit && !i_uop1.rs1_fp && prod_late_q[i_uop1.rs1];
    wire                    q2_busy = q2_hit || (i_uop1.rs2_fp ? fprod_busy_q[i_uop1.rs2] : prod_busy_q[i_uop1.rs2]);
    wire [QV_ROB_TAG_W-1:0] q2_tag  = q2_hit ? i_alloc_tag
                                    : i_uop1.rs2_fp ? fprod_tag_q[i_uop1.rs2] : prod_tag_q[i_uop1.rs2];
    wire                    q2_late = !q2_hit && !i_uop1.rs2_fp && prod_late_q[i_uop1.rs2];
    wire                    q3_busy = q3_hit || fprod_busy_q[i_uop1.rs3];
    wire [QV_ROB_TAG_W-1:0] q3_tag  = q3_hit ? i_alloc_tag : fprod_tag_q[i_uop1.rs3];
    wire [63:0]             s1_r1   = i_uop1.rs1_fp ? i_frs1_data : i_rs1b_data;
    wire [63:0]             s1_r2   = i_uop1.rs2_fp ? i_frs2_data : i_rs2b_data;
    assign o_rs1b_sel    = i_uop1.rs1;
    assign o_rs2b_sel    = i_uop1.rs2;
    assign o_lookup4_tag = q1_tag;
    assign o_lookup5_tag = q2_tag;

    assign o_rs1_sel     = i_uop.rs1;
    assign o_rs2_sel     = i_uop.rs2;
    assign o_lookup1_tag = p1_tag;
    assign o_lookup2_tag = p2_tag;
    assign o_lookup3_tag = fp_s1 ? q3_tag : p3_tag;
    assign o_frs1_sel    = fp_s1 ? i_uop1.rs1 : i_uop.rs1;
    assign o_frs2_sel    = fp_s1 ? i_uop1.rs2 : i_uop.rs2;
    assign o_frs3_sel    = fp_s1 ? i_uop1.rs3 : i_uop.rs3;

    // ---------------- operand resolution ----------------
    logic        a_ready, b_ready, c_ready;
    logic [63:0] opa, opb, opc;

    always_comb begin
        a_ready = 1'b1;
        opa     = i_uop.imm1;
        if (i_uop.rs1_used) begin
            if (!p1_busy)                                          opa = r1_data;
            else if (p1_late)                                      a_ready = 1'b0;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == p1_tag) opa = i_wb.value;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == p1_tag) opa = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == p1_tag) opa = i_wbl.value;
            else if (i_lookup1_complete)                           opa = i_lookup1_value;
            else                                                   a_ready = 1'b0;
        end

        b_ready = 1'b1;
        opb     = i_uop.imm2;
        if (i_uop.rs2_used) begin
            if (!p2_busy)                                          opb = r2_data;
            else if (p2_late)                                      b_ready = 1'b0;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == p2_tag) opb = i_wb.value;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == p2_tag) opb = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == p2_tag) opb = i_wbl.value;
            else if (i_lookup2_complete)                           opb = i_lookup2_value;
            else                                                   b_ready = 1'b0;
        end

        // F/D: the FMA's third source (an FP register; its producer is the FPU or an FP load)
        c_ready = 1'b1;
        opc     = 64'b0;
        if (i_uop.rs3_used) begin
            if (!p3_busy)                                            opc = i_frs3_data;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == p3_tag) opc = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == p3_tag) opc = i_wbl.value;
            else if (i_lookup3_complete)                             opc = i_lookup3_value;
            else                                                     c_ready = 1'b0;
        end
    end

    // (O4c) slot 1's operands, as slot 0's, but a source that is slot 0's destination is never ready now
    logic        a1_ready, b1_ready, c1_ready;
    logic [63:0] opa1, opb1, opc1;
    always_comb begin
        a1_ready = 1'b1;
        opa1     = i_uop1.imm1;
        if (i_uop1.rs1_used) begin
            if (q1_hit)                                             a1_ready = 1'b0;
            else if (!q1_busy)                                      opa1 = s1_r1;
            else if (q1_late)                                       a1_ready = 1'b0;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == q1_tag)   opa1 = i_wb.value;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == q1_tag) opa1 = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == q1_tag) opa1 = i_wbl.value;
            else if (i_lookup4_complete)                            opa1 = i_lookup4_value;
            else                                                    a1_ready = 1'b0;
        end
        b1_ready = 1'b1;
        opb1     = i_uop1.imm2;
        if (i_uop1.rs2_used) begin
            if (q2_hit)                                             b1_ready = 1'b0;
            else if (!q2_busy)                                      opb1 = s1_r2;
            else if (q2_late)                                       b1_ready = 1'b0;
            else if (BYPASS_EN && i_wb.valid && i_wb.tag == q2_tag)   opb1 = i_wb.value;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == q2_tag) opb1 = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == q2_tag) opb1 = i_wbl.value;
            else if (i_lookup5_complete)                            opb1 = i_lookup5_value;
            else                                                    b1_ready = 1'b0;
        end
        c1_ready = 1'b1;
        opc1     = 64'b0;
        if (i_uop1.rs3_used) begin
            if (q3_hit)                                               c1_ready = 1'b0;
            else if (!q3_busy)                                        opc1 = i_frs3_data;
            else if (BYPASS_EN && i_wbf.valid && i_wbf.tag == q3_tag) opc1 = i_wbf.value;
            else if (LSU_BYPASS && BYPASS_EN && i_wbl.valid && i_wbl.tag == q3_tag) opc1 = i_wbl.value;
            else if (i_lookup3_complete)                              opc1 = i_lookup3_value;
            else                                                      c1_ready = 1'b0;
        end
    end

    wire to_bru = (i_uop.fu == QV_FU_BRU);
    wire to_lsu = (i_uop.fu == QV_FU_LSU);
    wire to_div = (i_uop.fu == QV_FU_DIV);
    wire to_fpu = (i_uop.fu == QV_FU_FPU);
    wire fpu_ds = (qv_fp_op_e'(i_uop.fp_op) == QV_FP_DIV) || (qv_fp_op_e'(i_uop.fp_op) == QV_FP_SQRT);

    // the station's view of the ports (all 0 without one)
    logic     rs_room, rs_room2, rs_has_div, rs_has_fds, rs_sel_ab, rs_sel_div, rs_sel_fpu;
    fu_req_t  rs_alu_req, rs_bru_req, rs_div_req;
    fpu_req_t rs_fpu_req;

    // straight to the unit: operands ready and the unit's port free (not taken by the station; a divide or an FP
    // divide/square root also waits for every one of its kind in the station, which keeps them in program order)
    wire direct = a_ready && b_ready && c_ready
               && (to_lsu ? i_lsu_free
                   : to_div ? (i_div_free && !rs_has_div)
                   : to_fpu ? (!rs_sel_fpu && (!fpu_ds || (i_fpu_ds_free && !rs_has_fds)))
                   :          !rs_sel_ab);
    wire to_rs  = (RS_DEPTH > 0) && !to_lsu && !direct;
    // (LSQ_WAIT) a memory op needs only room in the queue: its operands may wait there
    wire to_lsq = LSQ_WAIT && to_lsu && i_lsu_free;

    assign o_issue = i_uop_valid && i_alloc_ready && (!SERIALIZE || i_rob_empty) && !i_flush
                  && (direct || to_lsq || (to_rs && rs_room));

    // ---------------- (O4c) slot 1 ----------------
    // alone: what dispatches by itself (in either slot)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic alone(input uop_t u);
        return (u.fu == QV_FU_CSR) || (u.fu == QV_FU_SYS) || (u.fu == QV_FU_DIV) || u.is_atomic || u.serialize
            || u.xcpt || u.trig_debug || u.trig_exc || (u.raw[6:0] == 7'b0001111)
            || ((u.fu == QV_FU_FPU) && ((qv_fp_op_e'(u.fp_op) == QV_FP_DIV) || (qv_fp_op_e'(u.fp_op) == QV_FP_SQRT)));
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    wire to_bru1 = (i_uop1.fu == QV_FU_BRU);
    wire to_lsu1 = (i_uop1.fu == QV_FU_LSU);
    wire to_fpu1 = (i_uop1.fu == QV_FU_FPU);
    // slot 0 takes the ALU/BRU port (or the FPU's) straight to its unit this cycle
    wire s0_ab   = o_issue && direct && !to_lsu && !to_div && !to_fpu;
    wire s0_fpu  = o_issue && direct && to_fpu;
    wire direct1 = a1_ready && b1_ready && c1_ready
                && (to_lsu1 ? i_lsu_free
                    : to_fpu1 ? (!rs_sel_fpu && !s0_fpu)
                    :           (!rs_sel_ab && !s0_ab));
    wire to_rs1  = (RS_DEPTH > 0) && !to_lsu1 && !direct1;
    wire to_lsq1 = LSQ_WAIT && to_lsu1 && i_lsu_free;
    wire rs_ok1  = (o_issue && to_rs) ? rs_room2 : rs_room;     // the station's room behind slot 0's push
    wire pair_ok = (DISPATCH_W > 1) && i_uop1_valid && o_issue && i_alloc_ready2 && !SERIALIZE && !i_pb_active
                && !alone(i_uop) && !alone(i_uop1) && !(to_lsu && to_lsu1) && !(fp_s0 && touches_fp(i_uop1));
    assign o_issue2 = pair_ok && (direct1 || to_lsq1 || (to_rs1 && rs_ok1));

    // (read by the CPI stack) the uop waits for room in a full station
    /* verilator lint_off UNUSEDSIGNAL */
    wire rs_full = i_uop_valid && to_rs && !rs_room;
    /* verilator lint_on UNUSEDSIGNAL */

    // (LSQ_WAIT) the memory op's operands for the queue: ready with the value, or waiting for the producer's tag
    always_comb begin
        o_lsu_opa       = '0;
        o_lsu_opa.rdy   = a_ready;
        o_lsu_opa.late  = p1_late;
        o_lsu_opa.tag   = p1_tag;
        o_lsu_opa.value = opa;
        o_lsu_opb       = '0;
        o_lsu_opb.rdy   = b_ready;
        o_lsu_opb.late  = p2_late;
        o_lsu_opb.tag   = p2_tag;
        o_lsu_opb.value = opb;
        // (O4c) a pair's memory op may be slot 1's (never both)
        if (o_issue2 && to_lsu1) begin
            o_lsu_opa.rdy = a1_ready;  o_lsu_opa.late = q1_late;  o_lsu_opa.tag = q1_tag;  o_lsu_opa.value = opa1;
            o_lsu_opb.rdy = b1_ready;  o_lsu_opb.late = q2_late;  o_lsu_opb.tag = q2_tag;  o_lsu_opb.value = opb1;
        end
        o_src0_a = '0;  o_src0_a.rdy = a_ready;  o_src0_a.tag = p1_tag;  o_src0_a.value = opa;
        o_src0_b = '0;  o_src0_b.rdy = b_ready;  o_src0_b.tag = p2_tag;  o_src0_b.value = opb;
        o_src1_a = '0;  o_src1_a.rdy = a1_ready; o_src1_a.tag = q1_tag;  o_src1_a.value = opa1;
        o_src1_b = '0;  o_src1_b.rdy = b1_ready; o_src1_b.tag = q2_tag;  o_src1_b.value = opb1;
    end

    // ---------------- ROB allocation ----------------
    assign o_alloc_valid   = o_issue;
    assign o_alloc_pc      = i_uop.pc;
    assign o_alloc_raw     = i_uop.raw;
    assign o_alloc_rd      = i_uop.rd;
    assign o_alloc_rd_wen  = i_uop.rd_wen;
    // the frontend's choice; the BRU checks it against the resolved one
    wire [63:0] pred_next  = i_uop.pred_taken ? i_uop.pred_tgt : i_uop.pc + (i_uop.rvc ? 64'd2 : 64'd4);
    assign o_alloc_next_pc = pred_next;

    always_comb begin
        o_alloc_ctrl           = '0;
        o_alloc_ctrl.cls       = i_uop.fu;
        o_alloc_ctrl.sys_op    = i_uop.sys_op;
        o_alloc_ctrl.csr_op    = i_uop.csr_op;
        o_alloc_ctrl.csr_addr  = i_uop.csr_addr;
        o_alloc_ctrl.csr_wsup  = i_uop.csr_wsup;
        o_alloc_ctrl.serialize = i_uop.serialize;
        // the reservation (LR sets it, any store-class op clears it) is kept
        // by commit; a decode fault never reaches the LSU, so it never counts
        o_alloc_ctrl.is_lr     = i_uop.is_atomic && i_uop.amo_op == QV_AMO_LR && !i_uop.xcpt;
        o_alloc_ctrl.is_store_class = (i_uop.is_store || (i_uop.is_atomic && i_uop.amo_op != QV_AMO_LR))
                                      && !i_uop.xcpt;
        o_alloc_ctrl.xcpt      = i_uop.xcpt;
        o_alloc_ctrl.cause     = i_uop.xcpt_cause;
        o_alloc_ctrl.xcpt_hi   = i_uop.xcpt_hi;
        o_alloc_ctrl.trig_debug = i_uop.trig_debug;
        o_alloc_ctrl.trig_exc   = i_uop.trig_exc;
        o_alloc_ctrl.rd_fp      = i_uop.rd_fp;
        // decode makes an unused source register 0
        o_alloc_ctrl.rvfi_rs1   = i_uop.rs1_fp ? 5'b0 : i_uop.rs1;
        o_alloc_ctrl.rvfi_rs2   = i_uop.rs2_fp ? 5'b0 : i_uop.rs2;
    end

    // (O4c) slot 1's allocation, as slot 0's
    wire [63:0] pred_next1  = i_uop1.pred_taken ? i_uop1.pred_tgt : i_uop1.pc + (i_uop1.rvc ? 64'd2 : 64'd4);
    assign o_alloc2_valid   = o_issue2;
    assign o_alloc2_pc      = i_uop1.pc;
    assign o_alloc2_raw     = i_uop1.raw;
    assign o_alloc2_rd      = i_uop1.rd;
    assign o_alloc2_rd_wen  = i_uop1.rd_wen;
    assign o_alloc2_next_pc = pred_next1;
    always_comb begin
        o_alloc2_ctrl           = '0;
        o_alloc2_ctrl.cls       = i_uop1.fu;
        o_alloc2_ctrl.sys_op    = i_uop1.sys_op;
        o_alloc2_ctrl.csr_op    = i_uop1.csr_op;
        o_alloc2_ctrl.csr_addr  = i_uop1.csr_addr;
        o_alloc2_ctrl.csr_wsup  = i_uop1.csr_wsup;
        o_alloc2_ctrl.serialize = i_uop1.serialize;
        o_alloc2_ctrl.is_lr     = i_uop1.is_atomic && i_uop1.amo_op == QV_AMO_LR && !i_uop1.xcpt;
        o_alloc2_ctrl.is_store_class = (i_uop1.is_store || (i_uop1.is_atomic && i_uop1.amo_op != QV_AMO_LR))
                                       && !i_uop1.xcpt;
        o_alloc2_ctrl.xcpt      = i_uop1.xcpt;
        o_alloc2_ctrl.cause     = i_uop1.xcpt_cause;
        o_alloc2_ctrl.xcpt_hi   = i_uop1.xcpt_hi;
        o_alloc2_ctrl.trig_debug = i_uop1.trig_debug;
        o_alloc2_ctrl.trig_exc   = i_uop1.trig_exc;
        o_alloc2_ctrl.rd_fp      = i_uop1.rd_fp;
        o_alloc2_ctrl.rvfi_rs1   = i_uop1.rs1_fp ? 5'b0 : i_uop1.rs1;
        o_alloc2_ctrl.rvfi_rs2   = i_uop1.rs2_fp ? 5'b0 : i_uop1.rs2;
    end

    // ---------------- dispatch: one request port per unit ----------------
    // CSR and SYS uops go through the ALU only to resolve their source
    // operand; commit carries out the operation itself at the ROB head.
    // Memory uops go to the LSU (op = {0, store, signed, size}; a = rs1,
    // b = rs2 or the I-immediate, imm = the S-immediate -- or, for an atomic,
    // op = {1, qv_amo_op_e}, a = rs1 (the address), b = rs2, is_word for .W),
    // which takes one at a time -- the next waits here until it is free. Divides likewise
    // go to the divider (op = {quotient, signed}, is_word for the W forms).
    // The ALU is the default for everything else, so every other unit must
    // be excluded from it by name.
    fu_req_t req, req1;
    always_comb begin
        req         = '0;
        req.tag     = i_alloc_tag;
        if (to_bru)      req.op = 5'(i_uop.bru_op);
        else if (to_lsu) req.op = i_uop.is_atomic ? {1'b1, 4'(i_uop.amo_op)}
                                                  : {1'b0, i_uop.is_store, i_uop.mem_signed, i_uop.mem_size};
        else if (to_div) req.op = {3'b0, i_uop.div_quot, i_uop.div_signed};
        else             req.op = i_uop.alu_op;
        req.is_word = i_uop.is_word;
        req.a       = opa;
        req.b       = opb;
        req.pc      = i_uop.pc;
        req.imm     = i_uop.imm3;
        req.rvc     = i_uop.rvc;
        req.pred_next = pred_next;
        req.fp        = i_uop.rd_fp;

        o_alu_req       = req;
        o_alu_req.valid = o_issue && direct && !to_bru && !to_lsu && !to_div && !to_fpu;
        o_bru_req       = req;
        o_bru_req.valid = o_issue && direct && to_bru;
        o_lsu_req       = req;
        o_lsu_req.valid = o_issue && to_lsu;
        o_div_req       = req;
        o_div_req.valid = o_issue && direct && to_div;

        // F/D: a = rs1 (an integer for FMV.W.X/D.X and the conversions from an integer), b = rs2, c = rs3
        o_fpu_req       = '0;
        o_fpu_req.valid = o_issue && direct && to_fpu;
        o_fpu_req.tag   = i_alloc_tag;
        o_fpu_req.op    = qv_fp_op_e'(i_uop.fp_op);
        o_fpu_req.fmt   = i_uop.fp_fmt;
        o_fpu_req.ityp  = i_uop.fp_ityp;
        o_fpu_req.rm    = i_uop.fp_rm;
        o_fpu_req.a     = opa;
        o_fpu_req.b     = opb;
        o_fpu_req.c     = opc;

        // (O4c) slot 1 straight to its unit: a port slot 0 and the station leave free
        req1         = '0;
        req1.tag     = i_alloc_tag1;
        if (to_bru1)      req1.op = 5'(i_uop1.bru_op);
        else if (to_lsu1) req1.op = {1'b0, i_uop1.is_store, i_uop1.mem_signed, i_uop1.mem_size};
        else              req1.op = i_uop1.alu_op;
        req1.is_word   = i_uop1.is_word;
        req1.a         = opa1;
        req1.b         = opb1;
        req1.pc        = i_uop1.pc;
        req1.imm       = i_uop1.imm3;
        req1.rvc       = i_uop1.rvc;
        req1.pred_next = pred_next1;
        req1.fp        = i_uop1.rd_fp;
        if (o_issue2 && direct1 && !to_bru1 && !to_lsu1 && !to_fpu1) begin
            o_alu_req = req1; o_alu_req.valid = 1'b1;
        end
        if (o_issue2 && direct1 && to_bru1) begin
            o_bru_req = req1; o_bru_req.valid = 1'b1;
        end
        if (o_issue2 && to_lsu1) begin
            o_lsu_req = req1; o_lsu_req.valid = 1'b1;
        end
        if (o_issue2 && direct1 && to_fpu1) begin
            o_fpu_req       = '0;
            o_fpu_req.valid = 1'b1;
            o_fpu_req.tag   = i_alloc_tag1;
            o_fpu_req.op    = qv_fp_op_e'(i_uop1.fp_op);
            o_fpu_req.fmt   = i_uop1.fp_fmt;
            o_fpu_req.ityp  = i_uop1.fp_ityp;
            o_fpu_req.rm    = i_uop1.fp_rm;
            o_fpu_req.a     = opa1;
            o_fpu_req.b     = opb1;
            o_fpu_req.c     = opc1;
        end

        // the station's picks take their ports (the dispatching uop then went into the station, or to another unit)
        if (rs_sel_ab) begin
            o_alu_req = rs_alu_req;
            o_bru_req = rs_bru_req;
        end
        if (rs_sel_div) o_div_req = rs_div_req;
        if (rs_sel_fpu) o_fpu_req = rs_fpu_req;
    end

    // ---------------- the reservation station ----------------
    generate
        if (RS_DEPTH > 0) begin : g_rs
            rs_entry_t pe;                      // the dispatching uop, as the station holds it
            always_comb begin
                pe           = '0;
                pe.kind      = qv_rs_kind_e'(to_bru ? QV_RS_BRU : to_div ? QV_RS_DIV
                             : to_fpu ? (fpu_ds ? QV_RS_FDS : QV_RS_FPU) : QV_RS_ALU);
                pe.tag       = i_alloc_tag;
                pe.op        = to_fpu ? i_uop.fp_op : req.op;
                pe.is_word   = i_uop.is_word;
                pe.pc        = i_uop.pc;
                pe.imm       = i_uop.imm3;
                pe.rvc       = i_uop.rvc;
                pe.pred_next = pred_next;
                pe.fmt       = i_uop.fp_fmt;
                pe.ityp      = i_uop.fp_ityp;
                pe.rm        = i_uop.fp_rm;
                pe.a.rdy     = a_ready;  pe.a.late = p1_late;  pe.a.tag = p1_tag;  pe.a.value = opa;
                pe.b.rdy     = b_ready;  pe.b.late = p2_late;  pe.b.tag = p2_tag;  pe.b.value = opb;
                pe.c.rdy     = c_ready;  pe.c.late = 1'b0;     pe.c.tag = p3_tag;  pe.c.value = opc;
            end
            rs_entry_t pe1;                     // (O4c) slot 1, as the station holds it (never a divide)
            always_comb begin
                pe1           = '0;
                pe1.kind      = qv_rs_kind_e'(to_bru1 ? QV_RS_BRU : to_fpu1 ? QV_RS_FPU : QV_RS_ALU);
                pe1.tag       = i_alloc_tag1;
                pe1.op        = to_fpu1 ? i_uop1.fp_op : req1.op;
                pe1.is_word   = i_uop1.is_word;
                pe1.pc        = i_uop1.pc;
                pe1.imm       = i_uop1.imm3;
                pe1.rvc       = i_uop1.rvc;
                pe1.pred_next = pred_next1;
                pe1.fmt       = i_uop1.fp_fmt;
                pe1.ityp      = i_uop1.fp_ityp;
                pe1.rm        = i_uop1.fp_rm;
                pe1.a.rdy     = a1_ready;  pe1.a.late = q1_late;  pe1.a.tag = q1_tag;  pe1.a.value = opa1;
                pe1.b.rdy     = b1_ready;  pe1.b.late = q2_late;  pe1.b.tag = q2_tag;  pe1.b.value = opb1;
                pe1.c.rdy     = c1_ready;  pe1.c.late = 1'b0;     pe1.c.tag = q3_tag;  pe1.c.value = opc1;
            end
            qv_rs #(.DEPTH(RS_DEPTH), .BYPASS_EN(BYPASS_EN), .LSU_BYPASS(LSU_BYPASS)) rs0 (
                .clk(clk), .rst(rst), .i_flush(i_flush),
                .i_push(o_issue && to_rs), .i_push_e(pe), .o_room(rs_room),
                .i_push2(o_issue2 && to_rs1), .i_push2_e(pe1), .o_room2(rs_room2),
                .o_has_div(rs_has_div), .o_has_fds(rs_has_fds),
                .i_wb(i_wb), .i_wbl(i_wbl), .i_wbd(i_wbd), .i_wbf(i_wbf), .i_wbc(i_wbc),
                .i_div_free(i_div_free), .i_fpu_ds_free(i_fpu_ds_free),
                .o_sel_ab(rs_sel_ab), .o_sel_div(rs_sel_div), .o_sel_fpu(rs_sel_fpu),
                .o_alu_req(rs_alu_req), .o_bru_req(rs_bru_req), .o_div_req(rs_div_req), .o_fpu_req(rs_fpu_req)
            );
        end else begin : g_nors
            assign rs_room    = 1'b0;
            assign rs_room2   = 1'b0;
            assign rs_has_div = 1'b0;
            assign rs_has_fds = 1'b0;
            assign rs_sel_ab  = 1'b0;
            assign rs_sel_div = 1'b0;
            assign rs_sel_fpu = 1'b0;
            assign rs_alu_req = '0;
            assign rs_bru_req = '0;
            assign rs_div_req = '0;
            assign rs_fpu_req = '0;
        end
    endgenerate

    // ---------------- producer table update ----------------
    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            for (int r = 0; r < 32; r++) begin
                prod_busy_q[r] <= 1'b0; prod_late_q[r] <= 1'b0; fprod_busy_q[r] <= 1'b0;
            end
        end else begin
            if (i_commit_valid && i_commit_rd_wen && i_commit_rd != 5'd0 && !i_commit_rd_fp
                    && prod_busy_q[i_commit_rd] && prod_tag_q[i_commit_rd] == i_commit_tag)
                prod_busy_q[i_commit_rd] <= 1'b0;
            if (i_commit_valid && i_commit_rd_wen && i_commit_rd_fp
                    && fprod_busy_q[i_commit_rd] && fprod_tag_q[i_commit_rd] == i_commit_tag)
                fprod_busy_q[i_commit_rd] <= 1'b0;
            // (O4) the second retirement's: two writes of one register leave the younger's claim, which the older's
            // tag does not match; a claim made this cycle comes later and wins, as for the first
            if (i_commit2_valid && i_commit2_rd_wen && i_commit2_rd != 5'd0 && !i_commit2_rd_fp
                    && prod_busy_q[i_commit2_rd] && prod_tag_q[i_commit2_rd] == i_commit2_tag)
                prod_busy_q[i_commit2_rd] <= 1'b0;
            if (i_commit2_valid && i_commit2_rd_wen && i_commit2_rd_fp
                    && fprod_busy_q[i_commit2_rd] && fprod_tag_q[i_commit2_rd] == i_commit2_tag)
                fprod_busy_q[i_commit2_rd] <= 1'b0;
            if (o_issue && i_uop.rd_wen && i_uop.rd_fp) begin
                fprod_busy_q[i_uop.rd] <= 1'b1;
                fprod_tag_q[i_uop.rd]  <= i_alloc_tag;
            end
            if (o_issue && i_uop.rd_wen && i_uop.rd != 5'd0 && !i_uop.rd_fp) begin
                prod_busy_q[i_uop.rd] <= 1'b1;
                prod_tag_q[i_uop.rd]  <= i_alloc_tag;
                prod_late_q[i_uop.rd] <= CSR_LATE && (i_uop.fu == QV_FU_CSR);
            end
            // (O4c) slot 1's claim, the younger: it wins a register both write
            if (o_issue2 && i_uop1.rd_wen && i_uop1.rd_fp) begin
                fprod_busy_q[i_uop1.rd] <= 1'b1;
                fprod_tag_q[i_uop1.rd]  <= i_alloc_tag1;
            end
            if (o_issue2 && i_uop1.rd_wen && i_uop1.rd != 5'd0 && !i_uop1.rd_fp) begin
                prod_busy_q[i_uop1.rd] <= 1'b1;
                prod_tag_q[i_uop1.rd]  <= i_alloc_tag1;
                prod_late_q[i_uop1.rd] <= 1'b0;                 // slot 1 is never a CSR op
            end
        end
    end
endmodule
