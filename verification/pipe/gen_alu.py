#!/usr/bin/env python3
"""gen_alu.py -- seeded random straight-line RV64IM integer-ALU programs.

Bring-up corpus for design/pipe/core_pipe.sv while it implements only
the single-cycle integer ALU class: RV64I register/immediate ops
including the *W forms, LUI, AUIPC, and MUL/MULH/MULHSU/MULHU/MULW. No
branches, so a program just runs off its end; run_rvfi_diff.sh compares
exactly the number of retirements printed on stdout. Assemble with
-march=rv64im (never C: gas would emit RVC, which isn't decoded yet).

Every register is first seeded with a value from a mix of edge cases
(0, 1, -1, INT64_MIN, INT64_MAX) and random 64-bit patterns. The body
then favours sources written in the last few instructions (--dep-bias),
so back-to-back RAW dependences -- the bypass path -- are common, as are
WAW chains and x0 destinations.

Usage: gen_alu.py --seed N --len L -o prog.s   (prints the instruction count)
"""
import argparse
import random

R_OPS = ["add", "sub", "slt", "sltu", "xor", "or", "and", "sll", "srl", "sra",
         "addw", "subw", "sllw", "srlw", "sraw",
         "mul", "mulh", "mulhsu", "mulhu", "mulw"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi", "addiw"]
SH_OPS = ["slli", "srli", "srai"]
SHW_OPS = ["slliw", "srliw", "sraiw"]
U_OPS = ["lui", "auipc"]
EDGE_IMM = [0, 1, -1, 2047, -2048, 0x555, -0x556]
EDGE_SH = [0, 1, 31, 32, 33, 63]
EDGE_SHW = [0, 1, 15, 16, 30, 31]
EDGE_U = [0, 1, 0x7FFFF, 0x80000, 0xFFFFF]


def imm12(rng):
    return rng.choice(EDGE_IMM) if rng.random() < 0.25 else rng.randint(-2048, 2047)


def shamt(rng, edges, top):
    return rng.choice(edges) if rng.random() < 0.25 else rng.randint(0, top)


def imm20(rng):
    return rng.choice(EDGE_U) if rng.random() < 0.25 else rng.randint(0, 0xFFFFF)


def seed_reg(rng, r):
    kind = rng.choice(["zero", "small", "m1", "min", "max", "rand", "rand", "rand"])
    if kind == "zero":
        return [f"addi x{r}, x0, 0"]
    if kind == "small":
        return [f"addi x{r}, x0, {imm12(rng)}"]
    if kind == "m1":
        return [f"addi x{r}, x0, -1"]
    if kind == "min":
        return [f"addi x{r}, x0, 1", f"slli x{r}, x{r}, 63"]
    if kind == "max":
        return [f"addi x{r}, x0, -1", f"srli x{r}, x{r}, 1"]
    out = [f"addi x{r}, x0, {imm12(rng)}"]
    for _ in range(5):
        out += [f"slli x{r}, x{r}, 12", f"xori x{r}, x{r}, {rng.randint(0, 2047)}"]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--len", type=int, default=400, help="body length (after register seeding)")
    ap.add_argument("--dep-bias", type=float, default=0.6)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    rng = random.Random(a.seed)

    lines = []
    for r in range(1, 32):
        lines += seed_reg(rng, r)

    recent = []
    for _ in range(a.len):
        def src():
            if recent and rng.random() < a.dep_bias:
                return rng.choice(recent[-3:])
            return rng.randint(0, 31)

        rd = 0 if rng.random() < 0.05 else rng.randint(1, 31)
        cls = rng.random()
        if cls < 0.5:
            lines.append(f"{rng.choice(R_OPS)} x{rd}, x{src()}, x{src()}")
        elif cls < 0.75:
            lines.append(f"{rng.choice(I_OPS)} x{rd}, x{src()}, {imm12(rng)}")
        elif cls < 0.85:
            lines.append(f"{rng.choice(SH_OPS)} x{rd}, x{src()}, {shamt(rng, EDGE_SH, 63)}")
        elif cls < 0.95:
            lines.append(f"{rng.choice(SHW_OPS)} x{rd}, x{src()}, {shamt(rng, EDGE_SHW, 31)}")
        else:
            lines.append(f"{rng.choice(U_OPS)} x{rd}, {imm20(rng)}")
        recent.append(rd)

    if 4 * len(lines) > 0x8000:
        raise SystemExit("program overflows .text.entry (0x8000 bytes)")

    with open(a.out, "w") as f:
        f.write(f"# gen_alu.py --seed {a.seed} --len {a.len} --dep-bias {a.dep_bias}\n")
        f.write(".option norvc\n.section .text.entry\n.globl _start\n_start:\n")
        for ln in lines:
            f.write(f"    {ln}\n")
    print(len(lines))


if __name__ == "__main__":
    main()
