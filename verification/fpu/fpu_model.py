#!/usr/bin/env python3
"""fpu_model.py -- a bit-level model of the FPU's algorithms, the ones design/pipe/qv_fpu_*.sv implements.

It is not a reference (TestFloat and Sail are): it is the RTL's algorithm, written where it is quick to test, and checked
against the same vectors (check_model below) before the RTL is written from it. Widths and steps match the RTL:

- unpack: a value is (sign, class, m, q) with x = m * 2^q, m in [2^52, 2^53) for every finite non-zero value of either
  precision (singles are shifted up by 29 bits, subnormals normalized with a leading-zero count). A single that is not
  NaN-boxed reads as the canonical NaN.
- round: (sign, biased exponent E, a (p+2)-bit significand with its MSB set, sticky) -> packed result and flags, with the
  subnormal shift, the five rounding modes, overflow and tininess after rounding (RISC-V).
- fused multiply-add: the 106-bit product placed at bit 2 of a W-bit window, the addend aligned to it; an addend far above
  puts the product into the sticky bit, one far below goes into the sticky bit (jamming); the sum is normalized with a
  leading-zero count and rounded once. FADD is a*1.0 + b, FMUL has no addend.
- divide and square root: restoring, 1 bit per step, 56 quotient / root bits for both precisions, remainder -> sticky.
- conversions to and from integers, between precisions; compare, min/max, classify, sign injection, the moves.

    python3 fpu_model.py VECFILE [--max N]     # check the model against a gen_vectors.py file
"""
import sys

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
BOX = 0xFFFFFFFF00000000
NX, UF, OF, DZ, NV = 1, 2, 4, 8, 16
W = 164                                   # the FMA window, bits (see fma)

FMT = {  # p (significand bits incl. hidden), exponent bits, bias, canonical NaN
    0: dict(p=24, eb=8, bias=127, nan=0x7FC00000, w=32),
    1: dict(p=53, eb=11, bias=1023, nan=0x7FF8000000000000, w=64),
}
ZERO, SUB, NORM, INF, QNAN, SNAN = range(6)


def clz(v, width):
    n = 0
    for i in range(width - 1, -1, -1):
        if (v >> i) & 1:
            return n
        n += 1
    return width


def unbox(fmt, reg):
    if fmt == 0:
        return reg & M32 if (reg >> 32) == M32 else FMT[0]["nan"]
    return reg & M64


def unpack(fmt, bits):
    """-> (sign, cls, m, q): x = m * 2^q, m in [2^52, 2^53) when finite non-zero."""
    f = FMT[fmt]
    p, eb, bias = f["p"], f["eb"], f["bias"]
    s = (bits >> (p - 1 + eb)) & 1
    e = (bits >> (p - 1)) & ((1 << eb) - 1)
    frac = bits & ((1 << (p - 1)) - 1)
    if e == (1 << eb) - 1:
        if frac == 0:
            return s, INF, 0, 0
        return s, (QNAN if (frac >> (p - 2)) & 1 else SNAN), 0, 0
    if e == 0 and frac == 0:
        return s, ZERO, 0, 0
    if e == 0:
        m, q, cls = frac, 1 - bias - (p - 1), SUB
    else:
        m, q, cls = frac | (1 << (p - 1)), e - bias - (p - 1), NORM
    m <<= 53 - p                          # to the common 53-bit position
    q -= 53 - p
    lz = clz(m, 53)                       # subnormals: normalize
    return s, cls, m << lz, q - lz


def pack(fmt, s, e, frac):
    f = FMT[fmt]
    return (s << (f["p"] - 1 + f["eb"])) | (e << (f["p"] - 1)) | frac


def box_res(fmt, v):
    return (v & M32) | BOX if fmt == 0 else v & M64


def zero(fmt, s):
    return pack(fmt, s, 0, 0)


def inf(fmt, s):
    f = FMT[fmt]
    return pack(fmt, s, (1 << f["eb"]) - 1, 0)


def round_pack(fmt, rm, s, E, m, sticky):
    """m: p+2 bits with m >> (p+1) == 1; value = (m / 2^(p+1)) * 2^(E - bias). -> (bits, flags)."""
    f = FMT[fmt]
    p, emaxf = f["p"], (1 << f["eb"]) - 1

    def rup(lsb, g, st):
        return {0: g and (st or lsb), 1: False, 2: s and (g or st), 3: (not s) and (g or st), 4: g}[rm]

    # tininess after rounding: round at p bits with an unbounded exponent
    g_u, st_u = (m >> 1) & 1, (m & 1) or sticky
    carry_u = ((m >> 2) == (1 << p) - 1) and rup(m & 4, g_u, st_u)
    tiny = (E + (1 if carry_u else 0)) < 1
    if E < 1:                             # the subnormal grid: shift right, jam into sticky
        k = 1 - E
        if k >= p + 2:
            sticky = sticky or m != 0
            m = 0
        else:
            sticky = sticky or (m & ((1 << k) - 1)) != 0
            m >>= k
        E = 0
    g, st = (m >> 1) & 1, (m & 1) or sticky
    sig = (m >> 2) + (1 if rup((m >> 2) & 1, g, st) else 0)
    inexact = bool(g or st)
    if E == 0:                            # subnormal (or rounded up to the smallest normal)
        e_field = 1 if sig >> (p - 1) else 0
    else:
        e_field = E
        if sig >> p:                      # carry out of the significand
            sig >>= 1
            e_field += 1
    flags = (NX if inexact else 0) | (UF if (tiny and inexact) else 0)
    if e_field >= emaxf:                  # overflow
        to_inf = rm in (0, 4) or (rm == 3 and not s) or (rm == 2 and s)
        r = inf(fmt, s) if to_inf else pack(fmt, s, emaxf - 1, (1 << (p - 1)) - 1)
        return r, NX | OF
    return pack(fmt, s, e_field, sig & ((1 << (p - 1)) - 1)), flags


def round_wide(fmt, rm, s, X, qacc):
    """Round the exact non-zero value X * 2^qacc (X a non-negative integer of any width)."""
    f = FMT[fmt]
    p = f["p"]
    msb = X.bit_length() - 1
    sh = msb - (p + 1)                    # keep p+2 bits
    if sh >= 0:
        m, st = X >> sh, (X & ((1 << sh) - 1)) != 0
    else:
        m, st = X << -sh, False
    return round_pack(fmt, rm, s, qacc + msb + f["bias"], m, st)


def nan_result(fmt):
    return FMT[fmt]["nan"]


# --------------------------------------------------------------------------------------------------------------
def fma(fmt, rm, a, b, c, neg_prod, neg_c, has_c=True):
    sa, ca, ma, qa = unpack(fmt, a)
    sb, cb, mb, qb = unpack(fmt, b)
    sc, cc, mc, qc = unpack(fmt, c) if has_c else (0, ZERO, 0, 0)
    sp = sa ^ sb ^ neg_prod
    sc ^= neg_c
    nan = (QNAN, SNAN)
    if ca in nan or cb in nan:
        fl = NV if SNAN in (ca, cb, cc) else 0
        return nan_result(fmt), fl
    if ca == INF or cb == INF:
        other = cb if ca == INF else ca
        if other == ZERO:                 # inf * 0: invalid, even with a quiet-NaN addend
            return nan_result(fmt), NV
        if cc in nan:
            return nan_result(fmt), NV if cc == SNAN else 0
        if cc == INF and sc != sp:
            return nan_result(fmt), NV
        return inf(fmt, sp), 0
    if cc in nan:
        return nan_result(fmt), NV if cc == SNAN else 0
    if cc == INF:
        return inf(fmt, sc), 0
    prod_zero = ca == ZERO or cb == ZERO
    if prod_zero:
        if not has_c:                     # FMUL: the product's own signed zero
            return zero(fmt, sp), 0
        if cc == ZERO:                    # 0 + 0: the IEEE sign rule
            s = sp if sp == sc else (1 if rm == 2 else 0)
            return zero(fmt, s), 0
        return round_wide(fmt, rm, sc, mc, qc)   # exact: c itself
    mp = ma * mb
    qp = qa + qb
    if cc == ZERO:                        # no addend (FMUL, or a zero c)
        return round_wide(fmt, rm, sp, mp, qp)
    d = qc - qp
    P = mp << 2
    sh = d + 2
    if sh > W - 53:                       # addend far above: the product is only sticky
        C, P, qacc = mc << (W - 53), 1, qc - (W - 53)
    elif sh >= 0:
        C, qacc = mc << sh, qp - 2
    else:
        k = -sh
        if k >= 53:
            C = 1
        else:
            C = (mc >> k) | (1 if mc & ((1 << k) - 1) else 0)
        qacc = qp - 2
    if sp == sc:
        X, s = P + C, sp
    else:
        X = P - C
        s = sp
        if X < 0:
            X, s = -X, sc
    if X == 0:
        return zero(fmt, 1 if rm == 2 else 0), 0
    return round_wide(fmt, rm, s, X, qacc)


def divide(fmt, rm, a, b):
    sa, ca, ma, qa = unpack(fmt, a)
    sb, cb, mb, qb = unpack(fmt, b)
    s = sa ^ sb
    if ca in (QNAN, SNAN) or cb in (QNAN, SNAN):
        return nan_result(fmt), NV if SNAN in (ca, cb) else 0
    if (ca == INF and cb == INF) or (ca == ZERO and cb == ZERO):
        return nan_result(fmt), NV
    if ca == INF or cb == ZERO:
        return inf(fmt, s), (DZ if cb == ZERO and ca != INF else 0)
    if ca == ZERO or cb == INF:
        return zero(fmt, s), 0
    # restoring division, 56 quotient bits: Q = floor(ma * 2^55 / mb), the remainder is sticky
    r, qbits = ma, 0
    for _ in range(56):
        if r >= mb:
            r -= mb
            qbits = (qbits << 1) | 1
        else:
            qbits <<= 1
        r <<= 1
    # qbits = floor(ma * 2^56 / mb) / 2 ... the loop compares before shifting: qbits = floor(ma * 2^55 / mb)
    return round_wide_st(fmt, rm, s, qbits, qa - qb - 55, r != 0)


def round_wide_st(fmt, rm, s, X, qacc, st_extra):
    f = FMT[fmt]
    p = f["p"]
    msb = X.bit_length() - 1
    sh = msb - (p + 1)
    m, st = X >> sh, (X & ((1 << sh) - 1)) != 0
    return round_pack(fmt, rm, s, qacc + msb + f["bias"], m, st or st_extra)


def sqrt(fmt, rm, a):
    sa, ca, ma, qa = unpack(fmt, a)
    if ca in (QNAN, SNAN):
        return nan_result(fmt), NV if ca == SNAN else 0
    if ca == ZERO:
        return zero(fmt, sa), 0
    if sa:
        return nan_result(fmt), NV
    if ca == INF:
        return inf(fmt, 0), 0
    if qa & 1:                            # even exponent
        ma, qa = ma << 1, qa - 1
    R = ma << 58                          # 112-bit radicand: 56 root bits
    # restoring square root, 1 bit per step from the top
    root, rem = 0, 0
    for i in range(55, -1, -1):
        rem = (rem << 2) | ((R >> (2 * i)) & 3)
        t = (root << 2) | 1
        if rem >= t:
            rem -= t
            root = (root << 1) | 1
        else:
            root <<= 1
    return round_wide_st(fmt, rm, 0, root, (qa - 58) // 2, rem != 0)


def f2i(fmt, rm, a, ityp):
    """ityp 0 W, 1 WU, 2 L, 3 LU -> (64-bit rd value, flags)."""
    s, cls, m, q = unpack(fmt, a)
    width = 32 if ityp < 2 else 64
    signed = ityp in (0, 2)
    imax = (1 << (width - 1)) - 1 if signed else (1 << width) - 1
    imin = -(1 << (width - 1)) if signed else 0

    def out(v):
        v &= (1 << width) - 1
        if width == 32 and (v >> 31) & 1:
            v |= BOX
        return v & M64

    if cls in (QNAN, SNAN):
        return out(imax), NV
    if cls == INF:
        return out(imin if s else imax), NV
    if cls == ZERO:
        return 0, 0
    if q >= 12:                           # at least 2^64: out of every range
        return out(imin if s else imax), NV
    if q >= 0:
        mag, g, st = m << q, 0, False
    else:
        k = -q
        if k > 54:
            mag, g, st = 0, 0, True
        else:
            mag, g, st = m >> k, (m >> (k - 1)) & 1, (m & ((1 << (k - 1)) - 1)) != 0
    up = {0: g and (st or (mag & 1)), 1: False, 2: s and (g or st), 3: (not s) and (g or st), 4: g}[rm]
    mag += 1 if up else 0
    v = -mag if s else mag
    if v > imax or v < imin:
        return out(imin if s else imax), NV
    return out(v), (NX if (g or st) else 0)


def i2f(fmt, rm, x, ityp):
    if ityp == 0:
        v = x & M32
        v = v - (1 << 32) if v >> 31 else v
    elif ityp == 1:
        v = x & M32
    elif ityp == 2:
        v = x & M64
        v = v - (1 << 64) if v >> 63 else v
    else:
        v = x & M64
    if v == 0:
        return zero(fmt, 0), 0
    s = 1 if v < 0 else 0
    return round_wide(fmt, rm, s, abs(v), 0)


def f2f(to_fmt, rm, a):
    frm_ = 1 - to_fmt
    s, cls, m, q = unpack(frm_, a)
    if cls in (QNAN, SNAN):
        return nan_result(to_fmt), NV if cls == SNAN else 0
    if cls == INF:
        return inf(to_fmt, s), 0
    if cls == ZERO:
        return zero(to_fmt, s), 0
    return round_wide(to_fmt, rm, s, m, q)


def is_nan(c):
    return c in (QNAN, SNAN)


def to_real(s, cls, m, q):
    if cls == ZERO:
        return 0
    from fractions import Fraction
    v = Fraction(m) * (Fraction(2) ** q)
    return -v if s else v


def compare(fmt, a, b, kind):
    """kind 2 FEQ, 1 FLT, 0 FLE."""
    ua, ub = unpack(fmt, a), unpack(fmt, b)
    if is_nan(ua[1]) or is_nan(ub[1]):
        if kind == 2:
            return 0, NV if SNAN in (ua[1], ub[1]) else 0
        return 0, NV
    if ua[1] == INF or ub[1] == INF:
        va = (float("-inf") if ua[0] else float("inf")) if ua[1] == INF else to_real(*ua)
        vb = (float("-inf") if ub[0] else float("inf")) if ub[1] == INF else to_real(*ub)
    else:
        va, vb = to_real(*ua), to_real(*ub)
    r = {2: va == vb, 1: va < vb, 0: va <= vb}[kind]
    return (1 if r else 0), 0


def minmax(fmt, a, b, is_max):
    ua, ub = unpack(fmt, a), unpack(fmt, b)
    fl = NV if SNAN in (ua[1], ub[1]) else 0
    if is_nan(ua[1]) and is_nan(ub[1]):
        return nan_result(fmt), fl
    if is_nan(ua[1]):
        return b, fl
    if is_nan(ub[1]):
        return a, fl
    if ua[1] == ZERO and ub[1] == ZERO:
        if is_max:
            return (a if ua[0] == 0 else b), fl
        return (a if ua[0] == 1 else b), fl
    ca, cb = compare(fmt, a, b, 1)[0], compare(fmt, b, a, 1)[0]   # a < b, b < a
    if is_max:
        return (b if ca else a), fl
    return (a if ca or not cb else b), fl


def classify(fmt, a):
    s, cls, _, _ = unpack(fmt, a)
    bit = {(1, INF): 0, (1, NORM): 1, (1, SUB): 2, (1, ZERO): 3, (0, ZERO): 4, (0, SUB): 5, (0, NORM): 6,
           (0, INF): 7}.get((s, cls))
    if cls == SNAN:
        bit = 8
    if cls == QNAN:
        bit = 9
    return 1 << bit


def sext32(v):
    v &= M32
    return v | BOX if v >> 31 else v


# --------------------------------------------------------------------------------------------------------------
def execute(insn, frm, ra, rb, rc):
    """One instruction on register values -> (rd value, flags). Mirrors qv_fp_dec's decoding."""
    opc = insn & 0x7F
    rm = (insn >> 12) & 7
    rm_eff = frm if rm == 7 else rm
    fmt = (insn >> 25) & 3
    if opc in (0x43, 0x47, 0x4B, 0x4F):
        a, b, c = unbox(fmt, ra), unbox(fmt, rb), unbox(fmt, rc)
        neg_prod = opc in (0x4B, 0x4F)
        neg_c = opc in (0x47, 0x4F)
        r, fl = fma(fmt, rm_eff, a, b, c, neg_prod, neg_c)
        return box_res(fmt, r), fl
    f5 = insn >> 27
    rs2 = (insn >> 20) & 0x1F
    f3 = rm
    a, b = unbox(fmt, ra), unbox(fmt, rb)
    one = pack(fmt, 0, FMT[fmt]["bias"], 0)
    if f5 in (0, 1):                      # FADD / FSUB: a*1.0 + (+-)b
        r, fl = fma(fmt, rm_eff, a, one, b, 0, f5 == 1)
    elif f5 == 2:
        r, fl = fma(fmt, rm_eff, a, b, 0, 0, 0, has_c=False)
    elif f5 == 3:
        r, fl = divide(fmt, rm_eff, a, b)
    elif f5 == 0b01011:
        r, fl = sqrt(fmt, rm_eff, a)
    elif f5 == 0b00100:
        sbit = 31 if fmt == 0 else 63
        sa_, sb_ = (a >> sbit) & 1, (b >> sbit) & 1
        s = {0: sb_, 1: sb_ ^ 1, 2: sa_ ^ sb_}[f3]
        r, fl = (a & ~(1 << sbit)) | (s << sbit), 0
    elif f5 == 0b00101:
        r, fl = minmax(fmt, a, b, f3 == 1)
    elif f5 == 0b01000:                   # FCVT.S.D / FCVT.D.S: the source is the other precision
        r, fl = f2f(fmt, rm_eff, unbox(1 - fmt, ra))
    elif f5 == 0b10100:
        v, fl = compare(fmt, a, b, f3)
        return v, fl
    elif f5 == 0b11000:
        return f2i(fmt, rm_eff, a, rs2)
    elif f5 == 0b11010:
        r, fl = i2f(fmt, rm_eff, ra, rs2)
    elif f5 == 0b11100:
        if f3 == 1:
            return classify(fmt, a), 0
        return (sext32(ra) if fmt == 0 else ra & M64), 0
    elif f5 == 0b11110:
        return box_res(fmt, ra), 0
    else:
        raise ValueError(f"insn {insn:08x}")
    return box_res(fmt, r), fl


def check_model(path, maxn=0):
    bad = n = 0
    for line in open(path):
        f = line.split()
        if len(f) != 7:
            continue
        insn, frm, a, b, c, res, flags = [int(x, 16) for x in f]
        r, fl = execute(insn, frm, a, b, c)
        n += 1
        if r != res or fl != flags:
            bad += 1
            if bad <= 25:
                print(f"MISMATCH {insn:08x} frm={frm} a={a:016x} b={b:016x} c={c:016x} "
                      f"expect={res:016x}/{flags:02x} model={r:016x}/{fl:02x}")
        if maxn and n >= maxn:
            break
    print(f"{n} vectors, {bad} mismatches")
    return bad


if __name__ == "__main__":
    mx = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 0
    sys.exit(1 if check_model(sys.argv[1], mx) else 0)
