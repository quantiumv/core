// SPDX-License-Identifier: MIT

/*
 * ras_props -- a miter for design/pipe/qv_ras.sv (O3): the circular speculative stack (REPAIR 2) against the shift
 * stack it replaced (REPAIR 0), DEPTH 4, under the same free operations (the aligner's two, commit's push and pop, a
 * flush) and no restore. They must agree at the outputs the aligner reads: whether there is a top, and the top when
 * there is one. The induction holds on the stronger fact that every entry the count makes visible is the same in
 * both (entry i of the shift stack is the circular one's index top - i), and the counts are equal; and that the
 * committed stacks, which are the same code in both, are equal.
 * Covers: a full stack that overflows, a flush that copies a non-empty committed stack, two ops in one cycle.
 */
module ras_props (
    input logic        clk,
    input logic        rst,
    input logic [1:0]  op0,
    input logic [63:0] a0,
    input logic [1:0]  op1,
    input logic [63:0] a1,
    input logic        cpush,
    input logic [63:0] ca,
    input logic        cpop,
    input logic        flush
);
    localparam int DEPTH = 4;
    logic [63:0] top_s, top_c;
    logic        has_s, has_c;

    qv_ras #(.DEPTH(DEPTH), .REPAIR(0)) shf (
        .clk(clk), .rst(rst),
        .i_sp_op0(op0), .i_sp_addr0(a0), .i_sp_op1(op1), .i_sp_addr1(a1),
        .i_cm_push(cpush), .i_cm_addr(ca), .i_cm_pop(cpop), .i_flush(flush),
        .o_top(top_s), .o_has1(has_s), .o_snap0(), .o_snap1()
    );
    qv_ras #(.DEPTH(DEPTH), .REPAIR(2)) cir (
        .clk(clk), .rst(rst),
        .i_sp_op0(op0), .i_sp_addr0(a0), .i_sp_op1(op1), .i_sp_addr1(a1),
        .i_cm_push(cpush), .i_cm_addr(ca), .i_cm_pop(cpop), .i_flush(flush),
        .o_top(top_c), .o_has1(has_c), .o_snap0(), .o_snap1()
    );

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @* if (init) assume (rst);
    // the aligner's ops: none, push or pop (2'b11 is never made)
    always @* begin
        assume (op0 != 2'b11);
        assume (op1 != 2'b11);
    end

    always @* if (!rst && !init) begin
        assert (has_c == has_s);
        if (has_s) assert (top_c == top_s);
        // the induction's lemmas
        assert (shf.s_n_q <= 3'd4 && shf.c_n_q <= 3'd4);
        assert (cir.g_circ.n_q == shf.s_n_q);
        assert (cir.c_q == shf.c_q && cir.c_n_q == shf.c_n_q);
        for (int i = 0; i < DEPTH; i++)
            if (i < shf.s_n_q) assert (cir.g_circ.a_q[2'(cir.g_circ.p_q - i)] == shf.s_q[64*i +: 64]);
    end

    always @* if (!rst) begin
        cover (shf.s_n_q == 3'd4 && op0 == 2'b01);
        cover (flush && shf.c_n_q >= 3'd2);
        cover (op0 == 2'b01 && op1 == 2'b10 && has_s);
    end
endmodule
