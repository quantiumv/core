// SPDX-License-Identifier: MIT

/*
 * gh_props -- (O8a) SymbiYosys properties for the global history of design/pipe/qv_gshare.sv, against a ghost of the
 * instructions in flight.
 *
 * The environment is the core's, reduced to what the history sees. The aligner sends out at most one instruction a
 * cycle into the ghost (D entries, in order): a conditional branch with a free predicted direction and a free real
 * one, or any other instruction (which can also be mispredicted: a jump through a register); each carries the
 * snapshot core.sv gives it (the history from before it, whether it is a conditional, its prediction). Free, every
 * cycle:
 *   - a recovery at execute at any instruction in flight whose prediction is wrong: the history is restored from its
 *     snapshot, everything younger is killed, and its prediction is now its real direction;
 *   - the oldest instruction retires (a conditional trains with its real direction: on the right path only, so an
 *     instruction retires only once it is not mispredicted, as a mispredicted one recovers first or is flushed);
 *   - a flush from commit: everything in flight goes.
 * As in the core, nothing is sent out in a cycle that restores or flushes (the frontend is flushed then).
 *
 * Properties (k-induction):
 *   - the speculative history is the committed one with the predictions of the conditionals in flight shifted in;
 *   - every instruction in flight carries the history of everything older (the committed history and the older
 *     conditionals' predictions), so a conditional retires with the committed history (core.sv's $fatal).
 */
`ifndef GH_H
`define GH_H 3
`endif
module gh_props (
    input logic        clk,
    input logic        rst,
    input logic        push,          // the aligner sends out an instruction
    input logic        push_cond,     // ... a conditional branch
    input logic        push_pred,     // ... predicted this way
    input logic        push_real,     // ... it really goes this way (a conditional), or is mispredicted (another)
    input logic        resolve,       // a recovery at execute ...
    input logic [1:0]  resolve_at,    // ... at this instruction in flight (from the oldest)
    input logic        retire,        // the oldest one retires
    input logic        flush          // a flush from commit
);
    localparam int H = `GH_H;
    localparam int D = 4;

    // the ghost: the instructions in flight, oldest first
    logic         g_v    [0:D-1];
    logic         g_c    [0:D-1];     // a conditional
    logic         g_p    [0:D-1];     // predicted (taken, for a conditional)
    logic         g_r    [0:D-1];     // real direction (a conditional); for another: still mispredicted
    logic [H-1:0] g_h    [0:D-1];     // its snapshot: the history from before it
    logic [2:0]   n = '0;

    logic         s_cond, s_pred, r_cond, r_pred, u_valid, u_taken;
    logic [H-1:0] r_h;
    logic [H-1:0] hist, hist_c;
    logic         init = 1'b1;

    function automatic logic [H-1:0] sh(input logic [H-1:0] h, input logic b);
        logic [H:0] t;
        t = {h, b};
        return t[H-1:0];
    endfunction
    // an instruction is mispredicted: a conditional whose prediction is not its direction, or another one flagged so
    function automatic logic mis(input int i);
        return g_c[i] ? (g_p[i] != g_r[i]) : g_r[i];
    endfunction

    wire        do_resolve = !rst && !init && resolve && (int'(resolve_at) < int'(n)) && mis(int'(resolve_at)) && !flush;
    wire        do_retire  = !rst && !init && retire && (n != 3'd0) && !mis(0) && !flush && !do_resolve;
    // the oldest retires with a flush from commit (a recovery at commit: it may be the mispredicted one; it trains
    // with its real direction, and the flush takes the committed history with that retirement)
    wire        do_retfl   = !rst && !init && retire && (n != 3'd0) && flush;
    wire        do_push    = !rst && !init && push && !flush && !do_resolve && (n - 3'(do_retire) < 3'(D));

    assign s_cond = do_push && push_cond;
    assign s_pred = push_pred;
    assign r_cond = g_c[resolve_at];
    assign r_pred = g_p[resolve_at];
    assign r_h    = g_h[resolve_at];
    assign u_valid = (do_retire || do_retfl) && g_c[0];
    assign u_taken = g_r[0];

    qv_gshare #(.H(H), .BITS(3)) dut (
        .clk(clk), .rst(rst),
        .i_base_pc(64'b0), .i_base1_pc(64'b0), .i_pend_pc(64'b0),
        .o_known(), .o_taken(), .o_known1(), .o_taken1(), .o_pend_known(), .o_pend_taken(), .o_hist(hist),
        .i_cond(s_cond), .i_pred(s_pred),
        .i_flush(flush && !rst), .i_restore(do_resolve), .i_restore_h(r_h), .i_restore_cond(r_cond),
        .i_restore_pred(r_pred),
        .i_upd_valid(u_valid), .i_upd_pc(64'b0), .i_upd_taken(u_taken), .o_hist_c(hist_c)
    );

    // the ghost's next cycle
    always @(posedge clk) begin
        init <= 1'b0;
        if (rst || flush) begin
            n <= '0;
            for (int i = 0; i < D; i++) g_v[i] <= 1'b0;
        end else if (do_resolve) begin
            // everything younger goes; the instruction keeps its place, its prediction now its real direction
            n <= 3'(int'(resolve_at) + 1);
            for (int i = 0; i < D; i++) if (i > int'(resolve_at)) g_v[i] <= 1'b0;
            if (g_c[resolve_at]) g_p[resolve_at] <= g_r[resolve_at];
            else                 g_r[resolve_at] <= 1'b0;
        end else begin
            // retire the oldest (shift down), then push at the end
            if (do_retire) begin
                for (int i = 0; i < D - 1; i++) begin
                    g_v[i] <= g_v[i + 1]; g_c[i] <= g_c[i + 1]; g_p[i] <= g_p[i + 1];
                    g_r[i] <= g_r[i + 1]; g_h[i] <= g_h[i + 1];
                end
                g_v[D - 1] <= 1'b0;
            end
            if (do_push) begin
                g_v[int'(n) - int'(do_retire)] <= 1'b1;
                g_c[int'(n) - int'(do_retire)] <= push_cond;
                g_p[int'(n) - int'(do_retire)] <= push_cond && push_pred;
                g_r[int'(n) - int'(do_retire)] <= push_real;
                g_h[int'(n) - int'(do_retire)] <= hist;          // the history from before it (core.sv's gs_hist0)
            end
            n <= n - 3'(do_retire) + 3'(do_push);
        end
    end

    always @* begin
        if (init) assume (rst);
    end

    // the history the committed one becomes with the conditionals in flight before entry k shifted in
    function automatic logic [H-1:0] fold(input int k);
        logic [H-1:0] h;
        h = hist_c;
        for (int i = 0; i < D; i++) if (i < k && i < int'(n) && g_c[i]) h = sh(h, g_p[i]);
        return h;
    endfunction

    always @* begin
        if (!rst && !init) begin
            assert (n <= 3'(D));
            for (int i = 0; i < D; i++) begin
                assert (g_v[i] == (i < int'(n)));
                if (i < int'(n)) assert (g_h[i] == fold(i));
            end
            assert (hist == fold(int'(n)));
            if (u_valid) assert (g_h[0] == hist_c);
        end
    end

    // non-vacuity
    always @* begin
        if (!rst && !init) begin
            cover (do_resolve && int'(resolve_at) == 1 && n == 3'd3 && g_c[1]);   // a conditional recovers, one younger goes
            cover (do_resolve && !g_c[resolve_at] && n >= 3'd2);                 // a jump recovers
            cover (u_valid && u_taken && n >= 3'd2);                             // a conditional retires, others in flight
            cover (flush && n == 3'd4);                                          // a full ghost flushed
        end
    end
endmodule
