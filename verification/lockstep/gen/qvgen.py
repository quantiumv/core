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
the pipelined core vs. ref_core. Both share this one generator -- the corpus is
identical, only the comparison target differs.

Memory map (1 MiB image, see verification/lockstep/gen/link.ld):
  0x00000-0x07FFF  .text.entry      -- preambles + the random main body
  0x08000-0x0FFFF  .text.handlers   -- M-mode/S-mode trap handlers
  0x10000-0x1FFFF  .data.sandbox    -- the load/store playground
  0x20000-0x2FFFF  .data.pagetables -- Sv39 page tables (--sv39 only): two sets of four tables
  0x30000-0x8EFFF  .data.misc       -- tohost, trap counter, register dump
  0x8F000          .data.ptpmp      -- --sv39: the L0 table a PMP pocket covers (a walk's PTE read can be denied)
  0x90C00          .text.pocket     -- --pmp / --sv39: a `jr x25` in the bad-address page (a fetch probe's target)
  0x91FF8          .text.probe      -- --sv39: a 32-bit `jr x25` at 0x91FFE, straddling two pages

--sv39 (P7.0): the page tables are static data (set A is what satp points at, set B a variant the body can switch
to, always followed by SFENCE.VMA). Per seed: random page flags (A and D often clear, U for a U body or now and then
for an S body, execute-only, read-only, malformed), a data window through a 2 MiB or 1 GiB leaf (x27 moves into it),
holes that page-fault (misaligned superpage with ppn0, ppn1 or both set, W without R, a reserved/PBMT/N bit in a
leaf or in a pointer, a pointer at the last level, V clear with the rest of a good leaf, unmapped, non-canonical
addresses that alias a mapped page) or take an access fault (a leaf onto physical 2^40, a pointer to a table above
2^38, a pointer and a leaf into the bus-error region at FAR_BASE, accesses past the image through a 2 MiB or 1 GiB
window; with --pmp an NA4 word cuts one PTE of a table in half), the MAGIC page for --irq, and probes of every
fault: the page-fault handlers fix A/D and retry (a fault that comes back is a real one and is skipped, or for a
fetch fault resumes at x25; the handler follows a pointer by its PPN field alone and never a far one: only access
faults come out of those). The body also toggles SUM/MXR (also just before a fetch probe: SUM never lets S fetch
from a user page), rewrites satp and thrashes the TLB. --no-sv39-fetch keeps every fetch fault-free. Two rules the stimulus
keeps because the FSM and the pipe legitimately differ where they are broken (speculation contract of the plan's
P7): R1 -- every PTE store and satp root switch is followed by an SFENCE.VMA before anything depends on it; R2 --
no non-leaf PTE and no executable leaf leads to a device: tables and code are in RAM, and what is not (the far
pointers and leaves, a probe page now and then) goes to an address above 2^38 that the PMP always denies, or to
FAR_BASE, where the harness answers with a bus error.

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
  x13-x23       FREE POOL for random-body content (a3-a7,s2-s7 -- 11 regs);
                under --dbg x22/x23 are left out of the pool (9 regs): the lockstep
                harness's scripted debugger (lockstep_dbg.sv) uses them as scratch
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
MAGIC_BASE = 0x0400F000          # the lockstep harness's MAGIC dword (tohost-style set/clear registers)
FAR_BASE = 0x08000000            # outside the RAM image and the MMIO window: the harness answers with a bus error
HOT_SIZE = 0x400                 # the start of the sandbox that accesses favor, where --pmp puts its small pockets
POCKET_X = BAD_ADDR_BASE + 0xC00 # --pmp: a `jr x25` lives here; a jump to it is a fetch from a PMP pocket
                                 # (past x26 + 2047, so the random bad-address stores can't overwrite it)

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
        self.ptpmp_data: list[str] = []       # --sv39: the L0 table at PMPT_PA
        self.pocket_code: list[str] = []      # --pmp, --sv39: what sits at POCKET_X
        self.probe_code: list[str] = []       # --sv39: what sits at PROBE_X
        self.pockets: list[tuple[int, int]] = []   # --pmp: the byte ranges [lo, hi) of the sandbox pockets
        self.ptpmp_k = None                   # --pmp --sv39: the PTE of the PMPT_VA table that a PMP word cuts in half
        self.reloc = False                    # --sv39: the S or U body runs through the window above the image (VA != PA)
        self.subroutines: list[str] = []  # appended to .text.entry at the end
        self.call_depth = 0
        self.open_labels: list[Label] = []  # forward branches waiting to land
        self.loop_nesting = 0
        self.smc_done = False
        # privilege-switching content (see emit_priv_op): body in S or U, sret
        # transitions, TSR/TVM, probes of the S/M CSRs. Off under --sail-safe
        # (Sail diff stays as audited). Combines with --sv39: the page-fault
        # handlers cope with a U body (they read user code under SUM) and the
        # page flags follow the body's privilege.
        self.priv_ext = args.priv == "msu" and not args.sail_safe
        self.body_u = False       # the body starts in U mode
        self.body_priv2 = False   # ... or in the reserved privilege 2'b10 (MPP is loaded raw)
        # --irq: the body runs with interrupts on, so an interrupt can strike between any two
        # instructions -- inside an idiom that keeps a value in x5-x8, or between a sepc write and the
        # sret that uses it. Hence transparent trap handlers (mscratch/sscratch are their save-area
        # pointers, off limits to the random CSR pool), a PMP region so the S handler can write the
        # MAGIC clear, and idioms that keep the S-level interrupts out of their windows. Not with
        # --sail-safe (no MMIO). With --sv39 the MAGIC page is mapped for the S handler.
        self.irq = bool(args.irq) and not args.sail_safe
        # --sv39: where the data window lives (x27) and the page flags the preamble chose, see plan_sv39
        self.data_base = SANDBOX_BASE
        self.sv_mode = "ident"
        self.sv_swap = False      # set B of the page tables exists and the body may switch satp to it
        self.body_sie = False     # S-mode body: sstatus.SIE is set, so delegated interrupts are taken
        self.tsr = False          # mstatus.TSR is set: SRET always traps

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
_M_MUL_OPS = ["mul", "mulh", "mulhu", "mulhsu", "mulw"]

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
    op = p.rng.choice(_M_MUL_OPS if p.args.no_div else _M_OPS)
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
    if p.pockets and p.rng.random() < 0.25:
        # right at a pocket's edge: a span that only partly overlaps a region is no match for it, and a
        # byte, a word and a dword at the same place can each come out differently
        lo, hi = p.rng.choice(p.pockets)
        addr = p.rng.choice([lo, hi]) + p.rng.randrange(-12, 13)
        addr = min(max(addr, SANDBOX_BASE), SANDBOX_BASE + SANDBOX_SIZE - 64)
        addr &= ~(width - 1)
        if p.rng.random() < 0.4:
            addr |= 4               # half a dword in: an NA4 word there is hit by a word access, not a dword one
        if misaligned and width > 1:
            addr += 1
        p.li(reg, addr)
        return
    hot = p.args.pmp and p.rng.random() < 0.3        # small PMP pockets live in the hot zone: hit them often
    if p.rng.random() < 0.5:
        off = p.rng.randrange(0, HOT_SIZE if hot else SANDBOX_SIZE - 64, width)
        if misaligned and width > 1:
            off += 1
        p.e(f"    addi    x{reg}, x27, {sign12(off)}")
    else:
        p.li(reg, p.rng.randrange(0, 1 << 20))
        mask = ((HOT_SIZE if hot else SANDBOX_SIZE) - 1) & ~(width - 1)
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
    elif r < badaddr_rate * 1.5:
        # nothing is there: a bus error (or, below M with --pmp, a PMP denial first)
        p.li(addr_r, FAR_BASE + p.rng.randrange(0, 0x1000, 8))
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
        while rd == addr_r:
            # The LR's rd must not be the address register: the store and the SC below still use it, and
            # the loaded word would become their address. That is a wild store, and when it lands in the
            # code (the sandbox word held a code address) the two cores can legitimately fetch different
            # bytes -- the pipe has prefetched them, the FSM has not -- since no FENCE.I follows.
            rd = p.reg()
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
            # the pipelined core, both required to agree with EACH OTHER on
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


# CSRs the privilege-aware body touches. Which accesses are safe depends on
# the privilege: an S-mode access to an M CSR, or a U-mode one to an M or S CSR,
# is simply an illegal instruction (a trap the handlers skip), so those can be
# written freely. The S CSRs that matter to control flow are only read.
_S_RW = ["sscratch", "sepc", "scause", "stval"]    # rewritten by hardware at the next trap before anything reads them
_S_RO = ["sstatus", "sie", "stvec", "scounteren", "sip", "satp"]    # a write could redirect traps, enable interrupts or translation
_M_ANY = ["mstatus", "misa", "medeleg", "mideleg", "mie", "mtvec", "mscratch", "mepc", "mcause", "mtval",
          "mip", "mhartid", "pmpcfg0", "pmpaddr0", "mcycle", "minstret"]
_U_RO = ["cycle", "instret", "time"]
# dcsr, dpc, dscratch0/1, tselect, tdata1-3, tinfo: an illegal instruction outside Debug Mode, from every privilege
_D_ANY = ["0x7b0", "0x7b1", "0x7b2", "0x7b3", "0x7a0", "0x7a1", "0x7a2", "0x7a3", "0x7a4"]


def emit_priv_csr(p: Program, recent: list[int]):
    # under --irq the scratch CSRs hold the handlers' save-area pointers, and sip / mip show the
    # injected pins, whose visibility cycle differs between cores
    s_rw = [c for c in _S_RW if not (p.irq and c == "sscratch")]
    s_ro = [c for c in _S_RO if not (p.irq and c == "sip")]
    m_any = [c for c in _M_ANY if not (p.irq and c in ("mscratch", "mip"))]
    r = p.rng.random()
    rd = p.reg_biased(recent)
    if r < 0.30:
        csr = p.rng.choice(s_rw)
        form = p.rng.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"])
    elif r < 0.55:
        csr = p.rng.choice(s_ro)
        form = "read"
    elif r < 0.82:
        csr = p.rng.choice(m_any)
        form = p.rng.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci", "read"])
    elif r < 0.90:
        csr = p.rng.choice(_D_ANY)
        form = p.rng.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci", "read"])
    else:
        csr = p.rng.choice(_U_RO)
        form = "read"
    if form == "read":
        p.e(f"    csrr    x{rd}, {csr}")
    elif form.endswith("i"):
        p.e(f"    {form:<7} x{rd}, {csr}, {p.rng.randint(0, 31)}")
    else:
        p.e(f"    {form:<7} x{rd}, {csr}, x{p.reg_biased(recent)}")
    recent.append(rd)
    del recent[:-8]


def emit_priv_op(p: Program, recent: list[int]):
    """A privilege-relevant instruction that is safe wherever the body runs:
    SRET (set up so a legal one lands on the next instruction, in S or U by SPP;
    from U, or under TSR, it traps and is skipped to the same place), MRET
    (never legal below M: always a trap), SFENCE.VMA (legal in S and U, a trap
    in S under TVM), or a CSR probe."""
    r = p.rng.random()
    if p.body_priv2 and r < 0.30:
        r += 0.30           # a legal sret at privilege 2 would drop to S or U for good: keep the body there
    if r < 0.30:
        nxt = Label("sret")
        if p.irq:
            # an S-level interrupt between the sepc write and the sret would overwrite sepc, and the
            # sret would then return to the interrupted pc for ever: keep SIE clear across the window
            # (M-level ones don't touch sepc), set SPIE so the sret turns SIE back on, and set it
            # again after the label in case the sret trapped (TSR) instead
            p.e("    csrci   sstatus, 2")
        p.e(f"    la      x6, {nxt}")
        p.e("    csrw    sepc, x6")
        if p.irq:
            p.e("    li      x6, 0x20")                           # sstatus.SPIE
            p.e("    csrs    sstatus, x6")
        p.e("    li      x6, 0x100")                              # sstatus.SPP
        spp_s = p.rng.random() < 0.7
        if p.args.sv39:
            # the code pages are executable by the body's privilege only (S needs U=0 pages, U needs U=1): a
            # legal sret must not change it. (From a U body it traps and is skipped, whatever SPP says.)
            spp_s = True
        p.e(f"    {'csrs' if spp_s else 'csrc'}    sstatus, x6")
        p.e("    sret")
        p.e(f"{nxt}:")
        if p.irq and p.body_sie:
            p.e("    csrsi   sstatus, 2")
    elif r < 0.40:
        p.e("    mret")
    elif r < 0.55:
        form = p.rng.choice(["", "x0, x0", f"x{p.reg()}, x0", f"x0, x{p.reg()}", f"x{p.reg()}, x{p.reg()}"])
        p.e(f"    sfence.vma {form}".rstrip())
    else:
        emit_priv_csr(p, recent)


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
    if p.priv_ext and p.rng.random() < 0.5:
        emit_priv_csr(p, recent)
        return
    if p.rng.random() < 0.12:
        # a debug or trigger CSR outside Debug Mode: an illegal instruction at every privilege. In an M-mode body
        # this is the only way to reach the decoder's Debug Mode check (below M the privilege check traps first).
        rd = p.reg_biased(recent)
        csr = p.rng.choice(_D_ANY)
        form = p.rng.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci", "read"])
        if form == "read":
            p.e(f"    csrr    x{rd}, {csr}")
        elif form.endswith("i"):
            p.e(f"    {form:<7} x{rd}, {csr}, {p.rng.randint(0, 31)}")
        else:
            p.e(f"    {form:<7} x{rd}, {csr}, x{p.reg_biased(recent)}")
        recent.append(rd)
        del recent[:-8]
        return
    csr = "sscratch" if p.args.priv == "msu" else "mscratch"
    if p.irq:
        csr = "stval" if p.args.priv == "msu" else "mtval"     # the scratch CSRs are the handlers' pointers
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
    instruction with a different one, fence.i, then fall through and
    actually fetch what was just written -- proves I$/D$ coherence, not
    just that FENCE.I assembles. The old and new instructions write
    different values to x14 (111 vs 222), so a stale fetch shows up in
    the retirement stream; storing a nop over a nop never could."""
    tgt = Label("smc")
    p.e(f"    la      x13, {tgt}")
    p.li(14, 0x0DE00713)  # addi x14, x0, 222
    p.e("    sw      x14, 0(x13)")
    p.e("    fence.i")
    p.e(f"{tgt}:")
    # `.option norvc`: the `sw` above writes a full 4-byte instruction,
    # so the target must ALSO be a real 4-byte instruction -- under RVC
    # (the default for --isa imac) gas would compress it to 2 bytes, and
    # the store's other 2 bytes would then land on and corrupt whatever
    # instruction happens to follow.
    #
    # A REAL bug this fixes, found by direct simulation (an illegal-
    # instruction fault a few instructions after a SMC site, under
    # --sv39): the trailing half of the NEXT instruction (there, a 4-
    # byte `ret`) got overwritten with zeros, splitting it into a valid
    # leading nop plus two orphaned zero bytes that don't decode as
    # anything.
    p.e("    .option norvc")
    p.e("    addi    x14, x0, 111")
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

def _emit_pagetable_walk_and_fix(p: Program, va_reg: int, done_label, ordinary_label, fetch_label):
    """Generic depth-first walk from satp down to whichever level is
    already a leaf (R|W|X nonzero) -- correct for a plain 4KB mapping OR
    a superpage, since it simply stops descending the instant it finds
    one. It does what a hardware walker with A/D update would have done
    and retries: sets A on the leaf (and D as well for a store/AMO page
    fault, cause 15), SFENCE.VMAs, and continues at `done_label` (the
    handler's common return, which restores what the handler saved and
    does the xRET with mepc/sepc unchanged, so the access runs again).

    Every other outcome is a fault retrying cannot fix, and goes to
    `fetch_label` for a fetch page fault (cause 12: there is no
    instruction to skip, the handler resumes at x25) or to
    `ordinary_label` (skip the faulting instruction by its length):
      - an invalid entry (V=0) at any level. A REAL bug this once
        fixed, found by direct simulation: V=0 has R|W|X all clear
        too, so it looked identical to "non-leaf, keep descending", and
        the walk followed a bogus PPN=0 chain into low memory,
        misreading part of the running program as a leaf and
        corrupting it with a stray A/D store;
      - a pointer at the last level (nothing below it to walk into);
      - a leaf that already has the bits the fix would set, so the
        fault is a real permission, U/SUM/MXR, misalignment or
        reserved-bit fault. Since the fix only ever ADDS A/D, a fault
        that comes back after it ends here: the handler cannot loop.
    The state of a PTE the handler modifies is the same on both cores
    of a lockstep run, and every store to a PTE is followed by the
    SFENCE.VMA (speculation contract R1)."""
    walk = Label("pfwalk")
    leaf = Label("pfleaf")
    needa = Label("pfneeda")
    fall = Label("pffall")
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
        f"    beqz    x11, {fall}",
        "    andi    x11, x10, 0xE",   # R|W|X
        f"    bnez    x11, {leaf}",
        "    li      x11, 12",         # a pointer at level 0 has nothing below it
        f"    beq     x12, x11, {fall}",
        "    slli    x7, x10, 10",     # the PPN field [53:10] only: a malformed pointer has reserved, PBMT or N bits above it
        "    srli    x7, x7, 20",
        "    slli    x7, x7, 12",
        "    addi    x12, x12, -9",
        f"    j       {walk}",
        f"{leaf}:",
        "    li      x11, 0x40",       # A
        "    li      x8, 15",
        f"    bne     x5, x8, {needa}",
        "    li      x11, 0xC0",       # A and D for a store/AMO
        f"{needa}:",
        "    and     x8, x10, x11",
        f"    beq     x8, x11, {fall}",
        "    or      x10, x10, x11",
        "    sd      x10, 0(x9)",
        "    sfence.vma",
        f"    j       {done_label}",
        f"{fall}:",
        "    li      x8, 12",
        f"    beq     x5, x8, {fetch_label}",
        f"    j       {ordinary_label}",
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

    m_pro, m_epi, s_pro, s_epi = [], [], [], []
    if p.irq:
        # save x5-x8 on entry and restore them on every return: the scratch CSR holds the save-area
        # pointer, swapped with x5 to get a register to address it with
        for csr, pro, epi in (("mscratch", m_pro, m_epi), ("sscratch", s_pro, s_epi)):
            pro += [f"    csrrw   x5, {csr}, x5",
                    "    sd      x6, 0(x5)", "    sd      x7, 8(x5)", "    sd      x8, 16(x5)",
                    f"    csrr    x6, {csr}", "    sd      x6, 24(x5)",
                    f"    csrw    {csr}, x5"]
            epi += [f"    csrr    x5, {csr}",
                    "    ld      x6, 0(x5)", "    ld      x7, 8(x5)", "    ld      x8, 16(x5)",
                    "    ld      x5, 24(x5)"]

    p.handlers += [
        "    .balign 4",             # mtvec's low bits may carry MODE bits, so its base has to be 4-aligned
        f"{m_trap}:",
        *m_pro,
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
    for cause in (8, 9, 11) + ((0,) if p.priv_ext else ()):
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
        _emit_pagetable_walk_and_fix(p, 6, m_ret, m_ordinary, m_fetch)
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
        # which privilege trapped. A body that runs through the window
        # above the image has a virtual mepc that M mode cannot read as
        # a physical address: the load is made with MPRV, at the
        # privilege that trapped (MPP), translated.
        "    csrr    x6, mepc",
        *(["    li      x8, 0x20000", "    csrs    mstatus, x8"] if p.reloc else []),
        "    lhu     x7, 0(x6)",
        *(["    csrc    mstatus, x8"] if p.reloc else []),
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
        *m_epi,
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
            "    .balign 4",         # stvec's low bits may carry MODE bits, so its base has to be 4-aligned
            f"{s_trap}:",
            *s_pro,
            "    csrr    x5, scause",
            f"    bge     x5, x0, {s_sync}",
            f"{s_intr}:",
            "    li      x6, 0x0400F004",
            "    li      x7, 1",
            "    sw      x7, 0(x6)",
            f"    j       {s_ret}",
            f"{s_sync}:",
        ]
        if p.priv_ext:
            # ECALL from U (cause 8) delegated to S: the epilogue's goes up to
            # M as an ECALL from S (cause 9, never delegated); any other is
            # an ordinary fault
            s_not_u = Label("snotu")
            p.handlers += [
                "    li      x6, 8",
                f"    bne     x5, x6, {s_not_u}",
                f"    li      x6, {EPILOGUE_MAGIC}",
                f"    bne     x24, x6, {s_ordinary}",
                "    ecall",
                f"{s_not_u}:",
            ]
        p.handlers += [
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
            _emit_pagetable_walk_and_fix(p, 6, s_ret, s_ordinary, s_fetch)
        # the first halfword of the faulting instruction, to size it. With Sv39 the code may be user code
        # (a U body): the read is a translated S-mode load, so SUM is set around it and put back
        s_lhu = ["    csrr    x6, sepc", "    lhu     x7, 0(x6)"]
        if a.sv39:
            sum_kept = Label("sumkept")
            s_lhu = ["    csrr    x6, sepc",
                     "    li      x8, 0x40000",                 # sstatus.SUM
                     "    csrrs   x9, sstatus, x8",
                     "    lhu     x7, 0(x6)",
                     "    and     x9, x9, x8",
                     f"    bnez    x9, {sum_kept}",              # it was set already: leave it
                     "    csrc    sstatus, x8",
                     f"{sum_kept}:"]
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
            *s_lhu,
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
            *s_epi,
            "    sret",
        ]

    _emit_epilogue_body(p)


# =======================================================================
# Preambles
# =======================================================================

_PMP_A_OFF, _PMP_A_TOR, _PMP_A_NA4, _PMP_A_NAPOT = 0, 1, 2, 3


def napot_pmpaddr(base: int, size: int) -> int:
    """pmpaddr for a NAPOT region of `size` bytes (a power of two, at least 8) at `base`."""
    assert size >= 8 and size & (size - 1) == 0 and base % size == 0
    return (base >> 2) | ((size >> 3) - 1)


def emit_pmp(p: Program):
    """Random PMP. The last entry is a NAPOT over the whole 1 MiB image, rwx and unlocked, so the code, the
    handlers, the data and the epilogue stay reachable below M (and M is never denied by an unlocked region).
    The entries ahead of it, which have priority, carve pockets with random permissions out of the sandbox and
    the bad-address page -- NAPOT or NA4, or a TOR region on top of an OFF entry that only supplies its lower
    bound -- and now and then lock one, so M mode obeys it too. Under --irq one entry is the MAGIC dword
    (read+write), which the S handler writes to clear the injected levels.

    Loads and stores into a pocket fault by what the pocket allows (5/7, LR and AMOs count as writes, a span
    that only partly overlaps a region is no match at all); `jr x25` at POCKET_X is the target of the
    fetch-fault idiom (emit_pmp_jump): execute permission there decides between a clean return and a fetch
    access fault the handler resumes from x25."""
    rng = p.rng
    p.e("    # -- PMP: random pockets over a permissive whole-image region --")

    def perms() -> int:
        # R=1, W=2, X=4; W without R is reserved
        return 0 if rng.random() < 0.35 else rng.choice([1, 1, 3, 3, 4, 5, 7])

    def pocket_cfg(a: int, lockable: bool = True) -> int:
        lock = 0x80 if lockable and rng.random() < 0.25 else 0
        return lock | (a << 3) | perms()

    def sandbox_pocket():
        """An NA4 word or a NAPOT block (16 bytes .. 16 KiB) in the sandbox."""
        if rng.random() < 0.3:
            area = HOT_SIZE if rng.random() < 0.7 else SANDBOX_SIZE
            a = SANDBOX_BASE + rng.randrange(0, area, 4)
            p.pockets.append((a, a + 4))
            return pocket_cfg(_PMP_A_NA4), a >> 2
        size = 1 << rng.randint(4, 14)
        if size <= HOT_SIZE and rng.random() < 0.7:
            base = SANDBOX_BASE + rng.randrange(0, HOT_SIZE, size)
        else:
            base = SANDBOX_BASE + rng.randrange(0, SANDBOX_SIZE, size) if size < SANDBOX_SIZE else SANDBOX_BASE
        p.pockets.append((base, base + size))
        return pocket_cfg(_PMP_A_NAPOT), napot_pmpaddr(base, size)

    def bad_page_pocket():
        if p.args.sv39:
            # 128 KiB: the bad-address page, the probe pages and the page of the PMPT_VA table. With reads forbidden
            # the PTE read of a walk through that table is denied (an access fault), not just the access itself
            return (pocket_cfg(_PMP_A_NAPOT), napot_pmpaddr(0x80000, 0x20000))
        return (pocket_cfg(_PMP_A_NAPOT), napot_pmpaddr(BAD_ADDR_BASE, 0x1000))

    entries = [None, None, None]
    if rng.random() < 0.3:
        # TOR layout: e0 only carries the lower bound, e1 is the TOR region on top of it
        lower = SANDBOX_BASE + rng.randrange(0, 0x6000, 4)
        top = lower + rng.randrange(8, 0x2000, 4)
        entries[0] = (0, lower >> 2)
        entries[1] = (pocket_cfg(_PMP_A_TOR), top >> 2)
        p.pockets.append((lower, top))
        entries[2] = bad_page_pocket()
    else:
        entries[0] = sandbox_pocket() if rng.random() < 0.85 else (0, 0)
        entries[1] = bad_page_pocket()
        entries[2] = sandbox_pocket() if rng.random() < 0.5 else (0, 0)
        if p.args.sv39 and not p.irq and rng.random() < 0.5:
            # the high probe page gets a pocket of its own ahead of the 128 KiB one (--irq needs the entry for the MAGIC
            # dword): the two pages of the straddling instruction, and the span of a fetch that starts in the first, can
            # then differ in X
            entries[2] = entries[1]
            entries[1] = (pocket_cfg(_PMP_A_NAPOT), napot_pmpaddr(PROBE_HI_VPN << 12, 0x1000))
        if p.args.sv39 and rng.random() < 0.35:
            # an NA4 word over the first half of one PTE of the PMPT_VA table, ahead of the region that covers the
            # whole table: a PTE read is eight bytes, so it only partly overlaps the word and is no match for it,
            # where a read of a single byte would match it (and get its permissions)
            p.ptpmp_k = rng.randrange(8)
            entries[0] = (pocket_cfg(_PMP_A_NA4, lockable=False), (PMPT_PA + 8 * p.ptpmp_k) >> 2)
    if p.irq:
        entries[2] = (0x18 | 0x3, napot_pmpaddr(MAGIC_BASE, 8))          # NAPOT, read+write, unlocked
    entries.append((0x18 | 0x7, napot_pmpaddr(0, 0x100000)))               # the base: NAPOT rwx over the image

    cfg = 0
    for i, (c, a) in enumerate(entries):
        p.li(6, a)
        p.e(f"    csrw    pmpaddr{i}, x6")
        cfg |= c << (8 * i)
    p.li(6, cfg)
    p.e("    csrw    pmpcfg0, x6")


def emit_pmp_jump(p: Program):
    """A jump into the bad-address page: a fetch from a PMP pocket. x25 is pointed at the label after it first;
    if the pocket forbids execute the fetch faults (cause 1) and the handler resumes at x25, otherwise the
    `jr x25` placed at POCKET_X returns there -- either way the program carries on. Needs the page's PMP entry,
    so only under --pmp."""
    nxt = Label("pmpjmp")
    p.e(f"    la      x25, {nxt}")
    p.li(6, POCKET_X)
    p.e("    jalr    x0, 0(x6)")
    p.e(f"{nxt}:")
    p.e("    la      x25, recovery_point")


# =======================================================================
# Sv39 (--sv39): the page tables, the data window, the probes
# =======================================================================
#
# The tables are static data at fixed physical addresses: the link script puts .data.pagetables at
# PAGETABLE_BASE and every table is exactly 4 KB. Set A is what satp points at when the body starts;
# set B is the same map with a few deliberate differences, which the body may switch to (satp write +
# SFENCE.VMA, speculation contract R1). A page-table walk reads no device (contract R2): every pointer
# PTE below points at one of these eight tables, except the far ones (above 2^38, which the PMP denies, and
# FAR_BASE, a bus error), and the only executable leaves map the code and the probe pages (RAM, or now and then
# FAR_BASE).

PTE_V, PTE_R, PTE_W, PTE_X, PTE_U, PTE_A, PTE_D = 0x01, 0x02, 0x04, 0x08, 0x10, 0x40, 0x80

SV_SET_A, SV_SET_B = 0, 1
SV_TABLE_NAMES = ["l2_table", "l1_table", "l0_table", "l0x_table",
                  "l2b_table", "l1b_table", "l0b_table", "l0xb_table"]


def sv_set_base(setno: int) -> int:
    return PAGETABLE_BASE + 0x4000 * setno


def sv_satp(setno: int) -> int:
    return (8 << 60) | (sv_set_base(setno) >> 12)


# the virtual layout. The first 2 MiB (L2[0], L1[0]) is mapped with 4 KB leaves; the other 2 MiB slots
# of the first gigabyte, and two further gigabytes, hold the data windows and the holes
MEGA_VA     = 0x0040_0000        # L1[2]: a 2 MiB window onto PA 0 (the data window of a "mega" seed)
MISMEGA_VA  = 0x0060_0000        # L1[3]: a 2 MiB leaf that is not 2 MiB aligned -> page fault
MALF_VA     = 0x0080_0000        # L1[4]: a leaf with W and no R -> page fault
RSVD_VA     = 0x00A0_0000        # L1[5]: a leaf with a reserved bit -> page fault
PTR0_VA     = 0x00C0_0000        # L1[6]: a pointer to a table whose entry 0 is a pointer -> page fault
UNMAP_VA    = 0x0100_0000        # L1[8]: not mapped
PMPT_VA     = 0x00E0_0000        # L1[7]: a pointer to the L0 table in the page at PMPT_PA, whose PTEs map eight
                                 # sandbox pages. With --pmp the bad-address pocket covers that page, and when the
                                 # pocket forbids reads the walk's PTE read is denied: an access fault (5/7), not a page fault
PMPT_PA     = 0x0008_F000
GIGA_VA     = 0x4000_0000        # L2[1]: a 1 GiB window onto PA 0 (the data window of a "giga" seed)
MISGIGA_VA  = 0x8000_0000        # L2[2]: a 1 GiB leaf that is not 1 GiB aligned -> page fault
# the entries below are about the bits of a PTE and of a physical address that the ordinary map never sets
DEAD_VA     = 0x0120_0000        # L1[9]: a 2 MiB leaf with V clear but R, W, A, D set -> page fault
FARLEAF_VA  = 0x0140_0000        # L1[10]: a 2 MiB leaf onto a PA with one high bit set: the PMP sees all 56 bits and
                                 # denies it, an address cut short would reach the RAM (access fault 5/7)
FARPTR_VA   = 0x0160_0000        # L1[11]: a pointer to a table far out (PA bit 32..55): the walk's PTE read is denied (5/7)
BUSPTR_VA   = 0x0180_0000        # L1[12]: a pointer to the bus-error region at FAR_BASE: the PTE read is denied by
                                 # PMP or, where a PMP entry lets it through, ends in a bus error (5/7 either way)
RSVDPTR_VA  = 0x01A0_0000        # L1[13]: a pointer with a reserved, PBMT or N bit set, to a valid table -> page fault
BUSLEAF_VA  = 0x01C0_0000        # L1[14]: a 2 MiB leaf onto FAR_BASE: PMP denial or a bus error after the translation
DEADGIGA_VA = 0xC000_0000        # L2[3]: a 1 GiB "leaf" with V clear -> page fault
FARGIGA_VA  = 0x1_8000_0000      # L2[6]: a 1 GiB leaf onto a far PA (access fault); an M body, which does not
                                 # translate, reaches the bus-error region with it
USERX_VA    = 0x0200_0000        # L1[16]: an executable user window onto PA 0: S mode never fetches from it, with SUM or not
FAR_PA_BITS = [32, 36, 38, 40, 44, 48, 52, 55]    # the one bit a far physical address has set (bit 55 is the last of a PTE's PPN)
# (virtual address, span the offset may cover) of every hole; the first group faults in the first 4 KB only
HOLE_VAS    = [(BAD_ADDR_BASE, 0x800), (MISMEGA_VA, 0x1000), (MALF_VA, 0x1000), (RSVD_VA, 0x1000), (PTR0_VA, 0x1000),
               (UNMAP_VA, 0x1000), (MISGIGA_VA, 0x1000), (FAR_BASE, 0x1000), (PMPT_VA, 0x8000), (PMPT_VA, 0x8000),
               (DEAD_VA, 0x1000), (DEADGIGA_VA, 0x1000), (FARPTR_VA, 0x1000), (BUSPTR_VA, 0x1000),
               (RSVDPTR_VA, 0x1000), (FARLEAF_VA, 0x20_0000), (BUSLEAF_VA, 0x20_0000), (FARGIGA_VA, 0x4000_0000)]
# addresses whose upper bits (63:39) are not a sign extension of bit 38; the low part of each is added at use
NONCANON_UPPER = [0x0000_0080_0000_0000, 0x0000_0100_0000_0000, 0x0001_0000_0000_0000, 0x4000_0000_0000_0000,
                  0x8000_0000_0000_0000, 0xFFFF_FF80_0000_0000, 0xFFFF_FF80_0000_0000, 0x7FFF_FF80_0000_0000,
                  0xFFFF_FE00_0000_0000]
NONCANON_VAS = [0x0000_0040_0000_0000, 0xFFFF_FFBF_FFFF_F000, 0x0000_00FF_FFFF_F000, 0xFFFF_FFC0_0000_0000]
PROBE_LO_VPN, PROBE_HI_VPN = 0x91, 0x92
PROBE_X = (PROBE_LO_VPN << 12) + 0xFFE      # a 32-bit `jr x25` straddling the 0x92000 page boundary
ALIAS_VA = 0x01E0_0000                      # L1[15]: an executable 2 MiB window onto PA 0, above the image: the pocket's `jr x25` and
ALIAS_X = ALIAS_VA + POCKET_X               # the straddling one run from virtual addresses that no PMP region covers (the PMP has to
ALIAS2_X = ALIAS_VA + PROBE_X               # look at the physical ones), and the two halves of the second sit in frames of their own


def sv_rsvd_bit(p: Program) -> int:
    """A bit that makes a PTE malformed: reserved (60:54), PBMT (62:61) or N (63), the last two favoured."""
    return p.rng.choice(list(range(54, 61)) + [61, 62, 63] * 3)


def sv_leaf(pa: int, flags: int) -> int:
    return ((pa >> 12) << 10) | flags


def sv_ptr(pa: int) -> int:
    return ((pa >> 12) << 10) | PTE_V


def sv_data_flags(p: Program, user: bool) -> int:
    """Random flags for a page of data: usually plain read/write, now and then read-only, execute-only
    (a load needs MXR), malformed (W without R), invalid, or invalid with the bits of a good leaf (V alone
    clear). A and D are often clear: the page-fault handler sets them (and R1 makes sure it follows with an
    SFENCE.VMA). 0 means not mapped."""
    rng = p.rng
    perm = rng.choices([PTE_R | PTE_W, PTE_R, PTE_X, PTE_R | PTE_X, PTE_R | PTE_W | PTE_X, PTE_W, 0, -1],
                       weights=[60, 10, 6, 4, 6, 3, 1, 2])[0]
    if perm == 0:
        return 0
    if perm < 0:                           # V clear, everything else a good leaf: the entry must not be used
        return PTE_R | PTE_W | PTE_A | PTE_D | (PTE_U if user else 0)
    f = PTE_V | perm
    if rng.random() < 0.85:
        f |= PTE_A
    if rng.random() < 0.5:
        f |= PTE_D
    if user:
        f |= PTE_U
    return f


def sv_exec_flags(p: Program, user: bool, ok_bias: float) -> int:
    """Random flags for a page a fetch probe jumps into: executable and fine (probability ok_bias), or
    one of the ways a fetch fails (invalid, not executable, A clear, wrong U for the privilege)."""
    rng = p.rng
    if rng.random() < ok_bias:
        return PTE_V | PTE_R | PTE_X | PTE_A | (PTE_U if user else 0)
    kind = rng.choice(["invalid", "noexec", "noA", "wrongU", "wrongU", "rwx"])
    if kind == "invalid":
        return 0
    if kind == "noexec":
        return PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | (PTE_U if user else 0)
    if kind == "noA":
        return PTE_V | PTE_R | PTE_X | (PTE_U if user else 0)
    if kind == "wrongU":
        return PTE_V | PTE_R | PTE_X | PTE_A | (0 if user else PTE_U)
    return PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | (PTE_U if user else 0)


def plan_sv39(p: Program):
    """The decisions that have to be known before the preamble loads x27: where the data window is."""
    rng = p.rng
    p.sv_mode = "ident"
    if p.priv_ext:
        p.sv_mode = rng.choice(["ident", "ident", "ident", "ident", "mega", "giga"])
    p.data_base = {"ident": SANDBOX_BASE, "mega": MEGA_VA + SANDBOX_BASE,
                   "giga": GIGA_VA + SANDBOX_BASE}[p.sv_mode]
    p.sv_swap = p.priv_ext and rng.random() < 0.6
    # the body itself at a virtual address that is not its physical one, through a 2 MiB leaf: every fetch is a
    # superpage hit, the pc is not the address the PMP sees, and a redirect that turns translation on (the MRET into
    # the body) has to translate its first fetch. The handlers stay where they are (the M handler cannot translate)
    p.reloc = p.priv_ext and not p.body_priv2 and p.args.sv39_fetch and rng.random() < 0.3


def sv39_pages(p: Program) -> dict:
    """The 4 KB pages of the first 2 MiB: vpn0 -> (pa, flags); flags 0 = not mapped."""
    rng = p.rng
    a = p.args
    user = p.body_u
    pages = {}
    for v in range(0, 16):                 # code (.text.entry, then the handlers); stays readable for the handlers
        f = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A
        if rng.random() < 0.3:
            f |= PTE_D
        if v < 8 and user:
            f |= PTE_U
        if a.sv39_fetch and 1 <= v < 8 and rng.random() < 0.25 and not p.sv_swap:
            # the first fetch from it page-faults; the handler sets A. Not when the body switches satp: the handler sets
            # A in the table set that is current, so the two sets would disagree about a code page, and an interrupt
            # between the satp write and its SFENCE.VMA (R1 has no way to keep one out) lets a core that re-walks the
            # page fault where one with a stale entry does not (found by the first run of the exit gate, 1 in 2000)
            f &= ~PTE_A
        pages[v] = (v << 12, f)
    for v in range(16, 24):                # the sandbox
        pages[v] = (v << 12, sv_data_flags(p, user or rng.random() < 0.2))
    for v in range(24, 32):
        pages[v] = (v << 12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    for v in range(32, 49):                # the tables, the epilogue's data (trap_count, tohost, saves): pre-dirtied, never U
        pages[v] = (v << 12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    if p.sv_mode == "ident":               # one real remap, so translation is not just an identity
        pages[17] = (MISC_BASE + 0x1000, sv_data_flags(p, user or rng.random() < 0.2))
    # the bad-address page (also where a PMP pocket's `jr x25` lives) and the two pages of a straddling probe
    bad = sv_exec_flags(p, user or rng.random() < 0.15, 0.5) if rng.random() < 0.6 else sv_data_flags(p, user)
    pages[BAD_ADDR_BASE >> 12] = (BAD_ADDR_BASE, bad)
    # a probe page now and then maps the bus-error region instead of its own code: a fetch that translates fine and
    # then gets a bus error (cause 1, in the second half of the straddling instruction when it is the high page).
    # The region holds no device, so a wrong-path fetch of it reads nothing (R2 is about devices)
    pa_lo = FAR_BASE if rng.random() < 0.15 else PROBE_LO_VPN << 12
    pa_hi = FAR_BASE if rng.random() < 0.25 else PROBE_HI_VPN << 12
    pages[PROBE_LO_VPN] = (pa_lo, sv_exec_flags(p, user or rng.random() < 0.1, 0.8))
    pages[PROBE_HI_VPN] = (pa_hi, sv_exec_flags(p, user or rng.random() < 0.1, 0.5))
    return pages


def sv39_pages_b(p: Program, pages_a: dict) -> dict:
    """Set B: set A with one to three sandbox pages changed (another physical page, other flags). The code,
    the handlers, the tables and the epilogue's data are the same in both, so a switch is safe anywhere."""
    rng = p.rng
    pages = dict(pages_a)
    for v in rng.sample(range(16, 24), rng.randint(1, 3)):
        user = bool(pages_a[v][1] & PTE_U) or p.body_u
        pa = 0x40000 + ((v - 16) << 12) if rng.random() < 0.6 else (v << 12)
        pages[v] = (pa, sv_data_flags(p, user))
    return pages


def sv39_tables(p: Program, pages: dict, setno: int):
    """-> the four tables of one set as dicts (index -> PTE): root, L1, L0, and the L0 table behind PTR0_VA."""
    rng = p.rng
    base = sv_set_base(setno)
    root_pa, l1_pa, l0_pa, l0x_pa = base, base + 0x1000, base + 0x2000, base + 0x3000
    user = p.body_u
    root, l1, l0, l0x = {}, {}, {}, {}
    root[0] = sv_ptr(l1_pa)
    l1[0] = sv_ptr(l0_pa)
    for v, (pa, f) in pages.items():
        if f:
            l0[v] = sv_leaf(pa, f)
    # the windows: leaves above the 4 KB level, onto physical 0
    def window_flags():
        f = PTE_V | PTE_R | PTE_W
        if rng.random() < 0.85:
            f |= PTE_A
        if rng.random() < 0.5:
            f |= PTE_D
        return f | (PTE_U if user else 0)
    if p.sv_mode == "mega":
        l1[(MEGA_VA >> 21) & 0x1FF] = sv_leaf(0, window_flags())
    if p.sv_mode == "giga":
        root[(GIGA_VA >> 30) & 0x1FF] = sv_leaf(0, window_flags())
    # holes: every access to them page-faults, or (the far ones) takes an access fault
    good = PTE_R | PTE_W | PTE_A | PTE_D
    # which low bits of a superpage's physical page number are set: ppn0 alone, ppn1 alone, or both
    l1[(MISMEGA_VA >> 21) & 0x1FF] = sv_leaf(rng.choice([0x1000, 0x201000, 0x1000_1000]), PTE_V | good)    # misaligned superpage
    l1[(MALF_VA >> 21) & 0x1FF] = sv_leaf(0x200000, PTE_V | PTE_W | PTE_A | PTE_D)                  # W without R
    l1[(RSVD_VA >> 21) & 0x1FF] = sv_leaf(0x400000, PTE_V | good) | (1 << sv_rsvd_bit(p))            # a reserved, PBMT or N bit
    l1[(PTR0_VA >> 21) & 0x1FF] = sv_ptr(l0x_pa)
    l0x[0] = sv_ptr(l0_pa)                                                                          # a pointer at the last level
    l1[(PMPT_VA >> 21) & 0x1FF] = sv_ptr(PMPT_PA)                                                   # the L0 table behind the PMP pocket
    root[(MISGIGA_VA >> 30) & 0x1FF] = sv_leaf(rng.choice([0x1000, 0x20_0000, 0x20_1000]), PTE_V | good)  # misaligned gigapage
    l1[(DEAD_VA >> 21) & 0x1FF] = sv_leaf(0, good)                                                  # V clear, the rest of a good leaf
    root[(DEADGIGA_VA >> 30) & 0x1FF] = sv_leaf(0, good)
    farf = PTE_V | good | (PTE_U if user else 0)
    far = lambda: 1 << rng.choice(FAR_PA_BITS)
    l1[(FARLEAF_VA >> 21) & 0x1FF] = sv_leaf(far(), farf)                                           # a high PA bit: the PMP denies it
    root[(FARGIGA_VA >> 30) & 0x1FF] = sv_leaf(far(), farf)
    l1[(BUSLEAF_VA >> 21) & 0x1FF] = sv_leaf(FAR_BASE, farf)                                        # the bus-error region
    l1[(FARPTR_VA >> 21) & 0x1FF] = sv_ptr(far() + l0_pa)                                           # a table far out
    l1[(BUSPTR_VA >> 21) & 0x1FF] = sv_ptr(FAR_BASE)                                                # a table in the bus-error region
    l1[(RSVDPTR_VA >> 21) & 0x1FF] = sv_ptr(l0_pa) | (1 << sv_rsvd_bit(p))                          # a malformed pointer to a good table
    if p.reloc:       # the body runs in it: everything allowed, and no fault to leave it for
        alias_flags = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | (PTE_U if user else 0)
    else:
        alias_flags = sv_exec_flags(p, user or rng.random() < 0.1, 0.8)
    l1[(ALIAS_VA >> 21) & 0x1FF] = sv_leaf(0, alias_flags)                                          # executable window onto PA 0
    l1[(USERX_VA >> 21) & 0x1FF] = sv_leaf(0, PTE_V | PTE_R | PTE_X | PTE_A | PTE_U)                # executable user window onto PA 0
    if p.irq:                                                       # the S handler's write of the MAGIC clear
        l1[(MAGIC_BASE >> 21) & 0x1FF] = sv_leaf(MAGIC_BASE & ~0x1FFFFF, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    return root, l1, l0, l0x


def sv_emit_table(p: Program, label: str, entries: dict):
    p.pagetable_data.append(f"{label}:")
    pos = 0
    for idx in sorted(entries):
        if idx > pos:
            p.pagetable_data.append(f"    .zero   {8 * (idx - pos)}")
        p.pagetable_data.append(f"    .dword  {entries[idx]:#x}")
        pos = idx + 1
    if pos < 512:
        p.pagetable_data.append(f"    .zero   {8 * (512 - pos)}")


def emit_sv39(p: Program):
    """Builds both table sets (static data, see the block comment above), then switches translation on in
    M mode: satp to set A and an SFENCE.VMA. The body runs translated from its first instruction (in S or U
    mode under --priv msu). Everything the generated program legitimately touches is mapped, and the faulting
    accesses (the holes, unlucky page flags) are recovered from by the handlers."""
    pages_a = sv39_pages(p)
    pages_b = sv39_pages_b(p, pages_a) if p.sv_swap else pages_a
    for setno, pages in ((SV_SET_A, pages_a), (SV_SET_B, pages_b)):
        for name, tab in zip(SV_TABLE_NAMES[4 * setno:4 * setno + 4], sv39_tables(p, pages, setno)):
            sv_emit_table(p, name, tab)
    # the L0 table the PMP pocket covers: eight sandbox pages, read/write, A and D set (a page fault here could make
    # the S handler write a PTE the pocket does not let it write), user only for a U body
    f = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | (PTE_U if p.body_u else 0)
    p.ptpmp_data += ["ptpmp_table:"] + [f"    .dword  {sv_leaf(SANDBOX_BASE + (i << 12), f):#x}" for i in range(8)]
    p.ptpmp_data += ["    .zero   " + str(8 * (512 - 8))]
    p.e("    # -- Sv39: the map is static data; satp to table set A --")
    p.li(6, sv_satp(SV_SET_A))
    p.e("    csrw    satp, x6")
    p.e("    sfence.vma")


# -- body operations that exercise translation (--sv39) ------------------------------------------------------
# They use x6 (and the usual FREE_POOL registers) and leave nothing in flight: a trap in the middle of one
# clobbers only handler scratch, and every access that can fault is the last thing the idiom does with its
# address register.

def emit_hole_access(p: Program, recent: list[int]):
    """A load, store, LR or AMO at an address that page-faults (a hole in the map, or a page whose flags forbid
    it), or that takes an access fault (a far physical address, a far page table, the bus-error region), or at the
    bad-address page and FAR_BASE, which fault too under Sv39. An access into a superpage behind a far address comes
    in twos and threes: the first fills the TLB, the others hit it."""
    rng = p.rng
    va0, span = rng.choice(HOLE_VAS)
    if va0 == PMPT_VA and p.ptpmp_k is not None and rng.random() < 0.7:
        va0, span = PMPT_VA + (p.ptpmp_k << 12), 0x1000      # the page behind the PTE a PMP word cuts in half
    if va0 == BUSLEAF_VA and rng.random() < 0.5:
        span = 0x1000                                        # the first page: where a PMP entry may let it through to the bus
    for _ in range(rng.choice([1, 2, 3]) if span > 0x8000 else 1):
        va = va0 + rng.randrange(0, span, 8)                # below the pocket at POCKET_X for the bad-address page
        if rng.random() < 0.2:
            va += rng.choice([1, 2, 3, 5, 6, 7])            # misaligned for every access wider than a byte: the
                                                            # misaligned trap comes first, before any walk
        p.li(6, va)
        r = rng.random()
        if r < 0.15:
            rd, rs = p.reg_biased(recent), p.reg_biased(recent)
            w = rng.choice(["w", "d"])
            if rng.random() < 0.5:
                p.e(f"    lr.{w}    x{rd}, (x6)")
            else:
                p.e(f"    {rng.choice(_AMO_RMW)}.{w} x{rd}, x{rs}, (x6)")
            recent.append(rd)
        elif r < 0.6:
            mnem, _ = rng.choice(_LOADS)
            rd = p.reg_biased(recent)
            p.e(f"    {mnem:<7} x{rd}, 0(x6)")
            recent.append(rd)
        else:
            mnem, _ = rng.choice(_STORES)
            p.e(f"    {mnem:<7} x{p.reg_biased(recent)}, 0(x6)")
        del recent[:-8]


def emit_window_probe(p: Program, recent: list[int]):
    """An access through the 2 MiB or 1 GiB data window at an offset the sandbox accesses never use: another page of
    the memory behind it (a read only, below 1 MiB: a store could land in the code or in a page table), or past the
    image, where the PMP denies it. Page-number bits of the virtual address that the physical address has to take
    from the virtual one are the point."""
    rng = p.rng
    if p.sv_mode == "mega":
        k = rng.randrange(0, 512)
        va = MEGA_VA + (k << 12) + rng.randrange(0, 0x1000, 8)
        may_store = k >= 256
    else:
        k = rng.randrange(0, 16)
        va = GIGA_VA + (k << 21) + (rng.randrange(0, 512) << 12) + rng.randrange(0, 0x1000, 8)
        may_store = k >= 1
    p.li(6, va)
    if may_store and rng.random() < 0.4:
        mnem, _ = rng.choice(_STORES)
        p.e(f"    {mnem:<7} x{p.reg_biased(recent)}, 0(x6)")
    else:
        mnem, _ = rng.choice(_LOADS)
        rd = p.reg_biased(recent)
        p.e(f"    {mnem:<7} x{rd}, 0(x6)")
        recent.append(rd)
    del recent[:-8]


def emit_noncanonical(p: Program, recent: list[int]):
    """An access to a virtual address whose upper bits are not a sign extension of bit 38: a page fault whatever
    the map says (but the walk still reads the root PTE first, so a PTE-read fault would win). Mostly an alias of a
    mapped address: the sandbox's page-number bits with other bits above 38, so that a core that checks the wrong
    bits, or too few, translates it."""
    rng = p.rng
    if rng.random() < 0.65:
        va = rng.choice(NONCANON_UPPER) | ((p.data_base & ((1 << 38) - 1)) + rng.randrange(0, 0x800, 8))
    else:
        va = rng.choice(NONCANON_VAS) + rng.randrange(0, 0x1000, 8) * (rng.random() < 0.5)
    p.li(6, va)
    # an M body does not translate: the address goes to the bus with its upper bits dropped, so a store through the
    # alias of a low address writes the real one (the aliases of PA 0 are the program's own code)
    if rng.random() < 0.5 or not p.priv_ext:
        mnem, _ = rng.choice(_LOADS)
        rd = p.reg_biased(recent)
        p.e(f"    {mnem:<7} x{rd}, 0(x6)")
        recent.append(rd)
    else:
        mnem, _ = rng.choice(_STORES)
        p.e(f"    {mnem:<7} x{p.reg_biased(recent)}, 0(x6)")
    del recent[:-8]


def emit_tlb_thrash(p: Program, recent: list[int]):
    """More distinct sandbox pages than a TLB has entries, in one burst: capacity misses and refills."""
    rng = p.rng
    for k in rng.sample(range(8), rng.randint(5, 8)):
        p.li(6, k * 0x1000 + rng.randrange(0, 0x800, 8))
        p.e("    add     x6, x6, x27")
        mnem, _ = rng.choice(_LOADS)
        rd = p.reg_biased(recent)
        p.e(f"    {mnem:<7} x{rd}, 0(x6)")
        recent.append(rd)
    del recent[:-8]


def emit_sum_mxr(p: Program):
    """Toggle sstatus.SUM and/or sstatus.MXR (an S-mode body only): whether a user page or an execute-only page
    can be loaded changes with them."""
    rng = p.rng
    p.li(6, rng.choice([1 << 18, 1 << 19, (1 << 18) | (1 << 19)]))
    p.e(f"    {rng.choice(['csrs', 'csrc'])}    sstatus, x6")


def emit_flip_pair(p: Program, recent: list[int]):
    """SUM and/or MXR set for one access to a sandbox page and cleared for the next, or the other way round: the
    first access fills the TLB, the second hits the entry, and the live check has to apply the bit as it is now,
    not as it was at the fill (an execute-only page is readable only while MXR is set, a user page is reachable from S
    only while SUM is set). Every access reloads x6: a trap in the middle clobbers it."""
    rng = p.rng
    bits = rng.choice([1 << 18, 1 << 19, (1 << 18) | (1 << 19)])
    off = rng.randrange(8) * 0x1000 + rng.randrange(0, 0x800, 8)
    first, second = ("csrs", "csrc") if rng.random() < 0.7 else ("csrc", "csrs")

    def access():
        p.li(6, off)
        p.e("    add     x6, x6, x27")
        if rng.random() < 0.35:                              # a store: the entry's W and D count as well
            mnem, _ = rng.choice(_STORES)
            p.e(f"    {mnem:<7} x{p.reg_biased(recent)}, 0(x6)")
        else:
            mnem, _ = rng.choice(_LOADS)
            rd = p.reg_biased(recent)
            p.e(f"    {mnem:<7} x{rd}, 0(x6)")
            recent.append(rd)

    p.li(6, bits)
    p.e(f"    {first}    sstatus, x6")
    access()
    p.li(6, bits)
    p.e(f"    {second}    sstatus, x6")
    access()
    del recent[:-8]


def emit_satp_op(p: Program):
    """satp: a write of the value it already holds (flushes nothing, changes nothing), a switch to the other
    table set followed by the SFENCE.VMA that speculation contract R1 requires, or the SFENCE.VMA alone."""
    rng = p.rng
    r = rng.random()

    def sfence():
        p.e("    sfence.vma")
        if rng.random() < 0.3:
            # the fetch after the SFENCE.VMA finds the instruction TLB empty and translates; FENCE.I then holds fetch
            # while that translation is pending
            p.e("    fence.i")

    if r < 0.35:
        p.e("    csrr    x6, satp")
        p.e("    csrw    satp, x6")
    elif p.sv_swap and r < 0.85:
        p.li(6, sv_satp(rng.choice([SV_SET_A, SV_SET_B])))
        p.e("    csrw    satp, x6")
        sfence()
    else:
        sfence()


def emit_fetch_probe(p: Program):
    """A jump to an address whose translation, flags or PMP decide whether a fetch from it works: the pocket in the
    bad-address page (`jr x25`); a 32-bit `jr x25` that straddles two pages with flags of their own (so a fault can
    be in the second half, where the trap value is pc + 8); an address behind a far page table (the walk's own PTE
    read faults: an access fault, cause 1); or those two `jr x25` again through a window above the image (the PMP
    has to look at the physical address, which the virtual one does not show); or, the same, through a user
    window (an S body can never fetch from it, whatever SUM says; a U body can). x25 holds the label after the
    jump: the instruction returns there if the fetch works, and a fetch fault resumes there."""
    nxt = Label("svprobe")
    if p.priv_ext and not p.body_u and p.rng.random() < 0.5:
        # SUM lets S read and write user pages, never fetch from one: with it set, a probe page that is a user page
        # still has to fault
        p.li(6, 1 << 18)
        p.e("    csrs    sstatus, x6")
    p.e(f"    la      x25, {nxt}")
    # the far pointers: the walk of the fetch itself ends in a PTE read that the PMP denies or that gets a bus error
    targets = [POCKET_X, PROBE_X, FARPTR_VA + 0x100, BUSPTR_VA + 0x100]
    if p.priv_ext:                  # translated for sure: in an M body there is nothing behind the window
        targets += [ALIAS_X, ALIAS_X, ALIAS2_X, ALIAS2_X, USERX_VA + POCKET_X, USERX_VA + POCKET_X]
    p.li(6, p.rng.choice(targets))
    p.e("    jalr    x0, 0(x6)")
    p.e(f"{nxt}:")
    p.e("    la      x25, recovery_point")


def emit_sv39_op(p: Program, recent: list[int]):
    rng = p.rng
    r = rng.random()
    can_csr = p.priv_ext and not p.body_u            # an S (or privilege 2) body can touch sstatus and satp
    if r < 0.30:
        emit_hole_access(p, recent)
    elif r < 0.40 and can_csr:
        emit_sum_mxr(p)
    elif r < 0.50 and can_csr:
        emit_flip_pair(p, recent)
    elif r < 0.60 and can_csr:
        emit_satp_op(p)
    elif r < 0.70:
        emit_tlb_thrash(p, recent)
    elif r < 0.78 and p.sv_mode != "ident":
        emit_window_probe(p, recent)
    elif r < 0.90 and p.args.sv39_fetch:
        emit_fetch_probe(p)
    else:
        emit_noncanonical(p, recent)


def emit_trap_delegation(p: Program):
    """Random-but-epilogue-safe medeleg/mideleg: never delegates ECALL
    from either U or S (bits 8/9), so the epilogue's own ECALL always
    reaches the M-handler directly regardless of what else is
    delegated -- see the module docstring's "Epilogue: ECALL to M"."""
    causes = [0, 1, 3, 4, 5, 6, 7, 12, 13, 15]  # never 9
    if p.priv_ext:
        causes.append(8)    # ECALL from U may go to S: its handler passes the epilogue's up to M
    # TSR makes every SRET trap, including the one that ends the S handler, so
    # it needs a program that never enters it: nothing delegated.
    if p.priv_ext and p.rng.random() < 0.15:
        p.tsr = True
    # a body at the reserved privilege 2 (MPP = 2'b10 is legal to load): its ECALL has cause 0, which the M
    # handler recognizes as the epilogue's. Nothing is delegated for it: a delegated trap would take it out
    # of privilege 2 (sret only returns to S or U), and the epilogue should run there
    p.body_priv2 = p.priv_ext and p.rng.random() < 0.12
    bits = 0
    if not p.tsr:
        for c in causes:
            if p.rng.random() < 0.5:
                bits |= (1 << c)
    if p.body_priv2:
        bits = 0
    p.li(6, bits)
    p.e("    csrw    medeleg, x6")
    mideleg = 0 if p.tsr else 0x222   # STIP|SEIP|SSIP delegated
    if p.irq and not p.tsr:
        # the injected sources: SEI (bit 9) is in 0x222 already; MTI (7) and MEI (11) can go to S too
        if p.rng.random() < 0.4:
            mideleg |= 1 << 7
        if p.rng.random() < 0.3:
            mideleg |= 1 << 11
        if p.rng.random() < 0.3:
            mideleg &= ~(1 << 9)
    p.li(6, mideleg)
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
    cfg = 0x0F  # L=0,A=TOR,X=1,W=1,R=1
    if p.irq:
        # entry 1: the 8-byte MAGIC dword (NAPOT), R+W, so a handler in S mode can write the clear
        p.li(6, 0x0400F000 >> 2)
        p.e("    csrw    pmpaddr1, x6")
        cfg |= 0x1B << 8
    if p.args.sv39:
        # entry 2: the bus-error region at FAR_BASE, read + write. A PTE read or a translated access that gets there
        # ends in a bus error (an access fault), where it would otherwise stop at the PMP
        p.li(6, napot_pmpaddr(FAR_BASE, 0x1000))
        p.e("    csrw    pmpaddr2, x6")
        cfg |= 0x1B << 16
    p.li(6, cfg)
    p.e("    csrw    pmpcfg0, x6")


def emit_irq_setup(p: Program):
    """--irq: the handlers' save-area pointers and the enables for the injected sources. Interrupts stay
    off until the body starts (MIE for an M body, below; SIE for an S body, after s_mode_entry; a U body
    takes the non-delegated ones whatever MIE says, and the delegated ones always)."""
    p.e("    # -- interrupts: handler save areas, source enables --")
    p.e("    la      x6, msave")
    p.e("    csrw    mscratch, x6")
    if p.args.priv == "msu":
        p.e("    la      x6, ssave")
        p.e("    csrw    sscratch, x6")
    bits = 0
    for b in (7, 9, 11):
        if p.rng.random() < 0.85:
            bits |= 1 << b
    p.li(6, bits or (1 << 7))
    p.e("    csrw    mie, x6")


def emit_entry_preamble(p: Program):
    a = p.args
    p.e("_start:")
    p.e("    la      x6, m_trap_handler")
    if not a.sail_safe and p.rng.random() < 0.3:
        p.e(f"    addi    x6, x6, {p.rng.choice([1, 2, 3])}")     # MODE bits: both cores take direct mode only
    p.e("    csrw    mtvec, x6")
    if a.priv == "msu":
        p.e("    la      x6, s_trap_handler")
        if not a.sail_safe and p.rng.random() < 0.3:
            p.e(f"    addi    x6, x6, {p.rng.choice([1, 2, 3])}")
        p.e("    csrw    stvec, x6")
        emit_trap_delegation(p)
        if a.sv39 and p.priv_ext:
            p.body_u = not p.body_priv2 and p.rng.random() < 0.4      # the page flags follow the body's privilege
    p.e("    la      x25, recovery_point")
    p.li(26, BAD_ADDR_BASE)
    if a.sv39:
        plan_sv39(p)
    p.li(27, p.data_base)
    if a.priv == "msu" and not a.pmp:
        emit_msu_minimal_pmp(p)
    if p.irq:
        emit_irq_setup(p)
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
        if p.priv_ext:
            if not a.sv39:
                p.body_u = not p.body_priv2 and p.rng.random() < 0.4
            # not under Sv39: TVM would trap the page-fault handler's own satp read and SFENCE.VMA
            tvm = p.rng.random() < 0.3 and not a.sv39
            mpp = 2 if p.body_priv2 else (0 if p.body_u else 1)
            mst = (mpp << 11) | ((1 << 22) if p.tsr else 0) | ((1 << 20) if tvm else 0)
            p.li(6, mst)
            p.e("    csrw    mstatus, x6")   # MPP = S or U, TSR, TVM
        else:
            p.li(6, 1)
            p.e("    slli    x6, x6, 11")
            p.e("    csrw    mstatus, x6")   # MPP = S
        p.e("    la      x6, s_mode_entry")
        if p.reloc:
            p.li(7, ALIAS_VA)
            p.e("    add     x6, x6, x7")         # the same address in the window above the image
        p.e("    csrw    mepc, x6")
        p.e("    mret")
        p.e("s_mode_entry:")
        if p.reloc:
            p.e("    la      x25, recovery_point")        # pc-relative: the one in the window
        if p.irq and not p.body_u:
            p.body_sie = p.rng.random() < 0.85
            if p.body_sie:
                p.e("    csrsi   sstatus, 2")      # SIE: delegated interrupts are taken in S
    else:
        if a.pmp and p.rng.random() < 0.5:
            # M-mode data accesses run at MPP while MPRV is set: the PMP pockets then bind them too
            mpp = p.rng.choice([0, 1, 3])
            p.li(6, (1 << 17) | (mpp << 11))
            p.e("    csrs    mstatus, x6")        # MPRV, MPP = U, S or M (M: MPRV changes nothing)
        if p.irq:
            p.e("    csrsi   mstatus, 8")          # MIE: the body runs in M
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
        if a.sv39 and p.rng.random() < 0.06:
            emit_sv39_op(p, recent)
            return
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
        elif r < 0.835 and a.pmp and not a.sv39:
            emit_pmp_jump(p)
        elif r < 0.85:
            p.e("    fence")
        elif r < 0.87:
            p.e("    wfi")
        elif r < 0.87 + a.illegal_rate:
            emit_fault(p, "illegal")
        elif r < 0.87 + a.illegal_rate + a.ecall_rate:
            emit_fault(p, p.rng.choice(["ecall", "ebreak"]))
        elif r < 0.87 + a.illegal_rate + a.ecall_rate + a.ebreak_rate:
            emit_fault(p, "ebreak")
        elif p.priv_ext and r < 0.87 + a.illegal_rate + a.ecall_rate + a.ebreak_rate + 0.07:
            emit_priv_op(p, recent)
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
    if p.args.pmp or (p.args.sv39 and p.args.sv39_fetch):
        p.pocket_code = ["    jr      x25"]
    if p.args.sv39 and p.args.sv39_fetch:
        # a 32-bit `jr x25` at PROBE_X = 0x91FFE, straddling the 0x92000 page boundary; the three halfwords
        # in front only pad the section to a dword boundary (the image loader wants dword-aligned segments)
        p.probe_code = ["    .half   0x0001", "    .half   0x0001", "    .half   0x0001",
                        "    .option push", "    .option norvc", "    jalr    x0, 0(x25)", "    .option pop"]
    if p.irq:
        p.misc_data += ["    .balign 8", "msave:", "    .zero   32", "ssave:", "    .zero   32"]
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
    if p.pocket_code:
        lines += ["", "    .section .text.pocket"]
        lines += p.pocket_code
    if p.probe_code:
        lines += ["", "    .section .text.probe"]
        lines += p.probe_code
    if p.ptpmp_data:
        lines += ["", "    .section .data.ptpmp"]
        lines += p.ptpmp_data
    lines += ["", "    .section .data.misc"]
    lines += p.misc_data
    return "\n".join(lines) + "\n"


def toolchain_build(asm_path: Path, out_base: Path, isa: str, has_pagetables: bool, has_pocket: bool = False,
                    has_probe: bool = False, has_ptpmp: bool = False):
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
    if has_pocket:
        sections += ["-j", ".text.pocket"]
    if has_probe:
        sections += ["-j", ".text.probe"]
    if has_ptpmp:
        sections += ["-j", ".data.ptpmp"]
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
    ap.add_argument("--sv39", action="store_true",
                    help="translate: static page tables (4 KB leaves, superpage data windows, holes that page-fault), "
                         "random page flags, a page-fault handler that fixes A/D, probes of every kind of fault")
    ap.add_argument("--sv39-fetch", action=argparse.BooleanOptionalAction, default=True, dest="sv39_fetch",
                    help="with --sv39: also provoke instruction page faults (code pages with A clear, jumps to "
                         "pages that cannot be fetched from, a 32-bit instruction whose second page faults). "
                         "--no-sv39-fetch keeps every fetch fault-free, for a core that does not translate fetches")
    ap.add_argument("--irq", action="store_true",
                     help="run the body with interrupts enabled, for the lockstep "
                          "harness's own interrupt injection (--irq-mode): source "
                          "enables, random mideleg, transparent trap handlers that "
                          "save and restore x5-x8, a PMP region over the MAGIC "
                          "register for S mode. Ignored under --sail-safe")
    ap.add_argument("--smc", action="store_true")
    ap.add_argument("--dbg", action="store_true",
                    help="keep x22/x23 out of the random pool, for the lockstep harness's scripted "
                         "debugger (--dbg-mode): it overwrites them from the Debug Module, and runs "
                         "Program Buffer snippets that use them and the sandbox base x27")
    ap.add_argument("--no-div", action="store_true", dest="no_div",
                    help="keep M to the multiplies (for cores without a divider yet)")
    ap.add_argument("--len", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--dep-bias", type=float, default=0.3, dest="dep_bias")
    ap.add_argument("--illegal-rate", type=float, default=0.02)
    ap.add_argument("--ecall-rate", type=float, default=0.01)
    ap.add_argument("--ebreak-rate", type=float, default=None,
                    help="extra EBREAKs on top of --ecall-rate's share (default 0; 0.012 with --dbg, "
                         "so dcsr.ebreak* armed by the debugger script has something to catch)")
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
        args.irq = False
    if args.dbg:
        del FREE_POOL[-2:]      # x22, x23 (in place: every user of the pool sees it)
    if args.ebreak_rate is None:
        args.ebreak_rate = 0.012 if args.dbg else 0.0

    if args.output is None:
        args.output = GEN_DIR / f"gen_{args.seed}"
    args.output.parent.mkdir(parents=True, exist_ok=True)

    p = build_program(args)
    text = render(p)
    asm_path = args.output.with_suffix(".s")
    asm_path.write_text(text)
    print(f"wrote {asm_path}")

    if args.build:
        elf, hexf = toolchain_build(asm_path, args.output, args.isa, bool(p.pagetable_data), bool(p.pocket_code),
                                    bool(p.probe_code), bool(p.ptpmp_data))
        print(f"built {elf}, {hexf}")


if __name__ == "__main__":
    sys.exit(main())
