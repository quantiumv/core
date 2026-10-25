#!/usr/bin/env python3
"""brpred.py -- what would a branch predictor buy on the perf kernels? (P9c)

Reads the control-flow traces perf_tb writes under +BRTRACE ("BR pc raw next_pc", hex, one line per
control-flow instruction retired inside a kernel's window) and replays them through candidate predictors:

  static     the core's own: JAL/C.J taken, conditional branches taken when backward, JALR never predicted
  bht        + a table of 2-bit counters indexed by pc[k:1] for conditional branches (an untrained entry
             uses the static rule)
  ras        + a return-address stack for JALR returns (calls: JAL/JALR with rd x1/x5; returns: JALR with
             rd x0 and rs1 x1/x5)
  btb        + a direct-mapped target buffer: a taken branch/jump found in it costs no fetch bubble

Cost model (cycles, measured on the core): a mispredict that commit redirects on costs MISP (the refill,
about 8 from the branch's issue to the first new instruction's commit); a predicted-taken branch that the
aligner redirects on costs BUBBLE (the request for the next sequential dword is already out); a taken
branch the BTB knows costs ZERO. The estimate is the sum over the trace.

  brpred.py /tmp/br_qsort.txt ...        per-kernel table
"""
import sys
from collections import OrderedDict

MISP = 8
BUBBLE = 3


def decode(raw, pc, nxt):
    """-> (kind, rvc, rd, rs1, static_taken, static_target); kind: 'cond' 'jal' 'jalr' or None"""
    if raw & 3 == 3:
        op = raw & 0x7F
        rd = (raw >> 7) & 31
        rs1 = (raw >> 15) & 31
        if op == 0x63:
            imm = (((raw >> 31) & 1) << 12) | (((raw >> 7) & 1) << 11) | (((raw >> 25) & 0x3F) << 5) | (((raw >> 8) & 0xF) << 1)
            if imm & 0x1000:
                imm -= 0x2000
            return "cond", False, 0, rs1, imm < 0, pc + imm
        if op == 0x6F:
            imm = (((raw >> 31) & 1) << 20) | (((raw >> 12) & 0xFF) << 12) | (((raw >> 20) & 1) << 11) | (((raw >> 21) & 0x3FF) << 1)
            if imm & 0x100000:
                imm -= 0x200000
            return "jal", False, rd, 0, True, pc + imm
        if op == 0x67:
            return "jalr", False, rd, rs1, False, 0
        return None, False, 0, 0, False, 0
    h = raw & 0xFFFF
    q = h & 3
    f3 = h >> 13
    if q == 1 and f3 == 5:  # C.J
        imm = (((h >> 12) & 1) << 11) | (((h >> 8) & 1) << 10) | (((h >> 9) & 3) << 8) | (((h >> 6) & 1) << 7) \
            | (((h >> 7) & 1) << 6) | (((h >> 2) & 1) << 5) | (((h >> 11) & 1) << 4) | (((h >> 3) & 7) << 1)
        if imm & 0x800:
            imm -= 0x1000
        return "jal", True, 0, 0, True, pc + imm
    if q == 1 and f3 in (6, 7):  # C.BEQZ / C.BNEZ
        imm = (((h >> 12) & 1) << 8) | (((h >> 5) & 3) << 6) | (((h >> 2) & 1) << 5) | (((h >> 10) & 3) << 3) | (((h >> 3) & 3) << 1)
        if imm & 0x100:
            imm -= 0x200
        return "cond", True, 0, 0, imm < 0, pc + imm
    if q == 2 and f3 == 4:  # C.JR / C.JALR (and C.MV/C.ADD: not control flow when rs2 != 0)
        rs2 = (h >> 2) & 31
        rs1 = (h >> 7) & 31
        if rs2 == 0 and rs1 != 0:
            return "jalr", True, 1 if (h >> 12) & 1 else 0, rs1, False, 0
    return None, False, 0, 0, False, 0


class Pred:
    def __init__(self, bht=0, ras=0, btb=0):
        self.bht_bits = bht
        self.bht = {}
        self.ras_n = ras
        self.ras = []
        self.btb_n = btb
        self.btb = {}

    def run(self, trace):
        r = OrderedDict(n=0, cond=0, cond_mis=0, jal=0, jalr=0, jalr_mis=0, bubbles=0, cycles=0)
        for pc, raw, nxt in trace:
            kind, rvc, rd, rs1, st_taken, st_tgt = decode(raw, pc, nxt)
            if kind is None:
                continue
            ln = 2 if rvc else 4
            taken = nxt != pc + ln
            r["n"] += 1
            btb_hit = self.btb_n and self.btb.get(pc % self.btb_n) == (pc, nxt)
            if kind == "cond":
                r["cond"] += 1
                if self.bht_bits:
                    idx = (pc >> 1) & ((1 << self.bht_bits) - 1)
                    c = self.bht.get(idx)
                    pred = st_taken if c is None else c >= 2
                else:
                    pred = st_taken
                if pred != taken:
                    r["cond_mis"] += 1
                    r["cycles"] += MISP
                elif taken:
                    if not btb_hit:
                        r["bubbles"] += 1
                        r["cycles"] += BUBBLE
                if self.bht_bits:
                    c = self.bht.get(idx)
                    if c is None:
                        c = 2 if st_taken else 1
                    c = min(3, c + 1) if taken else max(0, c - 1)
                    self.bht[idx] = c
            elif kind == "jal":
                r["jal"] += 1
                if not btb_hit:
                    r["bubbles"] += 1
                    r["cycles"] += BUBBLE
                if rd in (1, 5) and self.ras_n:
                    self.ras.append(pc + ln)
                    self.ras = self.ras[-self.ras_n:]
            else:  # jalr
                r["jalr"] += 1
                is_ret = rd == 0 and rs1 in (1, 5)
                is_call = rd in (1, 5)
                predicted = False
                if self.ras_n and is_ret and self.ras:
                    predicted = self.ras.pop() == nxt
                elif self.ras_n and is_ret:
                    predicted = False
                if predicted:
                    if not btb_hit:
                        r["bubbles"] += 1
                        r["cycles"] += BUBBLE
                else:
                    r["jalr_mis"] += 1
                    r["cycles"] += MISP
                if is_call and self.ras_n:
                    self.ras.append(pc + ln)
                    self.ras = self.ras[-self.ras_n:]
            if self.btb_n and taken:
                self.btb[pc % self.btb_n] = (pc, nxt)
        return r


def load(path):
    t = []
    for line in open(path):
        p = line.split()
        if len(p) == 4 and p[0] == "BR":
            t.append((int(p[1], 16), int(p[2], 16), int(p[3], 16)))
    return t


def main():
    cfgs = [("static", dict()), ("ras8", dict(ras=8)), ("bht512", dict(bht=9)), ("bht512+ras8", dict(bht=9, ras=8)),
            ("btb32+ras8", dict(btb=32, ras=8)), ("bht512+btb32+ras8", dict(bht=9, btb=32, ras=8)),
            ("bht64+btb32+ras8", dict(bht=6, btb=32, ras=8)), ("bht2k+btb64+ras8", dict(bht=11, btb=64, ras=8))]
    for path in sys.argv[1:]:
        tr = load(path)
        print(f"== {path}: {len(tr)} control-flow instructions")
        base = None
        for name, kw in cfgs:
            r = Pred(**kw).run(tr)
            if base is None:
                base = r["cycles"]
            print(f"  {name:20s} cond {r['cond']:6d} mis {r['cond_mis']:5d}  jal {r['jal']:5d}  jalr {r['jalr']:5d} mis {r['jalr_mis']:4d}"
                  f"  bubbles {r['bubbles']:5d}  est. cost {r['cycles']:7d}  saved {base - r['cycles']:6d}")


if __name__ == "__main__":
    main()
