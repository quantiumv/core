#!/usr/bin/env python3
"""check_cpi.py -- compare a CPI CSV (run_perf.sh's output) with the committed one.

    check_cpi.py                      working-tree baseline_pipe.csv against git HEAD's
    check_cpi.py --old A --new B      two files (--configs cache: only that configuration, e.g. for an oracle run)
    check_cpi.py --allow qsort,sieve  kernels whose cycles may rise (a per-kernel override)

For every kernel and configuration it prints the old and new cycles, the change, and
the new CPI. The exit status is 1 when

  - the retired-instruction count of any kernel changed: the kernels do not check their
    own results, so instret is the free functional invariant under the P9 performance
    steps, which must change when, never what, retires; or
  - the cycles of any kernel rose on a gated configuration (the cache configuration, the
    SoC, by default; --gate both also gates the shared-SRAM harness), unless the kernel is
    allowed; or
  - a row is missing.
Rises on the configuration that is not gated are printed and flagged, but do not fail.
"""
import argparse
import csv
import subprocess
import sys
from pathlib import Path

PERF = Path(__file__).resolve().parent
REPO = PERF.parent.parent


def load(text):
    rows = {}
    for r in csv.DictReader(text.splitlines()):
        rows[(r["kernel"], r["config"])] = (int(r["cycles"]), int(r["instret"]))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", default="pipe", help="baseline_<core>.csv (default pipe)")
    ap.add_argument("--old", help="the reference CSV (default: the committed one, git HEAD)")
    ap.add_argument("--new", help="the CSV to check (default: the working-tree baseline_<core>.csv)")
    ap.add_argument("--allow", default="", help="comma-separated kernels whose cycles may rise")
    ap.add_argument("--configs", default="", help="compare only these configurations (comma-separated; default all)")
    ap.add_argument("--gate", choices=["cache", "both"], default="cache",
                    help="which configurations fail the check when cycles rise (default cache)")
    args = ap.parse_args()

    name = f"baseline_{args.core}.csv"
    new_path = Path(args.new) if args.new else PERF / name
    new = load(new_path.read_text())
    if args.old:
        old = load(Path(args.old).read_text())
    else:
        rel = f"verification/perf/{name}"
        out = subprocess.run(["git", "show", f"HEAD:{rel}"], cwd=REPO, capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(f"cannot read {rel} from git HEAD: {out.stderr.strip()}")
        old = load(out.stdout)

    allowed = {k for k in args.allow.split(",") if k}
    gated = {"cache"} if args.gate == "cache" else {"cache", "sram"}
    bad = []
    print(f"{'kernel':<10} {'config':<6} {'old':>8} {'new':>8} {'change':>8}  {'cpi':>6}")
    only = {c for c in args.configs.split(",") if c}
    for key in sorted(old):
        if only and key[1] not in only:
            continue
        kernel, cfg = key
        if key not in new:
            bad.append(f"{kernel} {cfg}: missing from the new CSV")
            continue
        oc, oi = old[key]
        nc, ni = new[key]
        pct = 100.0 * (nc - oc) / oc
        flag = ""
        if ni != oi:
            flag = "  INSTRET CHANGED %d -> %d" % (oi, ni)
            bad.append(f"{kernel} {cfg}: instret {oi} -> {ni}")
        elif nc > oc:
            if cfg in gated and kernel not in allowed:
                flag = "  SLOWER"
                bad.append(f"{kernel} {cfg}: cycles {oc} -> {nc}")
            else:
                flag = "  slower (not gated)" if kernel not in allowed else "  slower (allowed)"
        print(f"{kernel:<10} {cfg:<6} {oc:>8} {nc:>8} {pct:>+7.1f}%  {nc / ni:>6.3f}{flag}")
    for key in sorted(set(new) - set(old)):
        print(f"{key[0]:<10} {key[1]:<6} (new row)")

    if bad:
        print("\nFAIL:")
        for b in bad:
            print("  " + b)
        sys.exit(1)
    print("\nOK")


if __name__ == "__main__":
    main()
