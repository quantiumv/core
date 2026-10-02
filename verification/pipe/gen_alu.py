#!/usr/bin/env python3
"""gen_alu.py -- seeded random RV64IM integer programs with control flow.

Bring-up corpus for design/pipe/core_pipe.sv while it implements the
single-cycle integer class: RV64I register/immediate ops including the
*W forms, LUI, AUIPC, MUL/MULH/MULHSU/MULHU/MULW, conditional branches,
JAL and JALR. Assemble with -march=rv64im (never C: gas would emit RVC,
which isn't decoded yet).

Every register is first seeded with a value from a mix of edge cases
(0, 1, -1, INT64_MIN, INT64_MAX) and random 64-bit patterns. The body is
a sequence of segments, each of which can only be entered at its first
instruction, so every program terminates:

  straight  ALU ops, forward branches, JAL, and auipc+JALR pairs, all
            targeting a later instruction of the same segment or the
            segment's end
  loop      li x31, K; body; addi x31, x31, -1; bne x31, x0, body
            (body branches may target the decrement but never the bne;
            x31 is written only here)

No branch may land between an auipc and the jalr that uses it. Sources
favour recent destinations (--dep-bias), so the bypass path feeds
branch operands as well as ALU ones.

The program ends at 4 * count; core_pipe has no way to stop, so
run_rvfi_diff.sh compares retirements up to the first one at that pc.

Usage: gen_alu.py --seed N --len L -o prog.s
Prints "<static instruction count> <upper bound on dynamic count>".
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
B_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
EDGE_IMM = [0, 1, -1, 2047, -2048, 0x555, -0x556]
EDGE_SH = [0, 1, 31, 32, 33, 63]
EDGE_SHW = [0, 1, 15, 16, 30, 31]
EDGE_U = [0, 1, 0x7FFFF, 0x80000, 0xFFFFF]
LOOP_REG = 31
MAX_K = 4


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


class Gen:
    def __init__(self, rng, dep_bias):
        self.rng = rng
        self.dep_bias = dep_bias
        self.recent = []
        self.nlabel = 0

    def src(self):
        if self.recent and self.rng.random() < self.dep_bias:
            return self.rng.choice(self.recent[-3:])
        return self.rng.randint(0, 31)

    def dst(self):
        rd = 0 if self.rng.random() < 0.05 else self.rng.randint(1, LOOP_REG - 1)
        self.recent.append(rd)
        return rd

    def alu(self):
        rng = self.rng
        cls = rng.random()
        if cls < 0.5:
            return f"{rng.choice(R_OPS)} x{self.dst()}, x{self.src()}, x{self.src()}"
        if cls < 0.75:
            return f"{rng.choice(I_OPS)} x{self.dst()}, x{self.src()}, {imm12(rng)}"
        if cls < 0.85:
            return f"{rng.choice(SH_OPS)} x{self.dst()}, x{self.src()}, {shamt(rng, EDGE_SH, 63)}"
        if cls < 0.95:
            return f"{rng.choice(SHW_OPS)} x{self.dst()}, x{self.src()}, {shamt(rng, EDGE_SHW, 31)}"
        return f"{rng.choice(U_OPS)} x{self.dst()}, {imm20(rng)}"

    def branch_srcs(self):
        a = self.src()
        b = a if self.rng.random() < 0.2 else self.src()   # equal operands: BEQ/BGE/BGEU taken
        return a, b

    def segment(self, n):
        """n slots of code: strings, or ('br'|'jal'|'jalr', ..., target_slot)
        tuples whose target slot is a later slot of this segment, n meaning
        the segment end."""
        rng = self.rng
        items, forbidden = [], set()
        i = 0
        while i < n:
            r = rng.random()
            if r < 0.15:
                a, b = self.branch_srcs()
                items.append(("br", rng.choice(B_OPS), a, b, None)); i += 1
            elif r < 0.20:
                items.append(("jal", self.dst(), None)); i += 1
            elif r < 0.25 and i + 1 < n:
                base = rng.randint(1, LOOP_REG - 1)
                items.append(f"auipc x{base}, 0")
                forbidden.add(i + 1)                    # never land on the jalr
                items.append(("jalr", self.dst(), base, None)); i += 2
                self.recent.append(base)
            else:
                items.append(self.alu()); i += 1
        # resolve targets now that every slot exists
        out = []
        for slot, it in enumerate(items):
            if isinstance(it, tuple):
                cands = [t for t in range(slot + 1, min(slot + 8, n) + 1) if t not in forbidden]
                t = rng.choice(cands) if cands else n
                it = it[:-1] + (t,)
            out.append(it)
        return out


def render(rng, items, base_slot, labels):
    """Turn a segment's items into asm lines; labels maps absolute slot -> name."""
    lines = []
    for k, it in enumerate(items):
        slot = base_slot + k
        if isinstance(it, str):
            lines.append((slot, it))
            continue
        kind = it[0]
        tgt = base_slot + it[-1]
        name = labels.setdefault(tgt, f"L{tgt}")
        if kind == "br":
            lines.append((slot, f"{it[1]} x{it[2]}, x{it[3]}, {name}"))
        elif kind == "jal":
            lines.append((slot, f"jal x{it[1]}, {name}"))
        else:  # jalr: base was set by the auipc in the previous slot
            off = 4 * (tgt - (slot - 1))
            if rng.random() < 0.3:
                off += 1                                # bit 0 is cleared by JALR
            lines.append((slot, f"jalr x{it[1]}, {off}(x{it[2]})"))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--len", type=int, default=400, help="approximate body length")
    ap.add_argument("--dep-bias", type=float, default=0.6)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    g = Gen(rng, a.dep_bias)

    lines = []           # (slot, text)
    for r in range(1, 32):
        for t in seed_reg(rng, r):
            lines.append((len(lines), t))
    labels = {}
    dyn = len(lines)
    body_start = len(lines)

    while len(lines) - body_start < a.len:
        base = len(lines)
        if rng.random() < 0.3:
            k = rng.randint(1, MAX_K)
            body_n = rng.randint(3, 10)
            # slots: 0 = li, 1..body_n = body, body_n+1 = addi, body_n+2 = bne
            lines.append((base, f"addi x{LOOP_REG}, x0, {k}"))
            body = g.segment(body_n)
            lines += render(rng, body, base + 1, labels)
            labels.setdefault(base + 1, f"L{base + 1}")
            lines.append((base + 1 + body_n, f"addi x{LOOP_REG}, x{LOOP_REG}, -1"))
            lines.append((base + 2 + body_n, f"bne x{LOOP_REG}, x0, L{base + 1}"))
            dyn += 1 + k * (body_n + 2)
        else:
            n = rng.randint(4, 16)
            seg = g.segment(n)
            lines += render(rng, seg, base, labels)
            dyn += n

    count = len(lines)
    if 4 * count > 0x8000:
        raise SystemExit("program overflows .text.entry (0x8000 bytes)")

    with open(a.out, "w") as f:
        f.write(f"# gen_alu.py --seed {a.seed} --len {a.len} --dep-bias {a.dep_bias}\n")
        f.write(".option norvc\n.section .text.entry\n.globl _start\n_start:\n")
        for slot, text in lines:
            if slot in labels:
                f.write(f"{labels[slot]}:\n")
            f.write(f"    {text}\n")
        if count in labels:
            f.write(f"{labels[count]}:\n")
    print(count, dyn)


if __name__ == "__main__":
    main()
