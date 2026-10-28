#!/usr/bin/env python3
"""gen_vectors.py -- architectural test vectors for the F/D instructions.

One line per case, all fields hex, space-separated:

    insn frm a b c result flags

- insn: the 32-bit instruction. rd = 4, rs1 = 1, rs2 = 2, rs3 = 3; rd and rs1 are x- or f-registers as the op says.
- frm: the dynamic rounding mode in effect (used when the insn's rm field is 7).
- a, b, c: the 64-bit values of rs1, rs2 and rs3 (an f-register holds a single-precision value NaN-boxed; x1 holds
  an integer source).
- result: the 64-bit value written to rd (boxed for a single-precision result; sign-extended for a 32-bit integer).
- flags: the fflags the instruction raises (NX 1, UF 2, OF 4, DZ 8, NV 16).

Sources:
- TestFloat (~/fp-tools/testfloat, see README.md) for add, sub, mul, div, sqrt, the four FMA forms, eq/lt/le and the
  conversions;
- a golden model here for sign injection, min/max, classify and the moves, which TestFloat does not generate.

Single-precision inputs that are not NaN-boxed read as the canonical NaN. Results never depend on a NaN's payload,
so a TestFloat case whose single-precision operand is a quiet NaN stays correct with that operand replaced by an
unboxed pattern; --unboxed adds such cases.

    python3 gen_vectors.py --level 1 --sample 500 -o smoke.vec
    python3 gen_vectors.py --level 1 --only 'fmadd|fmsub' -o fma.vec
"""
import argparse
import random
import re
import struct
import subprocess
import sys
from pathlib import Path

TESTFLOAT_GEN = Path.home() / "fp-tools" / "testfloat" / "build" / "Linux-x86_64-GCC" / "testfloat_gen"

OP_FP, FMADD, FMSUB, FNMSUB, FNMADD = 0x53, 0x43, 0x47, 0x4B, 0x4F
FMT = {"s": 0, "d": 1}
RM_OPT = ["-rnear_even", "-rminMag", "-rmin", "-rmax", "-rnear_maxMag"]   # rm 0..4: RNE RTZ RDN RUP RMM
BOX = 0xFFFFFFFF00000000
QNAN = {"s": 0x7FC00000, "d": 0x7FF8000000000000}
M32, M64 = (1 << 32) - 1, (1 << 64) - 1
RD, RS1, RS2, RS3 = 4, 1, 2, 3


def enc_r(funct5, fmt, rs2, rm):
    return (((funct5 << 2) | FMT[fmt]) << 25) | (rs2 << 20) | (RS1 << 15) | (rm << 12) | (RD << 7) | OP_FP


def enc_r4(opcode, fmt, rm):
    return (RS3 << 27) | (FMT[fmt] << 25) | (RS2 << 20) | (RS1 << 15) | (rm << 12) | (RD << 7) | opcode


def sext32(v):
    v &= M32
    return v | BOX if v & 0x80000000 else v


def box(fmt, v):
    return (v & M32) | BOX if fmt == "s" else v & M64


# ---------------------------------------------------------------------------------------------------------------
# TestFloat-backed functions. Each entry: name, testfloat function, operand kinds, result kind, encoder, rounds?
# Operand / result kinds: "s"/"d" (float of that precision), "i32"/"u32"/"i64"/"u64" (integer), "b" (0/1 compare).
# The FMA forms negate inputs (Sail and Spike compute FNMADD as mulAdd(-a, b, -c) and so on).
# ---------------------------------------------------------------------------------------------------------------
def _tf_table():
    t = []
    for f in "sd":
        tf = "f32" if f == "s" else "f64"
        for name, f5 in (("fadd", 0), ("fsub", 1), ("fmul", 2), ("fdiv", 3)):
            t.append((f"{name}.{f}", f"{tf}_{name[1:]}", (f, f), f, lambda rm, f=f, f5=f5: enc_r(f5, f, RS2, rm), True, None))
        t.append((f"fsqrt.{f}", f"{tf}_sqrt", (f,), f, lambda rm, f=f: enc_r(0b01011, f, 0, rm), True, None))
        for name, opc, neg in (("fmadd", FMADD, (0, 0)), ("fmsub", FMSUB, (0, 1)),
                               ("fnmsub", FNMSUB, (1, 0)), ("fnmadd", FNMADD, (1, 1))):
            t.append((f"{name}.{f}", f"{tf}_mulAdd", (f, f, f), f, lambda rm, f=f, opc=opc: enc_r4(opc, f, rm), True, neg))
        for name, fn, f3 in (("feq", "eq", 2), ("flt", "lt", 1), ("fle", "le", 0)):
            t.append((f"{name}.{f}", f"{tf}_{fn}", (f, f), "b", lambda rm, f=f, f3=f3: enc_r(0b10100, f, RS2, f3), False, None))
        for ik, sel in (("i32", 0), ("u32", 1), ("i64", 2), ("u64", 3)):
            suf = {"i32": "w", "u32": "wu", "i64": "l", "u64": "lu"}[ik]
            tfi = {"i32": "i32", "u32": "ui32", "i64": "i64", "u64": "ui64"}[ik]
            t.append((f"fcvt.{suf}.{f}", f"{tf}_to_{tfi}", (f,), ik, lambda rm, f=f, sel=sel: enc_r(0b11000, f, sel, rm), True, None))
            t.append((f"fcvt.{f}.{suf}", f"{tfi}_to_{tf}", (ik,), f, lambda rm, f=f, sel=sel: enc_r(0b11010, f, sel, rm), True, None))
    t.append(("fcvt.s.d", "f64_to_f32", ("d",), "s", lambda rm: enc_r(0b01000, "s", 1, rm), True, None))
    t.append(("fcvt.d.s", "f32_to_f64", ("s",), "d", lambda rm: enc_r(0b01000, "d", 0, rm), True, None))
    return t


TF_TABLE = _tf_table()


def operand_reg(kind, v, rng):
    """The register value for a TestFloat operand of this kind."""
    if kind == "s":
        return box("s", v)
    if kind == "d":
        return v & M64
    if kind in ("i32", "u32"):            # a W source uses x1[31:0]: put junk in the upper half
        return (rng.getrandbits(32) << 32) | (v & M32)
    return v & M64


def result_reg(kind, v):
    if kind == "s":
        return box("s", v)
    if kind in ("i32", "u32"):            # 32-bit results are sign-extended, unsigned ones too
        return sext32(v)
    return v & M64


def is_qnan_s(v):
    return (v & 0x7FC00000) == 0x7FC00000


def is_edge(line, rkind):
    """A case at a boundary the rounder handles specially: UF or OF raised, a subnormal or smallest-normal result,
    or an inexact result that is exactly a power of two (a carry out of the significand)."""
    f = line.split()
    res, flags = int(f[-2], 16), int(f[-1], 16)
    if flags & 0x06:
        return True
    if rkind not in ("s", "d"):
        return False
    eb, mb = (8, 23) if rkind == "s" else (11, 52)
    e = (res >> mb) & ((1 << eb) - 1)
    frac = res & ((1 << mb) - 1)
    return e == 0 and frac != 0 or (e == 1 and frac == 0) or (frac == 0 and 0 < e < (1 << eb) - 1 and flags & 1)


def run_testfloat(fn, level, rm, sample, seed, edge=0, rkind=None):
    args = [str(TESTFLOAT_GEN), "-level", str(level), "-seed", str(seed), RM_OPT[rm], "-exact", fn]
    if not sample:                        # every case: stream them (level 2 runs to tens of millions)
        return _stream(args)
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout.split("\n")
    lines = [l for l in out if l.strip()]
    if sample and len(lines) > sample:
        step = len(lines) / sample
        chosen = [lines[int(i * step)] for i in range(sample)]
        if edge:                          # plus up to `edge` boundary cases, spread over the whole output
            edges = [l for l in lines if is_edge(l, rkind)]
            if len(edges) > edge:
                step = len(edges) / edge
                edges = [edges[int(i * step)] for i in range(edge)]
            chosen += edges
        lines = chosen
    return lines


def _stream(args):
    p = subprocess.Popen(args, stdout=subprocess.PIPE, text=True)
    for line in p.stdout:
        if line.strip():
            yield line
    if p.wait() != 0:
        raise subprocess.CalledProcessError(p.returncode, args)


def tf_vectors(entry, level, sample, rng, unboxed, dyn_frac, seed, edge=0, only_rm=None):
    name, fn, kinds, rkind, encoder, rounds, neg = entry
    rms = range(5) if rounds else [0]
    if only_rm is not None:
        rms = [rm for rm in rms if rm == only_rm]
    for rm in rms:
        for line in run_testfloat(fn, level, rm, sample, seed, edge, rkind):
            fields = [int(x, 16) for x in line.split()]
            ops, res, flags = fields[:-2], fields[-2], fields[-1]
            if neg:                       # the FMA forms: flip the signs TestFloat's mulAdd lacks
                sign = 1 << (31 if kinds[0] == "s" else 63)
                if neg[0]:
                    ops[0] ^= sign
                if neg[1]:
                    ops[2] ^= sign
            regs = [operand_reg(k, v, rng) for k, v in zip(kinds, ops)]
            regs += [0] * (3 - len(regs))
            insn_rm, frm = rm, rng.randrange(5)
            if rounds and rng.random() < dyn_frac:
                insn_rm, frm = 7, rm
            insn = encoder(insn_rm)
            yield insn, frm, regs, result_reg(rkind, res), flags
            if unboxed:                   # the same case with each single-precision quiet-NaN operand unboxed
                for i, k in enumerate(kinds):
                    if k == "s" and is_qnan_s(ops[i]):
                        r2 = list(regs)
                        r2[i] = (rng.getrandbits(32) << 32) | rng.getrandbits(32)
                        if (r2[i] >> 32) == M32:
                            r2[i] ^= 1 << 40
                        yield insn, frm, r2, result_reg(rkind, res), flags


# ---------------------------------------------------------------------------------------------------------------
# The golden model for what TestFloat lacks.
# ---------------------------------------------------------------------------------------------------------------
def fields(fmt, v):
    if fmt == "s":
        return (v >> 31) & 1, (v >> 23) & 0xFF, v & 0x7FFFFF, 0xFF, 23
    return (v >> 63) & 1, (v >> 52) & 0x7FF, v & ((1 << 52) - 1), 0x7FF, 52


def unbox(fmt, reg):
    if fmt == "s":
        return reg & M32 if (reg >> 32) == M32 else QNAN["s"]
    return reg & M64


def is_nan(fmt, v):
    _, e, m, emax, _ = fields(fmt, v)
    return e == emax and m != 0


def is_snan(fmt, v):
    _, e, m, emax, mb = fields(fmt, v)
    return e == emax and m != 0 and not (m >> (mb - 1)) & 1


def to_py(fmt, v):
    if fmt == "s":
        return struct.unpack("<f", struct.pack("<I", v))[0]
    return struct.unpack("<d", struct.pack("<Q", v))[0]


def classify(fmt, v):
    s, e, m, emax, mb = fields(fmt, v)
    if e == emax:
        if m == 0:
            return 1 << 0 if s else 1 << 7
        return 1 << 9 if (m >> (mb - 1)) & 1 else 1 << 8
    if e == 0:
        if m == 0:
            return 1 << 3 if s else 1 << 4
        return 1 << 2 if s else 1 << 5
    return 1 << 1 if s else 1 << 6


def g_sgnj(fmt, a, b, kind):
    a, b = unbox(fmt, a), unbox(fmt, b)
    sb = 31 if fmt == "s" else 63
    sa_, sb_ = (a >> sb) & 1, (b >> sb) & 1
    s = sb_ if kind == 0 else (sb_ ^ 1 if kind == 1 else sa_ ^ sb_)
    return box(fmt, (a & ~(1 << sb)) | (s << sb)), 0


def g_minmax(fmt, a, b, is_max):
    a, b = unbox(fmt, a), unbox(fmt, b)
    flags = 16 if is_snan(fmt, a) or is_snan(fmt, b) else 0
    na, nb = is_nan(fmt, a), is_nan(fmt, b)
    if na and nb:
        return box(fmt, QNAN[fmt]), flags
    if na:
        return box(fmt, b), flags
    if nb:
        return box(fmt, a), flags
    sb = 31 if fmt == "s" else 63
    fa, fb = to_py(fmt, a), to_py(fmt, b)
    if fa == fb:                          # equal values: only +0 / -0 can differ
        sa_, sb_ = (a >> sb) & 1, (b >> sb) & 1
        pick_a = (sa_ < sb_) if is_max else (sa_ > sb_)
        return box(fmt, a if pick_a or sa_ == sb_ else b), flags
    pick_a = (fa > fb) if is_max else (fa < fb)
    return box(fmt, a if pick_a else b), flags


SPECIAL = {
    "s": [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000,
          0x7FA00000, 0xFF800001, 0x00000001, 0x80000001, 0x007FFFFF, 0x00800000, 0x7F7FFFFF, 0xFF7FFFFF,
          0x3F800001, 0x4B000000],
    "d": [0, 1 << 63, 0x3FF0000000000000, 0xBFF0000000000000, 0x7FF0000000000000, 0xFFF0000000000000,
          0x7FF8000000000000, 0xFFF8000000000000, 0x7FF4000000000000, 0xFFF0000000000001, 1, (1 << 63) | 1,
          (1 << 52) - 1, 1 << 52, 0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF, 0x3FF0000000000001, 0x4330000000000000],
}


def rand_operand(fmt, rng, allow_unboxed=True):
    r = rng.random()
    if r < 0.45:
        v = rng.choice(SPECIAL[fmt])
    elif r < 0.9:
        v = rng.getrandbits(32 if fmt == "s" else 64)
    else:
        v = rng.choice(SPECIAL[fmt]) ^ rng.getrandbits(3)
    reg = box(fmt, v)
    if fmt == "s" and allow_unboxed and rng.random() < 0.08:
        reg = (rng.getrandbits(32) << 32) | (v & M32)
        if (reg >> 32) == M32:
            reg ^= 1 << 40
    return reg


def golden_vectors(n, rng):
    for _ in range(n):
        fmt = rng.choice("sd")
        a, b = rand_operand(fmt, rng), rand_operand(fmt, rng)
        frm = rng.randrange(5)
        k = rng.randrange(8)
        if k < 3:                         # fsgnj / fsgnjn / fsgnjx
            res, fl = g_sgnj(fmt, a, b, k)
            yield enc_r(0b00100, fmt, RS2, k), frm, [a, b, 0], res, fl
        elif k < 5:                       # fmin / fmax
            res, fl = g_minmax(fmt, a, b, k == 4)
            yield enc_r(0b00101, fmt, RS2, k - 3), frm, [a, b, 0], res, fl
        elif k == 5:                      # fclass
            yield enc_r(0b11100, fmt, 0, 1), frm, [a, 0, 0], classify(fmt, unbox(fmt, a)), 0
        elif k == 6:                      # fmv.x.w / fmv.x.d: no box check
            res = sext32(a) if fmt == "s" else a
            yield enc_r(0b11100, fmt, 0, 0), frm, [a, 0, 0], res, 0
        else:                             # fmv.w.x / fmv.d.x from an integer register
            x = rng.getrandbits(64)
            yield enc_r(0b11110, fmt, 0, 0), frm, [x, 0, 0], box(fmt, x), 0


def special_vectors(rng):
    """Every op crossed with a pool of special operands (zeros, infinities, NaNs, +-1, the smallest subnormal, the
    smallest and largest normal, 1.5), the expected values from fpu_model.py -- check_vectors_sail.py then checks every
    one of them against Sail, which stays the independent reference. Even sampling of TestFloat's output can skip its
    special-value block; this does not."""
    import fpu_model
    pools = {
        "s": [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00000,
              0x00000001, 0x80000001, 0x00800000, 0x7F7FFFFF, 0xFF7FFFFF, 0x3FC00000],
        "d": [0, 1 << 63, 0x3FF0000000000000, 0xBFF0000000000000, 0x7FF0000000000000, 0xFFF0000000000000,
              0x7FF8000000000000, 0x7FF4000000000000, 1, (1 << 63) | 1, 1 << 52, 0x7FEFFFFFFFFFFFFF,
              0xFFEFFFFFFFFFFFFF, 0x3FF8000000000000],
    }
    fma_pool = {f: [p[i] for i in (0, 1, 2, 3, 4, 5, 6, 7, 11)] for f, p in pools.items()}
    ints = [0, 1, M64, 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF80000000, 1 << 63, (1 << 63) - 1, (1 << 53) + 1,
            0xFFFFFFFF, 0x0000000100000001]
    out = []

    def emit(insn, frm, a, b=0, c=0):
        r, fl = fpu_model.execute(insn, frm, a, b, c)
        out.append((insn, frm, [a, b, c], r, fl))

    for f in "sd":
        pool = [box(f, v) for v in pools[f]]
        for f5 in (0, 1, 2, 3):                                     # FADD FSUB FMUL FDIV
            for rm in range(5):
                for a in pool:
                    for b in pool:
                        emit(enc_r(f5, f, RS2, rm), rng.randrange(5), a, b)
        for f5, f3s in ((0b00100, (0, 1, 2)), (0b00101, (0, 1)), (0b10100, (0, 1, 2))):   # FSGNJ*, FMIN/FMAX, FLE/FLT/FEQ
            for f3 in f3s:
                for a in pool:
                    for b in pool:
                        emit(enc_r(f5, f, RS2, f3), 0, a, b)
        for a in pool:
            for rm in range(5):
                emit(enc_r(0b01011, f, 0, rm), 0, a)                # FSQRT
                for sel in range(4):
                    emit(enc_r(0b11000, f, sel, rm), 0, a)          # FCVT to W/WU/L/LU
            emit(enc_r(0b11100, f, 0, 1), 0, a)                     # FCLASS
        other = "d" if f == "s" else "s"
        for a in [box(other, v) for v in pools[other]]:
            for rm in range(5):
                emit(enc_r(0b01000, f, 1 if f == "s" else 0, rm), 0, a)   # FCVT.S.D / FCVT.D.S
        for x in ints:
            for rm in range(5):
                for sel in range(4):
                    emit(enc_r(0b11010, f, sel, rm), 0, x)          # FCVT from W/WU/L/LU
        fpool = [box(f, v) for v in fma_pool[f]]
        for opc in (FMADD, FMSUB, FNMSUB, FNMADD):
            for rm in (0, 2):                                       # RNE, and RDN for the signs of zero sums
                for a in fpool:
                    for b in fpool:
                        for c in fpool:
                            emit(enc_r4(opc, f, rm), 0, a, b, c)
    return out


def jam_vectors(n, rng):
    """FMA cases that only the addend's jammed bits decide (expected values from fpu_model.py; check them against Sail
    like the specials). The addend lies just below the product's window and, in an effective subtraction, its bits
    inside the window cancel the product's bits below the rounding point exactly: the result is inexact (and one ulp
    lower when rounding down) only because of the bits that fall below the window, which the FMA folds into a sticky
    bit. Half the cases have those bits zero (exact). Double precision only: a single's 24-bit significand never
    reaches below the window. In the window the product is mp << 2 (mp = mx * my, 105 or 106 bits); the addend's
    53-bit significand sits k bits below its bottom."""
    import fpu_model
    out = []

    def dbl(s, e, m):
        return (s << 63) | ((e + 1023) << 52) | (m & ((1 << 52) - 1))

    while len(out) < n:
        mx, my = (1 << 52) | rng.getrandbits(52), (1 << 52) | rng.getrandbits(52)
        p = (mx * my) << 2
        r = p.bit_length() - 53                                     # the result's ulp, in window bits
        k = rng.randint(1, 8)
        if (p & ((1 << r) - 1)) >> (53 - k) or not (p >> (52 - k)) & 1:
            continue                                                # the window bits must cancel against the addend
        lost = rng.randrange(1, 1 << k) if len(out) % 2 == 0 else 0
        mz = ((p & ((1 << (53 - k)) - 1)) << k) | lost
        ex, ey = rng.randint(-300, 300), rng.randint(-300, 300)
        sx, sy = rng.getrandbits(1), rng.getrandbits(1)
        opc = rng.choice((FMADD, FMSUB, FNMSUB, FNMADD))
        sz = (sx ^ sy) if opc in (FMSUB, FNMSUB) else 1 - (sx ^ sy)  # an effective subtraction
        a, b, c = dbl(sx, ex, mx), dbl(sy, ey, my), dbl(sz, ex + ey - 54 - k, mz)
        rm = rng.randrange(5)
        insn, frm = (enc_r4(opc, "d", 7), rm) if rng.random() < 0.25 else (enc_r4(opc, "d", rm), rng.randrange(5))
        res, fl = fpu_model.execute(insn, frm, a, b, c)
        assert bool(fl & 1) == bool(lost), (hex(a), hex(b), hex(c), fl)
        out.append((insn, frm, [a, b, c], res, fl))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--level", type=int, default=1, choices=(1, 2))
    ap.add_argument("--sample", type=int, default=0, help="at most this many TestFloat cases per function and rm")
    ap.add_argument("--only", default="", help="regex on the instruction name (e.g. 'fmadd|fdiv')")
    ap.add_argument("--golden", type=int, default=20000, help="golden-model cases (sgnj/min/max/class/moves)")
    ap.add_argument("--unboxed", action="store_true", help="add unboxed variants of quiet-NaN single operands")
    ap.add_argument("--dyn-frac", type=float, default=0.25, help="fraction of rounding cases using rm = dyn")
    ap.add_argument("--specials", action="store_true",
                    help="add every op crossed with a pool of special operands (expected values from fpu_model.py; "
                         "check the file against Sail with check_vectors_sail.py)")
    ap.add_argument("--edge", type=int, default=0,
                    help="with --sample: up to this many more cases per function and rm at the rounder's boundaries "
                         "(UF/OF raised, subnormal or smallest-normal results, a carry into a power of two)")
    ap.add_argument("--jam", type=int, default=0,
                    help="add this many FMA cases decided by the addend's jammed bits (expected values from "
                         "fpu_model.py; check them against Sail with check_vectors_sail.py)")
    ap.add_argument("--rm", type=int, default=None, choices=range(5),
                    help="only this rounding mode (0..4: RNE RTZ RDN RUP RMM) of the TestFloat cases; functions that "
                         "do not round have only rm 0")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-o", "--out", default="-")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    only = re.compile(a.only) if a.only else None
    out = sys.stdout if a.out == "-" else open(a.out, "w")
    n = 0
    for entry in TF_TABLE:
        if only and not only.search(entry[0]):
            continue
        for insn, frm, regs, res, flags in tf_vectors(entry, a.level, a.sample, rng, a.unboxed, a.dyn_frac, a.seed,
                                                      a.edge, a.rm):
            out.write(f"{insn:08x} {frm:x} {regs[0]:016x} {regs[1]:016x} {regs[2]:016x} {res:016x} {flags:02x}\n")
            n += 1
    if not only or only.search("fsgnj|fmin|fmax|fclass|fmv"):
        for insn, frm, regs, res, flags in golden_vectors(a.golden, rng):
            out.write(f"{insn:08x} {frm:x} {regs[0]:016x} {regs[1]:016x} {regs[2]:016x} {res:016x} {flags:02x}\n")
            n += 1
    if a.specials:
        for insn, frm, regs, res, flags in special_vectors(rng):
            out.write(f"{insn:08x} {frm:x} {regs[0]:016x} {regs[1]:016x} {regs[2]:016x} {res:016x} {flags:02x}\n")
            n += 1
    for insn, frm, regs, res, flags in jam_vectors(a.jam, rng):
        out.write(f"{insn:08x} {frm:x} {regs[0]:016x} {regs[1]:016x} {regs[2]:016x} {res:016x} {flags:02x}\n")
        n += 1
    if out is not sys.stdout:
        out.close()
    print(f"{n} vectors", file=sys.stderr)


if __name__ == "__main__":
    main()
