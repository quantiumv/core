#!/usr/bin/env python3
"""run_probes.py -- build probe_fd.S, run it on Sail with F/D/Zcd on, print one line per probe.

Each probe starts with a write of its id to x31 and records its observations in x28-x30; a trap writes mcause to x27
(see probe_fd.S). The table lists, per probe id, every write to x27-x30 in order.

Run inside WSL from the repo root:  python3 verification/fpu/probes/run_probes.py [--raw]
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SAIL = Path.home() / "sail-install" / "bin" / "sail_riscv_sim"
OVERRIDES = [REPO / "verification" / "lockstep" / "sail_config_override.json", HERE.parent / "sail_fd_override.json"]


def main():
    raw = "--raw" in sys.argv
    with tempfile.TemporaryDirectory() as d:
        elf = Path(d) / "probe_fd.elf"
        subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv64imafdc_zicsr", "-mabi=lp64", "-nostdlib", "-mno-relax",
                        "-T", str(HERE / "probe.ld"), "-o", str(elf), str(HERE / "probe_fd.S")], check=True)
        cmd = [str(SAIL)]
        for o in OVERRIDES:
            cmd += ["--config-override", str(o)]
        cmd += ["--inst-limit=20000", "--trace-instr", "--trace-reg", "--trace-exception", "--trace-htif", str(elf)]
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    if raw:
        print(out)
    cur = None
    rows = {}
    order = []
    for line in out.splitlines():
        m = re.match(r"^x(\d+) <- 0x([0-9A-Fa-f]+)$", line)
        if not m:
            continue
        reg, val = int(m.group(1)), int(m.group(2), 16)
        if reg == 31:
            cur = val
            if cur not in rows:
                rows[cur] = []
                order.append(cur)
            continue
        if cur is not None and 27 <= reg <= 30:
            rows[cur].append(("trap" if reg == 27 else f"x{reg}", val))
    for pid in order:
        print(f"{pid:3d}: " + "  ".join(f"{n}={v:#x}" for n, v in rows[pid]))


if __name__ == "__main__":
    main()
