#!/usr/bin/env python3
"""ilp.py -- what would out-of-order issue (O1) and two-wide dispatch and commit (O4) buy on the perf kernels? (O1.0)

Reads the traces perf_tb writes under +ILPTRACE (run_perf.sh --ilptrace DIR): one line per instruction retired inside
a kernel's window, with the cycles it entered and left the instruction queue (push, pop), was issued (disp: the ROB
allocation), reached the LSU and started its access (acc, go), wrote back (cmpl) and committed, plus whether the aligner
redirected fetch after it, whether it trapped, the commit redirect it caused and its physical dword.

The model replays the retired stream through a dataflow machine with the core's structure:
  frontend   instructions are pushed into the instruction queue in order, at most fe_w (2) a cycle, no earlier than the
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

(W.0) Any width: w uops dispatch, cw retire and fe_w enter the IQ a cycle. A dispatch group follows the pair rules as
counts (mem_n memory ops, fp_n uops touching FP state; alone: a group of one), and so does a commit group (its older
members plain retirements; st_n posted stores, br_n branches, fpw_n FP-state writes). Ports by capability (alu_ports,
bru_ports, mul_ports, fpu_ports), `engines` in-order engines, dc_ports D$ hit lookups a cycle. Every default is the
two-wide core's rule, so the earlier configurations replay as they did. --check counts the cycles in which a replay
exceeds a width or the integer ports (a residual can break a cap the constraints keep).

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
from collections import OrderedDict

import brpred

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
                 'iss', 'ds', 'cs', 'fr', 'dcm', 'cond', 'src_a', 'prod_a')


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
            i.cond = brpred.decode(i.raw, i.pc, 0)[0] == 'cond'
            # (O5.0) a memory op's address base (rs1), for sta
            i.src_a = i.srcs[0] if (i.mem and i.srcs and i.srcs[0] != ('x', 0)) else None
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
        i.prod_a = last.get(i.src_a) if i.src_a is not None else None
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
            mshr=0, hit_lat=1, miss_add=0,
            # (O5.0) dports: loads the D$ port takes at once (two engines on one blocking D$ queue for it); dc_in: the D$
            # inside the core (a hit is read in the engine's first cycle, takes no port, holds no drain off, and the
            # engine takes the next op in that cycle; a miss refills over the port); nomiss: every load hits; cwf: a
            # refill answers its load with the first beat (the requested word), a later load to that line takes its
            # word as its beat arrives, other lines wait for the refill; nb: (dc_in) a miss parks in one of `mshr`
            # handlers and frees the engine, hits to other lines go on, refills one at a time; eng_pipe: one bus
            # request a cycle (a pipelined engine on a pipelined bus); sta: a store's address is known once its
            # address operand is (O6a's address/data split); ld_order: (mem_ooo) 'po' loads in program order among
            # themselves, 'any' not; replay_at: a violation replays at execute ('x': `replay` cycles after the
            # store's address) or at commit ('c': the load is refetched when it reaches the head); dc_kib: a
            # direct-mapped write-through no-allocate D$ of that size replayed on the traced addresses replaces the
            # traced hits and misses (dc_warm: warmed by one pass over the trace first); early_st: plain stores post
            # before the head
            dports=1, dc_in=False, nomiss=False, cwf=False, nb=False, eng_pipe=False, sta=False, ld_order='any',
            replay_at='x', dc_kib=0, dc_warm=False, early_st=True,
            # (OX.0) frontend: fe_blk, the bytes fetched a cycle with fe='ideal'; fe_taken, the bubble after a taken
            # branch the aligner redirected on (None: as traced); nomp: no mispredicts (what one costs)
            fe_blk=8, fe_taken=None, nomp=False,
            # (OX.0) fe='ideal' details: fb, the fetch buffer's blocks (a block is fetched only once the block fb
            # before it has been used up); iq_room2, the aligner pushes only with room for two in the IQ (fetch
            # streaming off); al1dw, the aligner as built: two pushes in one cycle only from one block, the one each
            # ends in (a crossing instruction pairs with the next one), and a crossing instruction's first half is
            # stashed in one of the cycle's two slots before it goes (after a pair: a cycle later); fe_btb, the bubble after a taken branch that
            # crosses into the next block and that the aligner did not redirect on (the frontend as built: a cycle)
            fb=4, iq_room2=False, al1dw=False, fe_btb=0,
            # (O8.0) bp: a brpred.FE_CONFIGS name; each branch's class (steer, ared, phantom, mis, ok) replaces the
            # traced one: a mispredict recovers (with the refill measured in the fit when the trace has none there),
            # an aligner redirect or a phantom costs the traced bubble (its mean where the trace has none); al_ntk: the
            # aligner pairs nothing across a taken branch (the window aligner without pair_taken); al_cond1: at most one
            # conditional branch per aligner cycle (one history per cycle)
            bp=None, al_ntk=False, al_cond1=False,
            # (W.0) any width. cw: the commit width (None: w); fe_w: IQ pushes a cycle; al_cond_n: conditional branches
            # per aligner cycle (None: al_cond1's one, else any). Group rules: mem_n / fp_n, memory ops / uops touching
            # FP state in a dispatch group; fpw_n / st_n / br_n, FP-state writes / posted stores / branches in a commit
            # group (None: mem1's, fp1's, fpw1's one, else any; a commit group's older members are plain retirements).
            # Ports: bru_ports / mul_ports, the ports with a branch unit / a multiplier (with p0 they are nested, port 0
            # first: a branch and a multiply share max of the two); fpu_ports, FPU pipes. engines also counts for the
            # in-order engine (ops taken in program order, that many in flight); dc_ports: D$ hit lookups a cycle
            # (None: any); fb_bytes: the fetch buffer in bytes (None: fb blocks). book_iss: a port is booked in the
            # issue cycle (the traced one in the fit, the constraint's plus the residual in a replay), not the
            # constraint's. Sensitivity: res_clamp, a negative pop, dispatch or commit residual is not added back
            cw=None, fe_w=2, al_cond_n=None, mem_n=None, fp_n=None, fpw_n=None, st_n=1, br_n=1,
            bru_ports=1, mul_ports=1, fpu_ports=1, dc_ports=None, fb_bytes=None, book_iss=False, res_clamp=False)


class DPort:
    """The memory port behind the LSU: the blocking write-through D$, shared by loads and the store buffer's drain.
    A load holds it from its start to its writeback. A drain beat, decided at cycle s, holds it until its response at
    s + DB (the next beat may be decided in that cycle); the LSU may not start in [s, s + DB]. The drain never
    starts while a load is in flight or ready to start, unless the buffer is full or has waited YIELD cycles.
    Beats are scheduled lazily, in time order, as the loads that might go before them are placed."""

    def __init__(self, depth, db, yield_max=16, dports=1):
        self.depth, self.db, self.ymax, self.dports = depth, db, yield_max, dports
        self.sb = []            # [ready, go, resp, addr, idx] of each posted store, in order (idx: its instruction)
        self.liv = []           # (O5.0) (go, end) of the loads on the port: dports of them at once
        self.nd = 0             # the first one whose beat is not scheduled
        self.drain_avail = 0    # the next beat may be decided from here (the last one's response)
        self.load_end = -1      # the last load's writeback
        self.beats = []         # (s, resp) of the scheduled beats
        self.last = {}          # addr -> the index of the last posted store to it

    def push(self, ready, addr, idx=None):
        self.last[addr] = len(self.sb)
        self.sb.append([ready, None, None, addr, idx])

    def _start(self, e):
        return max(e[0], self.drain_avail, self.load_end + 1)

    def _cnt(self, x):
        """entries in the buffer at cycle x (one leaves at the edge after its response). Beats are scheduled in order,
        each from the last one's response on, so the responses grow with the index: the scheduled entries still there
        at x are the last few scheduled, and the walk back stops at the first one gone"""
        n = sum(1 for e in self.sb[self.nd:] if e[0] <= x)
        i = self.nd - 1
        while i >= 0 and self.sb[i][2] >= x:
            n += self.sb[i][0] <= x
            i -= 1
        return n

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
            busy = [e for (g, e) in self.liv if g <= t <= e]
            if len(busy) >= self.dports:                    # (O5.0) every port holds a load
                t, moved = min(busy) + 1, True
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
        self.liv.append((go, cmpl))
        if len(self.liv) > 64:
            self.liv.pop(0)

    def resp_of(self, i):
        while self.sb[i][2] is None:
            self._sched()
        return self.sb[i][2]

    def last_store_to(self, addr):
        return self.last.get(addr)

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
    CW = p['cw'] if p['cw'] is not None else W                  # (W.0) the commit width
    FW = p['fe_w']                                              # ... IQ pushes a cycle
    n_cond = p['al_cond_n'] if p['al_cond_n'] is not None else (1 if p['al_cond1'] else None)
    n_mem = p['mem_n'] if p['mem_n'] is not None else (1 if p['mem1'] else None)
    n_fp = p['fp_n'] if p['fp_n'] is not None else (1 if p['fp1'] else None)
    n_fpw = p['fpw_n'] if p['fpw_n'] is not None else (1 if p['fpw1'] else None)
    n_fb = max(1, p['fb_bytes'] // p['fe_blk']) if p['fb_bytes'] else p['fb']
    E_io = 1 if p['mem_ooo'] else p['engines']                  # engines taking ops in program order
    push = [0] * n; pop = [0] * n; disp = [0] * n; iss = [0] * n
    acc = [0] * n; go = [0] * n; cmpl = [0] * n; com = [0] * n
    if fit:
        for k in ('push', 'pop', 'disp', 'acc', 'go', 'com', 'lat', 'bus', 'iss'):
            res[k] = [0] * n
    trim = 4 * max(16, p['rob'], p['rs'])       # how far back the occupancy lists look
    ports = {}                      # (port, cycle) -> uses
    # p0: branches (p0b) and multiplies (p0m) on their own ports, nested from port 0, so together on max of the two
    cap = {'alu': p['alu_ports'], 'bru': p['bru_ports'], 'fpu': p['fpu_ports'],
           'p0': max(p['bru_ports'], p['mul_ports']), 'p0b': p['bru_ports'], 'p0m': p['mul_ports']}
    hit_go = []                     # (dc_ports) the cycles D$ hits were read in
    rs_occ = []                     # (disp, issue) of uops that waited in the RS
    last_div = None; last_fds = None
    mem_idx = []                    # indices of memory ops, in order
    dc = DPort(p['sb'], p['db'], dports=p['dports'])
    t_open = t0 if t0 is not None else (tr[0].commit - 1 if tr else 0)
    seg_start = t_open
    fe_blks = []                    # (fe ideal) the current stream's blocks: [block, arrival, last use]
    fe_k0 = 0                       # (fe ideal) the stream's first instruction
    neg = 0
    ld_idx = []; st_idx = []        # (lq/sq) the loads and the stores, in order
    eng_iv = []                     # (mem_ooo) (take, free) of the ops in the engines
    eng_free = [0] * n              # when the engine may take the next op after op k
    rdy = [0] * n                   # a memory op's operands are ready
    refills = []                    # (O5.0) (go, end, line, word, lat) of the refills
    dcsim = dc_replay(tr, p['dc_kib'], p['dc_warm']) if p['dc_kib'] else None
    miss_lat_s = []                 # (fit) the traced refills' latency
    miss_iv = []                    # (mshr) the misses in flight: (go, cmpl)
    waitbit = set()                 # (mdp waitbit) the loads that violated
    replay_at = None                # a load violated: what follows it restarts from here
    shift = max(3, (p['fe_blk'] - 1).bit_length())
    bpc = bp_classes(tr, p['bp']) if p['bp'] else None
    st = res.setdefault('stats', {}) if res is not None else {}
    refill_s = []; ared_s = []      # (fit) the traced refill after a recovery, and the bubble after an aligner redirect

    def redir_of(q):
        """the commit redirect an instruction causes in this configuration (nomp: never a mispredict; bp: as its
        class says)"""
        if bpc is not None and id(q) in bpc:
            if bpc[id(q)] == 'mis':
                return q.redir if q.redir in (1, 4) else 4
            return 0 if q.redir in (1, 4) else q.redir
        return 0 if (p['nomp'] and q.redir in (1, 4)) else q.redir

    def cls_of(q):
        return bpc.get(id(q)) if bpc is not None else None

    def bubble(q, k):
        """the aligner-redirect bubble after tr[k - 1]: fe_taken, else as traced, else the traced mean"""
        if p['fe_taken'] is not None:
            return p['fe_taken']
        return (q.push - tr[k - 1].push) if tr[k - 1].ared else st.get('ared', 2)

    def dmiss(k, q):
        """(O5.0) the load misses the D$ in this configuration"""
        if p['nomiss']:
            return False
        if dcsim is not None:
            return dcsim.get(k, False)
        return bool(q.dcm)

    def eng_place(c):
        """(mem_ooo) the first cycle from c at which one of `engines` is free"""
        while True:
            busy = [e for (a, e) in eng_iv if a <= c < e]
            if len(busy) < p['engines']:
                return c
            c = min(busy)

    def refill_wait(addr, c):
        """(O5.0) an in-core D$ hit at c during a refill: its own line's words as their beats arrive (cwf), else
        after the refill; other lines go on only with handlers (nb), else after it"""
        for (g, e, line, w0, lt) in reversed(refills[-4:]):
            if not (g <= c <= e):
                continue
            if (addr >> 5) == line:
                if p['cwf']:
                    j = (((addr >> 3) & 3) - w0) % 4
                    return max(c, g + 1 + max(1, (lt - 1) // 4) * (j + 1))
                return e + 1
            if not p['nb']:
                return e + 1
        return c

    def sta_known(s):
        """(sta) when store s's address is known: its address operand's producer, else its dispatch"""
        j = tr[s].prod_a
        return max(disp[s], avail(j) if j is not None else 0) + 1

    def rs_held(c):
        """the station entries a uop dispatching in cycle c finds taken: those in it during c and, with book_iss
        (W.0), those the older uops of its own dispatch group take in c (qv_rs: two pushes need o_room2, two free)"""
        if p['book_iss']:
            return sum(1 for (d, i) in rs_occ if d <= c <= i)
        return sum(1 for (d, i) in rs_occ if d < c <= i)

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
        if p['p0'] and q.cls == 'bru': return 'p0b'
        if p['p0'] and q.mul: return 'p0m'
        if q.cls in ('bru',): return 'bru'
        if q.cls in ('fpu',): return 'fpu'
        if q.cls in ('div', 'fds', 'lsu'): return None
        return 'alu'

    INT = ('alu', 'bru', 'p0b', 'p0m')

    def free_port(pt, t):
        """the first cycle from t at which port pt has room"""
        if pt is None:
            return t
        while (ports.get((pt, t), 0) >= cap[pt]
               or (pt in ('p0b', 'p0m') and ports.get(('p0', t), 0) >= cap['p0'])
               or (pt in INT and ports.get(('int', t), 0) >= p['alu_ports'])):
            t += 1
        return t

    def take_port(pt, t, exact=False):
        """book port pt in the first cycle from t with room (exact: in cycle t, as traced, room or not)"""
        if pt is None:
            return t
        if not exact:
            t = free_port(pt, t)
        ports[(pt, t)] = ports.get((pt, t), 0) + 1
        if pt in ('p0b', 'p0m'):
            ports[('p0', t)] = ports.get(('p0', t), 0) + 1
        if pt in INT:
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
        if p['res_clamp'] and name in ('pop', 'disp', 'com'):
            return cons + max(0, res[name][k])                # (W.0) sensitivity: no negative residual
        return cons + res[name][k]

    for k, q in enumerate(tr):
        prev = tr[k - 1] if k else None
        prev_redir = prev is not None and (redir_of(prev) or prev.trap)
        blk = q.pc >> shift
        bhi = (q.pc + (2 if q.rvc else 4) - 1) >> shift   # a crossing instruction needs the next block too
        # ---- frontend: push into the IQ ----
        if prev_redir:
            seg_start = com[k - 1]
            if p['xr'] and redir_of(prev) in (1, 4) and not prev.trap:
                seg_start = min(seg_start, cmpl[k - 1] + p['xr_lat'])     # recovered at execute (O3)
            c = seg_start
            fe_blks = []
            fe_k0 = k
        else:
            c = seg_start if k == 0 else push[k - 1]
            if k >= FW and push[k - FW] >= c:
                c = max(c, push[k - FW] + 1)                  # at most fe_w pushes a cycle
            if k >= p['iq']:
                c = max(c, pop[k - p['iq']] + 1)              # room in the IQ
            if p['iq_room2'] and k + 1 >= p['iq']:
                c = max(c, pop[k + 1 - p['iq']] + 1)          # the aligner waits for room for two
            if (p['fe'] == 'ideal' and p['al1dw'] and k > 0 and push[k - 1] >= c
                    and bhi != ((prev.pc + (2 if prev.rvc else 4) - 1) >> shift)):
                c = max(c, push[k - 1] + 1)                   # a pair only from one block
            if p['al_ntk'] and k > 0 and push[k - 1] >= c and q.pc != prev.pc + (2 if prev.rvc else 4):
                c = max(c, push[k - 1] + 1)                   # no pair across a taken branch
            if n_cond is not None and k > 0 and push[k - 1] >= c and q.cond:
                j, nc = k - 1, 0
                while j >= fe_k0 and push[j] == push[k - 1]:
                    nc += tr[j].cond
                    j -= 1
                if nc >= n_cond:
                    c = max(c, push[k - 1] + 1)               # al_cond_n conditional branches per aligner cycle
            if (p['fe'] == 'ideal' and p['al1dw'] and k > fe_k0 and bhi != blk
                    and q.pc == prev.pc + (2 if prev.rvc else 4)):
                pair = k - 2 >= fe_k0 and push[k - 2] == push[k - 1]
                c = max(c, push[k - 1] + (2 if pair else 1))  # its first half was stashed after the last push
            if p['fe'] == 'ideal' and fe_blks and k > 0:
                seq = q.pc == prev.pc + (2 if prev.rvc else 4)
                b = fe_blks[-1][0] + 1 if seq else blk
                while b <= bhi:                               # each block not fetched yet: fe_rate cycles after the
                    t = fe_blks[-1][1] + p['fe_rate']         # last one, once the fetch buffer has room for it
                    if (not seq and b == blk and not prev.ared
                            and ((prev.pc + (2 if prev.rvc else 4) - 1) >> shift) != (prev.pc >> shift)):
                        t += p['fe_btb']                      # a taken crossing branch the aligner did not redirect on
                    if len(fe_blks) >= n_fb:
                        t = max(t, fe_blks[-n_fb][2] + 1)
                    ared_prev = (cls_of(prev) == 'ared') if cls_of(prev) is not None else prev.ared
                    if not seq and b == blk and ared_prev:    # the bubble after a taken branch the aligner
                        t = max(t, push[k - 1] + bubble(q, k))   # redirected on
                    fe_blks.append([b, t, t])
                    b += 1
                c = max(c, fe_blks[-1][1])
                if cls_of(prev) == 'phantom' and blk != (prev.pc >> shift):
                    c = max(c, push[k - 1] + bubble(q, k))    # the aligner turned a steered fetch back
        if replay_at is not None:
            c = max(c, replay_at)                             # a load before it violated: refetched from there
            replay_at = None
        nomp_skip = prev is not None and prev.redir in (1, 4) and not prev.trap and redir_of(prev) == 0
        if not fit and (nomp_skip or (p['fe'] == 'ideal' and not prev_redir and k > 0)):
            push[k] = c                                         # no frontend residual within a fetch stream
        elif not fit and prev_redir and not prev.trap and prev.redir == 0:
            push[k] = c + st.get('refill', 4)                   # a mispredict the trace does not have
        else:
            push[k] = put('push', k, c, q.push)
        if fit and prev_redir and not prev.trap and prev.redir in (1, 4):
            refill_s.append(res['push'][k])
        if fit and k > 0 and not prev_redir and prev.ared:
            ared_s.append(q.push - prev.push)
        if p['fe'] == 'ideal' and not fit:
            nb = bhi - blk + 1
            if not fe_blks:                                   # a stream starts: its first blocks arrive with it
                fe_blks = [[b, push[k], push[k]] for b in range(blk, bhi + 1)]
            elif push[k] > c:                                 # a traced bubble was kept: the blocks came that late
                for e in fe_blks[-nb:]:
                    e[1] = max(e[1], push[k])
            for e in fe_blks[-nb:]:
                e[2] = push[k]                                # the block's last use so far
            if len(fe_blks) > 4 * n_fb + 4:
                del fe_blks[:len(fe_blks) - (4 * n_fb + 4)]
        # ---- decode ----
        c = push[k] + 1
        if k >= 1: c = max(c, pop[k - 1] + (1 if W == 1 else 0))
        if W >= 2 and k >= W: c = max(c, pop[k - W] + 1)    # W a cycle
        if k >= W: c = max(c, disp[k - W])                    # decode holds W uops until they dispatch
        pop[k] = put('pop', k, c, q.pop)
        # ---- dispatch ----
        c = pop[k] + 1
        if k >= 1: c = max(c, disp[k - 1] + (1 if W == 1 else 0))
        if W >= 2 and k >= W: c = max(c, disp[k - W] + 1)
        if p['dispatch1'] and k >= 1: c = max(c, disp[k - 1] + 1)
        # (in the fit too: a two-wide trace is fitted with its rules, or a replay would count a split pair twice)
        if W >= 2 and k >= 1 and disp[k - 1] >= c:
            grp = []                                          # would join the group dispatching in that cycle: the
            j = k - 1                                         # group rules (O4's pair rules, W.0's counts)
            while j >= 0 and j > k - W and disp[j] == disp[k - 1]:
                grp.append(tr[j])
                j -= 1
            if ((n_mem is not None and q.cls == 'lsu' and sum(1 for g in grp if g.cls == 'lsu') >= n_mem)
                    or (n_fp is not None and q.fp and sum(1 for g in grp if g.fp) >= n_fp)
                    or (p['alone'] and (q.alone or any(g.alone for g in grp)))):
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
                while rs_held(c) >= p['rs']:
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
                    while rs_held(disp[k]) >= p['rs']:
                        disp[k] += 1
                    t = earliest(disp[k])
                    if t > disp[k] and not p['book_iss']:
                        rs_occ.append((disp[k], t))
                        if len(rs_occ) > trim:
                            rs_occ.pop(0)
                if p['book_iss'] and p['iss_res']:
                    icons = None                              # (W.0) booked below, in its issue cycle
                else:
                    icons = take_port(pt, t)
            if icons is None and fit:
                # the fit books the traced issue cycle, so a later op's constraint sees the ports as they were taken
                # (booked at the constraint cycle, a wait for a busy port would become part of the residual)
                iss[k] = put('iss', k, free_port(pt, t), q.iss)
                take_port(pt, iss[k], exact=True)
            elif icons is None:
                iss[k] = take_port(pt, free_port(pt, t) + res['iss'][k])
            else:
                iss[k] = put('iss', k, icons, q.iss) if p['iss_res'] else icons
            if p['book_iss'] and p['rs'] > 0 and iss[k] > disp[k]:
                # (W.0) its station entry is held to its issue as it happens (traced in the fit), not to the
                # constraint's: else a full station's wait would become a dispatch residual
                rs_occ.append((disp[k], iss[k]))
                if len(rs_occ) > trim:
                    rs_occ.pop(0)
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
            rdy[k] = c
            eligible = (p['early'] and p['lsq'] > 0 and q.mem in ('ld', 'st') and not q.trap
                        and (q.mem == 'ld' or p['early_st']))
            ooo = p['mem_ooo'] and eligible
            is_ld = q.mem == 'ld' and not q.trap
            miss = is_ld and dmiss(k, q)
            dc_hit = p['dc_in'] and is_ld and not miss
            pm = mem_idx[-1] if mem_idx else None
            if ooo:
                # (OX.0) out-of-order memory: one of `engines` free, not after the older ops ...
                if p['ld_order'] == 'po' and q.mem == 'ld' and ld_idx:
                    c = max(c, acc[ld_idx[-1]])               # (O5.0) ... but after an older load
                c = eng_place(c)
            elif pm is not None and E_io > 1:
                c = max(c, acc[pm])                           # (W.0) engines in program order: that many in flight
                if len(mem_idx) >= E_io:
                    c = max(c, eng_free[mem_idx[-E_io]])
            elif pm is not None:
                c = max(c, eng_free[pm])
            acc[k] = put('acc', k, c, q.acc if q.acc else q.disp)
            if fit and is_ld and pm is not None and acc[k] > rdy[k] and acc[k] == eng_free[pm]:
                # (O5.0) a load with its operands waiting for the engine: what held the op before it
                pe = tr[pm]
                why = ('head' if not (p['early'] and pe.mem in ('ld', 'st') and not pe.trap)
                       else ('ld' if pe.mem == 'ld' else 'st') if acc[pm] == rdy[pm] and rdy[pm] > disp[pm]
                       else 'busy')
                st['ldb_' + why] = st.get('ldb_' + why, 0) + acc[k] - rdy[k]
            c = acc[k] + 1
            if not eligible:
                c = max(c, (com[k - 1] + 1) if k else c)      # at the head
            if fit:
                res['bus'][k] = q.cmpl - (q.go if q.go else q.cmpl)
                if is_ld and q.dcm:
                    miss_lat_s.append(res['bus'][k])
            lat = res['bus'][k]
            if is_ld and miss != bool(q.dcm):
                lat = st.get('miss_lat', 9) if miss else 1    # (O5.0) the D$ outcome changed (dc_kib, nomiss)
            if miss:
                lat += p['miss_add']
            efree = None                                      # (O5.0) when the engine may take the next op
            if is_ld:
                hold = c
                fwd_from = None
                viol = None
                if ooo:
                    # the older stores still in flight: an unknown address holds the load (unless it speculates),
                    # a known one to its dword forwards (fwd) or makes it wait for the drain
                    for s in reversed(st_idx):
                        if com[s] < c:
                            break
                        known = sta_known(s) if p['sta'] else acc[s] + 1
                        same = tr[s].addr == q.addr
                        if known > c:
                            wait = (not p['spec_ld'] or (p['mdp'] == 'ideal' and same)
                                    or (p['mdp'] == 'waitbit' and q.pc in waitbit))
                            if wait:
                                c = max(c, known)
                            elif same:
                                viol = max(viol or 0, known)  # a violation
                                if p['mdp'] == 'waitbit':
                                    waitbit.add(q.pc)
                        if same and p['fwd'] and fwd_from is None:
                            fwd_from = s
                    hold = c
                if fwd_from is not None:
                    c = max(c, go[fwd_from])                  # its bytes merged when the store has its data
                else:
                    # a load waits for an older store to its dword to leave the store buffer, then for the D$;
                    # (O5.0) with fwd it takes the buffer's bytes instead
                    m = dc.last_store_to(q.addr)
                    if m is not None and p['fwd'] and (dc.sb[m][2] is None or dc.sb[m][2] + 1 > c):
                        if dc.sb[m][4] is not None:
                            c = max(c, go[dc.sb[m][4]])
                    elif m is not None and not p['fwd'] and dc.resp_of(m) + 1 > c:
                        c = hold = dc.resp_of(m) + 1
                    elif not eligible:
                        # a load waiting for the head holds the drain off once it is among the three oldest
                        hold = max(acc[k] + 1, (com[k - 3] + 1) if k >= 3 else acc[k] + 1)
                if miss and p['mshr'] > 0:
                    while sum(1 for (a, b) in miss_iv if a <= c < b) >= p['mshr']:
                        c += 1                                # every miss handler is busy
                if dc_hit:
                    # (O5.0) the D$ in the core: read in the engine's first cycle, no port, no drain held off
                    c = refill_wait(q.addr, c)
                    if p['dc_ports'] is not None:
                        while sum(1 for g in hit_go[-8:] if g == c) >= p['dc_ports']:
                            c += 1                            # (W.0) every D$ lookup of the cycle is taken
                    go[k] = put('go', k, c, q.go if q.go else q.cmpl)
                    if p['dc_ports'] is not None:
                        hit_go.append(go[k])
                    cmpl[k] = go[k] + max(0, lat - 1)
                    efree = cmpl[k] if (p['handoff'] and p['lsq'] > 0) else cmpl[k] + 1
                else:
                    if miss and (p['dc_in'] or p['mshr'] > 0) and refills:
                        c = max(c, refills[-1][1] + 1)        # refills one at a time
                    gcons = dc.place_load(c, hold)
                    if fit and gcons > c:
                        st['ld_drain'] = st.get('ld_drain', 0) + gcons - c
                    go[k] = put('go', k, gcons, q.go if q.go else q.cmpl)
                    end = go[k] + lat                         # its access's end (a refill's last beat)
                    cmpl[k] = end
                    if miss:
                        if p['cwf']:
                            cmpl[k] = go[k] + 1 + max(1, (lat - 1) // 4)    # the requested word comes first
                        refills.append((go[k], end, q.addr >> 5, (q.addr >> 3) & 3, lat))
                        if len(refills) > 16:
                            refills.pop(0)
                        if p['nb'] and p['dc_in']:
                            efree = go[k]                     # parked in a handler: the engine goes on
                    if p['dc_in'] and miss:
                        dc.load_done(go[k], end)              # the refill holds the port to its last beat
                    elif p['eng_pipe'] and not miss:
                        dc.load_done(go[k], go[k])            # a pipelined bus: one request a cycle
                        efree = go[k]
                    else:
                        # a blocking D$ is busy until the load's data; a non-blocking one only for a hit's time
                        dc.load_done(go[k], cmpl[k] if p['mshr'] == 0 else go[k] + p['hit_lat'])
                if viol is not None:
                    if p['replay_at'] == 'c':
                        # (O5.0) replayed at commit: refetched when it reaches the head
                        t = max(com[k - 1] if k else 0, cmpl[k]) + 1 + st.get('refill', 4)
                        replay_at = max(replay_at or 0, t)
                        cmpl[k] = max(cmpl[k], t + 3)
                    else:
                        replay_at = max(replay_at or 0, viol + p['replay'])
                if replay_at is not None and replay_at > cmpl[k]:
                    cmpl[k] = replay_at                       # it ran again after the violation
                if miss and p['mshr'] > 0:
                    miss_iv.append((go[k], end))
                    if len(miss_iv) > trim:
                        miss_iv.pop(0)
            else:
                go[k] = put('go', k, c, q.go if q.go else q.cmpl)
                cmpl[k] = go[k] + lat
            if efree is None:
                hand = p['handoff'] and p['lsq'] > 0 and (q.posted or (q.go and q.cmpl > q.go))
                efree = cmpl[k] if hand else cmpl[k] + 1
            eng_free[k] = efree
            if p['mem_ooo']:
                eng_iv.append((acc[k], efree))
                if len(eng_iv) > trim:
                    eng_iv.pop(0)
            mem_idx.append(k)
            if q.mem == 'st':
                st_idx.append(k)
            else:
                ld_idx.append(k)
        # ---- commit ----
        c = cmpl[k] + 1
        if k >= 1:
            c = max(c, com[k - 1] + 1)
            if CW >= 2:
                g = []                                        # the group retiring in com[k - 1]'s cycle (or, where a
                j = k - 1                                     # negative residual put an older one later, that one too)
                while j >= 0 and com[j] >= com[k - 1] and len(g) < CW:
                    g.append(tr[j])
                    j -= 1
                join = (len(g) < CW
                        and all(not (x.trap or redir_of(x) or x.cls in ('csr', 'sys', 'fence')) for x in g)
                        and sum(1 for x in g if x.posted) + q.posted <= p['st_n']
                        and sum(1 for x in g if x.cls == 'bru') + (q.cls == 'bru') <= p['br_n'])
                if p['slot2'] and (q.trap or q.cls in ('csr', 'sys', 'fence')): join = False
                if n_fpw is not None and q.fpw and sum(1 for x in g if x.fpw) >= n_fpw: join = False
                if join:
                    c = max(cmpl[k] + 1, com[k - 1])
        if q.posted and p['sb'] > 0:
            c = max(c, dc.room_at(c))                         # the store buffer has room for it
        com[k] = put('com', k, c, q.commit)
        if q.posted:
            dc.push(com[k] + 1, q.addr, k)
    if fit:
        st['refill'] = round(sum(refill_s) / len(refill_s)) if refill_s else 4
        st['ared'] = round(sum(ared_s) / len(ared_s)) if ared_s else 2
        st['miss_lat'] = round(sum(miss_lat_s) / len(miss_lat_s)) if miss_lat_s else 9
        st['dcm_n'] = len(miss_lat_s)
    if p.get('_dbg') is not None:                   # (debugging) the replayed cycles, for a caller to compare
        p['_dbg'].update(push=push, pop=pop, disp=disp, com=com, iss=iss, port=[port_of(q) for q in tr])
    return com[-1] - t_open, neg


def count_caps(dbg, p):
    """(W.0, --check) the cycles of a replay (sim's _dbg) in which more instructions dispatched than w, retired than
    cw, entered the IQ than fe_w, or issued to the integer ports than alu_ports: residuals can break a cap that the
    constraints keep"""
    W = p['w']
    CW = p['cw'] if p['cw'] is not None else W
    out = {}
    for name, ev, lim in (('disp', dbg['disp'], W), ('com', dbg['com'], CW), ('push', dbg['push'], p['fe_w'])):
        n = {}
        for t in ev:
            n[t] = n.get(t, 0) + 1
        out[name] = sum(1 for v in n.values() if v > lim)
    n = {}
    for t, pt in zip(dbg['iss'], dbg['port']):
        if pt in ('alu', 'bru', 'p0b', 'p0m'):
            n[t] = n.get(t, 0) + 1
    out['int'] = sum(1 for v in n.values() if v > p['alu_ports'])
    return out


def dc_replay(tr, kib, warm):
    """(O5.0) a direct-mapped, write-through, no-allocate D$ of kib KiB (32-byte lines) replayed on the traced loads:
    {index: missed}; warm: one pass over the trace first"""
    nl = kib * 1024 // 32
    tags = [None] * nl

    def walk(record):
        out = {}
        for k, q in enumerate(tr):
            if q.mem in ('ld', 'amo') and not q.trap:
                line = q.addr >> 5
                i = line % nl
                hit = tags[i] == line
                if not hit:
                    tags[i] = line
                if record and q.mem == 'ld':
                    out[k] = not hit
        return out
    if warm:
        walk(False)
    return walk(True)


_BPC = {}


def bp_classes(tr, name):
    """(O8.0) {id(instruction): class} of the trace's control-flow instructions under brpred.FE_CONFIGS[name]"""
    # the entry holds the trace itself: keyed by id() alone, a later trace could reuse a freed one's id (and its
    # instructions those of its instructions) and be given another kernel's classes
    key = (id(tr), name)
    if key not in _BPC or _BPC[key][0] is not tr:
        brl, ks = [], []
        for k in range(len(tr) - 1):
            q = tr[k]
            if not q.trap and brpred.decode(q.raw, q.pc, 0)[0] is not None:
                # fetched about a cycle before its dword reached the fetch buffer; trains at its commit
                brl.append((q.pc, q.raw, tr[k + 1].pc, (q.fr or q.push) - 1, q.commit))
                ks.append(k)
        cl = brpred.FePred(**brpred.FE_CONFIGS[name]).classify(brl)
        _BPC[key] = (tr, {id(tr[k]): c for k, c in zip(ks, cl)})
    return _BPC[key][1]


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
    ('v_fs0', dict(iq=4, fe='ideal', fe_rate=2, fb=2, iq_room2=True, al1dw=True)),
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
# (O8.0) the core after O3: recovery at execute, fetch restarting in the mispredict's writeback cycle (XR_EARLY)
BASE_O3 = dict(BASE_O4, xr=True, xr_lat=0)

VALID_O4 = [  # label, model knobs against BASE_O4: runs of the core with one thing changed (run_perf.sh --label ...)
    ('v_w1', dict(w=1, alu_ports=1)),
    ('v_rs0', dict(rs=0)),
    ('v_sb2', dict(sb=2)),
    ('v_fs0', dict(iq=4, fe='ideal', fe_rate=2, fb=2, iq_room2=True, al1dw=True)),
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
    ('fe-core', cfg(fe='ideal', al1dw=True, fe_btb=1)),                 # the frontend model of the core as built: near 0
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

WIN = dict(fe='ideal', al_ntk=True)                       # O8b: the window aligner (no pair across a taken branch)
CONFIGS_O8 = [  # name, knobs against BASE_O3 (--fit o3): the frontend steps of O8, and D1's other milestones
    ('base', cfg()),                                                    # the fit replayed: +0.0 %
    ('fe-core', cfg(fe='ideal', al1dw=True, fe_btb=1)),                 # the core's own frontend: near 0
    ('fe-core bp', cfg(fe='ideal', al1dw=True, fe_btb=1, bp='rtl')),    # ... with its predictor modelled: near 0
    ('O8b', cfg(WIN, bp='rtl')),                                        # the window aligner
    ('O8b c1', cfg(WIN, bp='rtl', al_cond1=True)),
    ('O8b ptk', cfg(fe='ideal', bp='rtl')),                             # ... pairing across a taken branch too
    ('O8c', cfg(WIN, bp='ctr')),                                        # + the BTB's direction counter
    ('O8c ret', cfg(WIN, bp='ctr ret')),                                # + return entries
    ('O8a', cfg(WIN, bp='gshare', al_cond1=True)),                      # + gshare
    ('O8a nofb', cfg(WIN, bp='gshare nofb', al_cond1=True)),
    ('O8a h8', cfg(WIN, bp='gshare h8', al_cond1=True)),
    ('O8d', cfg(WIN, fe_blk=16, bp='gshare 16B', al_cond1=True)),       # + 16-byte blocks
    ('O8d w2', cfg(WIN, fe_blk=16, bp='gshare 16B w2', al_cond1=True)),
    ('O8 bound', cfg(fe='ideal', fe_blk=16, fe_taken=0, nomp=True)),    # no bubble, no mispredict
    ('O5/6', cfg(MEM, mshr=4)),
    ('O7', cfg(rob=16, rs=8)),
    ('O8a + O5/6', cfg(WIN, MEM, mshr=4, bp='gshare', al_cond1=True)),
]

# (O5.0) the core as it ships after O8 (O3 + the window aligner, the BTB counter and gshare): fitted on its own traces, so
# its frontend is in the residuals; the memory configurations of O5/6 against it
BASE_O8 = dict(BASE_O3)
VALID_O8 = [  # label, model knobs against BASE_O8: runs of the shipping core with one memory knob changed
    ('v_hand0', dict(handoff=False)),
    ('v_lsq2', dict(lsq=2)),
    ('v_est0', dict(early_st=False)),
    ('v_sb8', dict(sb=8)),
    ('v_dc_oracle', dict(dc_in=True, nomiss=True)),     # oracle_dc.sv (run_perf.sh --oracle dc), renamed
]
DC = dict(dc_in=True)                                     # O5a: the D$ in the core
OOO = dict(mem_ooo=True, engines=1, lsq=8)               # O6a: memory ops taken out of order by the one engine
SPEC = dict(spec_ld=True, mdp='none', replay_at='c')     # O6b: loads pass stores of unknown address
CONFIGS_O5 = [  # name, knobs against BASE_O8 (--fit o8)
    ('base', cfg()),                                                    # the fit replayed: +0.0 %
    ('dc', cfg(DC)),                                                    # D4
    ('dc nomiss', cfg(DC, nomiss=True)),                                # = the oracle (M0)
    ('eng_pipe', cfg(eng_pipe=True)),                                   # a pipelined engine on the bus (recorded)
    ('dc fwd', cfg(DC, fwd=True)),                                      # M2
    ('dc cwf', cfg(DC, cwf=True)),                                      # M4
    ('dc nb1', cfg(DC, nb=True, mshr=1)),                               # M5
    ('dc nb2', cfg(DC, nb=True, mshr=2)),
    ('dc nb4', cfg(DC, nb=True, mshr=4)),
    ('dc cwf nb2', cfg(DC, cwf=True, nb=True, mshr=2)),
    ('dc ooo po', cfg(DC, OOO, ld_order='po')),                         # M1
    ('dc ooo any', cfg(DC, OOO, ld_order='any')),                       # M1b
    ('dc ooo po fwd', cfg(DC, OOO, ld_order='po', fwd=True)),
    ('dc ooo sta', cfg(DC, OOO, ld_order='po', fwd=True, sta=True)),    # M3a
    ('dc ooo spec', cfg(DC, OOO, SPEC, ld_order='po', fwd=True)),       # M3 (replay at commit)
    ('dc ooo spec x4', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, replay_at='x', replay=4)),   # M3b
    ('dc ooo spec x8', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, replay_at='x', replay=8)),
    ('dc ooo spec x16', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, replay_at='x', replay=16)),
    ('dc ooo spec x32', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, replay_at='x', replay=32)),
    ('dc ooo spec wb', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, mdp='waitbit')),           # D6
    ('dc ooo spec ideal', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, mdp='ideal')),
    ('dc ooo 2ports', cfg(DC, OOO, ld_order='po', fwd=True, engines=2, dports=2)),            # M6
    ('dc all', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, cwf=True, nb=True, mshr=2)),
    ('bus fwd', cfg(fwd=True)),                                         # the fallback if D4 fails
    ('bus ooo', cfg(OOO, ld_order='po', fwd=True)),
    ('MEM', cfg(MEM, mshr=4)),                                          # the OX.0 configuration, on the fixed port
    ('dc lsq2', cfg(DC, lsq=2)),                                        # D2 sizes
    ('dc lsq8', cfg(DC, lsq=8)),
    ('dc ooo lsq4', cfg(DC, OOO, ld_order='po', fwd=True, lsq=4)),
    ('dc ooo lsq16 rob16', cfg(DC, OOO, ld_order='po', fwd=True, lsq=16, rob=16)),
    ('dc sb8', cfg(DC, sb=8)),
    ('dc 1k', cfg(DC, dc_kib=1)),
    ('dc 2k', cfg(DC, dc_kib=2)),                                       # the replayed D$ (cold) at its own size: ~ dc
    ('dc 4k', cfg(DC, dc_kib=4)),
    ('dc 8k', cfg(DC, dc_kib=8)),
    ('L20', cfg(miss_add=20)),                                          # (on L=1 traces) a slower memory
    ('L20 dc', cfg(DC, miss_add=20)),
    ('L20 dc cwf', cfg(DC, cwf=True, miss_add=20)),
    ('L20 dc nb4', cfg(DC, nb=True, mshr=4, miss_add=20)),
    ('L20 dc all', cfg(DC, OOO, SPEC, ld_order='po', fwd=True, cwf=True, nb=True, mshr=2, miss_add=20)),
]
# The frontend as it ships (the window aligner, one conditional branch a cycle) modelled, not kept as a residual: with
# memory faster, loops that were memory-bound become fetch-bound, and a residual frontend would hide that (it was
# measured with a full instruction queue). 'fe8' alone must replay the traces (near +0.0 %); every memory configuration
# and every validation row runs on top of it.
FE8 = dict(fe='ideal', al_ntk=True, al_cond1=True)
CONFIGS_O5 = [CONFIGS_O5[0], ('fe8', cfg(FE8))] + [(n, cfg(FE8, c)) for n, c in CONFIGS_O5[1:]]
VALID_O8 = [(n, cfg(FE8, c)) for n, c in VALID_O8]

# (O7b) the core with the D$ inside it (O5a) and the window O7b chose (ROB 32, RS 8, LSQ 8), fitted on its own traces;
# O5.0's memory rules re-run at the big window (O7 Decision 5: M1, M3 and the others), and the measured O7b size points
# as validation rows (each a window knob against the fit)
BASE_O7 = dict(BASE_O8, dc_in=True, rob=32, rs=8, lsq=8)
VALID_O7 = [(n, cfg(FE8, c)) for n, c in [
    ('r8s4q8', dict(rob=8, rs=4)),
    ('r16s8q8', dict(rob=16)),
    ('r32s8q16', dict(lsq=16)),
    ('r32s4q16', dict(rs=4, lsq=16)),
    ('r64s8q16', dict(rob=64, lsq=16)),
    ('r64s16q32', dict(rob=64, rs=16, lsq=32)),
]]
CONFIGS_O7 = [('base', cfg()), ('fe8', cfg(FE8))] + [(n, cfg(FE8, c)) for n, c in [
    ('ooo po', cfg(OOO, ld_order='po')),                                # M1
    ('ooo any', cfg(OOO, ld_order='any')),                              # M1b
    ('fwd', cfg(fwd=True)),                                             # M2
    ('ooo po fwd', cfg(OOO, ld_order='po', fwd=True)),
    ('ooo sta', cfg(OOO, ld_order='po', fwd=True, sta=True)),           # M3a
    ('ooo spec', cfg(OOO, SPEC, ld_order='po', fwd=True)),              # M3 (replay at commit)
    ('ooo spec x8', cfg(OOO, SPEC, ld_order='po', fwd=True, replay_at='x', replay=8)),    # M3b
    ('ooo spec wb', cfg(OOO, SPEC, ld_order='po', fwd=True, mdp='waitbit')),              # D6
    ('ooo spec ideal', cfg(OOO, SPEC, ld_order='po', fwd=True, mdp='ideal')),
    ('cwf', cfg(cwf=True)),                                             # M4
    ('nb2', cfg(nb=True, mshr=2)),                                      # M5
    ('nb4', cfg(nb=True, mshr=4)),
    ('ooo 2ports', cfg(OOO, ld_order='po', fwd=True, engines=2, dports=2)),               # M6
    ('ooo lsq16', cfg(OOO, ld_order='po', fwd=True, lsq=16)),
    ('ooo spec lsq16', cfg(OOO, SPEC, ld_order='po', fwd=True, lsq=16)),
    ('ooo spec rob64 lsq16', cfg(OOO, SPEC, ld_order='po', fwd=True, rob=64, lsq=16)),
    ('rs16', cfg(rs=16)),                                               # D2 (not measured alone)
    ('lsq16', cfg(lsq=16)),
    ('rob64', cfg(rob=64)),
    ('sb8', cfg(sb=8)),
]]

VREF = {}  # (W.0) --fit -> the knobs of the replay its validation rows are also given against (their frontend model)

# (W.0) three and four wide. Every row runs on the modelled frontend (FE8: the window aligner, one conditional branch an
# aligner cycle) with the shipping predictor modelled (gshare, at the row's block size), so a row's frontend error is
# the reference's too and cancels in a difference; the reference is the two-wide core so modelled (REF_W). A width n is
# n dispatches, n commits, n ALU ports and n IQ pushes a cycle; branches and multiplies stay on port 0 (p0) and the
# other rules stay the two-wide core's unless a rung lifts them. A rung that a two-wide core could take as well is run
# at two-wide too: the gain of width is the difference at the same rungs.
REF_W = cfg(FE8, bp='gshare')
RUNGS_W = OrderedDict([
    ('fe16', dict(fe_blk=16, fb_bytes=32)),          # 16 bytes fetched a cycle (the buffer keeps 32 bytes)
    ('fe32', dict(fe_blk=32, fb_bytes=64)),          # 32 bytes a cycle (64 in the buffer)
    ('iq16', dict(iq=16)),                           # a 16-entry instruction queue
    ('mem2', dict(mem_n=2, engines=2, dc_ports=2)),  # two memory ops a group, two engines, two D$ lookups a cycle
    ('st2', dict(st_n=2)),                           # two posted stores retire in a group
    ('db1', dict(db=1)),                             # a drain beat a cycle
    ('sb8', dict(sb=8)),                             # an 8-entry store buffer
    ('br2', dict(bru_ports=2, br_n=2)),              # a second branch unit, two branches retire in a group
    ('cond2', dict(al_cond_n=2)),                    # two conditional branches predicted an aligner cycle
    ('bslots2', dict(_b2=True)),                     # two branches per BTB block
    ('mul2', dict(mul_ports=2)),                     # a second multiplier
    ('fp2', dict(fp_n=2, fpw_n=2)),                  # two uops touching FP state a group, two FP writes a commit
    ('fpu2', dict(fpu_ports=2)),                     # a second FPU pipe
    ('rob64', dict(rob=64)),
    ('rs16', dict(rs=16)),
    ('lsq16', dict(lsq=16)),
])
ALL_W = [r for r in RUNGS_W if r != 'fe16']          # every rung, the widest fetch


def wrow(n, rungs=(), **extra):
    """(W.0) the knobs of width n with these rungs"""
    d = cfg(REF_W, w=n, cw=n, alu_ports=n, fe_w=n)
    b2 = False
    for r in rungs:
        kn = dict(RUNGS_W[r])
        b2 = kn.pop('_b2', False) or b2
        d.update(kn)
    d['bp'] = {8: 'gshare', 16: 'gshare 16B w2', 32: 'gshare 32B w2'}[d.get('fe_blk', 8)] + (' b2' if b2 else '')
    d.update(extra)
    return d


def ideal_w(n):
    """(W.0) no group rule, a unit of each kind behind every port"""
    return dict(mem1=False, mem_n=None, fp1=False, fp_n=None, fpw1=False, fpw_n=None, alone=False, slot2=False,
                p0=False, st_n=99, br_n=99, bru_ports=n, mul_ports=n, fpu_ports=n, engines=n, dc_ports=None,
                al_cond_n=n)


CONFIGS_W = [('base', cfg()), ('fe8', cfg(FE8)), ('ref', REF_W)]
for _n in (2, 3, 4):
    CONFIGS_W.append(('w%d' % _n, wrow(_n)))
    CONFIGS_W += [('w%d %s' % (_n, r), wrow(_n, [r])) for r in RUNGS_W]
    CONFIGS_W += [('w%d %s' % (_n, ' '.join(rs)), wrow(_n, rs)) for rs in (
        ('st2', 'db1'), ('mem2', 'lsq16'), ('mem2', 'st2', 'db1'), ('fe16', 'bslots2'), ('fe32', 'bslots2'),
        ('fe16', 'cond2'), ('fe32', 'cond2'))]
    CONFIGS_W.append(('w%d best' % _n, wrow(_n, ALL_W)))
    CONFIGS_W.append(('w%d best fe16' % _n, wrow(_n, ['fe16'] + [r for r in ALL_W if r != 'fe32'])))
    CONFIGS_W += [('w%d best -%s' % (_n, r), wrow(_n, [x for x in ALL_W if x != r])) for r in ALL_W]
    CONFIGS_W.append(('w%d ideal' % _n, wrow(_n, ALL_W, **ideal_w(_n))))
    CONFIGS_W += [('w%d res_clamp' % _n, wrow(_n, res_clamp=True)), ('w%d best res_clamp' % _n, wrow(_n, ALL_W, res_clamp=True))]
    CONFIGS_W += [('L20 w%d' % _n, wrow(_n, miss_add=20)), ('L20 w%d best' % _n, wrow(_n, ALL_W, miss_add=20))]

# (W.0) validation: the shipping core's fit predicts runs of the core at width 1 (downward), and each width-1 run's own
# fit predicts the shipping core (upward: the width code crossing a step with a measured answer); both on REF_W. The
# W.0 fits book a port in the traced issue cycle (book_iss): fitted at the constraint cycle, a one-port trace keeps its
# waits for the port as residuals, and two ports then buy almost nothing (--book-cons shows that convention)
BASE_W0 = dict(BASE_O7, book_iss=True)
VALID_W0 = [(lab, cfg(REF_W, kn)) for lab, kn in (
    ('v_c1', dict(cw=1)), ('v_d1', dict(w=1, cw=2)), ('v_a1', dict(alu_ports=1)), ('v_w1', dict(w=1, cw=1, alu_ports=1)))]
BASE_UP = {'v_c1': dict(BASE_W0, cw=1), 'v_d1': dict(BASE_W0, w=1, cw=2), 'v_a1': dict(BASE_W0, alu_ports=1),
           'v_w1': dict(BASE_W0, w=1, cw=1, alu_ports=1)}
VALID_UP = [('w0', cfg(REF_W, w=2, cw=2, alu_ports=2))]
VREF.update({f: REF_W for f in ['w0'] + list(BASE_UP)})
CONFIGS_V = [('base', cfg()), ('ref', REF_W)]           # (W.0) --set v: the validation rows with their reference only

# (W3.0) the three-wide track as built, step by step and cumulative (W3 plan): the drain beat (W3a), 16-byte fetch with
# a two-way BTB holding two branches per block and a 32-byte fetch buffer (W3b), the second memory engine (W3c), three
# commits at two dispatches (W3e), three dispatches at two ALU ports (W3f), the third ALU port (W3g)
W3_RUNGS = ['db1', 'fe16', 'bslots2', 'mem2']
STEPS_W3 = [
    ('W3a', wrow(2, ['db1'])),
    ('W3b', wrow(2, ['db1', 'fe16', 'bslots2'])),
    ('W3c', wrow(2, W3_RUNGS)),
    ('W3e', wrow(2, W3_RUNGS, cw=3)),
    ('W3f', wrow(2, W3_RUNGS, w=3, cw=3, fe_w=3)),
    ('W3g', wrow(3, W3_RUNGS)),
]
CONFIGS_W3 = ([('base', cfg()), ('ref', REF_W)] + STEPS_W3
              + [('L20 ref', cfg(REF_W, miss_add=20))] + [('L20 ' + n, cfg(kn, miss_add=20)) for n, kn in STEPS_W3])

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
    ap.add_argument('--stats', action='store_true', help='(O5.0) also print the fit\'s memory statistics per kernel')
    ap.add_argument('--csv', help='(W.0) also write every replay to this file: kernel,kind,name,cycles,fit,ref,meas')
    ap.add_argument('--book-cons', action='store_true',
                    help='(W.0) the fit and every replay book a port at its constraint cycle (the convention before W.0)')
    ap.add_argument('--check', action='store_true',
                    help='(W.0) also count, per kernel and configuration, the cycles in which a replay exceeds a width '
                         'or the integer ports (the fit included)')
    ap.add_argument('--set', default='o1', choices=('o1', 'o4', 'ox', 'o8', 'o5', 'o7', 'w', 'v', 'w3'),
                    help='o1: the O1.0 configurations; o4: two-wide with the pair rules; ox: the complete-OOO milestones; '
                         'o8: the frontend steps (with --fit o3); w: three and four wide (W.0, with --fit w0); v: only '
                         'the fit and its reference (for the validation rows); w3: the three-wide track as built, '
                         'step by step (W3.0, with --fit w0)')
    ap.add_argument('--fit', default='o1', choices=('o1', 'o4', 'o3', 'o8', 'o7', 'w0') + tuple(BASE_UP),
                    help='o1: fit one-wide traces with the station off (O1.0, O4.0); o4: fit traces of the core as built '
                         'after O4 (two-wide, the station on, issue cycles traced: OX.0); o3: ... after O3 (recovery at '
                         'execute, XR_EARLY); o8: ... after O8 (O5.0); o7: ... with the D$ and the big window (O7b); '
                         'w0: the shipping core (W.0), validated on its width-1 runs; v_c1 v_d1 v_a1 v_w1: those runs, '
                         'fitted on their own traces (--base their CSV), validated on the shipping core (label w0)')
    a = ap.parse_args()
    configs = {'o1': CONFIGS, 'o4': CONFIGS_O4, 'ox': CONFIGS_OX, 'o8': CONFIGS_O8, 'o5': CONFIGS_O5,
               'o7': CONFIGS_O7, 'w': CONFIGS_W, 'v': CONFIGS_V, 'w3': CONFIGS_W3}[a.set]
    sfx = '_s' if a.mode == 's' else ''
    base = load_csv(a.base or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'baseline_pipe%s.csv' % sfx))
    fitp = dict({'o4': BASE_O4, 'o3': BASE_O3, 'o8': BASE_O8, 'o7': BASE_O7, 'w0': BASE_W0}.get(
        a.fit, BASE_UP.get(a.fit, BASE)))
    fitp['db'] = a.db
    if a.book_cons:
        fitp['book_iss'] = False
    valid = {'o4': VALID_O4, 'o3': [], 'o8': VALID_O8, 'o7': VALID_O7, 'w0': VALID_W0}.get(
        a.fit, VALID_UP if a.fit in BASE_UP else VALID)
    vals = {}
    if a.validate:
        for lab, _ in valid:
            f = os.path.join(a.validate, 'baseline_pipe%s_%s.csv' % (sfx, lab))
            if os.path.exists(f):
                vals[lab] = load_csv(f)
    # (W.0) a fit's validation rows may run on a modelled frontend: they are then also given against that frontend's
    # own replay of the fit (vref), so its error, common to the row and the fit, cancels
    vref = VREF.get(a.fit)
    hdr = ['kernel', 'cycles', 'fit', 'neg']
    hdr += [('%s / vs ref (meas)' if vref is not None else '%s (meas)') % lab for lab, _ in valid if lab in vals]
    hdr += [c for c, _ in configs]
    print('| ' + ' | '.join(hdr) + ' |')
    print('|' + '---|' * len(hdr))
    logs = {}
    vlogs = {}                      # validation label -> ([log model/fit], [log model/ref], [log measured/base])
    stats = []
    resid = []
    checks = []
    csv_rows = []
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
        fp = dict(fitp, _dbg={}) if a.check else dict(fitp)
        fitc, neg = sim(tr, fp, res, fit=True, t0=t0)
        if a.check:
            checks.append((kern, 'fit', count_caps(fp['_dbg'], fp)))
        if a.stats:
            stt = dict(res.get('stats', {}))
            nld = sum(1 for q in tr if q.mem == 'ld' and not q.trap)
            for kib in (2, 4, 8):
                for w in (False, True):
                    d = dc_replay(tr, kib, w)
                    stt['dc%dk%s' % (kib, 'w' if w else 'c')] = sum(1 for v in d.values() if v)
            stt['loads'] = nld
            stats.append((kern, stt))
            rr = {}
            for name, sel in (('push', None), ('pop', None), ('disp', None), ('iss', 'op'), ('acc', 'mem'),
                              ('go', 'mem'), ('com', None)):
                v = [res[name][k] for k, q in enumerate(tr)
                     if sel is None or (sel == 'mem') == (q.cls == 'lsu')]
                rr[name] = (sum(1 for x in v if x < 0), sum(v) / len(v) if v else 0.0)
            resid.append((kern, rr))
        row = [kern, str(meas), str(fitc), str(neg)]
        refc = None
        if vref is not None and any(lab in vals for lab, _ in valid):
            p = dict(fitp); p.update(vref)
            refc, _ = sim(tr, p, res, t0=t0)
        for lab, kn in valid:
            if lab not in vals:
                continue
            p = dict(fitp); p.update(kn)
            pc, _ = sim(tr, p, res, t0=t0)
            m = int(vals[lab][(kern, a.config)]['cycles']) if (kern, a.config) in vals[lab] else 0
            vm = 100.0 * (m - meas) / meas if (meas and m) else 0
            vl = vlogs.setdefault(lab, ([], [], []))
            vl[0].append(math.log(pc / fitc))
            if refc is not None:
                vl[1].append(math.log(pc / refc))
            if meas and m:
                vl[2].append(math.log(m / meas))
            if refc is not None:
                row.append('%+.1f%% / %+.1f%% (%+.1f%%)' % (100.0 * (pc - fitc) / fitc, 100.0 * (pc - refc) / refc, vm))
            else:
                row.append('%+.1f%% (%+.1f%%)' % (100.0 * (pc - fitc) / fitc, vm))
            csv_rows.append((kern, 'valid', lab, pc, fitc, refc or '', m))
        for ci, (cname, kn) in enumerate(configs):
            p = dict(fitp); p.update(kn)
            if a.check:
                p['_dbg'] = {}
            pc, _ = sim(tr, p, res, t0=t0)
            if a.check:
                checks.append((kern, cname, count_caps(p['_dbg'], p)))
            csv_rows.append((kern, 'cfg', cname, pc, fitc, '', meas))
            row.append('%+.1f%%' % (100.0 * (pc - fitc) / fitc))
            logs.setdefault(ci, []).append(math.log(pc / fitc))
        print('| ' + ' | '.join(row) + ' |')
    gm = lambda v: 100.0 * (math.exp(sum(v) / len(v)) - 1) if v else 0.0
    if logs or vlogs:
        row = ['geomean', '', '', '']
        for lab, _ in valid:                                  # (W.0) the validation rows' geomeans too
            if lab not in vals:
                continue
            v = vlogs.get(lab, ([], [], []))
            if vref is not None:
                row.append('%+.1f%% / %+.1f%% (%+.1f%%)' % (gm(v[0]), gm(v[1]), gm(v[2])))
            else:
                row.append('%+.1f%% (%+.1f%%)' % (gm(v[0]), gm(v[2])))
        row += ['%+.1f%%' % gm(v) for ci, v in sorted(logs.items())]
        print('| ' + ' | '.join(row) + ' |')
    if a.csv:
        with open(a.csv, 'w') as f:
            f.write('kernel,kind,name,cycles,fit,ref,meas\n')
            for r in csv_rows:
                f.write(','.join(str(x) for x in r) + '\n')
    if stats:
        keys = ['loads', 'dcm_n', 'dc2kc', 'dc2kw', 'dc4kw', 'dc8kw', 'miss_lat', 'ld_drain',
                'ldb_ld', 'ldb_st', 'ldb_head', 'ldb_busy']
        print()
        print('| kernel | ' + ' | '.join(keys) + ' |')
        print('|' + '---|' * (len(keys) + 1))
        for kern, stt in stats:
            print('| %s | ' % kern + ' | '.join(str(stt.get(x, 0)) for x in keys) + ' |')
        # (W.0) the fit's residuals per event: how many are negative, and their mean (iss over the other ops, acc and
        # go over the memory ops, the rest over every instruction)
        ev = ['push', 'pop', 'disp', 'iss', 'acc', 'go', 'com']
        print()
        print('| kernel | ' + ' | '.join('%s neg / mean' % e for e in ev) + ' |')
        print('|' + '---|' * (len(ev) + 1))
        for kern, rr in resid:
            print('| %s | ' % kern + ' | '.join('%d / %.2f' % rr[e] for e in ev) + ' |')
    if a.check:
        bad = [(k, c, v) for (k, c, v) in checks if any(v.values())]
        print()
        print('check: %d replays, %d exceed a cap (cycles over: disp > w, com > cw, push > fe_w, int > alu_ports)'
              % (len(checks), len(bad)))
        for k, c, v in bad:
            print('  %s %s: %s' % (k, c, ' '.join('%s %d' % kv for kv in v.items() if kv[1])))


if __name__ == '__main__':
    main()
