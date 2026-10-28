// SPDX-License-Identifier: MIT

/*
 * qv_fpu_divsqrt -- FDIV and FSQRT, one at a time, one result bit per cycle (verification/fpu/fpu_model.py's divide
 * and sqrt, step for step).
 *
 * A request is taken only while idle (o_busy low). PREP unpacks the operands and settles the special cases (NaN,
 * infinity, zero, a negative square root, division by zero), which finish at once. Otherwise 56 restoring steps
 * follow, for either precision: the divide computes floor(ma * 2^55 / mb), the square root the integer root of the
 * significand shifted up to 112 bits (its exponent made even first); the remainder is the sticky bit. FIN normalizes
 * the 56-bit quotient or root (its MSB is bit 54 or 55) to 55 bits and rounds it with qv_fpu_round. The result is
 * then held (o_done) until the caller takes it (i_ack): the FPU's single writeback port prefers the pipeline, and a
 * finished divide waits for a free cycle. i_flush abandons whatever is in progress or held.
 */
module qv_fpu_divsqrt (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_flush,
    // c and ityp do not apply to a divide or a square root
    /* verilator lint_off UNUSEDSIGNAL */
    input  qv_pkg::fpu_req_t i_req,       // valid: a DIV or SQRT; taken only when !o_busy
    /* verilator lint_on UNUSEDSIGNAL */
    output logic             o_busy,      // computing or holding a result
    output logic             o_done,      // o_res is valid; held until i_ack
    output qv_pkg::wb_fp_t   o_res,
    input  logic             i_ack
);
    import qv_pkg::*;

`ifdef QV_FORMAL_FPU_ABSTRACT
    localparam logic [5:0] ITERS = 6'd3;       // formal: the result is free anyway; a short latency keeps proofs shallow
`else
    localparam logic [5:0] ITERS = 6'd56;
`endif

    typedef enum logic [2:0] { S_IDLE, S_PREP, S_ITER, S_FIN, S_DONE } st_e;
    st_e                st_q;
    logic [QV_ROB_TAG_W-1:0] tag_q;
    logic               sqrt_q, fmt_q, s_q;
    logic [2:0]         rm_q;
    logic [63:0]        a_q, b_q;
    logic [5:0]         cnt_q;
    logic [54:0]        rem_q, div_q;     // divide: partial remainder, divisor
    logic [111:0]       rad_q;            // square root: the radicand, two bits leave per step
    logic [59:0]        srem_q;           // square root: the partial remainder
    logic [55:0]        qr_q;             // quotient or root bits
    logic signed [13:0] eacc_q;           // the result is qr * 2^eacc
    logic [63:0]        res_q;
    logic [4:0]         flags_q;

    function automatic logic [63:0] canon(input logic fmt);
        return fmt ? 64'h7FF8_0000_0000_0000 : 64'hFFFF_FFFF_7FC0_0000;
    endfunction
    function automatic logic [63:0] infv(input logic fmt, input logic s);
        return fmt ? {s, 11'h7FF, 52'b0} : {32'hFFFF_FFFF, s, 8'hFF, 23'b0};
    endfunction
    function automatic logic [63:0] zerov(input logic fmt, input logic s);
        return fmt ? {s, 63'b0} : {32'hFFFF_FFFF, s, 31'b0};
    endfunction
    function automatic logic isnan(input logic [2:0] c);
        return c == QV_FPC_QNAN || c == QV_FPC_SNAN;
    endfunction

    // FIN: normalize and round
    wire        hi    = qr_q[55];
    wire [54:0] fin_m = hi ? qr_q[55:1] : qr_q[54:0];
    wire        fin_st = (hi && qr_q[0]) || (sqrt_q ? (srem_q != '0) : (rem_q != '0));
    wire signed [13:0] fin_e = eacc_q + (hi ? 14'sd55 : 14'sd54) + (fmt_q ? 14'sd1023 : 14'sd127);
    logic [63:0] rnd_res;
    logic [4:0]  rnd_flags;
    qv_fpu_round round0 (
        .i_fmt(fmt_q), .i_rm(rm_q), .i_sign(s_q), .i_exp(fin_e), .i_m(fin_m), .i_sticky(fin_st),
        .o_res(rnd_res), .o_flags(rnd_flags)
    );

    always_ff @(posedge clk) begin : fsm
        qv_fp_unp_t ua, ub;
        logic       s;
        logic [53:0] ma;
        logic signed [13:0] qa;
        logic [59:0] t, r2;
        if (rst || i_flush) begin
            st_q <= S_IDLE;
        end else begin
            case (st_q)
                S_IDLE: if (i_req.valid) begin
                    st_q   <= S_PREP;
                    tag_q  <= i_req.tag;
                    sqrt_q <= i_req.op == QV_FP_SQRT;
                    fmt_q  <= i_req.fmt;
                    rm_q   <= i_req.rm;
                    a_q    <= i_req.a;
                    b_q    <= i_req.b;
                end
                S_PREP: begin
                    ua = qv_fp_unpack(fmt_q, qv_fp_unbox(fmt_q, a_q));
                    ub = qv_fp_unpack(fmt_q, qv_fp_unbox(fmt_q, b_q));
                    st_q    <= S_DONE;                       // unless a real division / root follows
                    flags_q <= 5'h00;
                    if (!sqrt_q) begin
                        s = ua.s ^ ub.s;
                        if (isnan(ua.cls) || isnan(ub.cls)) begin
                            res_q   <= canon(fmt_q);
                            flags_q <= (ua.cls == QV_FPC_SNAN || ub.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                        end else if ((ua.cls == QV_FPC_INF && ub.cls == QV_FPC_INF) ||
                                     (ua.cls == QV_FPC_ZERO && ub.cls == QV_FPC_ZERO)) begin
                            res_q <= canon(fmt_q); flags_q <= 5'h10;
                        end else if (ua.cls == QV_FPC_INF || ub.cls == QV_FPC_ZERO) begin
                            res_q   <= infv(fmt_q, s);
                            flags_q <= (ub.cls == QV_FPC_ZERO && ua.cls != QV_FPC_INF) ? 5'h08 : 5'h00;   // DZ
                        end else if (ua.cls == QV_FPC_ZERO || ub.cls == QV_FPC_INF) begin
                            res_q <= zerov(fmt_q, s);
                        end else begin
                            st_q   <= S_ITER;
                            s_q    <= s;
                            rem_q  <= {2'b0, ua.m};
                            div_q  <= {2'b0, ub.m};
                            qr_q   <= '0;
                            cnt_q  <= ITERS;
                            eacc_q <= ua.q - ub.q - 14'sd55;
                        end
                    end else begin
                        if (isnan(ua.cls)) begin
                            res_q <= canon(fmt_q); flags_q <= (ua.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                        end else if (ua.cls == QV_FPC_ZERO) begin
                            res_q <= zerov(fmt_q, ua.s);          // sqrt(-0) = -0
                        end else if (ua.s) begin
                            res_q <= canon(fmt_q); flags_q <= 5'h10;
                        end else if (ua.cls == QV_FPC_INF) begin
                            res_q <= infv(fmt_q, 1'b0);
                        end else begin
                            // an even exponent, then the radicand shifted up by 58: 56 root bits
                            ma = ua.q[0] ? {ua.m, 1'b0} : {1'b0, ua.m};
                            qa = ua.q[0] ? ua.q - 14'sd1 : ua.q;
                            st_q   <= S_ITER;
                            s_q    <= 1'b0;
                            rad_q  <= {ma, 58'b0};
                            srem_q <= '0;
                            qr_q   <= '0;
                            cnt_q  <= ITERS;
                            eacc_q <= (qa - 14'sd58) >>> 1;
                        end
                    end
                end
                S_ITER: begin
                    if (!sqrt_q) begin                       // restoring division: compare, subtract, shift
                        if (rem_q >= div_q) begin
                            rem_q <= (rem_q - div_q) << 1;
                            qr_q  <= {qr_q[54:0], 1'b1};
                        end else begin
                            rem_q <= rem_q << 1;
                            qr_q  <= {qr_q[54:0], 1'b0};
                        end
                    end else begin                           // restoring square root, two radicand bits per step
                        r2 = {srem_q[57:0], rad_q[111:110]};
                        t  = {2'b0, qr_q, 2'b01};
                        if (r2 >= t) begin
                            srem_q <= r2 - t;
                            qr_q   <= {qr_q[54:0], 1'b1};
                        end else begin
                            srem_q <= r2;
                            qr_q   <= {qr_q[54:0], 1'b0};
                        end
                        rad_q <= rad_q << 2;
                    end
                    cnt_q <= cnt_q - 6'd1;
                    if (cnt_q == 6'd1) st_q <= S_FIN;
                end
                S_FIN: begin
                    res_q   <= fmt_q ? rnd_res : {32'hFFFF_FFFF, rnd_res[31:0]};
                    flags_q <= rnd_flags;
                    st_q    <= S_DONE;
                end
                S_DONE: if (i_ack) st_q <= S_IDLE;
                default: st_q <= S_IDLE;
            endcase
        end
    end

    assign o_busy = st_q != S_IDLE;
    assign o_done = st_q == S_DONE;
`ifdef QV_FORMAL_FPU_ABSTRACT
    // formal: the FSM stays (3 steps instead of 56, ITERS above; riscv-formal's liveness and hang assume no divide or
    // square root, as they do for the integer divider), the value and flags are free
    (* anyseq *) logic [63:0] abs_value;
    (* anyseq *) logic [4:0]  abs_flags;
`endif
    always_comb begin
        o_res       = '0;
        o_res.valid = o_done && !i_flush;
        o_res.tag   = tag_q;
`ifdef QV_FORMAL_FPU_ABSTRACT
        o_res.value = abs_value;
        o_res.flags = abs_flags;
`else
        o_res.value = res_q;
        o_res.flags = flags_q;
`endif
    end
endmodule
