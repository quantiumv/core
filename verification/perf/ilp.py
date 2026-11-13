#!/usr/bin/env python3
"""ilp.py -- what would out-of-order issue (O1) and two-wide dispatch and commit (O4) buy on the perf kernels? (O1.0)

Reads the traces perf_tb writes under +ILPTRACE (run_perf.sh --ilptrace DIR): one line per instruction retired inside
a kernel's window, with the cycles it entered and left the instruction queue (push, pop), was issued (disp: the ROB
allocation), reached the LSU and started its access (acc, go), wrote back (cmpl) and committed, plus whether the aligner
redirected fetch after it, whether it trapped, the commit redirect it caused and its physical dword.

The model replays the retired stream through a dataflow machine with the core's structure:
  frontend   instructions are pushed into the instruction queue in order, at most two a cycle, no earlier than the
             commit of the redirect that started their path, and no earlier than the IQ has room (IQ_DEPTH);
             decode pops one (or W) a cycle, holding at most W uops until they are dispatched
  dispatch   in order, W a cycle, into the ROB (ROB) and, for memory ops, the load/store queue (LSQ); in order mode
             (rs = 0) a uop also waits for its operands and its unit, as the core does today
  issue      (rs > 0) out of order: the oldest ready uop takes its port (ALU/BRU, DIV, FPU pipe, FP divide/sqrt);
             a uop that does not issue at dispatch takes a reservation-station entry (rs)
  memory     one engine, in order: a memory op is taken once dispatched, its operands are ready and the last op has
             completed (the handoff), starts a cycle later (or at the head when it may not go early) and completes
             after its own bus latency; posted stores drain from a store buffer of SB entries, one every DR cycles
  commit     in order, W a cycle (a pair only when the first is a plain retirement), a cycle after the writeback
Operands are ready in the producer's writeback cycle for the units with a bypass (ALU/BRU, FPU, LSU), a cycle later for
the divider, and a cycle after the commit for a CSR op (its value is made at commit).

The pair rules of O4 are knobs (all off by default, so the O1.0 configurations are unchanged): mem1, at most one memory
op in a dispatch pair; fp1, at most one uop touching FP state; alone, a CSR, SYS, FENCE, divide, FP divide/square root,
atomic or trapping uop dispatches alone; p0, branches and multiplies use port 0 only; slot2, the second commit is never
a trap, CSR, SYS or FENCE; fpw1, a commit pair writes FP state at most once; dispatch1, two commits with one dispatch.
--set o4 runs the two-wide configurations with them.

Everything the structure does not explain is kept as a per-instruction residual, measured on the core as it is: the
traced run is replayed in its own configuration ("fit"), each event's residual is its traced cycle minus the latest of
its modelled constraints, and other configurations add the same residual to their own constraints. That keeps cache
misses, the buffer's match waits, the I$ and the frontend's bubbles as measured; it is checked against runs of the core
with one knob changed (the --validate CSVs), whose cycle changes the model must predict.

  ilp.py --traces DIR [--validate DIR] [--config cache|sram] [--mode m|s]
"""
import argparse
import math
import os
import sys

# ---------------------------------------------------------------------------------------------------------------
# decode: class, destination, sources (('x', n) / ('f', n)), memory kind


def _rvc(raw):
    q = raw & 3
    f3 = (raw >> 13) & 7
    rp1 = 8 + ((raw >> 7) & 7)
    rp2 = 8 + ((raw >> 2) & 7)
    r1 = (raw >> 7) & 31
    r2 = (raw >> 2) & 31
    X = lambda n: ('x', n)
    F = lambda n: ('f', n)
    if q == 0:
        if f3 == 0: return 'alu', X(rp2), [X(2)], None
        if f3 == 1: return 'lsu', F(rp2), [X(rp1)], 'ld'
        if f3 in (2, 3): return 'lsu', X(rp2), [X(rp1)], 'ld'
        if f3 == 5: return 'lsu', None, [X(rp1), F(rp2)], 'st'
        if f3 in (6, 7): return 'lsu', None, [X(rp1), X(rp2)], 'st'
        return 'alu', None, [], None
    if q == 1:
        if f3 in (0, 1): return 'alu', X(r1), [X(r1)], None
        if f3 == 2: return 'alu', X(r1), [], None
        if f3 == 3: return ('alu', X(2), [X(2)], None) if r1 == 2 else ('alu', X(r1), [], None)
        if f3 == 4:
            f2 = (raw >> 10) & 3
            if f2 < 3: return 'alu', X(rp1), [X(rp1)], None
            return 'alu', X(rp1), [X(rp1), X(rp2)], None
        if f3 == 5: return 'bru', None, [], None
        return 'bru', None, [X(rp1)], None
    # q == 2
    if f3 == 0: return 'alu', X(r1), [X(r1)], None
    if f3 == 1: return 'lsu', F(r1), [X(2)], 'ld'
    if f3 in (2, 3): return 'lsu', X(r1), [X(2)], 'ld'
    if f3 == 4:
        b12 = (raw >> 12) & 1
        if b12 == 0:
            if r2 == 0: return 'bru', None, [X(r1)], None
            return 'alu', X(r1), [X(r2)], None
        if r1 == 0 and r2 == 0: return 'sys', None, [], None
        if r2 == 0: return 'bru', X(1), [X(r1)], None
        return 'alu', X(r1), [X(r1), X(r2)], None
    if f3 == 5: return 'lsu', None, [X(2), F(r2)], 'st'
    return 'lsu', None, [X(2), X(r2)], 'st'


def decode(raw):
    """-> (cls, dst, srcs, mem); cls: alu bru div lsu csr sys fence fpu fds; mem: None 'ld' 'st' 'amo'"""
    if raw & 3 != 3:
        return _rvc(raw & 0xFFFF)
    op = raw & 0x7F
    rd = (raw >> 7) & 31
    f3 = (raw >> 12) & 7
    r1 = (raw >> 15) & 31
    r2 = (raw >> 20) & 31
    r3 = (raw >> 27) & 31
    f7 = raw >> 25
    X = lambda n: ('x', n)
    F = lambda n: ('f', n)
    if op in (0x37, 0x17): return 'alu', X(rd), [], None
    if op == 0x6F: return 'bru', X(rd), [], None
    if op == 0x67: return 'bru', X(rd), [X(r1)], None
    if op == 0x63: return 'bru', None, [X(r1), X(r2)], None
    if op == 0x03: return 'lsu', X(rd), [X(r1)], 'ld'
    if op == 0x23: return 'lsu', None, [X(r1), X(r2)], 'st'
    if op in (0x13, 0x1B): return 'alu', X(rd), [X(r1)], None
    if op in (0x33, 0x3B):
        if f7 == 1 and f3 >= 4: return 'div', X(rd), [X(r1), X(r2)], None
        return 'alu', X(rd), [X(r1), X(r2)], None
    if op == 0x0F: return ('fence', None, [], None) if f3 == 0 else ('sys', None, [], None)
    if op == 0x73:
        if f3 == 0: return 'sys', None, [], None
        return 'csr', X(rd), ([X(r1)] if f3 < 4 else []), None
    if op == 0x2F:
        if (raw >> 27) == 2: return 'lsu', X(rd), [X(r1)], 'amo'          # LR
        return 'lsu', X(rd), [X(r1), X(r2)], 'amo'
    if op == 0x07: return 'lsu', F(rd), [X(r1)], 'ld'
    if op == 0x27: return 'lsu', None, [X(r1), F(r2)], 'st'
    if op in (0x43, 0x47, 0x4B, 0x4F): return 'fpu', F(rd), [F(r1), F(r2), F(r3)], None
    if op == 0x53:
        g = f7 >> 2
        if g in (0x00, 0x01, 0x02, 0x04, 0x05): return 'fpu', F(rd), [F(r1), F(r2)], None
        if g == 0x03: return 'fds', F(rd), [F(r1), F(r2)], None              # fdiv
        if g == 0x0B: return 'fds', F(rd), [F(r1)], None                     # fsqrt
        if g == 0x08: return 'fpu', F(rd), [F(r1)], None                     # fcvt.s.d / d.s
        if g == 0x14: return 'fpu', X(rd), [F(r1), F(r2)], None              # compares
        if g == 0x18: return 'fpu', X(rd), [F(r1)], None                     # fcvt to int
        if g == 0x1A: return 'fpu', F(rd), [X(r1)], None                     # fcvt from int
        if g == 0x1C: return 'fpu', X(rd), [F(r1)], None                     # fmv.x / fclass
        if g == 0x1E: return 'fpu', F(rd), [X(r1)], None                     # fmv to fp
        return 'fpu', F(rd), [F(r1), F(r2)], None
    return 'alu', None, [], None


# ---------------------------------------------------------------------------------------------------------------
# the trace


class Ins:
    __slots__ = ('pc', 'raw', 'push', 'pop', 'disp', 'acc', 'go', 'cmpl', 'commit', 'early', 'ared', 'trap', 'redir',
                 'addr', 'cls', 'dst', 'srcs', 'mem', 'posted', 'prod', 'dword', 'rvc', 'fpw', 'fp', 'alone', 'mul',
                 'iss', 'ds', 'cs', 'fr', 'dcm')


def read_trace(path):
    out = []
    with open(path) as f:
        for ln in f:
            p = ln.split()
            if len(p) < 15 or p[0] != 'ILP':
                continue
            i = Ins()
            i.pc, i.raw = int(p[1], 16), int(p[2], 16)
            (i.push, i.pop, i.disp, i.acc, i.go, i.cmpl, i.commit, i.early, i.ared, i.trap,
             i.redir) = (int(x) for x in p[3:14])
            i.addr = int(p[14], 16)
            # (OX.0) the cycle its unit took it, its dispatch slot and commit channel, when the fetch buffer got its
            # dword, whether its access met a D$ refill; older traces have none (issue = dispatch)
            if len(p) >= 20:
                i.iss, i.ds, i.cs, i.fr, i.dcm = (int(x) for x in p[15:20])
            else:
                i.iss, i.ds, i.cs, i.fr, i.dcm = 0, 0, 0, i.push, 0
            if not i.iss:
                i.iss = i.acc if i.acc else i.disp
            i.rvc = (i.raw & 3) != 3
            i.cls, i.dst, i.srcs, i.mem = decode(i.raw)
            if i.dst is not None and i.dst == ('x', 0):
                i.dst = None
            i.srcs = [s for s in i.srcs if s != ('x', 0)]
            i.posted = i.mem == 'st' and i.go and i.cmpl == i.go and not i.trap
            i.dword = i.pc >> 3
            i.fpw = (i.dst is not None and i.dst[0] == 'f') or i.cls in ('fpu', 'fds')    # writes FP state (fflags too)
            i.fp = i.fpw or any(s[0] == 'f' for s in i.srcs)
            i.alone = i.cls in ('csr', 'sys', 'fence', 'div', 'fds') or i.mem == 'amo' or bool(i.trap)
            i.mul = not i.rvc and (i.raw & 0x7F) in (0x33, 0x3B) and (i.raw >> 25) == 1 and i.cls == 'alu'
            out.append(i)
    last = {}
    for k, i in enumerate(out):
        i.prod = [last[s] for s in i.srcs if s in last]
        if i.dst is not None:
            last[i.dst] = k
    return out


# ---------------------------------------------------------------------------------------------------------------
# the machine

BASE = dict(w=1, rs=0, rob=8, iq=8, lsq=4, sb=4, handoff=True, early=True, lsu_bypass=True, bypass=True,
            alu_ports=1, fe='res', fe_rate=1, db=2,
            mem1=False, fp1=False, alone=False, p0=False, slot2=False, fpw1=False, dispatch1=False,
            # (OX.0) iss_res: the issue cycle is traced and fitted (a unit's latency counts from its issue, not its
            # dispatch), so a trace of the core with the station replays exactly; xr/xr_lat: a mispredict restarts
            # fetch xr_lat cycles after the branch's writeback, not at its commit (O3)
            iss_res=False, xr=False, xr_lat=1,
            # (OX.0) memory: lq/sq split the queue (0: one queue of lsq); mem_ooo: a memory op starts once its operands
            # are ready and one of `engines` is free, not after the older ones; fwd: a load takes an older store's
            # bytes instead of waiting for its drain; spec_ld: a load does not wait for older stores whose address is
            # unknown (a same-dword one resolving later is a violation: the load and what follows restart `replay`
            # cycles after it), mdp: none / waitbit (a load that violated waits next time) / ideal; mshr: misses in
            # flight at once (0: the D$ blocks), hit_lat: how long a hit holds the D$ when it does not; miss_add: more
            # cycles on every access that met a refill (a slower memory than the traced one)
            lq=0, sq=0, mem_ooo=False, engines=1, fwd=False, spec_ld=False, mdp='none', replay=8,
            mshr=0, hit_lat=2, miss_add=0,
            # (OX.0) frontend: fe_blk, the bytes fetched a cycle with fe='ideal'; fe_taken, the bubble after a taken
            # branch the aligner redirected on (None: as traced); nomp: no mispredicts (what one costs)
            fe_blk=8, fe_taken=None, nomp=False)


class DPort:
    """The memory port behind the LSU: the blocking write-through D$, shared by loads and the store buffer's drain.
    A load holds it from its start to its writeback. A drain beat, decided at cycle s, holds it until its response at
    s + DB (the next beat may be decided in that cycle); the LSU may not start in [s, s + DB]. The drain never
    starts while a load is in flight or ready to start, unless the buffer is full or has waited YIELD cycles.
    Beats are scheduled lazily, in time order, as the loads that might go before them are placed."""

    def __init__(self, depth, db, yield_max=16):
        self.depth, self.db, self.ymax = depth, db, yield_max
        self.sb = []            # [ready, go, resp, addr] of each posted store, in order
        self.nd = 0             # the first one whose beat is not scheduled
        self.drain_avail = 0    # the next beat may be decided from here (the last one's response)
        self.load_end = -1      # the last load's writeback
        self.beats = []         # (s, resp) of the scheduled beats

    def push(self, ready, addr):
        self.sb.append([ready, None, None, addr])

    def _start(self, e):
        return max(e[0], self.drain_avail, self.load_end + 1)

    def _cnt(self, x):
        """entries in the buffer at cycle x (one leaves at the edge after its response)"""
        return sum(1 for e in self.sb if e[0] <= x and (e[2] is None or e[2] >= x))

    def _sched(self, at=None):
        e = self.sb[self.nd]
        s0 = self._start(e) if at is None else at
        e[1], e[2] = s0, s0 + self.db
        self.drain_avail = e[2]
        self.beats.append((s0, e[2]))
        if len(self.beats) > max(64, 4 * self.depth):
            self.beats.pop(0)
        self.nd += 1

    def _free(self, t):
        moved = True
        while moved:
            moved = False
            for (s, r) in self.beats:
                if s <= t <= r:
                    t, moved = r + 1, True
        return t

    def place_load(self, t_ready, t_hold=None):
        """the cycle a load ready from t_ready starts; from t_hold (<= t_ready) it holds the drain off"""
        if t_hold is None or t_hold > t_ready:
            t_hold = t_ready
        while True:
            cand = self._free(t_ready)
            if self.nd < len(self.sb):
                s0 = self._start(self.sb[self.nd])
                if s0 < t_hold:
                    self._sched()
                    continue
                # held off by the load: it goes anyway once the buffer is full or it has waited YIELD cycles
                for x in range(s0, cand + 1):
                    if x - max(s0, t_hold) >= self.ymax or self._cnt(x) >= self.depth:
                        self._sched(x)
                        break
                else:
                    return cand
                continue
            return cand

    def load_done(self, go, cmpl):
        self.load_end = max(self.load_end, cmpl)

    def resp_of(self, i):
        while self.sb[i][2] is None:
            self._sched()
        return self.sb[i][2]

    def last_store_to(self, addr):
        for i in range(len(self.sb) - 1, -1, -1):
            if self.sb[i][3] == addr:
                return i
        return None

    def room_at(self, c):
        """the first cycle from c at which the buffer has room for one more"""
        n = len(self.sb)
        if n < self.depth:
            return c
        r = self.resp_of(n - self.depth) + 1                # its entry leaves at that response
        return max(c, r)


def sim(tr, p, res=None, fit=False, t0=None):
    """Replay the trace; returns (cycles, per-instruction commit list). fit: take every event at its traced cycle and
    record the residuals in res (a dict of lists), which other runs add back."""
    n = len(tr)
    W = p['w']
    push = [0] * n; pop = [0] * n; disp = [0] * n; iss = [0] * n
    acc = [0] * n; go = [0] * n; cmpl = [0] * n; com = [0] * n
    if fit:
        for k in ('push', 'pop', 'disp', 'acc', 'go', 'com', 'lat', 'bus', 'iss'):
            res[k] = [0] * n
    trim = 4 * max(16, p['rob'], p['rs'])       # how far back the occupancy lists look
    ports = {}                      # (port, cycle) -> uses
    cap = {'alu': p['alu_ports'], 'bru': 1, 'fpu': 1, 'p0': 1}     # p0: port 0's own (branches, multiplies)
    rs_occ = []                     # (disp, issue) of uops that waited in the RS
    last_div = None; last_fds = None
    mem_idx = []                    # indices of memory ops, in order
    dc = DPort(p['sb'], p['db'])
    t_open = t0 if t0 is not None else (tr[0].commit - 1 if tr else 0)
    seg_start = t_open
    first_dword_push = None         # (fe ideal) the push of the first instruction of the current dword
    neg = 0
    ld_idx = []; st_idx = []        # (lq/sq) the loads and the stores, in order
    eng_end = []                    # (mem_ooo) when each busy engine's op completes
    miss_iv = []                    # (mshr) the misses in flight: (go, cmpl)
    waitbit = set()                 # (mdp waitbit) the loads that violated
    replay_at = None                # a load violated: what follows it restarts from here
    shift = max(3, (p['fe_blk'] - 1).bit_length())

    def redir_of(q):
        """the commit redirect an instruction causes in this configuration (nomp: never a mispredict)"""
        return 0 if (p['nomp'] and q.redir in (1, 4)) else q.redir

    def avail(k):
        """when a consumer may take producer k's value (the cycle it issues in)"""
        q = tr[k]
        if q.cls == 'csr':
            return com[k] + 1
        if q.cls == 'div':
            return cmpl[k] + 1
        if q.cls == 'lsu' and not p['lsu_bypass']:
            return cmpl[k] + 1
        if not p['bypass']:
            return cmpl[k] + 1
        return cmpl[k]

    def port_of(q):
        if p['p0'] and (q.cls == 'bru' or q.mul): return 'p0'
        if q.cls in ('bru',): return 'bru'
        if q.cls in ('fpu',): return 'fpu'
        if q.cls in ('div', 'fds', 'lsu'): return None
        return 'alu'

    def free_port(pt, t):
        """the first cycle from t at which port pt has room"""
        if pt is None:
            return t
        while ports.get((pt, t), 0) >= cap[pt] or (pt in ('alu', 'bru', 'p0') and ports.get(('int', t), 0) >= p['alu_ports']):
            t += 1
        return t

    def take_port(pt, t):
        if pt is None:
            return t
        t = free_port(pt, t)
        ports[(pt, t)] = ports.get((pt, t), 0) + 1
        if pt in ('alu', 'bru', 'p0'):
            ports[('int', t)] = ports.get(('int', t), 0) + 1
        return t

    def put(name, k, cons, actual):
        # the residual is added back as measured (negative ones too), so the traced configuration replays exactly
        nonlocal neg
        if fit:
            r = actual - cons
            if r < 0:
                neg += 1
            res[name][k] = r
            return actual
        return cons + res[name][k]

    for k, q in enumerate(tr):
        prev = tr[k - 1] if k else None
        prev_redir = prev is not None and (redir_of(prev) or prev.trap)
        blk = q.pc >> shift
        # ---- frontend: push into the IQ ----
        if prev_redir:
            seg_start = com[k - 1]
            if p['xr'] and prev.redir in (1, 4) and not prev.trap:
                seg_start = min(seg_start, cmpl[k - 1] + p['xr_lat'])     # recovered at execute (O3)
            c = seg_start
            first_dword_push = None
        else:
            c = seg_start if k == 0 else push[k - 1]
            if k >= 2 and push[k - 2] >= c:
                c = max(c, push[k - 2] + 1)                   # at most two pushes a cycle
            if k >= p['iq']:
                c = max(c, pop[k - p['iq']] + 1)              # room in the IQ
            if p['fe'] == 'ideal' and k > 0 and blk != (prev.pc >> shift):
                if first_dword_push is not None:
                    c = max(c, first_dword_push + p['fe_rate'])   # one block a cycle (fe_rate cycles)
            if p['fe'] == 'ideal' and p['fe_taken'] is not None and prev is not None and prev.ared:
                c = max(c, push[k - 1] + p['fe_taken'])          # the bubble after a taken branch
        if replay_at is not None:
            c = max(c, replay_at)                             # a load before it violated: refetched from there
            replay_at = None
        nomp_skip = p['nomp'] and prev is not None and prev.redir in (1, 4) and not prev.trap
        if not fit and (nomp_skip or (p['fe'] == 'ideal' and not prev_redir and k > 0 and (
                not prev.ared or p['fe_taken'] is not None))):
            push[k] = c                                         # no frontend residual within a fetch stream
        else:
            push[k] = put('push', k, c, q.push)
        if k == 0 or blk != (prev.pc >> shift) or prev_redir:
            first_dword_push = push[k]
        # ---- decode ----
        c = push[k] + 1
        if k >= 1: c = max(c, pop[k - 1] + (1 if W == 1 else 0))
        if k >= 2 and W == 2: c = max(c, pop[k - 2] + 1)
        if k >= W: c = max(c, disp[k - W])                    # decode holds W uops until they dispatch
        pop[k] = put('pop', k, c, q.pop)
        # ---- dispatch ----
        c = pop[k] + 1
        if k >= 1: c = max(c, disp[k - 1] + (1 if W == 1 else 0))
        if k >= 2 and W == 2: c = max(c, disp[k - 2] + 1)
        if p['dispatch1'] and k >= 1: c = max(c, disp[k - 1] + 1)
        # (in the fit too: a two-wide trace is fitted with its rules, or a replay would count a split pair twice)
        if W == 2 and k >= 1 and disp[k - 1] >= c:
            pq = tr[k - 1]                                    # would pair with the uop before it: the pair rules
            if ((p['mem1'] and q.cls == 'lsu' and pq.cls == 'lsu') or (p['fp1'] and q.fp and pq.fp)
                    or (p['alone'] and (q.alone or pq.alone))):
                c = max(c, disp[k - 1] + 1)
        if k >= p['rob']: c = max(c, com[k - p['rob']] + 1)
        if q.cls == 'lsu':
            mi = len(mem_idx)
            if p['lq'] and p['sq']:                           # split queues: a load needs a load entry, a store a store one
                own, cap_q = (st_idx, p['sq']) if q.mem == 'st' else (ld_idx, p['lq'])
                if len(own) >= cap_q:
                    c = max(c, com[own[len(own) - cap_q]] + 1)
            elif p['lsq'] > 0 and mi >= p['lsq']:
                c = max(c, com[mem_idx[mi - p['lsq']]] + 1)
            if p['lsq'] == 0 and mem_idx:
                pm = mem_idx[-1]
                c = max(c, cmpl[pm] + 1)                      # one op in the LSU, taken once the last completed
        ready = max([avail(j) for j in q.prod] + [0])
        if p['rs'] == 0 or (q.cls == 'lsu' and p['lsq'] == 0):
            c = max(c, ready)                                 # in order: operands at dispatch
            if q.cls == 'div' and last_div is not None: c = max(c, cmpl[last_div] + 1)
            if q.cls == 'fds' and last_fds is not None: c = max(c, cmpl[last_fds] + 1)
        if p['rs'] > 0 and q.cls != 'lsu':
            pt = port_of(q)

            def earliest(d):
                t = max(d, ready)
                if q.cls == 'div' and last_div is not None: t = max(t, cmpl[last_div] + 1, iss[last_div] + 1)
                if q.cls == 'fds' and last_fds is not None: t = max(t, cmpl[last_fds] + 1, iss[last_fds] + 1)
                return free_port(pt, t)
            # (OX.0) a uop that will wait for its operands or its unit needs a station entry to dispatch: that wait
            # is part of the constraint, so a fit of a run whose station filled does not keep it as a residual (a
            # configuration with no station, or a bigger one, would add it back where it does not happen)
            if earliest(c) > c:
                while sum(1 for (d, i) in rs_occ if d < c <= i) >= p['rs']:
                    c += 1
        disp[k] = put('disp', k, c, q.disp)
        # ---- issue (non-memory) ----
        if q.cls != 'lsu':
            pt = port_of(q)
            if p['rs'] == 0:
                if not fit and W > 1:
                    disp[k] = free_port(pt, disp[k])          # in order: a busy port holds the dispatch
                icons = take_port(pt, disp[k]) if not fit else disp[k]
            else:
                t = earliest(disp[k])
                if t > disp[k]:
                    # it waits in a reservation-station entry (from its dispatch to its issue): dispatch needs room
                    while sum(1 for (d, i) in rs_occ if d < disp[k] <= i) >= p['rs']:
                        disp[k] += 1
                    t = earliest(disp[k])
                    if t > disp[k]:
                        rs_occ.append((disp[k], t))
                        if len(rs_occ) > trim:
                            rs_occ.pop(0)
                icons = take_port(pt, t)
            iss[k] = put('iss', k, icons, q.iss) if p['iss_res'] else icons
            if fit:
                res['lat'][k] = (q.cmpl - q.iss) if p['iss_res'] else (q.cmpl - q.disp)
            cmpl[k] = iss[k] + max(1, res['lat'][k])
            if q.cls == 'div': last_div = k
            if q.cls == 'fds': last_fds = k
        else:
            # ---- memory: the engine ----
            c = disp[k]
            if p['rs'] > 0 and p['lsq'] > 0:
                c = max(c, ready)
            eligible = p['early'] and p['lsq'] > 0 and q.mem in ('ld', 'st') and not q.trap
            ooo = p['mem_ooo'] and eligible
            if ooo:
                # (OX.0) out-of-order memory: one of `engines` free, not after the older ops
                eng_end[:] = [e for e in eng_end if e > c]
                if len(eng_end) >= p['engines']:
                    c = max(c, sorted(eng_end)[len(eng_end) - p['engines']])
            elif mem_idx:
                pm = mem_idx[-1]
                hand = p['handoff'] and p['lsq'] > 0 and (tr[pm].posted or (tr[pm].go and tr[pm].cmpl > tr[pm].go))
                c = max(c, cmpl[pm] if hand else cmpl[pm] + 1)
            acc[k] = put('acc', k, c, q.acc if q.acc else q.disp)
            c = acc[k] + 1
            if not eligible:
                c = max(c, (com[k - 1] + 1) if k else c)      # at the head
            if fit:
                res['bus'][k] = q.cmpl - (q.go if q.go else q.cmpl)
            lat = res['bus'][k] + (p['miss_add'] if q.dcm else 0)
            if q.mem == 'ld' and not q.trap:
                hold = c
                fwd_from = None
                if ooo:
                    # the older stores still in flight: an unknown address holds the load (unless it speculates),
                    # a known one to its dword forwards (fwd) or makes it wait for the drain
                    for s in reversed(st_idx):
                        if com[s] < c:
                            break
                        known = acc[s] + 1
                        same = tr[s].addr == q.addr
                        if known > c:
                            wait = (not p['spec_ld'] or (p['mdp'] == 'ideal' and same)
                                    or (p['mdp'] == 'waitbit' and q.pc in waitbit))
                            if wait:
                                c = max(c, known)
                            elif same:
                                replay_at = max(replay_at or 0, known + p['replay'])   # a violation
                                if p['mdp'] == 'waitbit':
                                    waitbit.add(q.pc)
                        if same and p['fwd'] and fwd_from is None:
                            fwd_from = s
                    hold = c
                if fwd_from is not None:
                    c = max(c, go[fwd_from])                  # its bytes merged when the store has its data
                else:
                    # a load waits for an older store to its dword to leave the store buffer, then for the D$
                    m = dc.last_store_to(q.addr)
                    if m is not None and dc.resp_of(m) + 1 > c:
                        c = hold = dc.resp_of(m) + 1
                    elif not eligible:
                        # a load waiting for the head holds the drain off once it is among the three oldest
                        hold = max(acc[k] + 1, (com[k - 3] + 1) if k >= 3 else acc[k] + 1)
                if q.dcm and p['mshr'] > 0:
                    while sum(1 for (a, b) in miss_iv if a <= c < b) >= p['mshr']:
                        c += 1                                # every miss handler is busy
                gcons = dc.place_load(c, hold)
                go[k] = put('go', k, gcons, q.go if q.go else q.cmpl)
                cmpl[k] = go[k] + lat
                if replay_at is not None and replay_at > cmpl[k]:
                    cmpl[k] = replay_at                       # it ran again after the violation
                if q.dcm and p['mshr'] > 0:
                    miss_iv.append((go[k], cmpl[k]))
                    if len(miss_iv) > trim:
                        miss_iv.pop(0)
                # a blocking D$ is busy until the load's data; a non-blocking one only for a hit's time
                dc.load_done(go[k], cmpl[k] if p['mshr'] == 0 else go[k] + p['hit_lat'])
            else:
                go[k] = put('go', k, c, q.go if q.go else q.cmpl)
                cmpl[k] = go[k] + lat
            if ooo:
                eng_end.append(cmpl[k])
            mem_idx.append(k)
            if q.mem == 'st':
                st_idx.append(k)
            else:
                ld_idx.append(k)
        # ---- commit ----
        c = cmpl[k] + 1
        if k >= 1:
            c = max(c, com[k - 1] + 1)
            if W == 2:
                pq = tr[k - 1]
                plain = not (pq.trap or redir_of(pq) or pq.cls in ('csr', 'sys', 'fence'))
                pair = plain and not (pq.posted and q.posted) and not (pq.cls == 'bru' and q.cls == 'bru')
                if p['slot2'] and (q.trap or q.cls in ('csr', 'sys', 'fence')): pair = False
                if p['fpw1'] and q.fpw and pq.fpw: pair = False
                if pair and (k < 2 or com[k - 2] < com[k - 1]):
                    c = max(cmpl[k] + 1, com[k - 1])
        if q.posted and p['sb'] > 0:
            c = max(c, dc.room_at(c))                         # the store buffer has room for it
        com[k] = put('com', k, c, q.commit)
        if q.posted:
            dc.push(com[k] + 1, q.addr)
    return com[-1] - t_open, neg


# ---------------------------------------------------------------------------------------------------------------

def load_csv(path):
    rows = {}
    with open(path) as f:
        hdr = f.readline().strip().split(',')
        for ln in f:
            v = ln.strip().split(',')
            rows[(v[0], v[1])] = dict(zip(hdr, v))
    return rows


KERNELS = 'memcpy crc32 qsort matmul sieve listchase mixedint trap fmatmul fpmix'.split()

VALID = [  # label, model knobs
    ('v_lsq0', dict(lsq=0, handoff=False, early=False, lsu_bypass=False)),
    ('v_hand0', dict(handoff=False)),
    ('v_early0', dict(early=False)),
    ('v_byp0', dict(bypass=False)),
    ('v_sb2', dict(sb=2)),
    ('v_fs0', dict(iq=4, fe='ideal', fe_rate=2)),
]

CONFIGS = [  # name, knobs
    ('fe-ideal', dict(fe='ideal')),
    ('ooo rs4', dict(rs=4)),
    ('ooo rs8', dict(rs=8)),
    ('ooo rs8 rob16', dict(rs=8, rob=16)),
    ('db1', dict(db=1)),
    ('w2 io rob8', dict(w=2, alu_ports=2)),
    ('w2 io', dict(w=2, alu_ports=2, rob=16)),
    ('w2 io fe-ideal', dict(w=2, alu_ports=2, rob=16, fe='ideal')),
    ('w2 ooo', dict(w=2, alu_ports=2, rob=16, rs=8)),
    ('w2 ooo fe-ideal', dict(w=2, alu_ports=2, rob=16, rs=8, fe='ideal')),
    ('w2 ooo rob32 fe-ideal', dict(w=2, alu_ports=2, rob=32, rs=16, fe='ideal')),
    ('w2 io db1', dict(w=2, alu_ports=2, rob=16, db=1)),
    ('w2 ooo db1 fe-ideal', dict(w=2, alu_ports=2, rob=16, rs=8, db=1, fe='ideal')),
]

RULES = dict(mem1=True, fp1=True, alone=True, p0=True, slot2=True, fpw1=True)
W2 = dict(w=2, alu_ports=2)

# (OX.0) the core as built after O4: two-wide with its pair rules, the 4-entry station, ROB 8, fitted on traces of the
# core itself (its issue cycles traced)
BASE_O4 = dict(BASE, rs=4, iss_res=True, **W2, **RULES)

VALID_O4 = [  # label, model knobs against BASE_O4: runs of the core with one thing changed (run_perf.sh --label ...)
    ('v_w1', dict(w=1, alu_ports=1)),
    ('v_rs0', dict(rs=0)),
    ('v_sb2', dict(sb=2)),
    ('v_fs0', dict(iq=4, fe='ideal', fe_rate=2)),
]

def cfg(*parts, **kw):
    out = {}
    for d in parts:
        out.update(d)
    out.update(kw)
    return out


XR = dict(xr=True)
MEM = dict(mem_ooo=True, engines=2, lq=8, sq=8, fwd=True, spec_ld=True, mdp='ideal')     # O5/6 at full stretch
FE = dict(fe='ideal', fe_blk=16, fe_taken=0)                                             # O8 at full stretch
CONFIGS_OX = [  # name, knobs against BASE_O4: what each milestone of the complete-OOO track would buy
    ('base', cfg()),                                                    # the fit replayed: must be +0.0% everywhere
    ('xr', cfg(XR)),                                                    # O3
    ('xr comb', cfg(XR, xr_lat=0)),                                     # D7
    ('xr nomp', cfg(XR, nomp=True)),                                    # what a mispredict costs (D5)
    ('xr fe8', cfg(XR, fe='ideal')),                                    # O8: one dword a cycle, bubbles as traced
    ('xr fe16', cfg(XR, FE)),                                           # O8: 16 bytes a cycle, no taken bubble
    ('xr mem-io fwd', cfg(XR, fwd=True, mem_ooo=True, engines=1, lq=8, sq=8)),
    ('xr mem nospec', cfg(XR, MEM, spec_ld=False)),
    ('xr mem none', cfg(XR, MEM, mdp='none')),                          # D6
    ('xr mem waitbit', cfg(XR, MEM, mdp='waitbit')),
    ('xr mem', cfg(XR, MEM)),                                           # O5/6
    ('xr mem mshr4', cfg(XR, MEM, mshr=4)),
    ('xr rob16 rs8', cfg(XR, rob=16, rs=8)),                            # O7 alone
    ('xr fe16 mem mshr4', cfg(XR, FE, MEM, mshr=4)),
    ('xr fe16 mem mshr4 rob16 rs8', cfg(XR, FE, MEM, mshr=4, rob=16, rs=8)),   # O7 on top
    ('xr fe16 mem mshr4 rob32 rs16', cfg(XR, FE, MEM, mshr=4, rob=32, rs=16)),
    ('L20', cfg(miss_add=20)),                                          # a slower memory (D1's L=20)
    ('L20 xr fe16', cfg(XR, FE, miss_add=20)),
    ('L20 xr mem mshr4', cfg(XR, MEM, mshr=4, miss_add=20)),
]

CONFIGS_O4 = [  # name, knobs: two-wide with the pair rules (O4.0)
    ('ooo rs4', dict(rs=4)),
    ('commit2 rob8 rs4', dict(w=2, rs=4, dispatch1=True, slot2=True, fpw1=True)),
    ('w2 io rob16', dict(W2, rob=16)),
    ('w2 ooo free rob16 rs8', dict(W2, rob=16, rs=8)),
    ('mem1', dict(W2, rob=16, rs=8, mem1=True)),
    ('fp1', dict(W2, rob=16, rs=8, fp1=True)),
    ('alone', dict(W2, rob=16, rs=8, alone=True)),
    ('p0', dict(W2, rob=16, rs=8, p0=True)),
    ('slot2', dict(W2, rob=16, rs=8, slot2=True)),
    ('fpw1', dict(W2, rob=16, rs=8, fpw1=True)),
    ('rules rob16 rs8', dict(W2, **RULES, rob=16, rs=8)),
    ('rules rob16 rs4', dict(W2, **RULES, rob=16, rs=4)),
    ('rules rob8 rs4', dict(W2, **RULES, rob=8, rs=4)),
    ('rules rob8 rs4 ideal', dict(W2, **RULES, rob=8, rs=4, fe='ideal')),
    ('rules rob16 rs8 ideal', dict(W2, **RULES, rob=16, rs=8, fe='ideal')),
    ('rules rob16 rs8 ideal db1', dict(W2, **RULES, rob=16, rs=8, fe='ideal', db=1)),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--traces', required=True)
    ap.add_argument('--validate', help='directory of baseline_pipe[_s]_<label>.csv runs with one knob changed')
    ap.add_argument('--base', help="the traced runs' cycles (default: verification/perf/baseline_pipe[_s].csv by --mode)")
    ap.add_argument('--config', default='cache')
    ap.add_argument('--mode', default='m')
    ap.add_argument('--kernels', default=' '.join(KERNELS))
    ap.add_argument('--db', type=int, default=2, help='cycles from a drain beat to its response (2: the D$ passes a store through)')
    ap.add_argument('--set', default='o1', choices=('o1', 'o4', 'ox'),
                    help='o1: the O1.0 configurations; o4: two-wide with the pair rules; ox: the complete-OOO milestones')
    ap.add_argument('--fit', default='o1', choices=('o1', 'o4'),
                    help='o1: fit one-wide traces with the station off (O1.0, O4.0); o4: fit traces of the core as built '
                         'after O4 (two-wide, the station on, issue cycles traced: OX.0)')
    a = ap.parse_args()
    configs = {'o1': CONFIGS, 'o4': CONFIGS_O4, 'ox': CONFIGS_OX}[a.set]
    sfx = '_s' if a.mode == 's' else ''
    base = load_csv(a.base or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'baseline_pipe%s.csv' % sfx))
    fitp = dict(BASE_O4) if a.fit == 'o4' else dict(BASE)
    fitp['db'] = a.db
    valid = VALID_O4 if a.fit == 'o4' else VALID
    vals = {}
    if a.validate:
        for lab, _ in valid:
            f = os.path.join(a.validate, 'baseline_pipe%s_%s.csv' % (sfx, lab))
            if os.path.exists(f):
                vals[lab] = load_csv(f)
    hdr = ['kernel', 'cycles', 'fit', 'neg']
    hdr += ['%s (meas)' % lab for lab, _ in valid if lab in vals]
    hdr += [c for c, _ in configs]
    print('| ' + ' | '.join(hdr) + ' |')
    print('|' + '---|' * len(hdr))
    logs = {}
    for kern in a.kernels.split():
        path = os.path.join(a.traces, '%s%s_%s.ilp' % (kern, sfx, a.config))
        if not os.path.exists(path):
            continue
        tr = read_trace(path)
        if not tr:
            continue
        meas = int(base[(kern, a.config)]['cycles']) if (kern, a.config) in base else 0
        t0 = tr[-1].commit - meas if meas else None
        res = {}
        fitc, neg = sim(tr, dict(fitp), res, fit=True, t0=t0)
        row = [kern, str(meas), str(fitc), str(neg)]
        for lab, kn in valid:
            if lab not in vals:
                continue
            p = dict(fitp); p.update(kn)
            pc, _ = sim(tr, p, res, t0=t0)
            m = int(vals[lab][(kern, a.config)]['cycles']) if (kern, a.config) in vals[lab] else 0
            row.append('%+.1f%% (%+.1f%%)' % (100.0 * (pc - fitc) / fitc, 100.0 * (m - meas) / meas if meas else 0))
        for ci, (_, kn) in enumerate(configs):
            p = dict(fitp); p.update(kn)
            pc, _ = sim(tr, p, res, t0=t0)
            row.append('%+.1f%%' % (100.0 * (pc - fitc) / fitc))
            logs.setdefault(ci, []).append(math.log(pc / fitc))
        print('| ' + ' | '.join(row) + ' |')
    if logs:
        row = ['geomean', '', '', ''] + [''] * len([l for l, _ in valid if l in vals])
        row += ['%+.1f%%' % (100.0 * (math.exp(sum(v) / len(v)) - 1)) for ci, v in sorted(logs.items())]
        print('| ' + ' | '.join(row) + ' |')


if __name__ == '__main__':
    main()
