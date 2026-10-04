#!/usr/bin/env python3
"""gen_alu.py -- seeded random RV64IM + Zicsr programs with control flow and traps.

Bring-up corpus for design/pipe/core_pipe.sv while it implements the
single-cycle integer class (RV64I register/immediate ops including the
*W forms, LUI, AUIPC, MUL/MULH/MULHSU/MULHU/MULW), conditional
branches, JAL, JALR, Zicsr, M-mode traps and RVC. Assemble with
-march=rv64imc_zicsr.

Everything runs in M-mode. A prologue points mtvec at a fixed handler
(.text.handlers, 0x8000) that reads mcause/mtval and returns to
mepc + 4; trap sources are ECALL, EBREAK, an all-zero word, writes to
read-only CSRs and any access to debug/trigger CSRs. CSR accesses
otherwise stick to CSRs whose writes can't change control flow or
privilege (see CSR_RW/CSR_RO), and MRET only ever runs in the handler,
so mstatus.MPP and MIE never leave their M-mode, interrupts-off state.

Every register is first seeded with a value from a mix of edge cases
(0, 1, -1, INT64_MIN, INT64_MAX) and random 64-bit patterns. The body is
a sequence of segments, each of which can only be entered at its first
instruction, so every program terminates:

  straight  ALU ops, forward branches, JAL, and auipc(+addi)+JALR
            sequences, all targeting a later instruction of the same
            segment or the segment's end
  loop      li x31, K; body; addi x31, x31, -1; bne x31, x0, body
            (body branches may target the decrement but never the bne;
            x31 is written only here)

No branch may land after an auipc in the sequence that uses it. Sources
favour recent destinations (--dep-bias), so the bypass path feeds
branch operands as well as ALU ones.

RVC is on: gas compresses whatever it can, so 16- and 32-bit
instructions mix freely and 32-bit ones regularly straddle a dword. All
addressing is by label (%pcrel_hi/%pcrel_lo for JALR). Trap sources
stay 4 bytes long for the handler's mepc + 4 (EBREAK is emitted as
.4byte so gas can't pick C.EBREAK; a reserved compressed encoding is
paired with a C.NOP).

The program ends at the end_of_test symbol; core_pipe has no way to
stop, so run_rvfi_diff.sh compares retirements up to the first one at
that pc.

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

# CSRs safe to write in M-mode without changing control flow or enabling
# anything: scratch/trap CSRs, interrupt enables (mstatus.MIE stays 0),
# delegation (never applies to M-mode traps), and an unbacked custom
# address (reads 0, ignores writes).
CSR_RW = [0x340, 0x341, 0x342, 0x343, 0x304, 0x302, 0x303, 0x7C0]
# read with write-suppressed forms only: mstatus/mtvec/mip are writable
# but must not change, the rest are read-only; never cycle/time, whose
# values depend on timing
CSR_RO = [0x300, 0x301, 0x305, 0x344, 0xF11, 0xF12, 0xF13, 0xF14, 0xB02, 0xC02]
# illegal in M-mode outside debug mode: debug and trigger CSRs at all,
# read-only CSRs when actually written
CSR_DEBUG = [0x7B0, 0x7B1, 0x7A0, 0x7A4]
CSR_READONLY = [0xF14, 0xC02, 0xC00]
# reserved compressed encodings c_expand.sv flags illegal; each is
# followed by a C.NOP so the trap source stays 4 bytes long
C_RESERVED = [0x0008, 0x6101, 0x2001, 0x4002, 0x6002, 0x8002, 0x8000, 0x2000]
HANDLER = [                      # .text.handlers at 0x8000 (mtvec, direct)
    "csrr x29, mcause",
    "csrr x28, mtval",
    "csrr x30, mepc",
    "addi x30, x30, 4",          # every trap source here is 4 bytes long
    "csrw mepc, x30",
    "mret",
]


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

    def system(self):
        """A CSR access or a system instruction. Returns (text, traps)."""
        rng = self.rng
        r = rng.random()
        if r < 0.55:
            csr = rng.choice(CSR_RW)
            op = rng.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"])
            if op.endswith("i"):
                src = 0 if rng.random() < 0.3 else rng.randint(0, 31)
            else:
                src = "x0" if rng.random() < 0.3 else f"x{self.src()}"
            return f"{op} x{self.dst()}, {csr:#x}, {src}", False
        if r < 0.80:
            csr = rng.choice(CSR_RO)
            op = rng.choice(["csrrs x{rd}, {csr:#x}, x0", "csrrc x{rd}, {csr:#x}, x0",
                             "csrrsi x{rd}, {csr:#x}, 0", "csrrci x{rd}, {csr:#x}, 0"])
            return op.format(rd=self.dst(), csr=csr), False
        if r < 0.85:
            return f"csrrs x{self.dst()}, {rng.choice(CSR_DEBUG):#x}, x0", True
        if r < 0.90:
            return f"csrrw x{self.dst()}, {rng.choice(CSR_READONLY):#x}, x{self.src()}", True
        return rng.choice([
            ("ecall", True),
            (".4byte 0x00100073", True),                    # EBREAK, never C.EBREAK
            (".4byte 0", True),
            (f".2byte {rng.choice(C_RESERVED):#06x}\n    .2byte 0x0001", True),
            ("wfi", False),
        ])

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
        self.seg_traps = 0
        i = 0
        while i < n:
            r = rng.random()
            if r < 0.08:
                text, traps = self.system()
                items.append(text); i += 1
                self.seg_traps += traps
            elif r < 0.15:
                a, b = self.branch_srcs()
                items.append(("br", rng.choice(B_OPS), a, b, None)); i += 1
            elif r < 0.20:
                items.append(("jal", self.dst(), None)); i += 1
            elif r < 0.25 and i + 2 < n:
                # auipc %pcrel_hi(T) [; addi %pcrel_lo] ; jalr -- the odd
                # form jumps to T+1, which JALR's bit-0 clear turns into T.
                # Nothing may land after the auipc, whose base it needs.
                base = rng.randint(1, LOOP_REG - 1)
                odd = rng.random() < 0.3
                auipc = i
                items.append(("auipc", base))
                if odd:
                    items.append(("addi_lo", base, auipc))
                    forbidden.add(i + 1)
                forbidden.add(i + 1 + odd)
                items.append(("jalr", self.dst(), base, odd, auipc, None))
                i += 2 + odd
                self.recent.append(base)
            else:
                items.append(self.alu()); i += 1
        # resolve targets now that every slot exists
        out = []
        for slot, it in enumerate(items):
            if isinstance(it, tuple) and it[0] in ("br", "jal", "jalr"):
                cands = [t for t in range(slot + 1, min(slot + 8, n) + 1) if t not in forbidden]
                t = rng.choice(cands) if cands else n
                it = it[:-1] + (t,)
            out.append(it)
        return out


def render(items, base_slot, labels):
    """Turn a segment's items into asm lines; labels maps absolute slot -> name."""
    lab = lambda s: labels.setdefault(s, f"L{s}")
    # each auipc needs its jalr's target
    jalr_tgt = {it[4]: it[-1] for it in items if isinstance(it, tuple) and it[0] == "jalr"}
    lines = []
    for k, it in enumerate(items):
        slot = base_slot + k
        if isinstance(it, str):
            lines.append((slot, it))
            continue
        kind = it[0]
        if kind == "auipc":
            lines.append((slot, f"auipc x{it[1]}, %pcrel_hi({lab(base_slot + jalr_tgt[k])})"))
        elif kind == "addi_lo":
            lines.append((slot, f"addi x{it[1]}, x{it[1]}, %pcrel_lo({lab(base_slot + it[2])})"))
        elif kind == "br":
            lines.append((slot, f"{it[1]} x{it[2]}, x{it[3]}, {lab(base_slot + it[-1])}"))
        elif kind == "jal":
            lines.append((slot, f"jal x{it[1]}, {lab(base_slot + it[-1])}"))
        else:  # jalr
            _, rd, base, odd, auipc, _ = it
            off = "1" if odd else f"%pcrel_lo({lab(base_slot + auipc)})"
            lines.append((slot, f"jalr x{rd}, {off}(x{base})"))
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

    lines = [(0, "lui x30, 8"), (1, "csrw mtvec, x30")]     # (slot, text); handler at 0x8000
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
            lines += render(body, base + 1, labels)
            labels.setdefault(base + 1, f"L{base + 1}")
            lines.append((base + 1 + body_n, f"addi x{LOOP_REG}, x{LOOP_REG}, -1"))
            lines.append((base + 2 + body_n, f"bne x{LOOP_REG}, x0, L{base + 1}"))
            dyn += 1 + k * (body_n + 2 + g.seg_traps * len(HANDLER))
        else:
            n = rng.randint(4, 16)
            seg = g.segment(n)
            lines += render(seg, base, labels)
            dyn += n + g.seg_traps * len(HANDLER)

    count = len(lines)
    if 4 * count > 0x8000:
        raise SystemExit("program overflows .text.entry (0x8000 bytes)")

    with open(a.out, "w") as f:
        f.write(f"# gen_alu.py --seed {a.seed} --len {a.len} --dep-bias {a.dep_bias}\n")
        f.write(".section .text.entry\n.globl _start\n_start:\n")
        for slot, text in lines:
            if slot in labels:
                f.write(f"{labels[slot]}:\n")
            f.write(f"    {text}\n")
        if count in labels:
            f.write(f"{labels[count]}:\n")
        f.write(".globl end_of_test\nend_of_test:\n")
        f.write(".section .text.handlers\ntrap_handler:\n")
        for text in HANDLER:
            f.write(f"    {text}\n")
    print(count, dyn)


if __name__ == "__main__":
    main()
