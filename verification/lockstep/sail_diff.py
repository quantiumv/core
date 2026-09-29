#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
sail_diff.py -- P3.2 Sail differential audit (pipelining track, see the
plan at C:\\Users\\Potato\\.claude\\plans\\
research-the-c-extension-reflective-candle.md).

Runs verification/lockstep/gen/qvgen.py --sail-safe output on BOTH this
repo's own core (design/core.sv, via testbench/rvfi_tracer.sv) and the
reference Sail RISC-V model (sail_riscv_sim), then diffs the two
retirement-by-retirement. --sail-safe means pure M/S ALU/mem/control-
flow content -- no PMP, no Sv39, no MMIO -- so both sides see identical,
unambiguous architectural state to compare (see qvgen.py's own
--sail-safe docstring).

Every difference is either a REFERENCE BUG (fix design/core.sv) or a
LEGAL CHOICE Sail's config doesn't yet encode (extend
sail_config_override.json and/or this script's own classification, with
a comment explaining the choice) -- this script only ever reports a
divergence; it never silently reclassifies one as ignorable on its own.

Requires (WSL): riscv64-unknown-elf-{as,ld,objcopy,nm}, iverilog/vvp,
and ~/sail-install/bin/sail_riscv_sim (see the module docstring of
gen/qvgen.py for the toolchain versions this repo already assumes).

Usage:
    sail_diff.py --seeds 1-20
    sail_diff.py --seeds 1,2,3 --len 300 --priv msu -v
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

LOCKSTEP_DIR = Path(__file__).resolve().parent
GEN_DIR = LOCKSTEP_DIR / "gen"
REPO_ROOT = LOCKSTEP_DIR.parent.parent
DESIGN_DIR = REPO_ROOT / "design"
TESTBENCH_DIR = REPO_ROOT / "testbench"
SAIL_CONFIG = LOCKSTEP_DIR / "sail_config_override.json"
SAIL_BIN = Path.home() / "sail-install" / "bin" / "sail_riscv_sim"

sys.path.insert(0, str(GEN_DIR))
import qvgen  # noqa: E402  (path set up above)

# ---------------------------------------------------------------------
# Sail cause-name -> RISC-V standard numeric cause code. Sail's
# --trace-exception output names causes (e.g. "m-call",
# "fetch-access-fault"); this repo's own RVFI trace reports the numeric
# mcause/scause value directly (see rvfi_tracer.sv). Anything NOT in
# this table raises loudly at parse time rather than being silently
# misclassified -- extend it (with the Sail source or an empirical
# `--trace-exception` run as the authority) if a new name shows up.
# ---------------------------------------------------------------------
SAIL_CAUSE_NAMES = {
    "fetch-address-misaligned": 0,
    "fetch-access-fault": 1,
    "illegal-instruction": 2,
    "breakpoint": 3,
    "software-breakpoint": 3,
    "hardware-breakpoint": 3,
    "load-address-misaligned": 4,
    "misaligned-load": 4,
    "load-access-fault": 5,
    "store/amo-address-misaligned": 6,
    "samo-address-misaligned": 6,
    "misaligned-store/amo": 6,
    "store/amo-access-fault": 7,
    "samo-access-fault": 7,
    "u-call": 8,
    "s-call": 9,
    "m-call": 11,
    "fetch-page-fault": 12,
    "load-page-fault": 13,
    "store/amo-page-fault": 15,
    "samo-page-fault": 15,
}
# Causes that can ONLY be fetch-side: structurally, they occur before any
# instruction is decoded, so they're always their own phantom retirement
# (see run_sail's own comment at its use).
FETCH_CAUSES = {0, 1, 12}


def toolchain_build_sail_safe(seed: int, args, out_base: Path):
    """Generate + assemble one --sail-safe program via qvgen.py, reusing
    its own Program/build_program/render/toolchain_build -- no subprocess,
    no re-parsing its CLI, just the same functions its own __main__ uses."""
    ns = argparse.Namespace(
        isa=args.isa, priv=args.priv, pmp=False, sv39=False, irq=False,
        smc=False, len=args.len, seed=seed, dep_bias=0.3,
        illegal_rate=args.illegal_rate, ecall_rate=0.01,
        misalign_rate=args.misalign_rate, badaddr_rate=0.0,
        max_call_depth=3, max_loop_nesting=2, sail_safe=True,
        output=out_base, build=True,
    )
    p = qvgen.build_program(ns)
    text = qvgen.render(p)
    asm_path = out_base.with_suffix(".s")
    asm_path.write_text(text)
    elf, hexf = qvgen.toolchain_build(asm_path, out_base, ns.isa, bool(p.pagetable_data))
    tohost = subprocess.run(
        ["riscv64-unknown-elf-nm", str(elf)], check=True,
        capture_output=True, text=True,
    ).stdout
    m = re.search(r"^([0-9a-fA-F]+) \S+ tohost$", tohost, re.M)
    if not m:
        raise RuntimeError(f"seed={seed}: no tohost symbol in {elf}")
    return elf, hexf, m.group(1)


# ---------------------------------------------------------------------
# Our own core, via rvfi_tracer.sv
# ---------------------------------------------------------------------
CORE_FILES = ["decoder.sv", "alu.sv", "c_expand.sv", "core.sv", "csr_file.sv",
              "divider.sv", "register_file.sv", "wb4_sram.sv", "wb_arbiter2.sv"]


def build_rvfi_tracer(vvp_path: Path):
    cmd = ["iverilog", "-g2012", "-DRISCV_FORMAL", "-I", ".", "-I", "defaults",
           "-o", str(vvp_path)] + CORE_FILES + [str(TESTBENCH_DIR / "rvfi_tracer.sv")]
    subprocess.run(cmd, cwd=DESIGN_DIR, check=True, capture_output=True, text=True)


_RVFI_RE = re.compile(
    r"rvfi order=(?P<order>\d+) pc_rdata=(?P<pc_rdata>[0-9a-f]+) "
    r"pc_wdata=(?P<pc_wdata>[0-9a-f]+) insn=(?P<insn>[0-9a-f]+) "
    r"mode=(?P<mode>\d+) trap=(?P<trap>[01]) intr=(?P<intr>[01]) "
    r"cause=(?P<cause>[0-9a-f]+) tval=(?P<tval>[0-9a-f]+) "
    r"rd_addr=(?P<rd_addr>\d+) rd_wdata=(?P<rd_wdata>[0-9a-f]+) "
    r"rs1_addr=(?P<rs1_addr>\d+) rs1_rdata=(?P<rs1_rdata>[0-9a-f]+) "
    r"rs2_addr=(?P<rs2_addr>\d+) rs2_rdata=(?P<rs2_rdata>[0-9a-f]+) "
    r"mem_addr=(?P<mem_addr>[0-9a-f]+) mem_rmask=(?P<mem_rmask>[0-9a-f]+) "
    r"mem_wmask=(?P<mem_wmask>[0-9a-f]+) mem_rdata=(?P<mem_rdata>[0-9a-f]+) "
    r"mem_wdata=(?P<mem_wdata>[0-9a-f]+)"
)


def run_our_core(vvp_path: Path, hexf: Path, tohost_hex: str, timeout_cycles: int):
    proc = subprocess.run(
        ["vvp", str(vvp_path), f"+HEXFILE={hexf}", f"+TOHOST_ADDR={tohost_hex}",
         f"+TIMEOUT={timeout_cycles}"],
        cwd=DESIGN_DIR, check=True, capture_output=True, text=True,
    )
    records = []
    for line in proc.stdout.splitlines():
        m = _RVFI_RE.match(line)
        if m:
            d = m.groupdict()
            mem_addr = int(d["mem_addr"], 16)
            mem_rmask = int(d["mem_rmask"], 16)
            mem_wmask = int(d["mem_wmask"], 16)
            # Normalize RVFI's ALIGNED_MEM convention (mem_addr is the
            # dword-aligned base; rmask/wmask are byte lanes WITHIN it)
            # to the same "precise byte address" shape Sail's own
            # mem[R/W,addr] trace already uses -- see diff_one's own
            # comment on why these must match before comparing.
            mask = mem_rmask or mem_wmask
            if mask:
                mem_addr += (mask & -mask).bit_length() - 1
            records.append({
                "pc": int(d["pc_rdata"], 16),
                "insn": int(d["insn"], 16),
                "trap": d["trap"] == "1",
                "cause": int(d["cause"], 16),
                "tval": int(d["tval"], 16),
                "rd_addr": int(d["rd_addr"]),
                "rd_wdata": int(d["rd_wdata"], 16),
                "mem_addr": mem_addr,
                "mem_rmask": mem_rmask,
                "mem_wmask": mem_wmask,
            })
    done = "RVFI_DONE" in proc.stdout
    return records, done


# ---------------------------------------------------------------------
# Sail, via --trace-instr/--trace-reg/--trace-mem/--trace-exception.
# Free-running --trace-rvfi produces no output in this build (it's tied
# to the RVFI-DII socket protocol, not this text trace log) -- these 4
# categories together give an equivalent per-retirement record.
# ---------------------------------------------------------------------
_SAIL_INSTR_RE = re.compile(
    r"^\[(?P<order>\d+)\] \[(?P<priv>[MSU])\]: 0x(?P<pc>[0-9A-Fa-f]+) "
    r"\(0x(?P<insn>[0-9A-Fa-f]+)\)"
)
_SAIL_REG_RE = re.compile(r"^x(?P<reg>\d+) <- 0x(?P<val>[0-9A-Fa-f]+)$")
_SAIL_MEM_RE = re.compile(
    # Reads/fetches print "-> 0xVAL" (data flowing out of memory);
    # writes print "<- 0xVAL" (data flowing in) -- same line shape,
    # opposite arrow, both accepted here (kind already says which).
    r"^mem\[(?P<kind>[RWX]),0x(?P<addr>[0-9A-Fa-f]+)\] (?:->|<-) 0x(?P<val>[0-9A-Fa-f]*)$"
)
_SAIL_EXC_RE = re.compile(
    r"^handling exc#(?P<cause>\S+) at priv (?P<priv>[MSU]) with tval "
    r"0x(?P<tval>[0-9A-Fa-f]+)$"
)


def run_sail(elf: Path, timeout_cycles: int):
    proc = subprocess.run(
        [str(SAIL_BIN), "--config-override", str(SAIL_CONFIG),
         f"--inst-limit={timeout_cycles}", "--trace-instr", "--trace-reg",
         "--trace-mem", "--trace-exception", "--trace-htif", str(elf)],
        check=True, capture_output=True, text=True,
    )
    lines = proc.stdout.splitlines()
    records = []
    cur = None
    i = 0
    while i < len(lines):
        line = lines[i]
        m = _SAIL_INSTR_RE.match(line)
        if m:
            if cur is not None:
                records.append(cur)
            cur = {
                "pc": int(m.group("pc"), 16),
                "insn": int(m.group("insn"), 16),
                "trap": False, "cause": 0, "tval": 0,
                "rd_addr": 0, "rd_wdata": 0,
                "mem_addr": 0, "mem_rmask": 0, "mem_wmask": 0,
            }
            i += 1
            continue
        m = _SAIL_REG_RE.match(line)
        if m and cur is not None:
            reg = int(m.group("reg"))
            if reg != 0:
                cur["rd_addr"] = reg
                cur["rd_wdata"] = int(m.group("val"), 16)
            i += 1
            continue
        m = _SAIL_MEM_RE.match(line)
        if m and cur is not None and m.group("kind") != "X":
            width = max(1, len(m.group("val")) // 2) if m.group("val") else 1
            mask = (1 << width) - 1
            addr = int(m.group("addr"), 16)
            if m.group("kind") == "R":
                cur["mem_addr"], cur["mem_rmask"] = addr, mask
            else:
                cur["mem_addr"], cur["mem_wmask"] = addr, mask
            i += 1
            continue
        m = _SAIL_EXC_RE.match(line)
        if m:
            name = m.group("cause")
            if name not in SAIL_CAUSE_NAMES:
                raise KeyError(
                    f"unrecognized Sail exception name {name!r} at trace "
                    f"line {i} -- add it to SAIL_CAUSE_NAMES (see that "
                    f"table's own header comment)"
                )
            cause = SAIL_CAUSE_NAMES[name]
            tval = int(m.group("tval"), 16)
            if cause in FETCH_CAUSES:
                # A fetch-side fault for the NEXT instruction: nothing
                # was successfully fetched/decoded (no `[N]: pc (insn)
                # mnemonic` line for it), so this is its OWN phantom
                # retirement -- pc = the failed fetch address = tval --
                # not an amendment to `cur`, which is still the PREVIOUS
                # instruction's own (already-complete, non-trapping)
                # record. A REAL parsing bug this fixes, found by direct
                # comparison against our own core: without this split, a
                # fetch fault immediately after (say) `mret` was
                # misattributed to the mret itself, reporting a false
                # trap on an instruction that genuinely didn't trap.
                if cur is not None:
                    records.append(cur)
                cur = {
                    "pc": tval, "insn": 0,
                    "trap": True, "cause": cause, "tval": tval,
                    "rd_addr": 0, "rd_wdata": 0,
                    "mem_addr": 0, "mem_rmask": 0, "mem_wmask": 0,
                }
            elif cur is not None:
                cur["trap"] = True
                cur["cause"] = cause
                cur["tval"] = tval
            i += 1
            continue
        i += 1
    if cur is not None:
        records.append(cur)
    done = "SUCCESS" in proc.stdout or "htif-syscall-proxy" in proc.stdout
    return records, done


# ---------------------------------------------------------------------
# Diff
# ---------------------------------------------------------------------
# Fields compared per retirement, and how forgiving each is: some fields
# are only meaningful on a trapping retirement (Sail doesn't report a
# register-write line differently depending on cause, so rd_addr/wdata
# are compared unconditionally; mem is compared only when EITHER side
# reports an access, and cause/tval only when EITHER side trapped).
def diff_one(ours: dict, sail: dict) -> list[str]:
    problems = []
    if ours["pc"] != sail["pc"]:
        problems.append(f"pc: ours={ours['pc']:#x} sail={sail['pc']:#x}")
    # insn is meaningless for a fetch-fault retirement (nothing was
    # successfully decoded) -- skip it when EITHER side reports one, to
    # avoid comparing a real placeholder encoding (ours) against a
    # synthetic 0 (sail's phantom record -- see run_sail's own comment).
    ours_fetch_fault = ours["trap"] and ours["cause"] in FETCH_CAUSES
    sail_fetch_fault = sail["trap"] and sail["cause"] in FETCH_CAUSES
    if not (ours_fetch_fault or sail_fetch_fault) and ours["insn"] != sail["insn"]:
        problems.append(f"insn: ours={ours['insn']:#010x} sail={sail['insn']:#010x}")
    if ours["trap"] != sail["trap"]:
        problems.append(f"trap: ours={ours['trap']} sail={sail['trap']}")
    elif ours["trap"]:
        if ours["cause"] != sail["cause"]:
            problems.append(f"cause: ours={ours['cause']} sail={sail['cause']}")
        if ours["tval"] != sail["tval"]:
            problems.append(f"tval: ours={ours['tval']:#x} sail={sail['tval']:#x}")
    if ours["rd_addr"] != sail["rd_addr"]:
        problems.append(f"rd_addr: ours={ours['rd_addr']} sail={sail['rd_addr']}")
    elif ours["rd_addr"] != 0 and ours["rd_wdata"] != sail["rd_wdata"]:
        problems.append(f"rd_wdata (x{ours['rd_addr']}): "
                         f"ours={ours['rd_wdata']:#x} sail={sail['rd_wdata']:#x}")
    # Memory-access fields are only meaningfully comparable for a
    # retirement that genuinely reached memory. A trapping instruction
    # never does (the fault is detected before any bus access) -- but
    # whether a "would-be" access shape is STILL reported on that
    # retirement is a reporting convention, not a correctness signal:
    # this core's own RVFI tap derives mem_rmask/addr combinationally
    # from the decoded instruction regardless of trap status, while
    # Sail reports nothing for a retirement that never actually
    # accessed memory. Comparing them for a trap would just be diffing
    # two conventions, not two behaviors -- skip it whenever EITHER
    # side trapped (found by direct comparison: a misaligned load,
    # correctly agreed by both sides on cause/tval, still showed a
    # spurious mem-access mismatch here before this exclusion).
    if not (ours["trap"] or sail["trap"]):
        ours_mem = ours["mem_rmask"] or ours["mem_wmask"]
        sail_mem = sail["mem_rmask"] or sail["mem_wmask"]
        if bool(ours_mem) != bool(sail_mem):
            problems.append(f"mem access presence: ours={bool(ours_mem)} sail={bool(sail_mem)}")
        elif ours_mem and ours["mem_addr"] != sail["mem_addr"]:
            problems.append(f"mem_addr: ours={ours['mem_addr']:#x} sail={sail['mem_addr']:#x}")
    return problems


def diff_seed(seed: int, args, vvp_path: Path, out_dir: Path, verbose: bool) -> bool:
    base = out_dir / f"sail_diff_{seed}"
    elf, hexf, tohost_hex = toolchain_build_sail_safe(seed, args, base)
    ours, ours_done = run_our_core(vvp_path, hexf, tohost_hex, args.timeout)
    sail, sail_done = run_sail(elf, args.timeout)

    n = min(len(ours), len(sail))
    for i in range(n):
        problems = diff_one(ours[i], sail[i])
        if problems:
            print(f"seed={seed}: MISMATCH at retirement {i} "
                  f"(ours pc={ours[i]['pc']:#x}, sail pc={sail[i]['pc']:#x})")
            for p in problems:
                print(f"    {p}")
            print("  context (last 3 retirements, ours | sail):")
            for j in range(max(0, i - 2), i + 1):
                print(f"    [{j}] ours: {ours[j]}")
                print(f"    [{j}]  sail: {sail[j]}")
            return False

    if len(ours) != len(sail):
        print(f"seed={seed}: MISMATCH -- retirement count differs: "
              f"ours={len(ours)} sail={len(sail)}")
        shorter, longer, who = (ours, sail, "sail") if len(ours) < len(sail) else (sail, ours, "ours")
        print(f"  first extra retirement on the {who} side: {longer[len(shorter)]}")
        return False

    if ours_done != sail_done:
        print(f"seed={seed}: MISMATCH -- completion differs: "
              f"ours_done={ours_done} sail_done={sail_done}")
        return False

    if not ours_done:
        print(f"seed={seed}: NEITHER side reached tohost within "
              f"{args.timeout} instructions (both traces agree up to "
              f"there, but this needs a longer --timeout or is a real "
              f"hang -- check by hand)")
        return False

    if verbose:
        print(f"seed={seed}: PASS ({len(ours)} retirements)")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", required=True,
                     help="comma/range list, e.g. '1-20' or '1,2,3' or '1-5,9,20-22'")
    ap.add_argument("--isa", choices=["i", "im", "imc", "imac"], default="imac")
    ap.add_argument("--priv", choices=["m", "msu"], default="msu")
    ap.add_argument("--len", type=int, default=200)
    ap.add_argument("--illegal-rate", type=float, default=0.02)
    ap.add_argument("--misalign-rate", type=float, default=0.05)
    ap.add_argument("--timeout", type=int, default=20000,
                     help="instruction/cycle bound for BOTH sides")
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    seeds = []
    for part in args.seeds.split(","):
        if "-" in part:
            lo, hi = part.split("-")
            seeds.extend(range(int(lo), int(hi) + 1))
        else:
            seeds.append(int(part))

    out_dir = args.out_dir or (LOCKSTEP_DIR / "gen" / "_sail_diff_scratch")
    out_dir.mkdir(parents=True, exist_ok=True)
    vvp_path = out_dir / "rvfi_tracer.vvp"
    print(f"building {vvp_path.name}...")
    build_rvfi_tracer(vvp_path)

    failed = []
    for seed in seeds:
        try:
            ok = diff_seed(seed, args, vvp_path, out_dir, args.verbose)
        except Exception as e:
            print(f"seed={seed}: ERROR -- {e}")
            ok = False
        if not ok:
            failed.append(seed)

    print(f"\n{len(seeds) - len(failed)}/{len(seeds)} seeds clean.")
    if failed:
        print(f"failed seeds: {failed}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
