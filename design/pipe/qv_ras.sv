// SPDX-License-Identifier: MIT

/*
 * qv_ras -- the return-address stack: where a return is expected to go.
 *
 * Two copies of a small stack of return addresses (the top is entry 0; a full stack drops its oldest entry):
 *
 *   speculative  pushed and popped by the aligner as it emits calls and returns, in fetch order, wrong paths included;
 *                it is what return predictions read
 *   committed    pushed and popped by commit as calls and returns retire, so it only ever holds architectural history
 *
 * Any redirect from commit (a mispredict, a trap, a serializing instruction, an interrupt) throws the speculative
 * stack away and makes it a copy of the committed one as it is after that cycle's retirement: everything older than
 * the redirecting instruction has retired by then, so the copy is exactly right; what the wrong path did to the
 * speculative stack is gone with it. A redirect of the aligner's own (a predicted-taken branch) changes nothing:
 * the instructions before it stay.
 *
 * The aligner emits up to two instructions a cycle, and each can be a call (push its return address) or a return
 * (pop): ops 0 and 1, in program order. Only the top is read: a return that is predicted redirects fetch, so no
 * instruction follows it in the same cycle, and one that is not (an empty stack) has nothing behind it to pop.
 */
module qv_ras #(
    parameter int DEPTH = 8
) (
    input  logic        clk,
    input  logic        rst,

    // the aligner's operations this cycle: none, push, pop (slot 0 first); none when it emitted nothing
    input  logic [1:0]  i_sp_op0,           // 2'b01 push i_sp_addr0, 2'b10 pop
    input  logic [63:0] i_sp_addr0,
    input  logic [1:0]  i_sp_op1,
    input  logic [63:0] i_sp_addr1,

    // commit's operations this cycle
    input  logic        i_cm_push,
    input  logic [63:0] i_cm_addr,
    input  logic        i_cm_pop,

    // a redirect from commit: the speculative stack becomes the committed one
    input  logic        i_flush,

    output logic [63:0] o_top,              // the speculative stack's top
    output logic        o_has1              // ... and whether there is one
);
    localparam int CNT_W = $clog2(DEPTH + 1);
    localparam int W = DEPTH * 64;

    logic [W-1:0]     s_q, c_q;             // entry 0 in bits [63:0]
    logic [CNT_W-1:0] s_n_q, c_n_q;

    assign o_top  = s_q[63:0];
    assign o_has1 = (s_n_q != '0);

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [W-1:0] push(input logic [W-1:0] st, input logic [63:0] a);
        return {st[W-65:0], a};
    endfunction
    function automatic logic [W-1:0] pop(input logic [W-1:0] st);
        return {64'b0, st[W-1:64]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function automatic logic [CNT_W-1:0] n_push(input logic [CNT_W-1:0] n);
        return (n == CNT_W'(DEPTH)) ? n : n + CNT_W'(1);
    endfunction
    function automatic logic [CNT_W-1:0] n_pop(input logic [CNT_W-1:0] n);
        return (n == '0) ? n : n - CNT_W'(1);
    endfunction

    // the committed stack after this cycle's retirement (a retiring instruction is one op: a call or a return)
    logic [W-1:0]     c_next, c_mid;
    logic [CNT_W-1:0] c_next_n, c_mid_n;
    // the speculative stack after the aligner's operations
    logic [W-1:0]     s_mid, s_next;
    logic [CNT_W-1:0] s_mid_n, s_next_n;
    always_comb begin
        c_mid    = i_cm_pop ? pop(c_q) : c_q;
        c_mid_n  = i_cm_pop ? n_pop(c_n_q) : c_n_q;
        c_next   = i_cm_push ? push(c_mid, i_cm_addr) : c_mid;
        c_next_n = i_cm_push ? n_push(c_mid_n) : c_mid_n;

        s_mid    = (i_sp_op0 == 2'b01) ? push(s_q, i_sp_addr0) : (i_sp_op0 == 2'b10) ? pop(s_q) : s_q;
        s_mid_n  = (i_sp_op0 == 2'b01) ? n_push(s_n_q) : (i_sp_op0 == 2'b10) ? n_pop(s_n_q) : s_n_q;
        s_next   = (i_sp_op1 == 2'b01) ? push(s_mid, i_sp_addr1) : (i_sp_op1 == 2'b10) ? pop(s_mid) : s_mid;
        s_next_n = (i_sp_op1 == 2'b01) ? n_push(s_mid_n) : (i_sp_op1 == 2'b10) ? n_pop(s_mid_n) : s_mid_n;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s_q <= '0; s_n_q <= '0;
            c_q <= '0; c_n_q <= '0;
        end else begin
            c_q   <= c_next;
            c_n_q <= c_next_n;
            if (i_flush) begin
                s_q   <= c_next;
                s_n_q <= c_next_n;
            end else begin
                s_q   <= s_next;
                s_n_q <= s_next_n;
            end
        end
    end
endmodule
