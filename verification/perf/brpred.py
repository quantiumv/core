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
  gshare     (OX.0) conditional branches from a table of 2-bit counters indexed by pc[k:1] xor the global history
             of the last h conditional outcomes
  tage       (OX.0) a TAGE-lite: a bimodal base and three tagged tables indexed with 4, 12 and 32 bits of global
             history; the longest hit predicts, a mispredict allocates in a longer table

Cost model (cycles, measured on the core): a mispredict that commit redirects on costs MISP (the refill,
about 8 from the branch's issue to the first new instruction's commit); a predicted-taken branch that the
aligner redirects on costs BUBBLE (the request for the next sequential dword is already out); a taken
branch the BTB knows costs ZERO. The estimate is the sum over the trace.

  brpred.py /tmp/br_qsort.txt ...        per-kernel table
"""
import heapq
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


class Tage:
    """TAGE-lite: base = 2-bit counters by pc; T1..T3 tagged, 2^bits entries each, 3-bit counters, a useful bit"""
    HIST = (4, 12, 32)

    def __init__(self, bits=8, tag_bits=8):
        self.bits, self.tag_bits = bits, tag_bits
        self.base = {}
        self.t = [dict() for _ in self.HIST]       # idx -> [tag, ctr (0..7), u]
        self.ghr = 0

    def _fold(self, h, n, w):
        v = h & ((1 << n) - 1)
        out = 0
        while v:
            out ^= v & ((1 << w) - 1)
            v >>= w
        return out

    def _idx(self, pc, i):
        return ((pc >> 1) ^ self._fold(self.ghr, self.HIST[i], self.bits)) & ((1 << self.bits) - 1)

    def _tag(self, pc, i):
        return ((pc >> 1) ^ self._fold(self.ghr, self.HIST[i], self.tag_bits) * 3) & ((1 << self.tag_bits) - 1)

    def predict(self, pc, static):
        for i in range(len(self.HIST) - 1, -1, -1):
            e = self.t[i].get(self._idx(pc, i))
            if e is not None and e[0] == self._tag(pc, i):
                return e[1] >= 4, i
        c = self.base.get((pc >> 1) & 0xFFF)
        return (static if c is None else c >= 2), -1

    def update(self, pc, taken, static):
        pred, prov = self.predict(pc, static)
        if prov >= 0:
            e = self.t[prov][self._idx(pc, prov)]
            e[1] = min(7, e[1] + 1) if taken else max(0, e[1] - 1)
            if pred == taken:
                e[2] = 1
        else:
            k = (pc >> 1) & 0xFFF
            c = self.base.get(k, 2 if static else 1)
            self.base[k] = min(3, c + 1) if taken else max(0, c - 1)
        if pred != taken:
            for i in range(prov + 1, len(self.HIST)):
                j = self._idx(pc, i)
                e = self.t[i].get(j)
                if e is None or e[2] == 0:
                    self.t[i][j] = [self._tag(pc, i), 4 if taken else 3, 0]
                    break
                e[2] = 0
        self.ghr = ((self.ghr << 1) | int(taken)) & ((1 << 64) - 1)


class Pred:
    def __init__(self, bht=0, ras=0, btb=0, gshare=None, tage=False):
        self.bht_bits = bht
        self.bht = {}
        self.gs = gshare                    # (history bits, index bits)
        self.gs_t = {}
        self.ghr = 0
        self.tage = Tage() if tage else None
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
                if self.tage is not None:
                    pred, _ = self.tage.predict(pc, st_taken)
                elif self.gs:
                    gidx = ((pc >> 1) ^ (self.ghr & ((1 << self.gs[0]) - 1))) & ((1 << self.gs[1]) - 1)
                    c = self.gs_t.get(gidx)
                    pred = st_taken if c is None else c >= 2
                elif self.bht_bits:
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
                if self.tage is not None:
                    self.tage.update(pc, taken, st_taken)
                elif self.gs:
                    c = self.gs_t.get(gidx)
                    if c is None:
                        c = 2 if st_taken else 1
                    self.gs_t[gidx] = min(3, c + 1) if taken else max(0, c - 1)
                    self.ghr = (self.ghr << 1) | int(taken)
                elif self.bht_bits:
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


class FePred:
    """(O8.0) The frontend as the RTL builds it, per dynamic control-flow instruction: a BTB that steers fetch (one
    branch per block of `blk` bytes, `entries` sets of `ways`, a crossing 32-bit branch filed under the block it ends
    in; on not taken either invalidated, ctr=False as today, or counted down, ctr=True: a conditional hit needs its
    2-bit counter at 2 or more), and the aligner's final call (direction: static, the BHT of 512 counters, or gshare
    with h history bits and 2^bits counters falling back to the BHT or to static; returns from a RAS of `ras`; a JALR
    that is no return only through a BTB entry when ind=True). Each instruction gets one class:
      ok       not taken, nothing steered: no cost
      steer    taken, the BTB steered fetch to its target: no bubble
      ared     taken and predicted so by the aligner only: an aligner-redirect bubble
      phantom  the BTB steered, the aligner's call is not taken (or another target) and right: a bubble
      mis      the final prediction is wrong: a recovery at execute
    Tables train at once (a trace study: no latency); the history holds every conditional outcome. (W.0) bslots: the
    branches one block may hold in the BTB (1, as built: a new taken branch evicts the block's other one)."""

    def __init__(self, blk=8, entries=32, ways=1, ctr=False, ret=False, ind=False, dirp='bht', h=12, bits=12,
                 fallback='bht', ras=8, bslots=1):
        self.blk, self.sets, self.ways, self.ctr, self.ret, self.ind = blk, entries // ways, ways, ctr, ret, ind
        self.dirp, self.h, self.bits, self.fallback, self.ras_n = dirp, h, bits, fallback, ras
        self.bslots = bslots
        self.btb = {}           # set -> list of [block, pc, tgt, ctr] (most recent last)
        self.bht = {}
        self.gs = {}
        self.ghr = 0
        self.ras = []

    def _key(self, pc, ln):
        b = pc // self.blk
        if ln == 4 and (pc + 2) // self.blk != b:
            b += 1              # a crossing branch: filed under the block it ends in
        return b

    def _lookup(self, pc, ln):
        b = self._key(pc, ln)
        for e in self.btb.get(b % self.sets, []):
            if e[0] == b and e[1] == pc:
                return e
        return None

    def _train_btb(self, pc, ln, taken, nxt, kind):
        b = self._key(pc, ln)
        s = self.btb.setdefault(b % self.sets, [])
        e = self._lookup(pc, ln)
        if taken:
            if e is None:
                same = [o for o in s if o[0] == b]
                for o in same[:max(0, len(same) - (self.bslots - 1))]:
                    s.remove(o)                  # bslots branches per block (one as built): the oldest goes
                if len(s) >= self.ways:
                    s.pop(0)
                s.append([b, pc, nxt, 2])
            else:
                e[2] = nxt
                e[3] = min(3, e[3] + 1)
                s.remove(e)
                s.append(e)
        elif e is not None:
            if self.ctr and kind == 'cond':
                e[3] = max(0, e[3] - 1)
            else:
                s.remove(e)

    def _dir(self, pc, st):
        """the aligner's direction for a conditional branch, and whether a table knew it"""
        bk = self.bht.get((pc >> 1) & 511)
        if self.dirp == 'gshare':
            g = self.gs.get(((pc >> 1) ^ (self.ghr & ((1 << self.h) - 1))) & ((1 << self.bits) - 1))
            if g is not None:
                return g >= 2, True
            if self.fallback == 'bht' and bk is not None:
                return bk >= 2, True
            return st, False
        if self.dirp == 'bht' and bk is not None:
            return bk >= 2, True
        return st, False

    def classify(self, trace):
        """trace: (pc, raw, next pc) per control-flow instruction, or (pc, raw, next pc, fetched, committed): then each
        one's tables train at its commit, seen only by those fetched after it (as the RTL does; the history is
        speculative and shifts at once)"""
        out = []
        pend = []               # (commit cycle, order, training) not applied yet
        for n_, it in enumerate(trace):
            pc, raw, nxt = it[:3]
            if len(it) > 3:
                while pend and pend[0][0] < it[3]:
                    heapq.heappop(pend)[2]()
            kind, rvc, rd, rs1, st_taken, st_tgt = decode(raw, pc, nxt)
            if kind is None:
                out.append(None)
                continue
            ln = 2 if rvc else 4
            taken = nxt != pc + ln
            e = self._lookup(pc, ln)
            steer = e is not None and (kind != 'cond' or not self.ctr or e[3] >= 2)
            stgt = e[2] if steer else None
            is_ret = kind == 'jalr' and rd == 0 and rs1 in (1, 5)
            is_call = kind != 'cond' and rd in (1, 5)
            if kind == 'jalr' and not is_ret and not is_call and not self.ind:
                steer, stgt = False, None        # today's BTB keeps no plain indirect jumps
            if kind == 'cond':
                d, known = self._dir(pc, st_taken)
                if not known and steer:
                    d = True                     # an untrained direction follows the BTB (hint_holds)
                ptk, ptgt = d, (st_tgt if d else pc + ln)
            elif kind == 'jal':
                ptk, ptgt = True, st_tgt
            elif is_ret and self.ras_n and self.ras:
                ptk, ptgt = True, self.ras[-1]
                if self.ret:
                    steer, stgt = True, self.ras[-1]   # a return entry: fetch takes the stack's top
            elif steer:
                ptk, ptgt = True, stgt
            else:
                ptk, ptgt = False, pc + ln
            if ptgt != nxt:
                c = 'mis'
            elif ptk:
                c = 'steer' if (steer and stgt == nxt) else 'ared'
            else:
                c = 'phantom' if steer else 'ok'
            out.append(c)
            # train: at once, or at the instruction's commit
            gi = ((pc >> 1) ^ (self.ghr & ((1 << self.h) - 1))) & ((1 << self.bits) - 1)

            def train(pc=pc, ln=ln, taken=taken, nxt=nxt, kind=kind, st_taken=st_taken, gi=gi, is_ret=is_ret):
                if kind == 'cond':
                    k = (pc >> 1) & 511
                    v = self.bht.get(k, 2 if st_taken else 1)
                    self.bht[k] = min(3, v + 1) if taken else max(0, v - 1)
                    if self.dirp == 'gshare':
                        v = self.gs.get(gi, 2 if st_taken else 1)
                        self.gs[gi] = min(3, v + 1) if taken else max(0, v - 1)
                if not is_ret:
                    self._train_btb(pc, ln, taken, nxt, kind)
            if len(it) > 3:
                heapq.heappush(pend, (it[4], n_, train))
            else:
                train()
            if kind == 'cond':
                self.ghr = ((self.ghr << 1) | int(taken)) & ((1 << 64) - 1)
            if self.ras_n:
                if is_ret and self.ras:
                    self.ras.pop()
                if is_call:
                    self.ras.append(pc + ln)
                    self.ras = self.ras[-self.ras_n:]
        return out


FE_CONFIGS = OrderedDict([  # (O8.0) the frontend options, for ilp.py --bp and brpred.py --fe
    ('rtl', dict()),                                                    # today: BHT, BTB 32 invalidated on not taken
    ('ctr', dict(ctr=True)),                                            # O8c: the BTB counts down instead
    ('ctr ret', dict(ctr=True, ret=True)),
    ('ctr ret w2', dict(ctr=True, ret=True, ways=2)),
    ('ctr ret 64', dict(ctr=True, ret=True, entries=64)),
    ('gshare', dict(ctr=True, ret=True, dirp='gshare')),                # O8a: gshare h12, 4K, BHT fallback
    ('gshare nofb', dict(ctr=True, ret=True, dirp='gshare', fallback='static')),
    ('gshare h8', dict(ctr=True, ret=True, dirp='gshare', h=8)),
    ('gshare h8 1k', dict(ctr=True, ret=True, dirp='gshare', h=8, bits=10)),
    ('gshare 16B', dict(ctr=True, ret=True, dirp='gshare', blk=16)),     # O8d
    ('gshare 16B w2', dict(ctr=True, ret=True, dirp='gshare', blk=16, ways=2)),
    ('gshare 16B w2 ras16', dict(ctr=True, ret=True, dirp='gshare', blk=16, ways=2, ras=16)),
    # (W.0) wider fetch: 32-byte blocks, and two branches per block
    ('gshare b2', dict(ctr=True, ret=True, dirp='gshare', bslots=2)),
    ('gshare 16B w2 b2', dict(ctr=True, ret=True, dirp='gshare', blk=16, ways=2, bslots=2)),
    ('gshare 32B w2', dict(ctr=True, ret=True, dirp='gshare', blk=32, ways=2)),
    ('gshare 32B w2 b2', dict(ctr=True, ret=True, dirp='gshare', blk=32, ways=2, bslots=2)),
])


def taken_per_block(tr, blk):
    """(W.0) the dynamic taken branches, by how many distinct taken branches their block of blk bytes holds over the
    trace: {1: n, 2: n, 3: n (three or more)}"""
    per = {}
    for pc, raw, nxt in tr:
        kind, rvc = decode(raw, pc, nxt)[:2]
        if kind is not None and nxt != pc + (2 if rvc else 4):
            per.setdefault(pc // blk, {}).setdefault(pc, 0)
            per[pc // blk][pc] += 1
    out = {1: 0, 2: 0, 3: 0}
    for b in per.values():
        out[min(3, len(b))] += sum(b.values())
    return out


def load(path):
    """BR lines (+BRTRACE), or ILP lines (+ILPTRACE, OX.0): every retirement in program order, both commit
    channels (BRTRACE prints the first channel's only), so a control-flow instruction's next pc is the next line's
    pc; a trapping one and the window's last line are left out"""
    t = []
    ilp = []
    for line in open(path):
        p = line.split()
        if len(p) == 4 and p[0] == "BR":
            t.append((int(p[1], 16), int(p[2], 16), int(p[3], 16)))
        elif len(p) >= 13 and p[0] == "ILP":
            ilp.append((int(p[1], 16), int(p[2], 16), p[12] != "0"))
    for k in range(len(ilp) - 1):
        pc, raw, trap = ilp[k]
        if not trap and decode(raw, pc, 0)[0] is not None:
            t.append((pc, raw, ilp[k + 1][0]))
    return t


def main():
    cfgs = [("static", dict()), ("ras8", dict(ras=8)), ("bht512", dict(bht=9)), ("bht512+ras8", dict(bht=9, ras=8)),
            ("btb32+ras8", dict(btb=32, ras=8)), ("bht512+btb32+ras8", dict(bht=9, btb=32, ras=8)),
            ("bht64+btb32+ras8", dict(bht=6, btb=32, ras=8)), ("bht2k+btb64+ras8", dict(bht=11, btb=64, ras=8)),
            ("gshare h8 1k+btb32+ras8", dict(gshare=(8, 10), btb=32, ras=8)),
            ("gshare h12 4k+btb32+ras8", dict(gshare=(12, 12), btb=32, ras=8)),
            ("tage-lite+btb32+ras8", dict(tage=True, btb=32, ras=8))]
    if sys.argv[1:2] == ["--blocks"]:      # (W.0) do blocks of 8, 16, 32 bytes hold more than one taken branch?
        for path in sys.argv[2:]:
            tr = load(path)
            cells = []
            for blk in (8, 16, 32):
                n = taken_per_block(tr, blk)
                tot = sum(n.values()) or 1
                cells.append(f"{blk}B: " + " / ".join(f"{100.0 * n[k] / tot:.0f}" for k in (1, 2, 3)))
            print(f"{path}: % of taken branches in a block with 1 / 2 / 3+ taken branches: " + "   ".join(cells))
        return
    if sys.argv[1:2] == ["--fe"]:          # (O8.0) the classes of the frontend options, per trace
        for path in sys.argv[2:]:
            tr = load(path)
            print(f"== {path}: {len(tr)} control-flow instructions")
            for name, kw in FE_CONFIGS.items():
                cl = FePred(**kw).classify(tr)
                n = {c: cl.count(c) for c in ("ok", "steer", "ared", "phantom", "mis")}
                print(f"  {name:22s} " + "  ".join(f"{c} {v:5d}" for c, v in n.items()))
        return
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
