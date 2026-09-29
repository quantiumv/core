#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
qvgen.py -- constrained-random RV64IMAC program generator (pipelining
track P3.2, see the plan at C:\\Users\\Potato\\.claude\\plans\\
research-the-c-extension-reflective-candle.md).

Emits real GNU-assembler text (.s), the same convention every other
hand-written program in this repo uses (firmware/*.s,
verification/riscv-arch-test's own build) -- NOT a hand-rolled
instruction encoder. riscv64-unknown-elf-as/-ld/-objcopy do the actual
encoding, so this script can't produce a malformed instruction; every
correctness question is about WHICH instructions/addresses/control flow
to emit, never HOW to encode them. --build invokes that real toolchain
(same -march building blocks firmware/Makefile already uses) to produce
a .elf/.hex pair.

Two audiences: (1) verification/lockstep/sail_diff.py (P3.2's own next
piece) runs --sail-safe output against sail_riscv_sim for a ground-truth
differential check, resolving the fetch-tval/LR-cause/trigger-priority
bugs (B10/B15/B16) deliberately deferred out of the P3.1 fix batch; (2)
the P3.4 lockstep harness runs the full (non-sail-safe) corpus against
core_pipe vs. ref_core. Both share this one generator -- the corpus is
identical, only the comparison target differs.

Memory map (1 MiB image, see verification/lockstep/gen/link.ld):
  0x00000-0x07FFF  .text.entry      -- preambles + the random main body
  0x08000-0x0FFFF  .text.handlers   -- M-mode/S-mode trap handlers
  0x10000-0x1FFFF  .data.sandbox    -- the load/store playground
  0x20000-0x2FFFF  .data.pagetables -- Sv39 page tables (--sv39 only)
  0x30000-0xFFFFF  .data.misc       -- tohost, trap counter, register dump

Register allocation (never overlapping -- the trap handlers and the
random body touch disjoint sets, so no save/restore dance is needed
around a trap; see the handler-design comment above _emit_handlers for
why that's sound for LOCKSTEP purposes specifically, even though it
wouldn't be for a real OS):
  x0            zero
  x1  (ra)      call/return (bounded-depth calls, see Program.call)
  x2  (sp)      reserved, unused (no stack -- call depth is tracked in
                this SCRIPT, not at runtime; see Program.call)
  x3  (gp)      reserved, unused
  x4  (tp)      reserved, unused
  x5-x12        handler scratch ONLY (t0,t1,t2,s0,s1,a0,a1,a2) -- never
                touched by the random body, so a trap can freely clobber
                them without needing to save/restore anything
  x13-x23       FREE POOL for random-body content (a3-a7,s2-s7 -- 11 regs)
  x24           epilogue marker (set immediately before the epilogue's
                own ECALL; the M-handler's ecall path checks it to tell
                the deliberate epilogue ecall apart from a random one)
  x25           recovery PC (fetch faults resume here, per the plan)
  x26           bad-address base (deliberately-invalid loads/stores are
                relative to this)
  x27           data (sandbox) base
  x28-x31       loop counters (one per nesting level; loops never nest
                deeper than 4, see Program.counted_loop)
"""

import argparse
import random
import subprocess
import sys
from pathlib import Path

GEN_DIR = Path(__file__).resolve().parent
REPO_ROOT = GEN_DIR.parent.parent.parent

# ---------------------------------------------------------------------
# Memory map (must match link.ld exactly)
# ---------------------------------------------------------------------
SANDBOX_BASE = 0x10000
SANDBOX_SIZE = 0x8000          # first half of .data.sandbox; leaves room
PAGETABLE_BASE = 0x20000
MISC_BASE = 0x30000
BAD_ADDR_BASE = 0x00090000      # inside the RAM region but never mapped
                                # by any preamble -- a genuinely
                                # out-of-range access from the CORE's own
                                # perspective once translation is on, and
                                # (deliberately) still IN-bounds for the
                                # flat-SRAM smoke-test harness so it reads
                                # as an ordinary (zeroed) location there
                                # rather than a bus error -- --sv39 mode
                                # is what actually makes this address
                                # fault (unmapped VA), matching the
                                # "deliberate misaligned and out-of-range
                                # accesses" bullet's intent for the
                                # SV39 case specifically; bare-mode runs
                                # exercise only the misaligned case for
                                # this same bullet, not a real access
                                # fault, since this harness's own flat
                                # SRAM has no protection to violate.
EPILOGUE_MAGIC = 0x51757645      # "QuVE", arbitrary/recognizable

# Free pool for random-body content (see module docstring).
FREE_POOL = list(range(13, 24))  # x13..x23

# ---------------------------------------------------------------------
def sign12(v: int) -> int:
    """Clamp an arbitrary int into ADDI's signed-12-bit range."""
    v &= 0xFFF
    return v - 0x1000 if v & 0x800 else v


class Label:
    _n = 0

    def __init__(self, tag: str):
        Label._n += 1
        self.name = f".L{tag}{Label._n}"

    def __str__(self):
        return self.name


class Program:
    """Accumulates one generated program as a list of assembly lines,
    split across the four named sections link.ld expects. Also owns all
    the generation-time bookkeeping (RNG, free-register pool, open
    forward-branch labels, call depth) -- there is exactly one Program
    per qvgen.py invocation, never nested."""

    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.entry: list[str] = []
        self.handlers: list[str] = []
        self.misc_data: list[str] = []
        self.pagetable_data: list[str] = []
        self.subroutines: list[str] = []  # appended to .text.entry at the end
        self.call_depth = 0
        self.open_labels: list[Label] = []  # forward branches waiting to land
        self.loop_nesting = 0
        self.smc_done = False

    # -- tiny emission helpers -----------------------------------------
    def e(self, line: str):
        self.entry.append(line)

    def reg(self):
        return self.rng.choice(FREE_POOL)

    def reg_biased(self, recent: list[int]):
        """--dep-bias: with probability args.dep_bias, reuse one of the
        last K destination registers instead of a fresh random pick --
        stresses same-register/back-to-back-dependency bypass paths."""
        if recent and self.rng.random() < self.args.dep_bias:
            return self.rng.choice(recent)
        return self.reg()

    def li(self, rd: int, val: int):
        """`li` is a real GAS pseudo-op (expands to whatever real
        sequence the value needs) -- correctness of the expansion is the
        assembler's job, not this script's."""
        self.e(f"    li      x{rd}, {val}")

    # -- forward-branch bookkeeping --------------------------------------
    def reserve_label(self, tag: str) -> Label:
        lbl = Label(tag)
        self.open_labels.append(lbl)
        return lbl

    def maybe_close_a_label(self, prob: float):
        """With probability `prob`, land one pending forward branch here
        -- keeps the DAG shallow instead of every branch skipping to the
        very end. Never closes a label from inside a counted loop's own
        body (loop_nesting>0) -- landing a DIFFERENT forward branch
        inside a loop body would make that branch's own "how many times
        does this run" story depend on which loop iteration hit it,
        needlessly complicating what "DAG" is supposed to mean here."""
        if self.loop_nesting or not self.open_labels:
            return
        if self.rng.random() < prob:
            lbl = self.open_labels.pop(self.rng.randrange(len(self.open_labels)))
            self.e(f"{lbl}:")

    def close_all_labels(self):
        for lbl in self.open_labels:
            self.e(f"{lbl}:")
        self.open_labels.clear()

    # -- calls (bounded depth, no runtime stack -- see module docstring) --
    # One dedicated link register PER NESTING LEVEL (x1=ra, x2=sp, x3=gp,
    # x4=tp -- none of the four are used for their conventional purpose
    # anywhere in this generator's own output: there is no runtime call
    # stack (sp), no global-pointer relaxation (gp; -mno-relax the same
    # way firmware/Makefile's own ASFLAGS already disable it), and no
    # thread-local storage (tp), so all four are free to repurpose).
    # LINK_REGS[d] bounds max_call_depth to 4; a 5th nesting level would
    # need a 5th register or a real stack, neither of which this
    # generator's default --max-call-depth=3 ever reaches.
    #
    # A REAL bug this fixes, found by direct simulation (a generated
    # msu-mode program hung, tracing showed an infinite self-loop): a
    # single shared link register (the original version used x1 for
    # every depth) means a NESTED call clobbers the OUTER call's own
    # return address before the outer subroutine ever gets to use it --
    # the outer subroutine's own `ret` then jumps to "right after the
    # nested call site" (a point INSIDE ITSELF), not to its real caller.
    LINK_REGS = [1, 2, 3, 4]

    def call(self, body_fn, max_depth: int):
        if self.call_depth >= max_depth or self.call_depth >= len(self.LINK_REGS):
            return
        link = self.LINK_REGS[self.call_depth]
        lbl = Label("sub")
        self.call_depth += 1
        if self.rng.random() < 0.5:
            self.e(f"    jal     x{link}, {lbl}")
        else:
            self.e(f"    la      x{link}, {lbl}")
            self.e(f"    jalr    x{link}, x{link}, 0")
        sub_lines = [f"{lbl}:"]
        save = self.entry
        self.entry = sub_lines
        body_fn()
        self.entry.append(f"    jalr    x0, x{link}, 0")
        self.subroutines.extend(self.entry)
        self.entry = save
        self.call_depth -= 1

    # -- counted loop (the only backward branch this generator emits) ----
    def counted_loop(self, body_fn, min_iters=2, max_iters=8, max_nesting=3):
        if self.loop_nesting >= max_nesting:
            body_fn()
            return
        counter = 28 + self.loop_nesting
        n = self.rng.randint(min_iters, max_iters)
        top = Label("loop")
        self.li(counter, n)
        self.e(f"{top}:")
        self.loop_nesting += 1
        body_fn()
        self.loop_nesting -= 1
        self.e(f"    addi    x{counter}, x{counter}, -1")
        self.e(f"    bnez    x{counter}, {top}")


# =======================================================================
# Random instruction emitters
# =======================================================================

_ALU_R = ["add", "sub", "and", "or", "xor", "sll", "srl", "sra",
          "slt", "sltu", "addw", "subw", "sllw", "srlw", "sraw"]
_ALU_I = ["addi", "andi", "ori", "xori", "slti", "sltiu", "addiw"]
_ALU_SHIFT_I = ["slli", "srli", "srai"]
_ALU_SHIFT_IW = ["slliw", "srliw", "sraiw"]
_EDGE_VALUES = [0, 1, -1, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000,
                0x7FFFFFFF, -0x80000000, 0xFF, -0x100]

_M_OPS = ["mul", "mulh", "mulhu", "mulhsu", "div", "divu", "rem", "remu",
          "mulw", "divw", "divuw", "remw", "remuw"]

_LOADS = [("ld", 8), ("lw", 4), ("lh", 2), ("lb", 1),
          ("lwu", 4), ("lhu", 2), ("lbu", 1)]
_STORES = [("sd", 8), ("sw", 4), ("sh", 2), ("sb", 1)]

_AMO_RMW = ["amoswap", "amoadd", "amoxor", "amoor", "amoand",
            "amomin", "amomax", "amominu", "amomaxu"]


def emit_alu(p: Program, recent: list[int]):
    op = p.rng.choice(_ALU_R + _ALU_I + _ALU_SHIFT_I + _ALU_SHIFT_IW)
    rd = p.reg_biased(recent)
    rs1 = p.reg_biased(recent)
    if op in _ALU_R:
        rs2 = p.reg_biased(recent)
        p.e(f"    {op:<7} x{rd}, x{rs1}, x{rs2}")
    elif op in _ALU_I:
        imm = p.rng.choice(_EDGE_VALUES) if p.rng.random() < 0.3 else p.rng.randint(-2047, 2047)
        p.e(f"    {op:<7} x{rd}, x{rs1}, {sign12(imm)}")
    elif op in _ALU_SHIFT_I:
        p.e(f"    {op:<7} x{rd}, x{rs1}, {p.rng.randint(0, 63)}")
    else:
        p.e(f"    {op:<7} x{rd}, x{rs1}, {p.rng.randint(0, 31)}")
    recent.append(rd)
    del recent[:-8]


def emit_m_ext(p: Program, recent: list[int]):
    op = p.rng.choice(_M_OPS)
    rd, rs1, rs2 = p.reg_biased(recent), p.reg_biased(recent), p.reg_biased(recent)
    if p.rng.random() < 0.15:
        # Divide-by-zero is legal, well-defined RISC-V behavior (not a
        # fault) -- worth exercising explicitly, not just by accident.
        p.li(rs2, 0)
    p.e(f"    {op:<7} x{rd}, x{rs1}, x{rs2}")
    recent.append(rd)
    del recent[:-8]


def _sandbox_addr(p: Program, reg: int, misaligned=False, width=8):
    """Load a real, in-sandbox address into `reg`, either via
    base+imm (x27 + a small offset) or and/add-masked from a computed
    value -- both forms the plan calls for."""
    if p.rng.random() < 0.5:
        off = p.rng.randrange(0, SANDBOX_SIZE - 64, width)
        if misaligned and width > 1:
            off += 1
        p.e(f"    addi    x{reg}, x27, {sign12(off)}")
    else:
        p.li(reg, p.rng.randrange(0, 1 << 20))
        mask = (SANDBOX_SIZE - 1) & ~(width - 1)
        # `mask` needs 15 bits (SANDBOX_SIZE-1 = 0x7FFF) -- too wide for
        # ANDI's 12-bit signed immediate, so it goes through a real `li`
        # into a scratch register instead of a truncated `andi`.
        #
        # A REAL bug this fixes, found by direct simulation (an infinite
        # fetch-fault loop under --sv39, seeds 10/13/14 of a sweep hung):
        # the old code did `andi x{reg},x{reg},sign12(mask & 0xFFF)`.
        # For width=1, mask=0x7FFF, and `0x7FFF & 0xFFF` = 0xFFF, whose
        # low 12 bits are ALL set -- sign12 reads that as -1, i.e. an
        # all-ones ANDI immediate that masks nothing at all. The "in-
        # sandbox" address was then SANDBOX_BASE + an unconstrained
        # 20-bit random value, occasionally landing outside the sandbox
        # entirely (once, inside the Sv39 page tables' own physical
        # range) -- harmless on the flat-SRAM smoke harness (an ordinary
        # untranslated read/write), but a genuine unmapped access under
        # --sv39.
        mreg = p.rng.choice([r for r in FREE_POOL if r != reg])
        p.li(mreg, mask)
        p.e(f"    and     x{reg}, x{reg}, x{mreg}")
        p.e(f"    add     x{reg}, x{reg}, x27")
        if misaligned and width > 1:
            p.e(f"    addi    x{reg}, x{reg}, 1")


def emit_mem(p: Program, recent: list[int], misalign_rate: float, badaddr_rate: float):
    addr_r = p.reg()
    r = p.rng.random()
    if r < badaddr_rate:
        off = p.rng.randrange(0, 0x1000, 8)
        p.e(f"    addi    x{addr_r}, x26, {sign12(off)}")
        misaligned = False
    else:
        misaligned = p.rng.random() < misalign_rate
        _sandbox_addr(p, addr_r, misaligned=misaligned)
    if p.rng.random() < 0.5:
        mnem, width = p.rng.choice(_LOADS)
        rd = p.reg_biased(recent)
        p.e(f"    {mnem:<7} x{rd}, 0(x{addr_r})")
        recent.append(rd)
    else:
        mnem, width = p.rng.choice(_STORES)
        rs = p.reg_biased(recent)
        p.e(f"    {mnem:<7} x{rs}, 0(x{addr_r})")
    del recent[:-8]


def emit_amo(p: Program, recent: list[int]):
    addr_r = p.reg()
    _sandbox_addr(p, addr_r, misaligned=False, width=8)
    width_sfx = p.rng.choice(["w", "d"])
    if p.rng.random() < 0.4:
        # LR/SC pair, with SC's own success/failure both real outcomes
        # -- but the FAILURE path only under normal generation, never
        # --sail-safe (see the comment just above that branch for why).
        rd = p.reg_biased(recent)
        p.e(f"    lr.{width_sfx}    x{rd}, (x{addr_r})")
        if p.args.sail_safe or p.rng.random() < 0.5:
            # success: SC to the SAME address, no intervening access.
            # The ONLY LR/SC shape --sail-safe ever generates: per spec,
            # an SC immediately following its own LR, same address, no
            # intervening access, MUST succeed under ANY implementation
            # -- unambiguous ground truth, safe to diff against Sail.
            sc_rd = p.reg()
            val = p.reg_biased(recent)
            p.e(f"    sc.{width_sfx}    x{sc_rd}, x{val}, (x{addr_r})")
        else:
            # failure: an intervening store (to the SAME address, so
            # the failure is unambiguous under any ADDRESS-RANGE-based
            # reservation-set model) breaks the reservation.
            #
            # NEVER generated under --sail-safe: found, via the P3.2
            # Sail audit (sail_diff.py) and direct comparison, that
            # this isn't just an address-granularity mismatch (which
            # aiming the intervening store at the SAME address would
            # fix) -- Sail's own single-hart reservation model doesn't
            # invalidate on a same-hart store AT ALL, regardless of
            # address, so its SC keeps succeeding even here. That's a
            # genuine implementation-choice gray area the spec permits
            # either way (a same-hart store between LR and SC is a
            # misuse of the primitive no correct program would ever
            # rely on), not a bug in either model, so it isn't safe
            # ground truth to diff against -- this core's own "ANY
            # store/SC/AMO clears it, anywhere" choice is instead
            # covered by the P3.4 lockstep harness (ref_core vs
            # core_pipe, both required to agree with EACH OTHER on
            # this core's own documented behavior).
            junk_val = p.reg_biased(recent)
            p.e(f"    sd      x{junk_val}, 0(x{addr_r})")
            sc_rd = p.reg()
            val = p.reg_biased(recent)
            p.e(f"    sc.{width_sfx}    x{sc_rd}, x{val}, (x{addr_r})")
        recent.append(rd)
    else:
        op = p.rng.choice(_AMO_RMW)
        rd = p.reg_biased(recent)
        rs2 = p.reg_biased(recent)
        p.e(f"    {op}.{width_sfx} x{rd}, x{rs2}, (x{addr_r})")
        recent.append(rd)
    del recent[:-8]


def emit_csr(p: Program, recent: list[int]):
    # mscratch/sscratch only -- see module docstring on why mstatus
    # deliberately isn't in this pool (it's load-bearing for the whole
    # privilege/trap mechanism; deliberate, targeted mstatus setup lives
    # in the preambles, not the random pool).
    #
    # A REAL bug this fixes, found by direct simulation: the main body
    # under --priv msu runs ENTIRELY in S-mode (see emit_entry_preamble's
    # M->S bootstrap) -- mscratch is M-mode-only, so an S-mode mscratch
    # access is a genuine privilege violation (illegal instruction).
    # Picking it at random here made roughly half of all emit_csr calls
    # under msu fault, which by itself was enough to cascade into a much
    # longer, harder-to-diagnose chain of faults. The main body must use
    # ONLY the CSR its own current privilege can legally reach.
    csr = "sscratch" if p.args.priv == "msu" else "mscratch"
    op = p.rng.choice(["csrrw", "csrrs", "csrrc"])
    rd = p.reg_biased(recent)
    rs1 = p.reg_biased(recent)
    p.e(f"    {op:<7} x{rd}, {csr}, x{rs1}")
    recent.append(rd)
    del recent[:-8]


def emit_fault(p: Program, kind: str):
    if kind == "illegal":
        p.e("    .word   0xFFFFFFFF")   # guaranteed-illegal (all-ones)
    elif kind == "ecall":
        p.e("    ecall")
    elif kind == "ebreak":
        p.e("    ebreak")


def emit_smc_fence_i(p: Program, recent: list[int]):
    """FENCE.I after a genuine self-modifying store: overwrite the NEXT
    instruction's own dword with something harmless-but-different (a
    NOP), fence.i, then fall through and actually fetch what was just
    written -- proves I$/D$ coherence, not just that FENCE.I assembles."""
    tgt = Label("smc")
    p.e(f"    la      x13, {tgt}")
    p.li(14, 0x00000013)  # nop
    p.e("    sw      x14, 0(x13)")
    p.e("    fence.i")
    p.e(f"{tgt}:")
    # `.option norvc`: the `sw` above writes a full 4-byte NOP, so the
    # target must ALSO be a real 4-byte instruction -- under RVC (the
    # default for --isa imac), a bare `nop` assembles as a 2-byte
    # `c.nop`, and the store's other 2 bytes then land on and corrupt
    # whatever instruction happens to follow.
    #
    # A REAL bug this fixes, found by direct simulation (an illegal-
    # instruction fault a few instructions after a SMC site, under
    # --sv39): the trailing half of the NEXT instruction (there, a 4-
    # byte `ret`) got overwritten with zeros, splitting it into a valid
    # leading nop plus two orphaned zero bytes that don't decode as
    # anything.
    p.e("    .option norvc")
    p.e("    nop")
    p.e("    .option rvc")
    p.smc_done = True


def emit_rvc_dword_cross(p: Program):
    """Forces a real 32-bit (non-compressible) instruction to straddle
    an 8-byte dword boundary (address ≡ 6 mod 8) -- the exact crossing
    case core.sv's own S_FETCH_HI/fstate machinery exists for. `.balign
    8` reaches a known boundary; THREE real `c.nop`s (`.half 0x0001`,
    guaranteed 16-bit regardless of -march) advance exactly 6 bytes,
    landing at offset 6; `.option norvc` then forces the assembler to
    NOT compress the instruction that follows, so it's genuinely 4
    bytes wide starting there, straddling into the next dword."""
    p.e("    .balign 8")
    p.e("    .half   0x0001")
    p.e("    .half   0x0001")
    p.e("    .half   0x0001")
    p.e("    .option norvc")
    p.e("    addi    x13, x13, 1")
    p.e("    .option rvc")


def emit_page_cross(p: Program):
    """Sv39-only: same technique as emit_rvc_dword_cross, but at a 4KB
    page boundary instead of a dword one -- exercises the independent
    fetch-hi walk for an instruction whose two halves live on different
    pages entirely. The wide instruction must land at offset 4094 (the
    LAST 2 bytes of the page), not offset 0 -- `.balign 4096` only
    reaches the page's own START, so 2047 real c.nop halves (.rept,
    not one-at-a-time -- 4094 bytes would be an unreasonable number of
    individual .half lines) pad out to the last 2 bytes before the wide
    instruction, which then genuinely straddles into the NEXT page."""
    p.e("    .balign 4096")
    p.e("    .rept   2047")
    p.e("    .half   0x0001")
    p.e("    .endr")
    p.e("    .option norvc")
    p.e("    addi    x13, x13, 1")
    p.e("    .option rvc")


# =======================================================================
# Trap handlers
# =======================================================================
#
# Both handlers below deliberately do NOT save/restore x5-x12 (their own
# scratch registers) around a trap. That would be wrong for a real OS,
# but it's sound here: the random body NEVER reads or writes x5-x12 (see
# the module docstring's register table), so there's nothing of the
# random body's own state to preserve. What DOES need to be consistent
# is that the same program produces the same handler behavior on every
# run -- which holds by construction, since the handler is pure,
# deterministic code with no randomness of its own.

def _emit_pagetable_walk_and_fix(p: Program, va_reg: int, ret_insn: str, invalid_label):
    """Generic depth-first walk from satp down to whichever level is
    already a leaf (R|W|X nonzero) -- correct for a plain 4KB mapping OR
    a superpage, since it simply stops descending the instant it finds
    one. Sets A+D (0xC0) on that leaf and retries (mepc/sepc unchanged)
    via `ret_insn` (mret or sret).

    A REAL bug this fixes, found by direct simulation: a genuinely
    INVALID entry (V=0 -- e.g. BAD_ADDR_BASE, which by design is never
    given any mapping, see the module docstring) has R|W|X all clear
    too, so it looked identical to "non-leaf, keep descending." The walk
    then followed a bogus PPN=0 chain into low memory, eventually
    misreading part of the running program itself as a "valid leaf" and
    corrupting it with a stray A/D-bit store. Now a V=0 entry at any
    level jumps to `invalid_label` (the caller's ordinary-fault path,
    which skips the faulting instruction by length like any other
    unrecoverable fault) instead of retrying something that can never
    succeed."""
    walk = Label("pfwalk")
    leaf = Label("pfleaf")
    p.handlers += [
        "    csrr    x7, satp",
        "    slli    x7, x7, 20",
        "    srli    x7, x7, 8",       # x7 = L2 table base PA (PPN<<12)
        "    li      x12, 30",
        f"{walk}:",
        f"    srl     x8, x{va_reg}, x12",
        "    andi    x8, x8, 0x1FF",
        "    slli    x8, x8, 3",
        "    add     x9, x7, x8",
        "    ld      x10, 0(x9)",
        "    andi    x11, x10, 0x1",   # V
        f"    beqz    x11, {invalid_label}",
        "    andi    x11, x10, 0xE",   # R|W|X
        f"    bnez    x11, {leaf}",
        "    srli    x7, x10, 10",
        "    slli    x7, x7, 12",
        "    addi    x12, x12, -9",
        f"    j       {walk}",
        f"{leaf}:",
        "    ori     x10, x10, 0xC0",  # A=1,D=1
        "    sd      x10, 0(x9)",
        "    sfence.vma",
        f"    {ret_insn}",
    ]


def _emit_epilogue_body(p: Program):
    """Dump the free-pool registers to .data.misc, write tohost=1, halt.
    Shared by both the direct-M-mode-body case and the msu case (which
    always reaches this via the M-handler's ecall path)."""
    p.misc_data += ["regdump:", "    .zero   " + str(8 * len(FREE_POOL))]
    p.handlers.append("epilogue:")
    for i, r in enumerate(FREE_POOL):
        p.handlers.append(f"    la      x6, regdump")
        p.handlers.append(f"    sd      x{r}, {8*i}(x6)")
    p.handlers += [
        "    la      x6, tohost",
        "    li      x7, 1",
        "    sd      x7, 0(x6)",
        "    ebreak",
    ]


def emit_handlers(p: Program):
    """m_trap_handler/s_trap_handler are FIXED names (not auto-numbered
    Labels): emit_entry_preamble references them by that same literal
    name when it points mtvec/stvec at them, so they must match exactly.
    Every OTHER label in this function is internal-only (never
    referenced outside emit_handlers), so those stay auto-numbered."""
    a = p.args
    m_trap = "m_trap_handler"
    m_sync = Label("msync")
    m_intr = Label("mintr")
    m_ordinary = Label("mordinary")
    m_ret = Label("mret_common")
    m_fetch = Label("mfetch")
    m_page = Label("mpage")
    m_len4 = Label("mlen4")
    m_len2 = Label("mlen2")
    m_lenmem = Label("mlenmem")
    m_not_ecall = Label("mnotecall")
    m_not_epi = Label("mnotepi")

    p.handlers += [
        f"{m_trap}:",
        "    csrr    x5, mcause",
        f"    bge     x5, x0, {m_sync}",
        f"{m_intr}:",
        # Best-effort MAGIC_IRQ_CLR write -- harmless against today's
        # flat-SRAM smoke-test harness (no MMIO device there yet; this
        # is the forward reference to P3.4's lockstep_mmio.sv, see the
        # module docstring).
        "    li      x6, 0x0400F004",
        "    li      x7, 1",
        "    sw      x7, 0(x6)",
        f"    j       {m_ret}",
        f"{m_sync}:",
    ]
    # Any of the 3 real ECALL causes (8=U, 9=S, 11=M) might be the
    # epilogue's own ecall -- NOT just 11. A REAL bug this fixes, found
    # by direct simulation (an msu-mode program hung): the epilogue
    # always executes at whatever privilege the main body itself runs
    # at (S, under --priv msu, since the WHOLE body including the
    # epilogue runs there after the M->S bootstrap) -- so its ecall is
    # cause 9, never 11. Checking only for 11 meant the msu case's own
    # epilogue ecall was never recognized, fell into the "ordinary
    # fault" path instead, got skipped over as if it were a random
    # fault, and the program ran off into whatever garbage follows.
    m_is_ecall = Label("misecall")
    for cause in (8, 9, 11):
        p.handlers += [f"    li      x6, {cause}", f"    beq     x5, x6, {m_is_ecall}"]
    p.handlers += [
        f"    j       {m_not_ecall}",
        f"{m_is_ecall}:",
        f"    li      x6, {EPILOGUE_MAGIC}",
        f"    bne     x24, x6, {m_not_epi}",
        "    j       epilogue",
        f"{m_not_epi}:",
        f"    j       {m_ordinary}",
        f"{m_not_ecall}:",
        # cause 1 = instruction ACCESS fault (e.g. PMP-X deny): no valid
        # instruction to measure the length of, so just resume at the
        # dedicated recovery pc (x25) instead of trying to skip past it.
        "    li      x6, 1",
        f"    beq     x5, x6, {m_fetch}",
    ]
    if a.sv39:
        p.handlers += [
            # causes 12/13/15 = instruction/load/store PAGE faults: these
            # are recoverable in place (fix A/D bits, retry the same pc),
            # unlike an access fault, so they route to m_page, not m_fetch.
            "    li      x6, 12",
            f"    beq     x5, x6, {m_page}",
            "    li      x6, 13",
            f"    beq     x5, x6, {m_page}",
            "    li      x6, 15",
            f"    beq     x5, x6, {m_page}",
        ]
    p.handlers += [
        f"    j       {m_ordinary}",
        f"{m_fetch}:",
        "    csrw    mepc, x25",
        f"    j       {m_ret}",
    ]
    if a.sv39:
        p.handlers.append(f"{m_page}:")
        p.handlers.append("    csrr    x6, mtval")
        _emit_pagetable_walk_and_fix(p, 6, "mret", m_ordinary)
        p.handlers.append(f"    j       {m_ret}")
    p.handlers += [
        f"{m_ordinary}:",
        "    la      x6, trap_count",
        "    ld      x7, 0(x6)",
        "    addi    x7, x7, 1",
        "    sd      x7, 0(x6)",
        "    li      x6, 2",
        f"    bne     x5, x6, {m_lenmem}",
        "    csrr    x7, mtval",
        "    andi    x7, x7, 3",
        "    li      x8, 3",
        f"    beq     x7, x8, {m_len4}",
        f"    j       {m_len2}",
        f"{m_lenmem}:",
        # "identity-mapped halfword otherwise" -- reads the halfword AT
        # mepc directly; sound because the Sv39 preamble (when active)
        # identity-maps the whole code region, so mepc (VA, if trapped
        # from S) and its physical content agree here regardless of
        # which privilege trapped.
        "    csrr    x6, mepc",
        "    lhu     x7, 0(x6)",
        "    andi    x7, x7, 3",
        "    li      x8, 3",
        f"    beq     x7, x8, {m_len4}",
        f"{m_len2}:",
        "    csrr    x6, mepc",
        "    addi    x6, x6, 2",
        "    csrw    mepc, x6",
        f"    j       {m_ret}",
        f"{m_len4}:",
        "    csrr    x6, mepc",
        "    addi    x6, x6, 4",
        "    csrw    mepc, x6",
        f"{m_ret}:",
        "    mret",
    ]

    if a.priv == "msu":
        s_trap = "s_trap_handler"
        s_sync = Label("ssync")
        s_intr = Label("sintr")
        s_ordinary = Label("sordinary")
        s_ret = Label("sret_common")
        s_fetch = Label("sfetch")
        s_page = Label("spage")
        s_len4 = Label("slen4")
        s_len2 = Label("slen2")
        s_lenmem = Label("slenmem")
        p.handlers += [
            f"{s_trap}:",
            "    csrr    x5, scause",
            f"    bge     x5, x0, {s_sync}",
            f"{s_intr}:",
            "    li      x6, 0x0400F004",
            "    li      x7, 1",
            "    sw      x7, 0(x6)",
            f"    j       {s_ret}",
            f"{s_sync}:",
            "    li      x6, 1",
            f"    beq     x5, x6, {s_fetch}",
        ]
        if a.sv39:
            p.handlers += [
                "    li      x6, 12",
                f"    beq     x5, x6, {s_page}",
                "    li      x6, 13",
                f"    beq     x5, x6, {s_page}",
                "    li      x6, 15",
                f"    beq     x5, x6, {s_page}",
            ]
        p.handlers += [
            f"    j       {s_ordinary}",
            f"{s_fetch}:",
            "    csrw    sepc, x25",
            f"    j       {s_ret}",
        ]
        if a.sv39:
            p.handlers.append(f"{s_page}:")
            p.handlers.append("    csrr    x6, stval")
            _emit_pagetable_walk_and_fix(p, 6, "sret", s_ordinary)
            p.handlers.append(f"    j       {s_ret}")
        p.handlers += [
            f"{s_ordinary}:",
            "    la      x6, trap_count",
            "    ld      x7, 0(x6)",
            "    addi    x7, x7, 1",
            "    sd      x7, 0(x6)",
            "    li      x6, 2",
            f"    bne     x5, x6, {s_lenmem}",
            "    csrr    x7, stval",
            "    andi    x7, x7, 3",
            "    li      x8, 3",
            f"    beq     x7, x8, {s_len4}",
            f"    j       {s_len2}",
            f"{s_lenmem}:",
            "    csrr    x6, sepc",
            "    lhu     x7, 0(x6)",
            "    andi    x7, x7, 3",
            "    li      x8, 3",
            f"    beq     x7, x8, {s_len4}",
            f"{s_len2}:",
            "    csrr    x6, sepc",
            "    addi    x6, x6, 2",
            "    csrw    sepc, x6",
            f"    j       {s_ret}",
            f"{s_len4}:",
            "    csrr    x6, sepc",
            "    addi    x6, x6, 4",
            "    csrw    sepc, x6",
            f"{s_ret}:",
            "    sret",
        ]

    _emit_epilogue_body(p)


# =======================================================================
# Preambles
# =======================================================================

def emit_pmp(p: Program):
    """TOR regions covering the whole 1 MiB image R+W+X (unlocked --
    never denies M-mode regardless, per the real spec rule this
    project's own PMP milestone already confirmed the hard way), plus
    ONE genuinely denied region (bad_addr's own page) so PMP is real,
    not a no-op rubber stamp."""
    p.e("    # -- PMP: permit everything except BAD_ADDR_BASE's own page --")
    p.li(6, 0x100 >> 2)  # region0 end (M-mode-only low code, permit)
    p.e("    csrw    pmpaddr0, x6")
    p.li(6, BAD_ADDR_BASE >> 2)
    p.e("    csrw    pmpaddr1, x6")  # region1 [region0,BAD_ADDR_BASE) permit
    p.li(6, (BAD_ADDR_BASE + 0x1000) >> 2)
    p.e("    csrw    pmpaddr2, x6")  # region2 = the denied page
    p.li(6, 0x100000 >> 2)
    p.e("    csrw    pmpaddr3, x6")  # region3 rest of the image, permit
    cfg = 0x0F | (0x0F << 8) | (0x00 << 16) | (0x0F << 24)
    p.li(6, cfg)
    p.e("    csrw    pmpcfg0, x6")


def emit_sv39(p: Program):
    """Identity-maps every page the generated program can ever legally
    touch -- [0, MISC_END), which covers .text.entry, .text.handlers,
    the whole sandbox, the page tables' own physical location, and the
    small trap_count/tohost/regdump footprint in .data.misc -- plus ONE
    deliberate non-identity remap, so the address-translation machinery
    is actually exercised, not just formally "on". Everything OUTSIDE
    this range (notably BAD_ADDR_BASE) is deliberately left unmapped, a
    genuine fault the trap handler must recover from without retrying.

    A REAL bug this fixes, found by direct simulation (an infinite
    fetch-fault loop -- seeds 10-14 of an sv39+pmp+smc+msu sweep all
    hung): earlier versions mapped only [0,0x10000) plus a single
    sandbox page, on the theory that "page fault" always means "valid
    mapping, A/D just needs fixing up" (see _emit_pagetable_walk_and_fix).
    But under Sv39, EVERY S/U-mode load/store is translated, including
    ones this generator's own handler code makes for its own bookkeeping
    (e.g. s_ordinary/m_ordinary bumping trap_count) and the walker's own
    PTE reads/writes (computed as physical addresses, but still sent
    through translation like anything else) -- so any of those landing
    on a genuinely-unmapped page hit the exact same "fix and retry"
    logic, which can't fix an absent mapping and just refaults forever.
    Mapping the whole footprint up front is simpler and more robust than
    chasing each individually-reachable address one at a time."""
    p.e("    # -- Sv39: identity-map code, remap data --")
    p.pagetable_data += ["l2_table:", "    .zero   4096",
                          "l1_table:", "    .zero   4096",
                          "l0_table:", "    .zero   4096"]

    def pte(reg_tmp, phys_label_or_imm, flags, l0_index):
        if isinstance(phys_label_or_imm, str):
            p.e(f"    la      x{reg_tmp}, {phys_label_or_imm}")
        else:
            p.li(reg_tmp, phys_label_or_imm)
        p.e(f"    srli    x{reg_tmp}, x{reg_tmp}, 12")
        p.e(f"    slli    x{reg_tmp}, x{reg_tmp}, 10")
        p.e(f"    ori     x{reg_tmp}, x{reg_tmp}, {flags}")
        p.e(f"    la      x7, l0_table")
        p.e(f"    addi    x7, x7, {l0_index * 8}")
        p.e(f"    sd      x{reg_tmp}, 0(x7)")

    # L2[VPN2] -> l1_table, L1[VPN1] -> l0_table. VPN2=VPN1=0 for every
    # address this generator EVER maps or deliberately leaves unmapped
    # (everything lives below 0x200000, and even BAD_ADDR_BASE=0x90000
    # is well under the 1GB/2MB reach of L2 index 0 / L1 index 0) -- so
    # both pointer PTEs belong at index 0 (byte offset 0) in their
    # respective tables.
    #
    # A REAL bug this fixes, found by direct simulation (the same
    # infinite fetch-fault loop as the mapping-coverage fixes above,
    # surviving even after every reachable VA was correctly identity-
    # mapped): these were previously written to l2_table index 1 and
    # l1_table index 2 -- indices that NOTHING ever looks up, since the
    # walker computes L2/L1 indices from the VPN2/VPN1 bits of the
    # actual faulting address, which are always 0 here. Every walk was
    # therefore reading l2_table[0] (still all-zero) as if it were the
    # pointer to l1_table, and treating that zero entry exactly like any
    # other genuinely-invalid PTE -- indistinguishable, at the point of
    # the V-bit check, from a real unmapped access.
    p.e("    la      x6, l1_table")
    p.e("    srli    x6, x6, 12")
    p.e("    slli    x6, x6, 10")
    p.e("    ori     x6, x6, 1")
    p.e("    la      x7, l2_table")
    p.e("    sd      x6, 0(x7)")

    p.e("    la      x6, l0_table")
    p.e("    srli    x6, x6, 12")
    p.e("    slli    x6, x6, 10")
    p.e("    ori     x6, x6, 1")
    p.e("    la      x7, l1_table")
    p.e("    sd      x6, 0(x7)")

    # Identity leaves for every 4KB page in [0, MISC_END) -- vpn0 =
    # 0..48. [0,0x10000) (code) gets X; everything else (sandbox, the
    # gap, the page tables, the gap, the used sliver of .data.misc) gets
    # R+W only, since nothing ever fetches there. D=0 everywhere except
    # the page tables' own 3 pages (see below), so a store still needs
    # the walker's A/D fixup for everything else.
    MISC_END = MISC_BASE + 0x1000  # covers trap_count/tohost/regdump
    assert PAGETABLE_BASE + 0x3000 <= MISC_END
    pt_lo, pt_hi = PAGETABLE_BASE // 0x1000, PAGETABLE_BASE // 0x1000 + 3
    trap_count_vpn0 = MISC_BASE // 0x1000
    # D=1 (not just A=1) for every page the TRAP HANDLER ITSELF might
    # write while handling some OTHER, unrelated fault: the page tables'
    # own 3 pages (the walker's PTE write-back always lands there -- see
    # below) and trap_count's page (s_ordinary/m_ordinary bump it on
    # every entry). Left D=0 everywhere else, so an ordinary store still
    # needs the walker's A/D fixup, which is the behavior this generator
    # means to exercise.
    predirty = {v for v in range(pt_lo, pt_hi)} | {trap_count_vpn0}
    for vpn0 in range(MISC_END // 0x1000):
        if vpn0 < 16:
            flags = 0x4F  # V,R,W,X,A (code: X for fetch, W for --smc)
        elif vpn0 in predirty:
            flags = 0xC7  # V,R,W,A,D
        else:
            flags = 0x47  # V,R,W,A (ordinary data)
        pte(6, vpn0 * 0x1000, flags, vpn0)

    # A REAL bug the page-table pre-dirtying above fixes, found by
    # direct simulation (an infinite fetch-fault loop surviving even the
    # L2/L1 index fix): the walker's own PTE write-back (`leaf:` in
    # _emit_pagetable_walk_and_fix) always lands inside l0_table's own
    # page (every leaf PTE this generator ever creates lives in that one
    # 4KB table). If THAT page also had D=0, fixing up any OTHER page's
    # D bit would require a store into l0_table, which itself faults for
    # the exact same reason and needs fixing up first -- and fixing IT
    # requires a store into the SAME page (l0_table's entry for its own
    # vpn0 lives inside itself), which needs D=1 to succeed, which is
    # exactly what the store was trying to set. Genuinely unfixable by
    # retrying, since the walker never reaches its own `sfence.vma` to
    # make the fix visible.
    #
    # A SECOND, more subtle real bug the trap_count pre-dirtying fixes,
    # ALSO found by direct simulation (a later seed still hung after the
    # first fix): even a FIXABLE nested fault is dangerous here, not just
    # an unfixable one. With trap_count left D=0, s_ordinary's own bump
    # of it can fault WHILE s_ordinary is still in the middle of handling
    # some unrelated outer fault. That nested fault's OWN handling ends
    # in the walker's bare `sret` (to retry the trap_count store) --  but
    # `sret` unconditionally clears sstatus.SPP after consuming it. When
    # control later reaches the OUTER fault's own `sret` (to truly return
    # to the random body), SPP has already been cleared to U by the INNER
    # sret, so the outer sret drops to U-mode instead of S-mode -- and
    # every subsequent fetch then faults on every mapping's unset U bit,
    # forever. Pre-dirtying trap_count's page prevents the nested fault
    # (and its consumed sret) from ever happening in the first place.

    # Non-identity leaf: remap ONE sandbox page to a genuinely different
    # PA (overriding the identity leaf just installed above for this one
    # vpn0), proving translation isn't just an identity passthrough:
    # vpn0=17 (VA 0x11000) -> PA MISC_BASE+0x1000 (data, R+W, not identity).
    pte(6, MISC_BASE + 0x1000, 0xC7, 17)  # R=1,W=1,X=0,A=1,D=1

    p.e("    la      x6, l2_table")
    p.e("    srli    x6, x6, 12")
    p.e("    li      x7, 8")
    p.e("    slli    x7, x7, 60")
    p.e("    or      x6, x6, x7")
    p.e("    csrw    satp, x6")
    p.e("    sfence.vma")


def emit_trap_delegation(p: Program):
    """Random-but-epilogue-safe medeleg/mideleg: never delegates ECALL
    from either U or S (bits 8/9), so the epilogue's own ECALL always
    reaches the M-handler directly regardless of what else is
    delegated -- see the module docstring's "Epilogue: ECALL to M"."""
    causes = [0, 1, 3, 4, 5, 6, 7, 12, 13, 15]  # never 8, never 9
    bits = 0
    for c in causes:
        if p.rng.random() < 0.5:
            bits |= (1 << c)
    p.li(6, bits)
    p.e("    csrw    medeleg, x6")
    p.li(6, 0x222)  # STIP|SEIP|SSIP delegated -- harmless, no source yet
    p.e("    csrw    mideleg, x6")


def emit_msu_minimal_pmp(p: Program):
    """A single, fully-permissive TOR PMP region covering the whole
    1 MiB image -- emitted whenever --priv msu is used WITHOUT --pmp,
    so the S-mode bootstrap's correctness never depends on this core's
    own particular PMP reset default rather than on something this
    program itself explicitly configures.

    This core's region 0 resets to a fully-permissive NAPOT-all region
    (pmp0cfg_a_q/_x_q/_w_q/_r_q's own reset values in csr_file.sv) -- a
    real, deliberate design choice (confirmed by reading csr_file.sv
    directly), not a bug: it's what lets M-mode software boot and reach
    S-mode at all before configuring PMP itself. But the privileged
    spec leaves PMP reset state unspecified beyond "defaults to denying
    S/U-mode access" being merely ALLOWED, not required -- nothing
    guarantees any other implementation (including Sail, whose own
    default does deny S/U by reset) makes the same reset choice.

    A REAL gap this closes, found via the P3.2 Sail differential audit
    (sail_diff.py): under --sail-safe --priv msu (no --pmp, so this was
    previously the ONLY path into S-mode), the random body's very first
    S-mode fetch relied ENTIRELY on this core's own reset default to
    succeed -- Sail correctly denied it instead (a fetch-access-fault),
    a real, reproducible divergence. Explicit configuration removes the
    dependency on either side's particular reset choice, rather than
    trying to make Sail's config imitate this one core's own reset
    values (its config schema has no way to express PMP reset state
    beyond entry count, only the CSRs' own live values, which software
    -- this preamble -- is exactly the right place to set)."""
    p.e("    # -- msu bootstrap: explicit permissive PMP (no --pmp) --")
    p.li(6, 0x100000 >> 2)
    p.e("    csrw    pmpaddr0, x6")
    p.li(6, 0x0F)  # L=0,A=TOR,X=1,W=1,R=1
    p.e("    csrw    pmpcfg0, x6")


def emit_entry_preamble(p: Program):
    a = p.args
    p.e("_start:")
    p.e("    la      x6, m_trap_handler")
    p.e("    csrw    mtvec, x6")
    if a.priv == "msu":
        p.e("    la      x6, s_trap_handler")
        p.e("    csrw    stvec, x6")
        emit_trap_delegation(p)
    p.e("    la      x25, recovery_point")
    p.li(26, BAD_ADDR_BASE)
    p.li(27, SANDBOX_BASE)
    if a.priv == "msu" and not a.pmp:
        emit_msu_minimal_pmp(p)
    if a.pmp:
        emit_pmp(p)
    if a.sv39:
        emit_sv39(p)
    if a.priv == "msu":
        # Bootstrap M -> S for the random body, exactly like
        # firmware/sv39_real_test.s's own mstatus.MPP dance, generalized
        # to work whether or not Sv39 is active (the target is a real
        # label either way -- `la` + mepc works identically for a VA or
        # a PA, since under --sv39 the code region is identity-mapped).
        p.li(6, 1)
        p.e("    slli    x6, x6, 11")
        p.e("    csrw    mstatus, x6")   # MPP = S
        p.e("    la      x6, s_mode_entry")
        p.e("    csrw    mepc, x6")
        p.e("    mret")
        p.e("s_mode_entry:")
    p.e("recovery_point:")


# =======================================================================
# Main body
# =======================================================================

def emit_main_body(p: Program):
    a = p.args
    recent: list[int] = []
    have_amo = "a" in a.isa
    have_m = "m" in a.isa
    have_c = "c" in a.isa

    def one_instr():
        r = p.rng.random()
        if r < 0.35:
            emit_alu(p, recent)
        elif have_m and r < 0.45:
            emit_m_ext(p, recent)
        elif r < 0.65:
            emit_mem(p, recent, a.misalign_rate, a.badaddr_rate)
        elif have_amo and r < 0.72:
            emit_amo(p, recent)
        elif r < 0.80:
            emit_csr(p, recent)
        elif r < 0.83 and a.smc and not p.smc_done:
            emit_smc_fence_i(p, recent)
        elif r < 0.85:
            p.e("    fence")
        elif r < 0.87:
            p.e("    wfi")
        elif r < 0.87 + a.illegal_rate:
            emit_fault(p, "illegal")
        elif r < 0.87 + a.illegal_rate + a.ecall_rate:
            emit_fault(p, p.rng.choice(["ecall", "ebreak"]))
        else:
            emit_alu(p, recent)

    def loop_body():
        for _ in range(p.rng.randint(2, 5)):
            one_instr()

    def sub_body():
        for _ in range(p.rng.randint(3, 10)):
            one_instr()
            if p.rng.random() < 0.15:
                p.call(sub_body, a.max_call_depth)

    emitted = 0
    if have_c and p.rng.random() < 0.9:
        emit_rvc_dword_cross(p)
        emitted += 2
    if a.sv39 and p.rng.random() < 0.9:
        emit_page_cross(p)
        emitted += 2

    while emitted < a.len:
        r = p.rng.random()
        if r < 0.10:
            p.counted_loop(loop_body, max_nesting=a.max_loop_nesting)
            emitted += 5
        elif r < 0.15:
            p.call(sub_body, a.max_call_depth)
            emitted += 5
        elif r < 0.30 and not p.loop_nesting:
            lbl = p.reserve_label("fwd")
            cond = p.rng.choice(["beqz", "bnez", "b"])
            r1 = p.reg_biased(recent)
            if cond == "b":
                p.e(f"    j       {lbl}")
            else:
                p.e(f"    {cond}    x{r1}, {lbl}")
            emitted += 1
        else:
            one_instr()
            emitted += 1
        p.maybe_close_a_label(0.3)

    p.close_all_labels()


def emit_epilogue(p: Program):
    p.li(24, EPILOGUE_MAGIC)
    p.e("    ecall")


# =======================================================================
# Driver
# =======================================================================

def build_program(args) -> Program:
    p = Program(args)
    emit_entry_preamble(p)
    emit_main_body(p)
    emit_epilogue(p)
    emit_handlers(p)
    p.entry.extend(p.subroutines)
    p.misc_data += ["trap_count:", "    .zero   8", "tohost:", "    .zero   8"]
    return p


def render(p: Program) -> str:
    lines = [
        "# Generated by verification/lockstep/gen/qvgen.py -- DO NOT EDIT.",
        f"# args: {vars(p.args)}",
        "    .section .text.entry",
        "    .globl  _start",
    ]
    lines += p.entry
    lines += ["", "    .section .text.handlers"]
    lines += p.handlers
    lines += ["", "    .section .data.sandbox", "    .zero   " + str(SANDBOX_SIZE)]
    if p.pagetable_data:
        lines += ["", "    .section .data.pagetables", "    .align  12"]
        lines += p.pagetable_data
    lines += ["", "    .section .data.misc"]
    lines += p.misc_data
    return "\n".join(lines) + "\n"


def toolchain_build(asm_path: Path, out_base: Path, isa: str, has_pagetables: bool):
    # -j (only-section) with a section name absent from the ELF is a
    # real objcopy error ("invalid operation"), not a silent no-op --
    # .data.pagetables only exists when --sv39 emitted it (render()
    # skips the whole `.section .data.pagetables` directive otherwise),
    # so it must be conditionally excluded here to match.
    march = f"rv64{isa}_zicsr_zifencei"
    obj = out_base.with_suffix(".o")
    elf = out_base.with_suffix(".elf")
    hexf = out_base.with_suffix(".hex")
    subprocess.run(["riscv64-unknown-elf-as", "-g", f"-march={march}", "-mabi=lp64",
                     "-o", str(obj), str(asm_path)], check=True)
    subprocess.run(["riscv64-unknown-elf-ld", "-T", str(GEN_DIR / "link.ld"),
                     "-o", str(elf), str(obj)], check=True)
    sections = ["-j", ".text.entry", "-j", ".text.handlers",
                "-j", ".data.sandbox", "-j", ".data.misc"]
    if has_pagetables:
        sections += ["-j", ".data.pagetables"]
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "verilog",
                     *sections, "--verilog-data-width=8",
                     str(elf), str(hexf)], check=True)
    return elf, hexf


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--isa", choices=["i", "im", "imc", "imac"], default="imac")
    ap.add_argument("--priv", choices=["m", "msu"], default="m")
    ap.add_argument("--pmp", action="store_true")
    ap.add_argument("--sv39", action="store_true")
    ap.add_argument("--irq", action="store_true",
                     help="reserved for the P3.4 lockstep harness's own "
                          "interrupt injection -- affects nothing in "
                          "THIS generator's own output today beyond the "
                          "handler's best-effort MAGIC_IRQ_CLR write, "
                          "which is always emitted regardless of this "
                          "flag (see emit_handlers)")
    ap.add_argument("--smc", action="store_true")
    ap.add_argument("--len", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--dep-bias", type=float, default=0.3, dest="dep_bias")
    ap.add_argument("--illegal-rate", type=float, default=0.02)
    ap.add_argument("--ecall-rate", type=float, default=0.01)
    ap.add_argument("--misalign-rate", type=float, default=0.05)
    ap.add_argument("--badaddr-rate", type=float, default=0.03)
    ap.add_argument("--max-call-depth", type=int, default=3)
    ap.add_argument("--max-loop-nesting", type=int, default=2)
    ap.add_argument("--sail-safe", action="store_true",
                     help="pure M/S/U ALU/mem/control-flow only -- no "
                          "PMP, no Sv39, no MMIO-adjacent writes; forces "
                          "--pmp/--sv39 off regardless of what else was "
                          "passed, for a clean differential run against "
                          "a plain Sail model")
    ap.add_argument("-o", "--output", type=Path, default=None,
                     help="output basename (default: gen_<seed>)")
    ap.add_argument("--build", action="store_true",
                     help="also invoke the real toolchain (as/ld/objcopy)")
    args = ap.parse_args()

    if args.sail_safe:
        args.pmp = False
        args.sv39 = False

    if args.output is None:
        args.output = GEN_DIR / f"gen_{args.seed}"
    args.output.parent.mkdir(parents=True, exist_ok=True)

    p = build_program(args)
    text = render(p)
    asm_path = args.output.with_suffix(".s")
    asm_path.write_text(text)
    print(f"wrote {asm_path}")

    if args.build:
        elf, hexf = toolchain_build(asm_path, args.output, args.isa, bool(p.pagetable_data))
        print(f"built {elf}, {hexf}")


if __name__ == "__main__":
    sys.exit(main())
