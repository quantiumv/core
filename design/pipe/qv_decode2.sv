// SPDX-License-Identifier: MIT

/*
 * qv_decode2 -- O4c: the decode stage of a core that dispatches two instructions a cycle. It holds up to two decoded
 * uops (slot 0 the older, slot 1 the next one in program order; slot 1 only when slot 0 is held) and decodes the two
 * oldest IQ entries with two copies of qv_decode's builder (BUILD_ONLY).
 *
 * Issue takes 0, 1 or 2 of them a cycle (i_issue_n; 2 only when both are held, and slot 1 never without slot 0).
 * What is left moves down (slot 1 to slot 0 when slot 0 alone issued), and the free slots refill from the IQ in
 * order: its head first, then the entry behind it. Both builders see the same live privilege, FS, trigger and PMP
 * state as qv_decode does, and the rule that makes that exact holds for two uops as for one: every change of that
 * state flushes decode (qv_decode.sv's header), so a held uop never outlives the state it was decoded against.
 */
module qv_decode2 #(
    parameter bit FPU_EN    = 1'b0,
    parameter bit CSR_NOSER = 1'b0,
    parameter bit ZICNTR_EN = 1'b0
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_flush,

    // the live state qv_decode reads (see there)
    input  logic [1:0]        i_priv,
    input  logic              i_tsr,
    input  logic              i_tvm,
    input  logic [1:0]        i_fs,
    input  logic [2:0]        i_frm,
    input  logic [2:0]        i_mcounteren,
    input  logic [2:0]        i_scounteren,
    input  logic              i_in_debug,
    input  logic              i_pb_active,
    input  logic [63:0]       i_tdata1_0,
    input  logic [63:0]       i_tdata2_0,
    input  logic [63:0]       i_tdata1_1,
    input  logic [63:0]       i_tdata2_1,
    input  logic [63:0]       i_pmpcfg0,
    input  logic [63:0]       i_pmpaddr0,
    input  logic [63:0]       i_pmpaddr1,
    input  logic [63:0]       i_pmpaddr2,
    input  logic [63:0]       i_pmpaddr3,

    // the IQ's two oldest entries, and how many of them are taken
    input  logic              i_iq_valid,
    input  qv_pkg::fe_instr_t i_iq_data,
    input  logic              i_iq1_valid,
    input  qv_pkg::fe_instr_t i_iq1_data,
    output logic              o_iq_pop,
    output logic              o_iq_pop2,

    output logic              o_valid,          // slot 0
    output qv_pkg::uop_t      o_uop,
    output logic              o_valid1,         // slot 1 (only with slot 0)
    output qv_pkg::uop_t      o_uop1,
    input  logic [1:0]        i_issue_n         // 0, 1 (slot 0) or 2 (both) issue this cycle
);
    import qv_pkg::*;

    uop_t b0, b1;                               // the IQ head and the entry behind it, decoded now
    /* verilator lint_off PINCONNECTEMPTY */
    qv_decode #(.FPU_EN(FPU_EN), .CSR_NOSER(CSR_NOSER), .ZICNTR_EN(ZICNTR_EN), .BUILD_ONLY(1'b1)) build0 (
        .clk(clk), .rst(rst), .i_flush(i_flush),
        .i_priv(i_priv), .i_tsr(i_tsr), .i_tvm(i_tvm), .i_fs(i_fs), .i_frm(i_frm),
        .i_mcounteren(i_mcounteren), .i_scounteren(i_scounteren), .i_in_debug(i_in_debug), .i_pb_active(i_pb_active),
        .i_tdata1_0(i_tdata1_0), .i_tdata2_0(i_tdata2_0), .i_tdata1_1(i_tdata1_1), .i_tdata2_1(i_tdata2_1),
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1),
        .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_iq_valid(i_iq_valid), .i_iq_data(i_iq_data), .o_iq_pop(),
        .o_valid(), .o_uop(b0), .i_issue_ready(1'b0)
    );
    qv_decode #(.FPU_EN(FPU_EN), .CSR_NOSER(CSR_NOSER), .ZICNTR_EN(ZICNTR_EN), .BUILD_ONLY(1'b1)) build1 (
        .clk(clk), .rst(rst), .i_flush(i_flush),
        .i_priv(i_priv), .i_tsr(i_tsr), .i_tvm(i_tvm), .i_fs(i_fs), .i_frm(i_frm),
        .i_mcounteren(i_mcounteren), .i_scounteren(i_scounteren), .i_in_debug(i_in_debug), .i_pb_active(i_pb_active),
        .i_tdata1_0(i_tdata1_0), .i_tdata2_0(i_tdata2_0), .i_tdata1_1(i_tdata1_1), .i_tdata2_1(i_tdata2_1),
        .i_pmpcfg0(i_pmpcfg0), .i_pmpaddr0(i_pmpaddr0), .i_pmpaddr1(i_pmpaddr1),
        .i_pmpaddr2(i_pmpaddr2), .i_pmpaddr3(i_pmpaddr3),
        .i_iq_valid(i_iq1_valid), .i_iq_data(i_iq1_data), .o_iq_pop(),
        .o_valid(), .o_uop(b1), .i_issue_ready(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic v0_q, v1_q;
    uop_t u0_q, u1_q;
    assign o_valid  = v0_q;
    assign o_uop    = u0_q;
    assign o_valid1 = v1_q;
    assign o_uop1   = u1_q;

    // what is left after this cycle's issue, moved down
    wire  take0 = (i_issue_n != 2'd0) && v0_q;
    wire  take1 = (i_issue_n == 2'd2) && v1_q;
    wire  r0_v  = take0 ? (v1_q && !take1) : v0_q;      // slot 0 after the issue: slot 1 moved down, or kept
    uop_t r0_u;
    assign r0_u = take0 ? u1_q : u0_q;
    wire  r1_v  = !take0 && v1_q;                        // slot 1 stays only when nothing issued

    // refill in order from the IQ: the head into the first free slot, the entry behind it into the next
    assign o_iq_pop  = i_iq_valid && !r1_v && !i_flush;
    assign o_iq_pop2 = o_iq_pop && !r0_v && i_iq1_valid;

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            v0_q <= 1'b0;
            v1_q <= 1'b0;
        end else begin
            if (r0_v) begin
                v0_q <= 1'b1;
                u0_q <= r0_u;
                v1_q <= r1_v || o_iq_pop;
                if (!r1_v && o_iq_pop) u1_q <= b0;
            end else begin
                v0_q <= o_iq_pop;
                if (o_iq_pop) u0_q <= b0;
                v1_q <= o_iq_pop2;
                if (o_iq_pop2) u1_q <= b1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!rst && !i_flush) begin
        if (i_issue_n == 2'd2 && !(v0_q && v1_q))
            $error("qv_decode2: two issue with fewer held");
        if (i_issue_n == 2'd1 && !v0_q)
            $error("qv_decode2: one issues with none held");
        if (v1_q && !v0_q)
            $error("qv_decode2: slot 1 held without slot 0");
    end
`endif
endmodule
