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
 *
 * (O3) REPAIR > 0: the speculative stack is circular instead (an array, the top's index and a count; a push onto a
 * full one overwrites its oldest entry), which behaves the same at its outputs, and o_snap0/o_snap1 say how op 0, and
 * ops 0 and 1, leave it (qv_pkg::ras_snap_t): each instruction carries its own to the ROB. A recovery at execute
 * (i_restore, with the mispredicted branch's snapshot) puts the index and the count back (REPAIR 1) and the top entry
 * too (REPAIR 2: a wrong path that popped and pushed overwrote it); deeper entries a wrong path overwrote stay
 * overwritten (a later return mispredicts, which is all it costs). A flush still wins, and copies the committed stack
 * in with its top at index 0. REPAIR 0 is the shift stack above, and o_snap* are 0.
 */
module qv_ras #(
    parameter int DEPTH = 8,
    parameter int REPAIR = 0
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
    output logic        o_has1,             // ... and whether there is one

    // (O3, REPAIR > 0) the stack after op 0 and after ops 0 and 1, and a recovery at execute
    output qv_pkg::ras_snap_t o_snap0,
    output qv_pkg::ras_snap_t o_snap1,
    input  logic              i_restore = 1'b0,
    input  qv_pkg::ras_snap_t i_restore_snap = '0
);
    localparam int CNT_W = $clog2(DEPTH + 1);
    localparam int W = DEPTH * 64;

    logic [W-1:0]     s_q, c_q;             // entry 0 in bits [63:0]
    logic [CNT_W-1:0] s_n_q, c_n_q;

    logic [63:0] cr_top;
    logic        cr_has1;
    assign o_top  = (REPAIR > 0) ? cr_top  : s_q[63:0];
    assign o_has1 = (REPAIR > 0) ? cr_has1 : (s_n_q != '0);

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

    // ---------------- (O3) REPAIR > 0: the circular speculative stack ----------------
    localparam int PTR_W = $clog2(DEPTH);
    generate
        if (REPAIR > 0) begin : g_circ
            logic [63:0]      a_q [0:DEPTH-1];
            logic [PTR_W-1:0] p_q;                  // the top's index
            logic [CNT_W-1:0] n_q;
            logic [PTR_W-1:0] p0, p1;
            logic [CNT_W-1:0] n0, n1;
            logic [63:0]      top0, top1;
            wire  [PTR_W-1:0] rs_ptr = PTR_W'(i_restore_snap.ptr);
            // one operation: a push moves the top up (a full stack loses its oldest), a pop down (none on an empty one)
            function automatic logic [PTR_W+CNT_W-1:0] step(input logic [PTR_W-1:0] p, input logic [CNT_W-1:0] n,
                                                            input logic [1:0] op);
                if (op == 2'b01) return {p + PTR_W'(1), n_push(n)};
                if (op == 2'b10 && n != '0) return {p - PTR_W'(1), n - CNT_W'(1)};
                return {p, n};
            endfunction
            always_comb begin
                {p0, n0} = step(p_q, n_q, i_sp_op0);
                {p1, n1} = step(p0, n0, i_sp_op1);
                top0 = (i_sp_op0 == 2'b01) ? i_sp_addr0 : a_q[p0];
                top1 = (i_sp_op1 == 2'b01) ? i_sp_addr1 : ((i_sp_op0 == 2'b01) && (p1 == p0)) ? i_sp_addr0 : a_q[p1];
                o_snap0     = '0;
                o_snap0.ptr = 3'(p0);
                o_snap0.cnt = 4'(n0);
                o_snap0.top = (REPAIR > 1) ? top0 : 64'b0;
                o_snap1     = '0;
                o_snap1.ptr = 3'(p1);
                o_snap1.cnt = 4'(n1);
                o_snap1.top = (REPAIR > 1) ? top1 : 64'b0;
            end
            assign cr_top  = a_q[p_q];
            assign cr_has1 = (n_q != '0);
            always_ff @(posedge clk) begin
                if (rst) begin
                    p_q <= '0; n_q <= '0;
                    for (int i = 0; i < DEPTH; i++) a_q[i] <= 64'b0;
                end else if (i_flush) begin
                    // the committed stack after this cycle's retirement, its entry i at index -i (so index j holds
                    // entry -j); the index on the left is the loop's own (iverilog misplaces a computed one here)
                    for (int j = 0; j < DEPTH; j++) a_q[j] <= c_next[64*((DEPTH - j) % DEPTH) +: 64];
                    p_q <= '0;
                    n_q <= c_next_n;
                end else if (i_restore) begin
                    p_q <= rs_ptr;
                    n_q <= CNT_W'(i_restore_snap.cnt);
                    if (REPAIR > 1) a_q[rs_ptr] <= i_restore_snap.top;
                end else begin
                    if (i_sp_op0 == 2'b01) a_q[p0] <= i_sp_addr0;
                    if (i_sp_op1 == 2'b01) a_q[p1] <= i_sp_addr1;
                    p_q <= p1;
                    n_q <= n1;
                end
            end
        end else begin : g_shift
            assign cr_top  = 64'b0;
            assign cr_has1 = 1'b0;
            assign o_snap0 = '0;
            assign o_snap1 = '0;
        end
    endgenerate
endmodule
