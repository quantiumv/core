#!/usr/bin/env python3
"""ilp_width.py -- W.0's decision numbers: what three- and four-wide would buy, from ilp.py's model.

  ilp_width.py --traces DIR --base-m CSV --base-s CSV chosen
      each width's chosen row: a greedy forward selection over ilp.RUNGS_W (from 16- and from 32-byte fetch, which
      exclude each other) until the row is within 0.5 points of the width's best non-ideal row; then the chosen
      rungs at widths 2, 3 and 4 (width gain), leaving each one out, and the same at L=20 (miss_add=20)
  ilp_width.py --traces DIR --base-m CSV --base-s CSV rows R1,R2,... [R1,...]
      a rung set at widths 2, 3 and 4, leaving each rung out at width 3 (with the kernel it costs most), L=20, and
      the kernels

DIR holds the shipping core's traces (run_perf.sh --ilptrace, both modes); the CSVs are those runs' cycles. Every
number is the geomean cycle change (%) on the SoC against the modelled two-wide core (ilp.REF_W), the mean of M and
S mode (each given too); width gain is the difference between two widths at the same rungs. One process per kernel
and mode (a pool of --jobs).
"""
import argparse
import math
import os
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ilp  # noqa: E402

KERNELS = ilp.KERNELS
MODES = ('m', 's')
A = None


def _fit(kern, mode):
    tr = ilp.read_trace(os.path.join(A.traces, '%s%s_cache.ilp' % (kern, '_s' if mode == 's' else '')))
    base = ilp.load_csv(A.base_s if mode == 's' else A.base_m)
    t0 = tr[-1].commit - int(base[(kern, 'cache')]['cycles'])
    res = {}
    fitp = dict(ilp.BASE_W0, db=2)
    ilp.sim(tr, dict(fitp), res, fit=True, t0=t0)
    return tr, res, fitp, t0


def _work(args):
    kern, mode, knobs = args
    tr, res, fitp, t0 = _fit(kern, mode)
    out = []
    for kn in [ilp.REF_W] + knobs:
        p = dict(fitp)
        p.update(kn)
        out.append(ilp.sim(tr, p, res, t0=t0)[0])
    return kern, mode, out


POOL = None


def evaluate(knobs_list):
    """-> [(delta, {mode: geomean %}, {(kernel, mode): %})] for each knob dict, against REF_W"""
    got = POOL.map(_work, [(k, m, knobs_list) for k in KERNELS for m in MODES])
    outs = []
    for i in range(len(knobs_list)):
        per, gm = {}, {}
        for m in MODES:
            logs = []
            for (k, mm, cyc) in got:
                if mm == m:
                    r = cyc[i + 1] / cyc[0]
                    per[(k, m)] = 100.0 * (r - 1)
                    logs.append(math.log(r))
            gm[m] = 100.0 * (math.exp(sum(logs) / len(logs)) - 1)
        outs.append((sum(gm.values()) / len(gm), gm, per))
    return outs


def fmt(e):
    return '%+.1f (M %+.1f, S %+.1f)' % (e[0], e[1]['m'], e[1]['s'])


def chosen(widths):
    report = {}
    for n in widths:
        bests = evaluate([ilp.wrow(n, ilp.ALL_W), ilp.wrow(n, ['fe16'] + [r for r in ilp.ALL_W if r != 'fe32'])])
        best = min(bests, key=lambda e: e[0])
        bare = evaluate([ilp.wrow(n)])[0]
        print('w%d: bare %s, best %s (fe32 %s, fe16 %s)' % (n, fmt(bare), fmt(best), fmt(bests[0]), fmt(bests[1])),
              flush=True)
        paths = []
        for start in ('fe16', 'fe32'):
            S = [start]
            cur = evaluate([ilp.wrow(n, S)])[0]
            print('  start %-5s -> %s' % (start, fmt(cur)), flush=True)
            while cur[0] - best[0] > 0.5:
                cand = [r for r in ilp.RUNGS_W if r not in S and r not in ('fe16', 'fe32')]
                if not cand:
                    break
                ev = evaluate([ilp.wrow(n, S + [r]) for r in cand])
                j = min(range(len(cand)), key=lambda i: ev[i][0])
                S.append(cand[j])
                cur = ev[j]
                print('  + %-8s -> %s' % (cand[j], fmt(cur)), flush=True)
            paths.append((cur[0] - best[0] > 0.5, len(S), cur[0], S))
        paths.sort(key=lambda x: (x[0], x[1], x[2]))
        report[n] = paths[0][3]
        print('  chosen: %s (%+.1f, best %+.1f)' % (' '.join(paths[0][3]), paths[0][2], best[0]), flush=True)
    print()
    for n in widths:
        rows(report[n], 'chosen rungs of w%d' % n)


def rows(rungs, title=None):
    ev = evaluate([ilp.wrow(w, rungs) for w in (2, 3, 4)] + [ilp.wrow(3, [x for x in rungs if x != r]) for r in rungs]
                  + [ilp.wrow(w, rungs, miss_add=20) for w in (2, 3, 4)])
    e2, e3, e4 = ev[:3]
    print('%s: %s' % (title or 'rungs', ' '.join(rungs)))
    print('  w2 %s | w3 %s | w4 %s' % (fmt(e2), fmt(e3), fmt(e4)))
    print('  width gain: w3 - w2 %+.1f (M %+.1f, S %+.1f), w4 - w3 %+.1f (M %+.1f, S %+.1f)'
          % (e3[0] - e2[0], e3[1]['m'] - e2[1]['m'], e3[1]['s'] - e2[1]['s'],
             e4[0] - e3[0], e4[1]['m'] - e3[1]['m'], e4[1]['s'] - e3[1]['s']))
    for r, e in zip(rungs, ev[3:3 + len(rungs)]):
        worst = max(KERNELS, key=lambda k: max(e[2][(k, 'm')] - e3[2][(k, 'm')], e[2][(k, 's')] - e3[2][(k, 's')]))
        print('  w3 without %-8s costs %+.1f; most on %s %+.1f/%+.1f' % (
            r, e[0] - e3[0], worst, e[2][(worst, 'm')] - e3[2][(worst, 'm')], e[2][(worst, 's')] - e3[2][(worst, 's')]))
    l2, l3, l4 = ev[-3:]
    print('  L=20: width gain w3 - w2 %+.1f, w4 - w3 %+.1f' % (l3[0] - l2[0], l4[0] - l3[0]))
    for name, e in (('w2', e2), ('w3', e3), ('w4', e4)):
        print('  %s vs ref (M/S): ' % name + ', '.join('%s %+.1f/%+.1f' % (k, e[2][(k, 'm')], e[2][(k, 's')])
                                                    for k in KERNELS))
    print(flush=True)


def steps():
    """(W3.0) the three-wide track as built (ilp.STEPS_W3), each step against the one before and cumulative against
    the reference, per kernel; and at L=20"""
    names = [n for n, _ in ilp.STEPS_W3]
    ev = evaluate([kn for _, kn in ilp.STEPS_W3] + [ilp.cfg(kn, miss_add=20) for _, kn in ilp.STEPS_W3]
                  + [ilp.cfg(ilp.REF_W, miss_add=20)])
    n = len(names)
    cur, l20, r20 = ev[:n], ev[n:2 * n], ev[2 * n]
    print('| step | the step (M / S) | cumulative (M / S) | L=20 cumulative |')
    print('|---|---|---|---|')
    prev = None
    for i, name in enumerate(names):
        e = cur[i]
        own = (e[1]['m'] - (prev[1]['m'] if prev else 0), e[1]['s'] - (prev[1]['s'] if prev else 0))
        print('| %s | %+.1f / %+.1f | %+.1f / %+.1f (%+.1f) | %+.1f |' % (
            name, own[0], own[1], e[1]['m'], e[1]['s'], e[0], l20[i][0] - r20[0]))
        prev = e
    print()
    print('| kernel | ' + ' | '.join(names) + ' |')
    print('|---|' + '---|' * n)
    for k in KERNELS:
        row = []
        for i in range(n):
            pm = cur[i - 1][2][(k, 'm')] if i else 0.0
            ps = cur[i - 1][2][(k, 's')] if i else 0.0
            row.append('%+.1f / %+.1f' % (cur[i][2][(k, 'm')] - pm, cur[i][2][(k, 's')] - ps))
        print('| %s | ' % k + ' | '.join(row) + ' |')
    print('(each step against the one before it, M / S, points; the cumulative row above)', flush=True)


def main():
    global A, POOL
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--traces', required=True)
    ap.add_argument('--base-m', required=True)
    ap.add_argument('--base-s', required=True)
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    ap.add_argument('what', choices=('chosen', 'rows', 'steps'))
    ap.add_argument('rungs', nargs='*', help='(rows) comma-separated rung lists')
    A = ap.parse_args()
    POOL = Pool(A.jobs)
    if A.what == 'chosen':
        chosen([2, 3, 4])
    elif A.what == 'steps':
        steps()
    else:
        for spec in A.rungs:
            rows(spec.split(','))


if __name__ == '__main__':
    main()
