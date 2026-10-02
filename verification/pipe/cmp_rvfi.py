#!/usr/bin/env python3
"""cmp_rvfi.py -- compare two testbench/rvfi_tracer.sv logs retirement by retirement.

Usage: cmp_rvfi.py REF.log DUT.log N

Compares the first N retirements on every field the tracer prints.
mem_rdata is ignored when mem_rmask is 0 and mem_wdata when mem_wmask is
0: core.sv drives both unconditionally from the bus, so outside a real
access they carry whatever the bus last held. Fewer than N retirements
on either side is a failure (a hang or stall). Last line is
"RVFI_DIFF: PASS ..." or "RVFI_DIFF: FAIL ...".
"""
import sys

FIELDS = ["order", "pc_rdata", "pc_wdata", "insn", "mode", "trap", "intr", "cause",
          "tval", "rd_addr", "rd_wdata", "rs1_addr", "rs1_rdata", "rs2_addr",
          "rs2_rdata", "mem_addr", "mem_rmask", "mem_wmask", "mem_rdata", "mem_wdata"]


def load(path, n):
    recs = []
    with open(path) as f:
        for line in f:
            if not line.startswith("rvfi "):
                continue
            rec = dict(kv.split("=", 1) for kv in line.split()[1:])
            if int(rec["mem_rmask"], 16) == 0:
                rec["mem_rdata"] = "-"
            if int(rec["mem_wmask"], 16) == 0:
                rec["mem_wdata"] = "-"
            recs.append(rec)
            if len(recs) == n:
                break
    return recs


def main():
    ref_path, dut_path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    ref, dut = load(ref_path, n), load(dut_path, n)
    for i in range(min(len(ref), len(dut))):
        bad = [k for k in FIELDS if ref[i].get(k) != dut[i].get(k)]
        if bad:
            print(f"first divergence at retirement {i}:")
            for j in range(max(0, i - 4), i):
                print(f"  ok   {j}: pc={ref[j]['pc_rdata']} insn={ref[j]['insn']}")
            print(f"  {'field':10} {'ref':>18} {'dut':>18}")
            for k in FIELDS:
                mark = " <--" if k in bad else ""
                print(f"  {k:10} {ref[i].get(k, '?'):>18} {dut[i].get(k, '?'):>18}{mark}")
            print(f"RVFI_DIFF: FAIL at {i} ({', '.join(bad)})")
            return 1
    if len(ref) < n or len(dut) < n:
        print(f"RVFI_DIFF: FAIL short log (ref={len(ref)} dut={len(dut)} want={n})")
        return 1
    print(f"RVFI_DIFF: PASS n={n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
