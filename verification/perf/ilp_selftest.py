#!/usr/bin/env python3
"""ilp_selftest.py -- hand-built traces with known schedules for ilp.py's width and group rules (W.0).

Each case is a short instruction stream replayed with every residual at zero (a unit latency for the ALU, a one-cycle
D$ hit), so the schedule is the model's constraints alone and the expected numbers follow from them:
  alu        independent ALU ops at width N retire N a cycle: the last commit moves by floor((n-1)/N)
  chain      a dependence chain retires one a cycle at any width
  mem        independent loads: one a cycle with one memory op per group, two with mem_n 2, two engines and two D$
             lookups, one again with a single D$ lookup
  csr        a CSR op ends its commit group (it is not a plain retirement), and with slot2 it never joins one
  stores     posted stores per commit group stay within st_n, branches within br_n
  caps       no replay dispatches, retires or pushes more than its widths in a cycle

  python3 verification/perf/ilp_selftest.py        (exit status 1 on a failure)
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ilp  # noqa: E402


def addi(rd, rs1):
    return (1 << 20) | (rs1 << 15) | (rd << 7) | 0x13


def ld(rd, rs1):
    return (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03


def sd(rs2, rs1):
    return (rs2 << 20) | (rs1 << 15) | (3 << 12) | 0x23


def beq_nt():
    return (0 << 20) | (0 << 15) | (8 << 7) | 0x63      # beq x0, x0, +8 is taken; the trace's next pc says not


def csrr(rd):
    return (0xB00 << 20) | (2 << 12) | (rd << 7) | 0x73


def trace(raws, store_posted=True):
    """an ILP trace of raws at consecutive pcs; stores are posted (go == cmpl), each memory op its own dword"""
    lines = []
    for k, raw in enumerate(raws):
        is_st = (raw & 0x7F) == 0x23
        go = 1 if is_st and store_posted else 0
        lines.append('ILP %x %08x 0 0 0 0 %d %d 0 0 0 0 0 %x 0 0 0 0 0'
                     % (0x80000000 + 4 * k, raw, go, go, 0x1000 + 8 * k))
    fd, path = tempfile.mkstemp(suffix='.ilp')
    with os.fdopen(fd, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    tr = ilp.read_trace(path)
    os.unlink(path)
    return tr


def run(tr, **kn):
    """replay with zero residuals: -> (cycles, the replay's event lists)"""
    p = dict(ilp.BASE_O7, **kn)
    p['_dbg'] = {}
    n = len(tr)
    res = {k: [0] * n for k in ('push', 'pop', 'disp', 'acc', 'go', 'com', 'iss')}
    res['lat'] = [1] * n
    res['bus'] = [1] * n
    res['stats'] = {}
    cyc, _ = ilp.sim(tr, p, res, t0=0)
    return cyc, p['_dbg'], p


def per_cycle_max(ev, sel=None):
    n = {}
    for k, t in enumerate(ev):
        if sel is None or sel(k):
            n[t] = n.get(t, 0) + 1
    return max(n.values())


FAIL = []


def check(name, cond, info=''):
    print('%-4s %s %s' % ('ok' if cond else 'FAIL', name, info))
    if not cond:
        FAIL.append(name)


def width(n):
    return dict(w=n, cw=n, alu_ports=n, fe_w=n)


def main():
    nn = 24
    alu = trace([addi(1 + k % 30, 0) for k in range(nn)])
    c1 = run(alu, **width(1))[0]
    for n in (1, 2, 3, 4):
        cyc, d, p = run(alu, **width(n))
        check('alu w%d' % n, cyc == c1 - (nn - 1) + (nn - 1) // n, 'cycles %d (w1 %d)' % (cyc, c1))
        check('alu w%d caps' % n, ilp.count_caps(d, p) == dict(disp=0, com=0, push=0, int=0)
              and per_cycle_max(d['com']) == n and per_cycle_max(d['disp']) == n)
    chain = trace([addi(1, 1) for _ in range(nn)])
    cs = [run(chain, **width(n))[0] for n in (1, 2, 3, 4)]
    check('chain', len(set(cs)) == 1, 'cycles %s' % cs)
    mem = trace([ld(1 + k % 30, 0) for k in range(nn)])
    is_ld = lambda k: True
    c_m1, d1, _ = run(mem, **width(4))
    c_m2, d2, _ = run(mem, **width(4), mem_n=2, engines=2, dc_ports=2)
    c_m2p1, d3, _ = run(mem, **width(4), mem_n=2, engines=2, dc_ports=1)
    check('mem one a cycle', per_cycle_max(d1['disp'], is_ld) == 1, 'cycles %d' % c_m1)
    check('mem two a cycle', per_cycle_max(d2['disp'], is_ld) == 2 and c_m2 == c_m1 - (nn - 1) + (nn - 1) // 2,
          'cycles %d' % c_m2)
    check('mem one D$ lookup', c_m2p1 == c_m1, 'cycles %d' % c_m2p1)
    seq = [addi(1 + k, 0) for k in range(6)] + [csrr(10)] + [addi(11 + k, 0) for k in range(6)]
    t = trace(seq)
    _, d, _ = run(t, **width(4), alone=False, slot2=False)
    check('csr ends its group', d['com'][7] > d['com'][6] and d['com'][6] == d['com'][5])
    _, d, _ = run(t, **width(4), alone=False, slot2=True)
    check('slot2: csr joins no group', d['com'][6] > d['com'][5] and d['com'][7] > d['com'][6])
    sts = trace([sd(0, 0) for _ in range(8)])
    for s_n in (1, 2, 3):
        _, d, _ = run(sts, **width(4), st_n=s_n, sb=64, db=1, mem_n=4, engines=4)
        check('st_n %d' % s_n, per_cycle_max(d['com']) == s_n)
    brs = trace([beq_nt() for _ in range(8)])
    for b_n in (1, 2):
        _, d, _ = run(brs, **width(4), br_n=b_n, bru_ports=b_n, mul_ports=1)
        check('br_n %d' % b_n, per_cycle_max(d['com']) == b_n)
    if FAIL:
        print('%d FAILED: %s' % (len(FAIL), ', '.join(FAIL)))
        sys.exit(1)
    print('all passed')


if __name__ == '__main__':
    main()
