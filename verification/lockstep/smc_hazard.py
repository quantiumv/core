#!/usr/bin/env python3
"""smc_hazard.py -- triage helper for a lockstep divergence: is the program invalid stimulus?

Two hazards are looked for. Both make the program invalid, not the core wrong:

  code    the diverging instruction was fetched from bytes that an earlier store had written, with no FENCE.I since.
          Without a FENCE.I what a core fetches from freshly written code is unspecified, and the FSM (no prefetch)
          and the pipe (prefetched bytes) legitimately differ.

  pte     (--sv39 programs) the diverging instruction retired after a store into the page tables with no SFENCE.VMA
          since. Without the SFENCE.VMA which translation a core uses for a changed PTE is unspecified: the FSM has
          one unified TLB that only fills for the path the program takes, the pipe two TLBs that also fill on
          wrong paths. This is speculation contract R1 (a PTE store, satp write or root swap is followed by an
          SFENCE.VMA before anything depends on it).

Contract R2 (every non-leaf PTE and every executable leaf points into RAM) cannot be read from a trace; a walk that
reached MMIO shows up as an MMIO-read log mismatch instead.

Usage:
    QV_LOCKSTEP_EXTRA=+RVFI_TRACE run_lockstep.sh ... --only '^TAG[|]' --force    # the result file gets the trace
    smc_hazard.py RESULT_FILE [--order N] [--code-end 0x10000] [--pt-ranges 0x20000-0x28000,0x8f000-0x90000]

RESULT_FILE holds the `RT <order> pc=.. insn=.. ... mem=<addr>/r<mask>/w<mask>/<data>` lines of side A
(lockstep_tb.sv, +RVFI_TRACE). N defaults to the last retirement in the file, the first divergence when the
run failed. Exit status 0: hazard found (invalid stimulus), 1: none (look for a real bug), 2: usage error.
"""
import argparse
import re
import sys

RT = re.compile(r"^RT (\d+) pc=([0-9a-f]+) insn=([0-9a-f]+) .* trap=(\d) .* mem=([0-9a-f]+)/r([0-9a-f]{2})/w([0-9a-f]{2})/([0-9a-f]+)")


def is_sfence_vma(insn):
    return (insn & 0xFE007FFF) == 0x12000073


def parse_ranges(text):
    out = []
    for part in text.split(","):
        lo, hi = part.split("-")
        out.append((int(lo, 0), int(hi, 0)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--order", type=int, default=None)
    ap.add_argument("--code-end", type=lambda s: int(s, 0), default=0x10000,
                    help="stores below this address count as stores into code (default 0x10000)")
    ap.add_argument("--pt-ranges", default="0x20000-0x28000,0x8f000-0x90000",
                    help="physical ranges that hold page tables (default: qvgen's two table sets and the PMP-pocketed table)")
    args = ap.parse_args()
    pt_ranges = parse_ranges(args.pt_ranges)

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
    pt_dirty = None   # (order of the store, its address) of the last store into a page table, since the last SFENCE.VMA
    for order, pc, insn, trap, addr, wmask in recs[:target]:
        if (insn & 0x7F) == 0x0F and ((insn >> 12) & 7) == 1:            # FENCE.I retires: everything is clean again
            dirty.clear()
        elif is_sfence_vma(insn) and not trap:
            pt_dirty = None
        elif wmask and not trap:
            if addr < args.code_end:
                dirty[addr >> 3] = (order, addr)
            if any(lo <= addr < hi for lo, hi in pt_ranges):
                pt_dirty = (order, addr)

    order, pc, insn = recs[target][:3]
    n = 4 if (insn & 3) == 3 else 2
    found = False
    hit = [(dw, dirty[dw]) for dw in sorted({pc >> 3, (pc + n - 1) >> 3}) if dw in dirty]
    for dw, (so, sa) in hit:
        print(f"order {order}: pc={pc:#x} len={n}: dword {dw << 3:#x} was written by the store at order {so} "
              f"(address {sa:#x}) and no FENCE.I retired since -- invalid stimulus, the cores may fetch different bytes")
        found = True
    if pt_dirty is not None and not is_sfence_vma(insn):
        print(f"order {order}: pc={pc:#x}: the store at order {pt_dirty[0]} (address {pt_dirty[1]:#x}) wrote a page table "
              f"and no SFENCE.VMA retired since -- invalid stimulus (contract R1), the cores may use different translations")
        found = True
    if not found:
        print(f"order {order}: pc={pc:#x} len={n}: no store into its bytes since the last FENCE.I and no page-table store "
              f"since the last SFENCE.VMA -- not these hazards")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
