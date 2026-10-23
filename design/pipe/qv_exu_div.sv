// SPDX-License-Identifier: MIT

/*
 * qv_exu_div -- the divide functional unit: DIV/DIVU/REM/REMU and their W
 * forms, one at a time, on divider.sv (a restoring divider, one quotient bit
 * per cycle).
 *
 * Issue dispatches a fu_req_t (op = {quotient, signed}, is_word for the W
 * forms). The request is registered first, so the operand width extension
 * and the divider's own load-cycle negation stay off issue's bypass paths,
 * and the divider starts from that register the cycle after. o_free is a
 * registered "no divide in flight": issue holds a second divide until the
 * first has written back, since at 66 cycles each there is nothing to gain
 * from overlapping them.
 *
 * The result leaves on a one-cycle writeback pulse in the divider's own
 * done cycle. Operand extension and result extension follow ref_core.sv: the
 * W forms divide the sign- (DIVW/REMW) or zero-extended (DIVUW/REMUW) low
 * halves of the operands and sign-extend the low half of the result.
 *
 * Flush kills the divide. The ROB reuses tags after a flush, so a result for
 * a dead instruction arriving later would complete whatever now owns its
 * tag; nothing here ever holds a result across a cycle, and the pulse is
 * masked in a flush cycle (a flush before the pulse keeps it from ever
 * being raised, via the divider's kill).
 */
module qv_exu_div (
    input  logic            clk,
    input  logic            rst,
    input  logic            i_flush,
    // pc, imm, rvc and pred_next don't apply to a divide
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::fu_req_t i_req,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic            o_free,
    output qv_pkg::wb_t     o_wb
);
    import qv_pkg::*;

    logic                    busy_q;     // from accept through the done cycle
    logic                    pend_q;     // registered request, divider not started yet
    logic [QV_ROB_TAG_W-1:0] tag_q;
    logic [63:0]             a_q, b_q;
    logic                    signed_q, quot_q, word_q;
    logic                    div_done;
    logic [63:0]             quotient, remainder;

    // (a request in a flush cycle never gets this far: the reset-or-flush arm below comes first)
    wire accept = i_req.valid && !busy_q;

    always_ff @(posedge clk) begin
        if (rst || i_flush) begin
            busy_q <= 1'b0;
            pend_q <= 1'b0;
        end else begin
            if (accept) begin
                busy_q   <= 1'b1;
                pend_q   <= 1'b1;
                tag_q    <= i_req.tag;
                a_q      <= i_req.a;
                b_q      <= i_req.b;
                signed_q <= i_req.op[0];
                quot_q   <= i_req.op[1];
                word_q   <= i_req.is_word;
            end else begin
                pend_q <= 1'b0;
            end
            if (div_done) busy_q <= 1'b0;
        end
    end
    assign o_free = !busy_q;

    // W forms: operands from the low 32 bits, sign- or zero-extended
    wire [63:0] dividend = !word_q ? a_q : signed_q ? {{32{a_q[31]}}, a_q[31:0]} : {32'b0, a_q[31:0]};
    wire [63:0] divisor  = !word_q ? b_q : signed_q ? {{32{b_q[31]}}, b_q[31:0]} : {32'b0, b_q[31:0]};

    divider divider0 (
        .i_clk(clk), .i_rst(rst),
        .i_start(pend_q), .i_dividend(dividend), .i_divisor(divisor), .i_signed(signed_q),
        .i_kill(i_flush),
        /* verilator lint_off PINCONNECTEMPTY */
        .o_busy(),
        /* verilator lint_on PINCONNECTEMPTY */
        .o_done(div_done), .o_quotient(quotient), .o_remainder(remainder)
    );

    wire [63:0] raw = quot_q ? quotient : remainder;
    always_comb begin
        o_wb       = '0;
        o_wb.valid = div_done && !i_flush;
        o_wb.tag   = tag_q;
        o_wb.value = word_q ? {{32{raw[31]}}, raw[31:0]} : raw;
    end
endmodule
