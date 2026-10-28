// SPDX-License-Identifier: MIT

// ref_fpu_pkg -- the F/D section of design/pipe/qv_pkg.sv, renamed (made by gen_copies.sh: do not edit).
package ref_fpu_pkg;
    localparam int QV_ROB_TAG_W = 4;           // qv_pkg's tag width (ROB of 8: index + wrap bit)
    // ---- F/D section begin: from here to the end marker, verification/reference/gen_copies.sh copies these lines into
    // ref_fpu_pkg.sv for the reference's FPU (keep them self-contained: they may use QV_ROB_TAG_W only) ----

    // F/D: what the FPU does (fpu_req_t.op). The precision is fmt (0 single, 1 double: for the conversions between
    // the two, the destination's), the integer type of a conversion ityp (0 W, 1 WU, 2 L, 3 LU: FCVT's rs2 field).
    // FADD/FSUB/FMUL are the FMA with b = 1.0 or no addend (qv_fpu_pipe.sv); DIV and SQRT run in qv_fpu_divsqrt.sv.
    typedef enum logic [4:0] {
        QV_FP_ADD,
        QV_FP_SUB,
        QV_FP_MUL,
        QV_FP_MADD,
        QV_FP_MSUB,
        QV_FP_NMSUB,
        QV_FP_NMADD,
        QV_FP_DIV,
        QV_FP_SQRT,
        QV_FP_SGNJ,
        QV_FP_SGNJN,
        QV_FP_SGNJX,
        QV_FP_MIN,
        QV_FP_MAX,
        QV_FP_EQ,
        QV_FP_LT,
        QV_FP_LE,
        QV_FP_CLASS,
        QV_FP_MV_XF,               // FMV.X.W / FMV.X.D: the register bits to an integer register
        QV_FP_MV_FX,               // FMV.W.X / FMV.D.X: the other way (a single is NaN-boxed)
        QV_FP_F2I,                 // FCVT.{W,WU,L,LU}.{S,D}
        QV_FP_I2F,                 // FCVT.{S,D}.{W,WU,L,LU}
        QV_FP_F2F                  // FCVT.S.D / FCVT.D.S
    } qv_fp_op_e;

    // Issue -> FPU. a, b, c are register values (rs1 an integer for MV_FX and I2F; singles NaN-boxed), rm the
    // rounding mode resolved at decode (frm already substituted for rm = 7).
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        qv_fp_op_e               op;
        logic                    fmt;
        logic [1:0]              ityp;
        logic [2:0]              rm;
        logic [63:0]             a;
        logic [63:0]             b;
        logic [63:0]             c;
    } fpu_req_t;

    // FPU -> ROB and bypass: the rd value (NaN-boxed for a single result; an integer result sign- or zero-extended
    // to 64 bits as the instruction defines) and the exception flags it raises (NX 1, UF 2, OF 4, DZ 8, NV 16).
    typedef struct packed {
        logic                    valid;
        logic [QV_ROB_TAG_W-1:0] tag;
        logic [63:0]             value;
        logic [4:0]              flags;
    } wb_fp_t;

    // An unpacked FP value, either precision: value = (-1)^s * m * 2^q, with m's MSB (bit 52) set for every finite
    // non-zero value (a single is shifted up by 29 bits, a subnormal normalized). The FPU's datapaths work on this.
    localparam logic [2:0] QV_FPC_ZERO = 3'd0;
    localparam logic [2:0] QV_FPC_SUB  = 3'd1;
    localparam logic [2:0] QV_FPC_NORM = 3'd2;
    localparam logic [2:0] QV_FPC_INF  = 3'd3;
    localparam logic [2:0] QV_FPC_QNAN = 3'd4;
    localparam logic [2:0] QV_FPC_SNAN = 3'd5;
    typedef struct packed {
        logic               s;
        logic [2:0]         cls;
        logic [52:0]        m;
        logic signed [13:0] q;
    } qv_fp_unp_t;

    // A single that is not NaN-boxed (upper 32 bits not all ones) reads as the canonical NaN.
    function automatic logic [63:0] qv_fp_unbox(input logic fmt, input logic [63:0] r);
        if (fmt) return r;
        return {32'b0, (r[63:32] == 32'hFFFF_FFFF) ? r[31:0] : 32'h7FC0_0000};
    endfunction

    // bits: an unboxed value (a single in the low 32 bits)
    function automatic qv_fp_unp_t qv_fp_unpack(input logic fmt, input logic [63:0] bits);
        qv_fp_unp_t         u;
        logic [10:0]        e;
        logic [51:0]        frac;
        logic               emax, ezero, fzero, quiet;
        logic [52:0]        m;
        logic signed [13:0] q;
        int                 lz;
        if (fmt) begin
            u.s = bits[63]; e = bits[62:52]; frac = bits[51:0];
            emax = (e == 11'h7FF); ezero = (e == 11'h000);
        end else begin
            u.s = bits[31]; e = {3'b0, bits[30:23]}; frac = {bits[22:0], 29'b0};
            emax = (e[7:0] == 8'hFF); ezero = (e[7:0] == 8'h00);
        end
        fzero = (frac == 52'b0);
        quiet = frac[51];
        u.m = '0;
        u.q = '0;
        if (emax)             u.cls = fzero ? QV_FPC_INF : (quiet ? QV_FPC_QNAN : QV_FPC_SNAN);
        else if (ezero && fzero) u.cls = QV_FPC_ZERO;
        else begin
            u.cls = ezero ? QV_FPC_SUB : QV_FPC_NORM;
            m = {!ezero, frac};                      // a single's 23 fraction bits are already at the top
            // q = E - bias - 52 (doubles) or E - bias - 23 - 29 (singles: shifted up by 29), E = 1 for a subnormal
            q = fmt ? (14'(ezero ? 11'd1 : e) - 14'sd1075) : (14'(ezero ? 11'd1 : e) - 14'sd179);
            lz = 53;
            for (int i = 0; i <= 52; i++)               // the highest set bit wins
                if (m[i]) lz = 52 - i;
            u.m = m << lz;
            u.q = q - 14'(lz);
        end
        return u;
    endfunction

    // ---- F/D section end ----
endpackage
