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
 */
module qv_exu_alu (
    input  logic            clk,
    input  logic            rst,
    input  logic            i_flush,
    input  qv_pkg::fu_req_t i_req,
    output qv_pkg::wb_t     o_wb
);
    import qv_pkg::*;

    fu_req_t     req_q;
    logic [63:0] result;

    always_ff @(posedge clk) begin
        if (rst || i_flush) req_q <= '0;
        else                req_q <= i_req;
    end

    alu alu0 (
        .i_operand_A(req_q.a),
        .i_operation(req_q.op),
        .i_operand_B(req_q.b),
        .o_result(result)
    );

    always_comb begin
        o_wb       = '0;
        o_wb.valid = req_q.valid;
        o_wb.tag   = req_q.tag;
        o_wb.value = result;
    end
endmodule
