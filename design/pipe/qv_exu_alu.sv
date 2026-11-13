// SPDX-License-Identifier: MIT

/*
 * qv_exu_alu -- the ALU functional unit.
 *
 * One register on entry (the I/X boundary): issue dispatches a fu_req_t,
 * this latches it, and alu.sv (reused unmodified, purely combinational)
 * computes during the next cycle. The writeback is combinational from
 * that register, so a result is on the writeback bus exactly one cycle
 * after issue -- in time for a dependent instruction issuing that same
 * cycle to take it through issue's bypass (zero-cycle stall), or, with
 * bypass disabled, for the ROB to capture it at the end of the cycle
 * (one-cycle stall).
 *
 * HAS_MUL 0 (O4d): a second ALU port's, without the multipliers. Issue sends it no multiply and no branch (R6 of
 * the O4 plan): those go to port 0.
 */
module qv_exu_alu #(
    parameter bit HAS_MUL = 1'b1
) (
    input  logic            clk,
    input  logic            rst,
    input  logic            i_flush,
    input  qv_pkg::fu_req_t i_req,
    input  logic [(1<<qv_pkg::QV_ROB_TAG_W)-1:0] i_kill_vec = '0,   // (O3) tags killed by a recovery at execute
    output qv_pkg::wb_t     o_wb
);
    import qv_pkg::*;

    // pc/imm/rvc are for the BRU
    /* verilator lint_off UNUSEDSIGNAL */
    fu_req_t     req_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0] result;

    always_ff @(posedge clk) begin
        if (rst || i_flush) req_q <= '0;
        else                req_q <= i_req;
    end

    alu #(.HAS_MUL(HAS_MUL)) alu0 (
        .i_operand_A(req_q.a),
        .i_operation(req_q.op),
        .i_operand_B(req_q.b),
        .o_result(result)
    );

    always_comb begin
        o_wb       = '0;
        o_wb.valid = req_q.valid && !i_kill_vec[req_q.tag];     // (O3) a killed op writes nothing back
        o_wb.tag   = req_q.tag;
        o_wb.value = req_q.is_word ? {{32{result[31]}}, result[31:0]} : result;
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (!rst && !HAS_MUL && req_q.valid && qv_is_mul(req_q.op))
            $error("qv_exu_alu: a multiply on a port without a multiplier");
`endif
endmodule
