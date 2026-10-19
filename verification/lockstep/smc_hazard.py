#!/usr/bin/env python3
"""smc_hazard.py -- triage helper for a lockstep divergence: was the diverging instruction fetched from
bytes that an earlier store had written, with no FENCE.I since?

Such a program is invalid stimulus, not a core bug: without a FENCE.I what a core fetches from freshly
written code is unspecified, and the FSM (no prefetch) and the pipe (prefetched bytes) legitimately differ.

Usage:
    QV_LOCKSTEP_EXTRA=+RVFI_TRACE run_lockstep.sh ... --only '^TAG[|]' --force    # the result file gets the trace
    smc_hazard.py RESULT_FILE [--order N] [--code-end 0x10000]

RESULT_FILE holds the `RT <order> pc=.. insn=.. ... mem=<addr>/r<mask>/w<mask>/<data>` lines of side A
(lockstep_tb.sv, +RVFI_TRACE). N defaults to the last retirement in the file, the first divergence when the
run failed. Exit status 0: hazard found (invalid stimulus), 1: none (look for a real bug), 2: usage error.
"""
import argparse
import re
import sys

RT = re.compile(r"^RT (\d+) pc=([0-9a-f]+) insn=([0-9a-f]+) .* trap=(\d) .* mem=([0-9a-f]+)/r([0-9a-f]{2})/w([0-9a-f]{2})/([0-9a-f]+)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--order", type=int, default=None)
    ap.add_argument("--code-end", type=lambda s: int(s, 0), default=0x10000,
                    help="stores below this address count as stores into code (default 0x10000)")
    args = ap.parse_args()

    recs = []
    for line in open(args.trace, errors="replace"):
        m = RT.match(line)
        if m:
            recs.append((int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4)),
                         int(m.group(5), 16), int(m.group(7), 16)))
    if not recs:
        print("no RT lines in the file (run with +RVFI_TRACE)", file=sys.stderr)
        return 2
    target = len(recs) - 1
    if args.order is not None:
        idx = [i for i, r in enumerate(recs) if r[0] == args.order]
        if not idx:
            print(f"no RT line for order {args.order}", file=sys.stderr)
            return 2
        target = idx[0]

    dirty = {}        # dword -> (order of the store, its address), since the last FENCE.I
    for order, pc, insn, trap, addr, wmask in recs[:target]:
        if (insn & 0x7F) == 0x0F and ((insn >> 12) & 7) == 1:            # FENCE.I retires: everything is clean again
            dirty.clear()
        elif wmask and not trap and addr < args.code_end:
            dirty[addr >> 3] = (order, addr)

    order, pc, insn = recs[target][:3]
    n = 4 if (insn & 3) == 3 else 2
    hit = [(dw, dirty[dw]) for dw in sorted({pc >> 3, (pc + n - 1) >> 3}) if dw in dirty]
    if not hit:
        print(f"order {order}: pc={pc:#x} len={n}: no store into its bytes since the last FENCE.I -- not this hazard")
        return 1
    for dw, (so, sa) in hit:
        print(f"order {order}: pc={pc:#x} len={n}: dword {dw << 3:#x} was written by the store at order {so} "
              f"(address {sa:#x}) and no FENCE.I retired since -- invalid stimulus, the cores may fetch different bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
