# The frozen reference core (P3.3)

This directory holds `ref_core.sv` and its six leaf-module dependencies:
a frozen copy of `design/core.sv` as it stood at the pipelining track's
P3.3 milestone, used as the golden retirement-by-retirement reference
the P3.4 lockstep harness checks a new pipelined core (`core_pipe`,
`design/pipe/`) against. See the plan at
`C:\Users\Potato\.claude\plans\research-the-c-extension-reflective-candle.md`
for the full pipelining track context.

## Provenance

Frozen from commit `b52e9a3c047fa503ac00a4f1e130d1fd0a4c4389` ("Add
sail_diff.py, the P3.2 Sail differential audit") -- the state of
`design/core.sv` at that commit is byte-identical to `ref_core.sv` here
modulo the mechanical changes below. `design/core.sv` itself was last
substantively changed by `4972f90` ("Fix 11 pre-existing FSM bugs found
auditing it for the freeze"), P3.1's own bug-fix pass that this freeze
is built on top of.

## What changed, mechanically, relative to `design/*.sv`

Nothing behavioral. Every file here is a copy of its `design/` original
with exactly these substitutions:

- **`ref_core.sv`** (from `design/core.sv`):
  - Module header: `module core (` became
    ```systemverilog
    `ifdef QV_REF_AS_CORE
    module core
    `else
    module ref_core
    `endif
        #(parameter int QV_MUTANT = 0)
    (
    ```
    so `-DQV_REF_AS_CORE` makes this file compile AS `core` -- every
    testbench, `soc.sv`, `act_runner_tb.sv` and the formal `wrapper.sv`
    instantiate a module literally named `core`, so the whole existing
    verification suite runs against this file unedited, the same way it
    runs against `design/core.sv` today. `QV_MUTANT` is an unused hook
    for now -- P3.4's own mutant-kill-matrix testing (`ref_core #(k)`
    vs `#(0)`) will gate specific injected bugs on its value as those
    mutants get written.
  - Leaf-module instance TYPES renamed to their `ref_*` counterparts
    below; INSTANCE NAMES are unchanged (`decoder0`, `regfile0`,
    `csr_file0`, `alu0`, `divider0`, `c_expand0`), so every hierarchical
    reference anywhere in the test suite (`dut.csr_file0.mcause_q` and
    the like) still resolves identically.
  - Every `` `INSTR_CODE(...) `` / `` `IS_INSTR(...) `` call site (117 of
    them) renamed to `` `REF_INSTR_CODE(...) `` / `` `REF_IS_INSTR(...) ``
    -- see `ref_macros.svh`'s own header comment for why.
  - Added `` `include "ref_macros.svh" `` alongside the existing
    `` `include ``s near the top.
- **`ref_decoder.sv`** (from `design/decoder.sv`): same macro-call-site
  rename (109 sites) and the same `` `include "ref_macros.svh" ``, but
  here it REPLACES the two original `` `define IS_INSTR ``/
  `` `define INSTR_CODE `` lines outright (this file is where the FSM's
  own originals live) rather than sitting alongside them.
- **`ref_alu.sv`, `ref_register_file.sv`, `ref_csr_file.sv`,
  `ref_divider.sv`, `ref_c_expand.sv`**: module (and, where present,
  `endmodule :`) name only -- `alu` -> `ref_alu`, etc. None of these
  five use `IS_INSTR`/`INSTR_CODE` at all (confirmed by grep before
  copying), so no macro handling was needed in them.

`design/defaults/*.sv` (the shared `` `include ``d bit-pattern/mask/ISA
constant files `decoder.sv` and `ref_decoder.sv` both pull in) is
**not** copied -- both cores `` `include `` the SAME files from
`design/defaults/`, by reference. That sharing is exactly why those
files have their own append-only rule (see below): a change to a
shared constant would otherwise silently change `ref_core.sv`'s
behavior without `ref_core.sv` itself ever being touched.

## Why `` `INSTR_CODE ``/`` `IS_INSTR `` needed renaming and nothing else did

`` `define `` is compilation-unit-global in SystemVerilog, not scoped to
a module or file. `design/core.sv`+`decoder.sv` and this directory's
`ref_core.sv`+`ref_decoder.sv` are compiled together, in one run, by
every regression/lockstep/formal harness that exercises both --
redefining the SAME macro name in both would either silently override
the FSM's own definition (if this directory's copy loads second) or
vice versa, and most toolchains at minimum warn on any redefinition
regardless of whether the two bodies happen to match. `IS_INSTR` and
`INSTR_CODE` are the only two macros either file defines that are
FUNCTION-LIKE with real logic in their body and are used across file
boundaries (`decoder.sv` defines them, `core.sv` calls them) -- every
other macro `decoder.sv` defines (`OUTPUT_R_TYPE_INSTR` and its
siblings) is used only within `decoder.sv` itself, confirmed by grep,
so they needed no treatment. The bit-pattern-only constants
(`` `INSTR_CODE_ADD ``, `` `INSTR_MASK_ADD ``, etc.) aren't function-like
and live in the SHARED `design/defaults/` files described above, so
they're defined exactly once regardless of how many cores include them.

## Guards against accidental drift

- **`MANIFEST.sha256`** + **`check_manifest.sh`**: SHA-256 of every
  `ref_*.sv`/`ref_macros.svh` file as of the freeze. Run
  `wsl bash -lc "verification/reference/check_manifest.sh"` to confirm
  nothing here has changed since. A mismatch means an accidental edit
  (revert it), a deliberate errata fix, or a P3.4 mutant addition (see
  "Running mutants" below) that forgot to regenerate the manifest
  (regenerate it -- see below). The manifest was last regenerated after
  adding mutants 1-10 to `ref_core.sv`/`ref_c_expand.sv`; that's a real,
  intentional diff from the original freeze snapshot, not an accidental
  edit -- confirmed `QV_MUTANT=0` (every existing caller) behaves
  identically before and after via the unchanged full regression suite
  (72/72) and the unchanged default-config lockstep smoke test.
- **`defaults_snapshot/`** + **`check_defaults.sh`**: a copy of
  `design/defaults/*.sv` as of the freeze. Run
  `wsl bash -lc "verification/reference/check_defaults.sh"` to confirm
  those shared files have only ever grown (new constants may be
  appended anywhere; no existing line may change or disappear).

## Errata rule

A reference bug found after this freeze (e.g. via the P3.4 lockstep
harness disagreeing with `core_pipe`, or a later Sail audit run) gets
fixed in **both** `design/core.sv` (until P8's switchover retires it)
**and** `ref_core.sv` here, as a single, clearly-labeled errata commit
-- never `ref_core.sv` alone, or the two cores silently diverge and
`design/core.sv`'s own regression suite stops being meaningful ground
truth for the fix; never `design/core.sv` alone, or the lockstep
harness starts comparing `core_pipe` against a reference that's
already known to be wrong. After such a fix, regenerate
`MANIFEST.sha256` (`sha256sum ref_*.sv ref_macros.svh > MANIFEST.sha256`
run from this directory) and add an entry below.

**Errata log:** (empty -- no post-freeze fixes yet)

## Running the reference as `core`

Any existing harness works unedited: add `-DQV_REF_AS_CORE` to the
`iverilog`/`verilator` invocation, use `verification/regress/
ref_design_files.list` in place of `design_files.list` (it swaps in
this directory's 6 leaf files + `ref_core.sv`; everything else --
`soc.sv`, the buses, caches, debug module, peripherals -- is shared,
unmodified), and add `-I verification/reference` to the include path
(for `ref_macros.svh`). The checked-in scripts already do this:

```bash
wsl bash -lc "verification/regress/run_regress.sh --core ref"
wsl bash -lc "verification/regress/lint.sh --core ref"
CORE=ref wsl bash -lc "verification/riscv-arch-test/run_act_tests.sh"
```

## Running mutants

`ref_core #(.QV_MUTANT(k))` in place of the default `#(.QV_MUTANT(0))`
selects mutant `k` -- P3.4's own kill-matrix mutants, gated on
`QV_MUTANT`'s value at the specific injection point each one targets, so
`QV_MUTANT=0` (the default, used everywhere outside
verification/lockstep/) is provably identical to the pre-mutant RTL: see
the "Guards against accidental drift" note below on why this changed
`MANIFEST.sha256` without being an errata fix. `ref_c_expand.sv` also
gained its own `QV_MUTANT` parameter (mutant 8 needs it; it had none
before) -- ref_core.sv passes its own QV_MUTANT straight through at the
`c_expand0` instantiation, same as every other leaf module already gets
QV_MUTANT threaded to it structurally (only ref_alu.sv still doesn't --
mutant 1 lives in ref_core.sv instead, corrupting alu_result after the
ref_alu0 instantiation, since ref_alu.sv only ever sees operand VALUES,
never the register indices mutant 1 needs).

| k | Mutates | Where |
|---|---|---|
| 1 | ALU result off by one when rs1==rs2 (register index, via read_gpr_A_sel/read_gpr_B_sel) | ref_core.sv, after the ref_alu0 instantiation |
| 2 | SB at address offset 7 writes byte lane 6 instead of 7 | ref_core.sv, `mem_sel` |
| 3 | BLTU compares signed instead of unsigned | ref_core.sv, `branch_comparator` |
| 4 | ECALL from U-mode reports cause 9 (S-mode's) instead of 8 | ref_core.sv, `exc_code` |
| 5 | Interrupts sampled one retirement later than the real sampling point | ref_core.sv, `interrupt_sample_q` (double-registered `commit_now_q`) |
| 6 | minstret wrongly skips CSR instructions | ref_core.sv, `csr_file0`'s `i_instr_retired` |
| 7 | An ordinary store no longer clears the LR/SC reservation | ref_core.sv, the reservation-clear `always_ff` |
| 8 | C.ADDI16SP's `i_instr16[5]`/`i_instr16[2]` bit groups swapped | ref_c_expand.sv, `c_addi16sp` |
| 9 | FENCE.I never flushes the icache | ref_core.sv, `icache_flush_o` |
| 10 | Data-side page-fault mtval/stval off by 8 | ref_core.sv, `trap_val`'s `mem_fault_q` arm |

Confirmed caught (a REF-vs-REF run reports `LOCKSTEP_RESULT: FAIL`) for
1-4 and 6-8 and 10, each via a corpus entry chosen to actually exercise
that specific condition -- see `run_lockstep.sh --mode mutant --mutant
k`. Mutants 5 and 9 are implemented and regression-clean (the full
72/72 suite in `verification/regress/` passes unchanged at
`QV_MUTANT=0`) but not yet proven caught by an actual run: mutant 9
(FENCE.I's flush) has no observable effect at all without an icache
present, and `verification/lockstep/lockstep_mem.sv`'s own cache
memory configuration has a separate, unresolved issue (see its KNOWN
GAP comment); mutant 5 (interrupt timing) needs a real interrupt to
actually be TAKEN, which hits a separate stall documented in
`lockstep_tb.sv`'s own KNOWN GAP comment (reproduce with
`verification/lockstep/repro_irq_stall.s`).
