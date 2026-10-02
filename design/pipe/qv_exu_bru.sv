// SPDX-License-Identifier: MIT

/*
 * qv_exu_bru -- the branch unit: conditional branches, JAL and JALR.
 *
 * Same shape and latency as qv_exu_alu (one register on entry, result on
 * the writeback bus the next cycle), so issue never sees the two units'
 * results collide.
 *
 * Operands follow decoder.sv's layout: a = rs1 (or the J offset for JAL,
 * unused), b = rs2 for branches or the I offset for JALR, imm = the B or
 * J offset. Targets match core.sv's next_pc: pc + offset for branches and
 * JAL, (rs1 + offset) with bit 0 cleared for JALR. The writeback value is
 * the link (pc + instruction length); branches don't write rd, so it's
 * ignored for them.
 *
 * The frontend always predicts fall-through so far, so mispredict means
 * the resolved next pc isn't pc + length. A taken branch whose target
 * happens to be the next instruction is therefore not a mispredict.
 */
module qv_exu_bru (
    input  logic            clk,
    input  logic            rst,
    input  logic            i_flush,
    input  qv_pkg::fu_req_t i_req,
    output qv_pkg::wb_t     o_wb
);
    import qv_pkg::*;

    // only the low 3 bits of op carry a qv_bru_op_e; is_word is ALU-only
    /* verilator lint_off UNUSEDSIGNAL */
    fu_req_t req_q;
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (rst || i_flush) req_q <= '0;
        else                req_q <= i_req;
    end

    qv_bru_op_e op;
    assign op = qv_bru_op_e'(req_q.op[2:0]);

    logic taken;
    always_comb begin
        case (op)
            QV_BR_BEQ:  taken = (req_q.a == req_q.b);
            QV_BR_BNE:  taken = (req_q.a != req_q.b);
            QV_BR_BLT:  taken = ($signed(req_q.a) <  $signed(req_q.b));
            QV_BR_BGE:  taken = ($signed(req_q.a) >= $signed(req_q.b));
            QV_BR_BLTU: taken = (req_q.a <  req_q.b);
            QV_BR_BGEU: taken = (req_q.a >= req_q.b);
            default:    taken = 1'b1;   // JAL, JALR
        endcase
    end

    wire [63:0] jalr_target = (req_q.a + req_q.b) & ~64'd1;
    wire [63:0] target      = (op == QV_BR_JALR) ? jalr_target : req_q.pc + req_q.imm;
    wire [63:0] fallthrough = req_q.pc + (req_q.rvc ? 64'd2 : 64'd4);
    wire [63:0] next_pc     = taken ? target : fallthrough;

    always_comb begin
        o_wb            = '0;
        o_wb.valid      = req_q.valid;
        o_wb.tag        = req_q.tag;
        o_wb.value      = fallthrough;
        o_wb.next_pc    = next_pc;
        o_wb.mispredict = req_q.valid && (next_pc != fallthrough);
    end
endmodule
