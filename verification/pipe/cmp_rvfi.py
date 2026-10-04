#!/usr/bin/env python3
"""cmp_rvfi.py -- compare two testbench/rvfi_tracer.sv logs retirement by retirement.

Usage: cmp_rvfi.py REF.log DUT.log END_PC

END_PC (hex) is where the program ends. Each log is cut at its first
retirement with pc_rdata == END_PC; everything before that must match on
every field the tracer prints, and both logs must reach END_PC (a side
that never gets there hung, stalled, or ran off somewhere else).
mem_rdata is ignored when mem_rmask is 0 and mem_wdata when mem_wmask is
0: core.sv drives both unconditionally from the bus, so outside a real
access they carry whatever the bus last held. mem_rdata is ignored on
trapping records too: a misaligned access never reaches the bus, and a
bus error's data is whatever the slave last drove, which depends on
each core's own fetch/load interleaving. Addresses and masks stay
strict on every record. Last line is
"RVFI_DIFF: PASS ..." or "RVFI_DIFF: FAIL ...".
"""
import sys

FIELDS = ["order", "pc_rdata", "pc_wdata", "insn", "mode", "trap", "intr", "cause",
          "tval", "rd_addr", "rd_wdata", "rs1_addr", "rs1_rdata", "rs2_addr",
          "rs2_rdata", "mem_addr", "mem_rmask", "mem_wmask", "mem_rdata", "mem_wdata"]


def load(path, end_pc):
    """Records before the first one at end_pc, and whether end_pc was reached."""
    recs = []
    with open(path) as f:
        for line in f:
            if not line.startswith("rvfi "):
                continue
            rec = dict(kv.split("=", 1) for kv in line.split()[1:])
            if int(rec["pc_rdata"], 16) == end_pc:
                return recs, True
            if int(rec["mem_rmask"], 16) == 0 or rec["trap"] == "1":
                rec["mem_rdata"] = "-"
            if int(rec["mem_wmask"], 16) == 0:
                rec["mem_wdata"] = "-"
            recs.append(rec)
    return recs, False


def main():
    ref_path, dut_path, end_pc = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
    (ref, ref_done), (dut, dut_done) = load(ref_path, end_pc), load(dut_path, end_pc)
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
    if not (ref_done and dut_done) or len(ref) != len(dut):
        print(f"RVFI_DIFF: FAIL did not both reach end pc {end_pc:x} "
              f"(ref={len(ref)}{'' if ref_done else ' unfinished'} "
              f"dut={len(dut)}{'' if dut_done else ' unfinished'})")
        return 1
    print(f"RVFI_DIFF: PASS n={len(ref)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
