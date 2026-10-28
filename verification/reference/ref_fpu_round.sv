// SPDX-License-Identifier: MIT

/*
 * ref_fpu_round -- round an exact value to single or double precision and pack it (pure combinational).
 *
 * The value is (-1)^sign * (m / 2^54) * 2^(E - bias): m is a 55-bit significand with its MSB (bit 54) set and sticky
 * stands for any non-zero bits below it; E is the biased exponent it would have unbounded (it may be below 1 or above
 * the maximum). A single uses the top 26 bits of m (24 significand bits and two below), the rest joins the sticky bit.
 * Steps, as in verification/fpu/fpu_model.py's round_pack:
 *  - tininess after rounding (RISC-V): the value is tiny if, rounded to the precision with an unbounded exponent, it is
 *    still below the smallest normal;
 *  - below the normal range (E < 1) the significand is shifted onto the subnormal grid, the shifted-out bits joining
 *    the sticky bit;
 *  - round per rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM) at the LSB, with the next bit as guard; a carry out of the
 *    significand bumps the exponent (a subnormal that rounds up to the smallest normal gets exponent field 1);
 *  - overflow goes to infinity or to the largest finite value, by rm and sign.
 * Flags: NX when anything was rounded away, UF when tiny and inexact, OF (with NX) on overflow. A zero or a special
 * value never comes here. o_res holds a single in its low 32 bits (the caller NaN-boxes it).
 */
module ref_fpu_round (
    input  logic               i_fmt,       // 0 single, 1 double
    input  logic [2:0]         i_rm,
    input  logic               i_sign,
    input  logic signed [13:0] i_exp,
    input  logic [54:0]        i_m,
    input  logic               i_sticky,
    output logic [63:0]        o_res,
    output logic [4:0]         o_flags      // {NV, DZ, OF, UF, NX}; NV and DZ are always 0 here
);
    function automatic logic rup(input logic [2:0] rm, input logic s, input logic lsb, input logic g, input logic st);
        case (rm)
            3'd0:    return g && (st || lsb);
            3'd2:    return s && (g || st);
            3'd3:    return !s && (g || st);
            3'd4:    return g;
            default: return 1'b0;                   // RTZ
        endcase
    endfunction

    always_comb begin : round
        logic [54:0]        v, vs, lostmask;
        logic               st, g_u, st_u, carry_u, tiny, g, st2, up, inexact, ovf, to_inf;
        logic               all1_u;
        logic signed [14:0] e_u, e_field;
        logic [6:0]         k;
        logic [53:0]        sig;                    // p + 1 bits, the carry included
        logic [10:0]        emax;
        k = '0; lostmask = '0;
        // a single: its 26 bits right-aligned in the same container, the rest into the sticky bit
        v  = i_fmt ? i_m : {29'b0, i_m[54:29]};
        st = i_sticky || (!i_fmt && (i_m[28:0] != 29'b0));
        emax = i_fmt ? 11'd2047 : 11'd255;

        // tininess after rounding: unbounded exponent, round at the precision
        g_u     = v[1];
        st_u    = v[0] || st;
        all1_u  = i_fmt ? (v[54:2] == '1) : (v[25:2] == '1);
        carry_u = all1_u && rup(i_rm, i_sign, v[2], g_u, st_u);
        e_u     = 15'(i_exp) + (carry_u ? 15'sd1 : 15'sd0);
        tiny    = e_u < 15'sd1;

        // the subnormal grid
        vs = v;
        if (i_exp < 14'sd1) begin
            k = (i_exp < -14'sd60) ? 7'd61 : 7'(14'sd1 - i_exp);
            if (k >= 7'd55) begin
                st = st || (v != 55'b0);
                vs = '0;
            end else begin
                lostmask = (55'b1 << k) - 55'b1;
                st = st || ((v & lostmask) != 55'b0);
                vs = v >> k;
            end
        end
        g       = vs[1];
        st2     = vs[0] || st;
        up      = rup(i_rm, i_sign, vs[2], g, st2);
        sig     = {1'b0, vs[54:2]} + (up ? 54'd1 : 54'd0);
        inexact = g || st2;

        if (i_exp < 14'sd1) begin
            e_field = (i_fmt ? sig[52] : sig[23]) ? 15'sd1 : 15'sd0;
        end else if (i_fmt ? sig[53] : sig[24]) begin
            sig     = sig >> 1;
            e_field = 15'(i_exp) + 15'sd1;
        end else begin
            e_field = 15'(i_exp);
        end

        ovf    = e_field >= $signed({4'b0, emax});
        to_inf = (i_rm == 3'd0) || (i_rm == 3'd4) || (i_rm == 3'd3 && !i_sign) || (i_rm == 3'd2 && i_sign);
        if (ovf) begin
            if (i_fmt) o_res = to_inf ? {i_sign, 11'h7FF, 52'b0} : {i_sign, 11'h7FE, {52{1'b1}}};
            else       o_res = {32'b0, to_inf ? {i_sign, 8'hFF, 23'b0} : {i_sign, 8'hFE, {23{1'b1}}}};
            o_flags = 5'b00101;                     // OF, NX
        end else begin
            if (i_fmt) o_res = {i_sign, e_field[10:0], sig[51:0]};
            else       o_res = {32'b0, i_sign, e_field[7:0], sig[22:0]};
            o_flags = {2'b00, 1'b0, tiny && inexact, inexact};
        end
    end
endmodule
