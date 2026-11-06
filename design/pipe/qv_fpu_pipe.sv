// SPDX-License-Identifier: MIT

/*
 * qv_fpu_pipe -- every FPU operation except divide and square root, in a 4-stage pipeline that accepts one per cycle.
 *
 * The algorithms are verification/fpu/fpu_model.py's, step for step (that model is checked against TestFloat and Sail
 * vectors). All ops take the same 4 cycles, from the request register r0 to the writeback, and leave in order:
 *  A (r0 -> r1): unbox and unpack the operands (qv_pkg::qv_fp_unpack); the special cases of the fused multiply-add
 *     (NaN, infinity, zero operands); the 53x53 product and the alignment of the addend against it in a W-bit window
 *     (an addend far above makes the product a sticky bit, one far below becomes one: jamming); the conversions from an
 *     integer and between the precisions set up the same path with their magnitude in place of the product. The ops
 *     that need no rounding (sign injection, min/max, compare, classify, moves) and the conversions to an integer are
 *     finished here and only carried along.
 *  B (r1 -> r2): the sum, or the difference made positive (its sign follows).
 *  C (r2 -> r3): leading-zero count, normalize to a 55-bit significand plus sticky, the biased exponent; an exact zero
 *     sum takes the IEEE sign (-0 only under RDN).
 *  D (r3 -> o_wb): qv_fpu_round; a single result is NaN-boxed.
 * FADD/FSUB are the FMA with b = 1.0 (and the sign of b flipped for FSUB), FMUL has no addend, so its zero product
 * keeps its own sign. i_flush empties the pipeline; the writeback is masked in a flush cycle.
 */
module qv_fpu_pipe (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_flush,
    input  qv_pkg::fpu_req_t i_req,        // valid: an op other than DIV/SQRT, accepted every cycle
    output qv_pkg::wb_fp_t   o_wb
);
    import qv_pkg::*;

    localparam int W = 164;                // the FMA window (see fpu_model.py)

    function automatic logic rup(input logic [2:0] rm, input logic s, input logic lsb, input logic g, input logic st);
        case (rm)
            3'd0:    return g && (st || lsb);
            3'd2:    return s && (g || st);
            3'd3:    return !s && (g || st);
            3'd4:    return g;
            default: return 1'b0;
        endcase
    endfunction

    // a < b for two unboxed non-NaN values of one precision (+0 and -0 are equal)
    function automatic logic flt(input logic fmt, input logic [63:0] a, input logic [63:0] b);
        logic        sa, sb;
        logic [62:0] ma, mb;
        sa = fmt ? a[63] : a[31];
        sb = fmt ? b[63] : b[31];
        ma = fmt ? a[62:0] : {32'b0, a[30:0]};
        mb = fmt ? b[62:0] : {32'b0, b[30:0]};
        if (ma == 63'b0 && mb == 63'b0) return 1'b0;
        if (sa != sb) return sa;
        return sa ? (ma > mb) : (ma < mb);
    endfunction

    function automatic logic feq(input logic fmt, input logic [63:0] a, input logic [63:0] b);
        logic [62:0] ma, mb;
        ma = fmt ? a[62:0] : {32'b0, a[30:0]};
        mb = fmt ? b[62:0] : {32'b0, b[30:0]};
        return (ma == 63'b0 && mb == 63'b0) || (fmt ? (a == b) : (a[31:0] == b[31:0]));
    endfunction

    function automatic logic [63:0] boxv(input logic fmt, input logic [63:0] v);
        return fmt ? v : {32'hFFFF_FFFF, v[31:0]};
    endfunction

    function automatic logic [63:0] canon(input logic fmt);
        return fmt ? 64'h7FF8_0000_0000_0000 : 64'hFFFF_FFFF_7FC0_0000;
    endfunction

    function automatic logic [63:0] infv(input logic fmt, input logic s);
        return fmt ? {s, 11'h7FF, 52'b0} : {32'hFFFF_FFFF, s, 8'hFF, 23'b0};
    endfunction

    function automatic logic [63:0] zerov(input logic fmt, input logic s);
        return fmt ? {s, 63'b0} : {32'hFFFF_FFFF, s, 31'b0};
    endfunction

    function automatic logic [63:0] sext32(input logic [31:0] v);
        return {{32{v[31]}}, v};
    endfunction

    function automatic logic isnan(input logic [2:0] c);
        return c == QV_FPC_QNAN || c == QV_FPC_SNAN;
    endfunction

    // ---------------- r0: the request ----------------
    fpu_req_t r0;
    always_ff @(posedge clk) begin
        if (rst || i_flush) r0 <= '0;
        else                r0 <= i_req;
    end

    // ---------------- stage A ----------------
    logic               a_done;            // finished here (or a special case): a_res/a_flags are the result
    logic [63:0]        a_res;
    logic [4:0]         a_flags;
    logic [W-1:0]       a_p, a_c;          // the two terms in the window
    logic               a_sub, a_sp, a_sc; // effective subtraction; the signs of the product and the addend
    logic signed [13:0] a_qacc;            // the window's LSB weight is 2^qacc

    always_comb begin : stage_a
        logic [63:0]        xa, xb, xc, xx, yy, zz, one;
        qv_fp_unp_t         ux, uy, uz;
        logic [2:0]         ocls;              // the class of the factor that is not infinite
        logic               has_z, neg_prod, neg_c, sp, sc, snan, x_nan, y_nan, z_nan;
        logic [105:0]       mp;
        logic signed [13:0] qp, d, sh;
        logic [13:0]        k;
        logic [52:0]        lost;
        // conversions to an integer
        logic               w32, sgn, g, st, up, inr;
        logic [63:0]        mag, imax, imin, v;
        logic [64:0]        mag2;
        logic [63:0]        ival, imag;
        logic               ineg;

        a_done = 1'b1; a_res = '0; a_flags = '0;
        a_p = '0; a_c = '0; a_sub = 1'b0; a_sp = 1'b0; a_sc = 1'b0; a_qacc = '0;
        // every local has a value on every path (no latches)
        xx = '0; yy = '0; zz = '0; ux = '0; uy = '0; uz = '0; ocls = '0;
        has_z = 1'b0; neg_prod = 1'b0; neg_c = 1'b0; sp = 1'b0; sc = 1'b0; snan = 1'b0;
        x_nan = 1'b0; y_nan = 1'b0; z_nan = 1'b0; mp = '0; qp = '0; d = '0; sh = '0; k = '0; lost = '0;
        w32 = 1'b0; sgn = 1'b0; g = 1'b0; st = 1'b0; up = 1'b0; inr = 1'b0;
        mag = '0; imax = '0; imin = '0; v = '0; mag2 = '0; ival = '0; imag = '0; ineg = 1'b0;

        xa  = qv_fp_unbox(r0.fmt, r0.a);
        xb  = qv_fp_unbox(r0.fmt, r0.b);
        xc  = qv_fp_unbox(r0.fmt, r0.c);
        one = r0.fmt ? 64'h3FF0_0000_0000_0000 : 64'h0000_0000_3F80_0000;

        case (r0.op)
            QV_FP_ADD, QV_FP_SUB, QV_FP_MUL, QV_FP_MADD, QV_FP_MSUB, QV_FP_NMSUB, QV_FP_NMADD: begin
                has_z    = r0.op != QV_FP_MUL;
                xx       = xa;
                yy       = (r0.op == QV_FP_ADD || r0.op == QV_FP_SUB) ? one : xb;
                zz       = (r0.op == QV_FP_ADD || r0.op == QV_FP_SUB) ? xb : xc;
                neg_prod = r0.op == QV_FP_NMSUB || r0.op == QV_FP_NMADD;
                neg_c    = r0.op == QV_FP_MSUB || r0.op == QV_FP_NMADD || r0.op == QV_FP_SUB;
                ux = qv_fp_unpack(r0.fmt, xx);
                uy = qv_fp_unpack(r0.fmt, yy);
                uz = qv_fp_unpack(r0.fmt, zz);
                sp = ux.s ^ uy.s ^ neg_prod;
                sc = uz.s ^ neg_c;
                x_nan = isnan(ux.cls);
                y_nan = isnan(uy.cls);
                z_nan = has_z && isnan(uz.cls);
                snan  = ux.cls == QV_FPC_SNAN || uy.cls == QV_FPC_SNAN || (has_z && uz.cls == QV_FPC_SNAN);
                mp = ux.m * uy.m;
                qp = ux.q + uy.q;
                if (x_nan || y_nan) begin
                    a_res = canon(r0.fmt); a_flags = snan ? 5'h10 : 5'h00;
                end else if (ux.cls == QV_FPC_INF || uy.cls == QV_FPC_INF) begin
                    ocls = (ux.cls == QV_FPC_INF) ? uy.cls : ux.cls;  // the other factor
                    if (ocls == QV_FPC_ZERO) begin                     // inf * 0: invalid, even with a quiet-NaN addend
                        a_res = canon(r0.fmt); a_flags = 5'h10;
                    end else if (z_nan) begin
                        a_res = canon(r0.fmt); a_flags = (uz.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                    end else if (has_z && uz.cls == QV_FPC_INF && sc != sp) begin
                        a_res = canon(r0.fmt); a_flags = 5'h10;
                    end else begin
                        a_res = infv(r0.fmt, sp);
                    end
                end else if (z_nan) begin
                    a_res = canon(r0.fmt); a_flags = (uz.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                end else if (has_z && uz.cls == QV_FPC_INF) begin
                    a_res = infv(r0.fmt, sc);
                end else if (ux.cls == QV_FPC_ZERO || uy.cls == QV_FPC_ZERO) begin
                    if (!has_z)                     a_res = zerov(r0.fmt, sp);
                    else if (uz.cls == QV_FPC_ZERO) a_res = zerov(r0.fmt, (sp == sc) ? sp : (r0.rm == 3'd2));
                    else                            // the addend itself, exactly (with its sign as used)
                        a_res = r0.fmt ? {sc, zz[62:0]} : {32'hFFFF_FFFF, sc, zz[30:0]};
                end else begin
                    a_done = 1'b0;
                    a_sp   = sp;
                    a_sc   = sc;
                    if (!has_z || uz.cls == QV_FPC_ZERO) begin            // no addend
                        a_p    = W'(mp) << 2;
                        a_qacc = qp - 14'sd2;
                    end else begin
                        a_sub = sp != sc;
                        d  = uz.q - qp;
                        sh = d + 14'sd2;
                        if (sh > 14'sd111) begin                          // the addend far above: the product is sticky
                            a_c    = {uz.m, 111'b0};
                            a_p    = W'(1);
                            a_qacc = uz.q - 14'sd111;
                        end else if (sh >= 14'sd0) begin
                            a_c    = W'(uz.m) << sh;
                            a_p    = W'(mp) << 2;
                            a_qacc = qp - 14'sd2;
                        end else begin                                    // the addend below the window: jammed
                            k = 14'(-sh);
                            if (k >= 14'd53) begin
                                a_c = W'(1);
                            end else begin
                                lost = (53'b1 << k) - 53'b1;
                                a_c  = W'(uz.m >> k) | W'((uz.m & lost) != 53'b0);
                            end
                            a_p    = W'(mp) << 2;
                            a_qacc = qp - 14'sd2;
                        end
                    end
                end
            end

            QV_FP_SGNJ, QV_FP_SGNJN, QV_FP_SGNJX: begin
                if (r0.fmt) a_res = {(r0.op == QV_FP_SGNJ) ? xb[63] : (r0.op == QV_FP_SGNJN) ? !xb[63] : (xa[63] ^ xb[63]),
                                     xa[62:0]};
                else        a_res = {32'hFFFF_FFFF,
                                     (r0.op == QV_FP_SGNJ) ? xb[31] : (r0.op == QV_FP_SGNJN) ? !xb[31] : (xa[31] ^ xb[31]),
                                     xa[30:0]};
            end

            QV_FP_MIN, QV_FP_MAX: begin
                ux = qv_fp_unpack(r0.fmt, xa);
                uy = qv_fp_unpack(r0.fmt, xb);
                a_flags = (ux.cls == QV_FPC_SNAN || uy.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                if (isnan(ux.cls) && isnan(uy.cls))                  a_res = canon(r0.fmt);
                else if (isnan(ux.cls))                              a_res = boxv(r0.fmt, xb);
                else if (isnan(uy.cls))                              a_res = boxv(r0.fmt, xa);
                else if (ux.cls == QV_FPC_ZERO && uy.cls == QV_FPC_ZERO)   // +0 / -0
                    a_res = boxv(r0.fmt, (r0.op == QV_FP_MAX) ? (ux.s ? xb : xa) : (ux.s ? xa : xb));
                else if (r0.op == QV_FP_MAX)                         a_res = boxv(r0.fmt, flt(r0.fmt, xa, xb) ? xb : xa);
                else                                                 a_res = boxv(r0.fmt, flt(r0.fmt, xb, xa) ? xb : xa);
            end

            QV_FP_EQ, QV_FP_LT, QV_FP_LE: begin
                ux = qv_fp_unpack(r0.fmt, xa);
                uy = qv_fp_unpack(r0.fmt, xb);
                if (isnan(ux.cls) || isnan(uy.cls)) begin           // FEQ is quiet, FLT/FLE signal on any NaN
                    a_res   = '0;
                    a_flags = (r0.op != QV_FP_EQ || ux.cls == QV_FPC_SNAN || uy.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                end else begin
                    a_res = {63'b0, (r0.op == QV_FP_EQ) ? feq(r0.fmt, xa, xb) :
                                    (r0.op == QV_FP_LT) ? flt(r0.fmt, xa, xb) :
                                                          (flt(r0.fmt, xa, xb) || feq(r0.fmt, xa, xb))};
                end
            end

            QV_FP_CLASS: begin
                ux = qv_fp_unpack(r0.fmt, xa);
                case (ux.cls)
                    QV_FPC_INF:  a_res = ux.s ? 64'h001 : 64'h080;
                    QV_FPC_NORM: a_res = ux.s ? 64'h002 : 64'h040;
                    QV_FPC_SUB:  a_res = ux.s ? 64'h004 : 64'h020;
                    QV_FPC_ZERO: a_res = ux.s ? 64'h008 : 64'h010;
                    QV_FPC_SNAN: a_res = 64'h100;
                    default:     a_res = 64'h200;
                endcase
            end

            QV_FP_MV_XF: a_res = r0.fmt ? r0.a : sext32(r0.a[31:0]);   // the raw register bits, no box check
            QV_FP_MV_FX: a_res = boxv(r0.fmt, r0.a);

            QV_FP_F2I: begin
                ux   = qv_fp_unpack(r0.fmt, xa);
                w32  = !r0.ityp[1];
                sgn  = !r0.ityp[0];
                imax = w32 ? (sgn ? 64'h0000_0000_7FFF_FFFF : 64'hFFFF_FFFF_FFFF_FFFF)
                           : (sgn ? 64'h7FFF_FFFF_FFFF_FFFF : 64'hFFFF_FFFF_FFFF_FFFF);
                imin = w32 ? (sgn ? 64'hFFFF_FFFF_8000_0000 : 64'h0) : (sgn ? 64'h8000_0000_0000_0000 : 64'h0);
                mag = '0; g = 1'b0; st = 1'b0;
                if (isnan(ux.cls)) begin
                    a_res = imax; a_flags = 5'h10;
                end else if (ux.cls == QV_FPC_INF || ux.q >= 14'sd12) begin       // at least 2^64
                    a_res = ux.s ? imin : imax; a_flags = 5'h10;
                end else if (ux.cls == QV_FPC_ZERO) begin
                    a_res = '0;
                end else begin
                    if (ux.q >= 14'sd0) begin
                        mag = 64'(ux.m) << ux.q;
                    end else begin
                        k = 14'(-ux.q);
                        if (k > 14'd54) begin
                            st = 1'b1;
                        end else begin
                            mag  = 64'(ux.m >> k);
                            g    = ((ux.m >> (k - 14'd1)) & 53'b1) != 53'b0;
                            lost = (53'b1 << (k - 14'd1)) - 53'b1;
                            st   = (ux.m & lost) != 53'b0;
                        end
                    end
                    up   = rup(r0.rm, ux.s, mag[0], g, st);
                    mag2 = {1'b0, mag} + (up ? 65'd1 : 65'd0);
                    if (w32) inr = ux.s ? (sgn ? (mag2 <= 65'h0_8000_0000) : (mag2 == 65'd0))
                                        : (mag2 <= (sgn ? 65'h0_7FFF_FFFF : 65'h0_FFFF_FFFF));
                    else     inr = ux.s ? (sgn ? (mag2 <= 65'h0_8000_0000_0000_0000) : (mag2 == 65'd0))
                                        : (sgn ? (mag2 <= 65'h0_7FFF_FFFF_FFFF_FFFF) : !mag2[64]);
                    if (!inr) begin
                        a_res = ux.s ? imin : imax; a_flags = 5'h10;
                    end else begin
                        v       = ux.s ? (64'd0 - mag2[63:0]) : mag2[63:0];
                        a_res   = w32 ? sext32(v[31:0]) : v;
                        a_flags = (g || st) ? 5'h01 : 5'h00;
                    end
                end
            end

            QV_FP_I2F: begin
                // the integer source: W sign-extends rs1[31:0], WU zero-extends it; L/LU use all 64 bits
                ival = (r0.ityp == 2'd0) ? sext32(r0.a[31:0]) : (r0.ityp == 2'd1) ? {32'b0, r0.a[31:0]} : r0.a;
                ineg = !r0.ityp[0] && ival[63];
                // the magnitude in a 64-bit variable first: inside a W-bit cast the subtraction would be W bits wide
                imag = ineg ? (64'd0 - ival) : ival;
                if (ival == 64'b0) begin
                    a_res = zerov(r0.fmt, 1'b0);
                end else begin
                    a_done = 1'b0;
                    a_sp   = ineg;
                    a_p    = W'(imag);
                    a_qacc = 14'sd0;
                end
            end

            QV_FP_F2F: begin                                        // the source is the other precision
                ux = qv_fp_unpack(!r0.fmt, qv_fp_unbox(!r0.fmt, r0.a));
                if (isnan(ux.cls)) begin
                    a_res = canon(r0.fmt); a_flags = (ux.cls == QV_FPC_SNAN) ? 5'h10 : 5'h00;
                end else if (ux.cls == QV_FPC_INF) begin
                    a_res = infv(r0.fmt, ux.s);
                end else if (ux.cls == QV_FPC_ZERO) begin
                    a_res = zerov(r0.fmt, ux.s);
                end else begin
                    a_done = 1'b0;
                    a_sp   = ux.s;
                    a_p    = W'(ux.m);
                    a_qacc = ux.q;
                end
            end

            default: ;                                              // DIV/SQRT never come here
        endcase
    end

    // ---------------- r1 / stage B: the sum ----------------
    logic               r1_valid, r1_fmt, r1_done, r1_sub, r1_sp, r1_sc;
    logic [QV_ROB_TAG_W-1:0] r1_tag;
    logic [2:0]         r1_rm;
    logic [63:0]        r1_res;
    logic [4:0]         r1_flags;
    logic [W-1:0]       r1_p, r1_c;
    logic signed [13:0] r1_qacc;
    always_ff @(posedge clk) begin
        if (rst || i_flush) r1_valid <= 1'b0;
        else                r1_valid <= r0.valid;
        r1_tag <= r0.tag; r1_fmt <= r0.fmt; r1_rm <= r0.rm;
        r1_done <= a_done; r1_res <= a_res; r1_flags <= a_flags;
        r1_p <= a_p; r1_c <= a_c; r1_sub <= a_sub; r1_sp <= a_sp; r1_sc <= a_sc; r1_qacc <= a_qacc;
    end

    logic [W:0] b_x;
    logic       b_s;
    always_comb begin : stage_b
        b_x = r1_sub ? ({1'b0, r1_p} - {1'b0, r1_c}) : ({1'b0, r1_p} + {1'b0, r1_c});
        b_s = r1_sp;
        if (r1_sub && b_x[W]) begin
            b_x = ({(W+1){1'b0}} - b_x);
            b_s = r1_sc;
        end
    end

    // ---------------- r2 / stage C: normalize ----------------
    logic               r2_valid, r2_fmt, r2_done, r2_s;
    logic [QV_ROB_TAG_W-1:0] r2_tag;
    logic [2:0]         r2_rm;
    logic [63:0]        r2_res;
    logic [4:0]         r2_flags;
    logic [W:0]         r2_x;
    logic signed [13:0] r2_qacc;
    always_ff @(posedge clk) begin
        if (rst || i_flush) r2_valid <= 1'b0;
        else                r2_valid <= r1_valid;
        r2_tag <= r1_tag; r2_fmt <= r1_fmt; r2_rm <= r1_rm;
        r2_done <= r1_done; r2_res <= r1_res; r2_flags <= r1_flags;
        r2_x <= b_x; r2_s <= b_s; r2_qacc <= r1_qacc;
    end

    logic               c_done;
    logic [63:0]        c_res;
    logic [54:0]        c_m;
    logic               c_st;
    logic signed [13:0] c_e;
    always_comb begin : stage_c
        int         lz;
        logic [W:0] xn;
        c_done = r2_done;
        c_res  = r2_res;
        lz = W + 1;
        for (int i = 0; i <= W; i++)
            if (r2_x[i]) lz = W - i;
        xn   = r2_x << lz;
        c_m  = xn[W:W-54];
        c_st = xn[W-55:0] != '0;
        c_e  = r2_qacc + 14'(W - lz) + (r2_fmt ? 14'sd1023 : 14'sd127);
        if (!r2_done && r2_x == '0) begin                  // an exact zero sum: +0, or -0 under RDN
            c_done = 1'b1;
            c_res  = zerov(r2_fmt, r2_rm == 3'd2);
        end
    end

    // ---------------- r3 / stage D: round ----------------
    logic               r3_valid, r3_fmt, r3_done, r3_s, r3_st;
    logic [QV_ROB_TAG_W-1:0] r3_tag;
    logic [2:0]         r3_rm;
    logic [63:0]        r3_res;
    logic [4:0]         r3_flags;
    logic [54:0]        r3_m;
    logic signed [13:0] r3_e;
    always_ff @(posedge clk) begin
        if (rst || i_flush) r3_valid <= 1'b0;
        else                r3_valid <= r2_valid;
        r3_tag <= r2_tag; r3_fmt <= r2_fmt; r3_rm <= r2_rm;
        r3_done <= c_done; r3_res <= c_res; r3_flags <= r2_flags;
        r3_s <= r2_s; r3_m <= c_m; r3_st <= c_st; r3_e <= c_e;
    end

    logic [63:0] d_res;
    logic [4:0]  d_flags;
    qv_fpu_round round0 (
        .i_fmt(r3_fmt), .i_rm(r3_rm), .i_sign(r3_s), .i_exp(r3_e), .i_m(r3_m), .i_sticky(r3_st),
        .o_res(d_res), .o_flags(d_flags)
    );

`ifdef QV_FORMAL_FPU_ABSTRACT
    // formal: the control above stays, the value and flags are free (the datapath then drives nothing and is removed)
    (* anyseq *) logic [63:0] abs_value;
    (* anyseq *) logic [4:0]  abs_flags;
`endif
    always_comb begin
        o_wb       = '0;
        o_wb.valid = r3_valid && !i_flush;
        o_wb.tag   = r3_tag;
`ifdef QV_FORMAL_FPU_ABSTRACT
        o_wb.value = abs_value;
        o_wb.flags = abs_flags;
`else
        o_wb.value = r3_done ? r3_res : boxv(r3_fmt, d_res);
        o_wb.flags = r3_done ? r3_flags : d_flags;
`endif
    end
endmodule
