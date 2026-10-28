#!/usr/bin/env python3
"""check_vectors_sail.py -- replay a gen_vectors.py file on Sail and compare every result and flag set.

This checks the vector generator (its TestFloat mapping and its golden model) against Sail before any RTL is held
to the vectors. Each chunk of vectors becomes one program: a table of operands, and one stub per vector holding the
instruction and a return. A loop loads rs1-rs3 and frm, clears fflags, calls the stub, and copies f4, x4 and fflags to
x30, x29 and x28, which Sail's trace prints.

    python3 check_vectors_sail.py smoke.vec [--max N] [--chunk 12000]
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SAIL = Path.home() / "sail-install" / "bin" / "sail_riscv_sim"
OVERRIDES = [REPO / "verification" / "lockstep" / "sail_config_override.json", HERE / "sail_fd_override.json"]


def rd_is_int(insn):
    if insn & 0x7F != 0x53:
        return False
    return (insn >> 27) in (0b10100, 0b11000, 0b11100)


PROGRAM = """
    .option norvc
    .section .text
    .globl _start
_start:
    li      t0, 0x6000
    csrs    mstatus, t0
    la      s0, table
    la      s1, stubs
    li      s2, {n}
    li      x31, 0
1:  ld      x1, 0(s0)
    fmv.d.x f1, x1
    ld      t0, 8(s0)
    fmv.d.x f2, t0
    ld      t0, 16(s0)
    fmv.d.x f3, t0
    ld      t0, 24(s0)
    csrw    frm, t0
    csrw    fflags, x0
    jalr    t1, 0(s1)
    fmv.x.d x30, f4
    mv      x29, x4
    csrr    x28, fflags
    addi    x31, x31, 1
    addi    s0, s0, 32
    addi    s1, s1, 8
    bne     x31, s2, 1b
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
2:  j       2b
    .balign 8
stubs:
{stubs}
    .section .data
    .balign 8
table:
{table}
    .balign 8
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
"""

LD = """OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS { . = 0x0; .text : { *(.text*) } .data : { *(.data*) } }
"""


def run_chunk(vecs, d):
    stubs = "\n".join(f"    .word 0x{v[0]:08x}\n    jr t1" for v in vecs)
    table = "\n".join(f"    .dword 0x{v[2]:016x}, 0x{v[3]:016x}, 0x{v[4]:016x}, 0x{v[1]:x}" for v in vecs)
    src, ld, elf = Path(d) / "chk.S", Path(d) / "chk.ld", Path(d) / "chk.elf"
    src.write_text(PROGRAM.format(n=len(vecs), stubs=stubs, table=table))
    ld.write_text(LD)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv64imafdc_zicsr", "-mabi=lp64", "-nostdlib", "-mno-relax",
                    "-T", str(ld), "-o", str(elf), str(src)], check=True)
    cmd = [str(SAIL)]
    for o in OVERRIDES:
        cmd += ["--config-override", str(o)]
    cmd += [f"--inst-limit={40 * len(vecs) + 1000}", "--trace-reg", str(elf)]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    got = []
    cur = None                            # the first x31 write is the loop's `li x31, 0`, before any vector
    for line in out.splitlines():
        m = re.match(r"^x(28|29|30|31) <- 0x([0-9A-Fa-f]+)$", line)
        if not m:
            continue
        reg, val = int(m.group(1)), int(m.group(2), 16)
        if reg == 31:
            if cur is not None:
                got.append(cur)
            cur = {}
        elif cur is not None:
            cur[reg] = val
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vecfile")
    ap.add_argument("--max", type=int, default=0)
    ap.add_argument("--chunk", type=int, default=12000)
    a = ap.parse_args()
    vecs = []
    for line in open(a.vecfile):
        f = line.split()
        if len(f) == 7:
            vecs.append([int(x, 16) for x in f])
        if a.max and len(vecs) >= a.max:
            break
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for base in range(0, len(vecs), a.chunk):
            chunk = vecs[base:base + a.chunk]
            got = run_chunk(chunk, d)
            if len(got) != len(chunk):
                print(f"chunk at {base}: Sail ran {len(got)} of {len(chunk)} vectors")
                bad += 1
                continue
            for i, (v, g) in enumerate(zip(chunk, got)):
                res = g.get(29) if rd_is_int(v[0]) else g.get(30)
                if res != v[5] or g.get(28) != v[6]:
                    bad += 1
                    if bad <= 20:
                        print(f"MISMATCH #{base + i}: insn={v[0]:08x} frm={v[1]} a={v[2]:016x} b={v[3]:016x} "
                              f"c={v[4]:016x} expect={v[5]:016x}/{v[6]:02x} sail={res if res is None else f'{res:016x}'}"
                              f"/{g.get(28) if g.get(28) is None else f'{g.get(28):02x}'}")
    print(f"{len(vecs)} vectors, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
