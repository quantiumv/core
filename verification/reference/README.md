# The frozen reference core (P3.3)

This directory holds `ref_core.sv` and its six leaf-module dependencies:
a frozen copy of the multi-cycle FSM core, which was `design/core.sv`
until the pipelining track's P8 switchover deleted that file and made the
pipelined core (`design/pipe/core.sv`) the module `core`. It is the golden
retirement-by-retirement reference the lockstep harness checks the core
against, and `-DQV_REF_AS_CORE` builds it as `core`, so the whole test
suite can also run against it (`make regress CORE=ref`). See the plan at
`C:\Users\Potato\.claude\plans\research-the-c-extension-reflective-candle.md`
for the full pipelining track context.

## Provenance

Frozen from commit `b52e9a3c047fa503ac00a4f1e130d1fd0a4c4389` ("Add
sail_diff.py, the P3.2 Sail differential audit") -- the state of
`design/core.sv` at that commit is byte-identical to `ref_core.sv` here
modulo the mechanical changes below. `design/core.sv` itself was last
substantively changed by `4972f90` ("Fix 11 pre-existing FSM bugs found
auditing it for the freeze"), P3.1's own bug-fix pass that this freeze
is built on top of. (`design/core.sv` is gone since P8;
`git show b52e9a3:design/core.sv` still shows it.)

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
    ran against `design/core.sv` before P8. `QV_MUTANT` selects the
    kill-matrix mutants (`ref_core #(k)` vs `#(0)`, see "Running mutants"
    below); 0 is the frozen behavior.
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
a module or file. `design/decoder.sv` (whose macros the pipelined core's
`qv_decode.sv` calls) and this directory's `ref_core.sv`+`ref_decoder.sv`
are compiled together, in one run, by every lockstep and RVFI-diff
harness that exercises both -- redefining the SAME macro name in both
would either silently override `design/decoder.sv`'s own definition (if
this directory's copy loads second) or vice versa, and most toolchains at
minimum warn on any redefinition regardless of whether the two bodies
happen to match. `IS_INSTR` and `INSTR_CODE` are the only two macros
either file defines that are FUNCTION-LIKE with real logic in their body
and are used across file boundaries (`decoder.sv` defines them, its
callers use them -- `core.sv`, the FSM, when this was written) -- every
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
  (regenerate it -- see below). The manifest has been regenerated for
  every deliberate change since the freeze: mutants 1-10
  (`ref_core.sv`, `ref_c_expand.sv`), errata E1 and E2, mutants 11-13.
  Each is a real, intentional diff from the original freeze snapshot, not
  an accidental edit -- `QV_MUTANT=0` (every existing caller) behaves
  identically before and after, shown by the unchanged regression and
  lockstep results.
- **`defaults_snapshot/`** + **`check_defaults.sh`**: a copy of
  `design/defaults/*.sv` as of the freeze. Run
  `wsl bash -lc "verification/reference/check_defaults.sh"` to confirm
  those shared files have only ever grown (new constants may be
  appended anywhere; no existing line may change or disappear).

## Errata rule

A reference bug found after this freeze (e.g. via the lockstep harness
disagreeing with the core, or a later Sail audit run) gets fixed in
`ref_core.sv` here, as a single, clearly-labeled errata commit -- and,
when the pipelined core (`design/pipe/`) has the same defect, in the core
too, in that commit or a labeled companion, so the lockstep harness is
never knowingly comparing against a reference that is wrong. After such a
fix, regenerate `MANIFEST.sha256` (`sha256sum ref_*.sv ref_macros.svh >
MANIFEST.sha256` run from this directory) and add an entry below.

Before the P8 switchover `design/core.sv` was the production core, and
every errata fix went into it and `ref_core.sv` together (E1 and E2
below). It no longer exists; `ref_core.sv` is the only copy of that FSM.

Line citations. Comments and READMEs elsewhere cite `core.sv:NNNN`. Those
are lines of the FSM as it stood when the comment was written, the text
that is `ref_core.sv` now, with its lines shifted by the module header, the
macro rename and the mutant hooks: find the logic by name rather than by
line number. The pipelined core's own file is `design/pipe/core.sv`, and
it is cited with its directory.

**Errata log:**

- **E1 + E2 (2026-10-19, both found while planning the P6 debug port; fixed
  together in `design/core.sv` and `ref_core.sv`).** Both are about an
  action=0 execute trigger (a breakpoint exception, cause 3):
  - E1: `trigger_exception_match` had no `!in_debug_mode` term, but it sits
    in `mem_phase_needed`'s exclusion list. A Program Buffer load or store
    whose drifting pc equalled an action=0 trigger's `tdata2` silently
    lost its bus access (a load wrote stale read-bus data to rd). Triggers
    never fire in Debug Mode, so the wire now includes `!in_debug_mode`.
  - E2: `trap_val` ranked the misaligned and access-fault arms above the
    trigger arm, while `exc_code` ranks the trigger above them, so a
    trigger exception on a misaligned or PMP-denied access reported cause
    3 with the data address as `mtval`. The trigger arm now sits just
    below the illegal-instruction arm, so `mtval` is the pc.
  Tests: `core_trigger_tb` scenarios `dut_trig_pbmem` and `dut_trig_misal`
  (both failed before the fix). Behavior change on the mainline paths:
  none; ACT, lockstep and the regression are unchanged.
- **E3 (2026-10-28, found while planning F/D; fixed together in
  `design/csr_file.sv` and `ref_csr_file.sv`).** `misa` read
  `0x8000000000000100`, the `I` letter only, although A, C, M, S and U are
  all implemented. OpenSBI decides from misa whether S-mode exists (it
  skips trap delegation without the `S` letter). misa is now
  `0x8000000000141105` (A C I M S U, the value Sail reports for this ISA,
  `verification/fpu/README.md` probe 10). The three tests that pinned the
  old value (`csr_file_tb`, `csr_file_random_tb`, `core_zicsr_tb`) pin the
  new one. Both cores share the constant and no generated program reads
  misa, so lockstep and ACT cannot see the change.
- **E7 (2026-10-29, found by ACT once the configs declared PMP: `pmpsm_csr_walk`,
  `pmpzca_cret_napot`; fixed together in `design/pipe/qv_decode.sv` and
  `ref_core.sv`).** Every unmapped CSR reads 0 and ignores writes, the PMP
  ones included, but on RV64 with 16 PMP CSRs (4 of them implemented)
  `pmpcfg1`, `pmpcfg3`-`pmpcfg15` and `pmpaddr16`-`pmpaddr63` do not exist,
  and Sail traps on them. An access to one is now an illegal instruction;
  `pmpcfg2` and `pmpaddr4`-`pmpaddr15` exist and still read 0. Other
  unmapped CSRs are unchanged. Tests: `qv_decode_tb` (every address
  0x3A0-0x3EF), `core_pmp_spec_tb` checks 1-7.
- **E4 (2026-10-29, found by ACT `S-00` once the configs declared Sv39;
  fixed together in `design/csr_file.sv` (so `ref_csr_file.sv`),
  `design/pipe/qv_commit.sv` and `ref_core.sv`).** `mtvec`/`stvec` stored
  MODE as written and the cores never read it: every trap went to BASE, so
  vectored mode read back as set but behaved as direct, and the reserved
  modes 2 and 3 read back too. MODE is now WARL {0, 1}: a write of 2 or 3
  keeps the old mode and takes the new base (Sail's rule), and an interrupt
  taken with MODE 1 goes to BASE + 4 * cause (exceptions still go to BASE).
  Tests: `core_pmp_spec_tb` checks 8-13 (WARL) and 29-32 (a vectored MTI in
  M, a vectored, delegated SEI in S).
- **E5 (2026-10-29, found by ACT `pmpsm_access_double_region`,
  `pmpsm_na4_boundary`, `pmpsm_tor_boundary` once the configs declared PMP;
  fixed together in `design/pipe/qv_pmp.sv` and `ref_core.sv`).** A PMP
  region that held only part of an access counted as no match, and the
  search went on to the next region: an 8-byte store straddling an NA4 or
  TOR edge succeeded on a more permissive region (or, in M mode, on none).
  The spec, and Sail, let the lowest-numbered region holding ANY byte
  decide, and the access fails unless that region holds all of them,
  whatever L, R, W and X say and in M mode too. Both cores now do that, for
  every stream (fetch, data, the walker's PTE reads); `ref_core.sv` has one
  function, `ref_pmp_xwr`, in place of the four copies of the old match
  logic. The fetch stream's span was still 8 bytes in this commit (E6).
  Tests: `core_pmp_spec_tb` checks 14-17, `qv_pmp_tb` (its model is the
  spec's rule now).
- **E6 (2026-10-29, found by ACT `pmpsm_napot_legal_lxwr` and the
  `pmpsm_*_boundary` fetch cases once the configs declared PMP; fixed
  together in `design/pipe/qv_decode.sv`, `qv_commit.sv` and `ref_core.sv`).**
  The fetch PMP check covered [pc, pc+7] (and [pc+8, pc+15] for a 32-bit
  instruction crossing a dword), so an instruction next to a denied region
  faulted although none of its bytes were in it. The spec checks the bytes
  the instruction occupies; Sail checks each 2-byte parcel, so a 32-bit
  instruction whose second parcel is denied reports mtval = pc + 2. Both
  cores now check [pc, pc+1] and, for a 32-bit instruction, [pc+2, pc+3]
  (in the next dword or the next page for a crossing one), and a fault in
  the second parcel, PMP or translation, reports pc + 2. This also fixes B10:
  a page fault in the second dword of a crossing instruction reported pc + 8
  and an access fault there pc. Tests: `core_pmp_spec_tb` checks 18-28,
  `qv_decode_tb`, `qv_commit_tb`, `core_sv39_fetch_tb` E,
  `core_bus_fault_trap_tb` B.

## Feature additions

The errata rule keeps the reference fixed except for bugs. A feature the
pipelined core gains that the reference must also model, so the lockstep
harness can check it, is a *feature addition*: a labelled commit series
that adds the feature here behind a define whose default leaves the
reference exactly as it was, verified on the reference alone (ACT and the
Sail diff) before the pipelined core is lockstepped against it. As for
errata, `MANIFEST.sha256` is regenerated and an entry goes below.

Where the feature's logic is shared with the pipelined core, the reference
gets private copies of those `design/` files, renamed and otherwise
identical (`gen_copies.sh` makes them, `check_copies.sh` checks that each
still equals its original): a later change to `design/` reaches the
reference only when the copies are regenerated on purpose. That logic is
then common to both cores, so lockstep cannot see a bug in it; it is
verified on its own (for the FPU: TestFloat, Sail and ACT).

**Feature log:**

- **F/D (2026-10-28): F, D and Zcd, behind `QV_FPU_EN`.** It defaulted to 0
  while the pipelined core caught up and is 1 since; `QV_FPU_EN=0` builds the
  reference as it was before.
  Copies: `ref_fpu_pkg.sv` (the F/D section of `qv_pkg.sv`),
  `ref_fp_dec.sv`, `ref_fpu_round.sv`, `ref_fpu_pipe.sv`,
  `ref_fpu_divsqrt.sv`, `ref_exu_fpu.sv`, `ref_fprf.sv`, and
  `ref_csr_file.sv` (`FP_EN`: mstatus.FS/SD and fcsr). `ref_c_expand.sv`
  got the Zcd arms by hand (it carries mutant 8). An FP instruction is
  shown to `ref_decoder` as an integer instruction of the same shape (an
  FP load as LD/LWU, a store as SD/SW of x0, anything else as an ADD), so
  addressing, faults, PMP, translation, triggers and RVFI take the
  integer paths; the FPU runs one op at a time in S_EXEC like the divider,
  its start guarded as the divider's is. RVFI gains `rvfi_frd_*` (an FP
  register write) and reports FP sources and destinations as register 0.
  Mutants 14-17 below. With `QV_FPU_EN` 0 the reference behaves as before
  (FP encodings are illegal, FS reads 0).

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
| 11 | A TLB hit skips the permission / U / A / D re-check (P7) | ref_core.sv, `ptw_pte_fault` |
| 12 | SFENCE.VMA does not flush the TLB (P7) | ref_core.sv, the SFENCE.VMA flush |
| 13 | A PMP-denied PTE read (data walk) is a page fault, not an access fault (P7) | ref_core.sv, the `ptw_pmp_fault` capture for the mem reason |
| 14 | FLW does not NaN-box the loaded single (F/D) | ref_core.sv, `fp_reg_wdata` |
| 15 | FP exception flags are not accrued into fflags (F/D) | ref_core.sv, `csr_file0`'s `i_fp_accrue` |
| 16 | An FP register write does not set mstatus.FS Dirty (F/D) | ref_core.sv, `csr_file0`'s `i_fp_frd_we` |
| 17 | A dynamic rounding mode (rm = 7) ignores frm and rounds to nearest (F/D) | ref_core.sv, `fpdec0`'s `i_frm` |

All 13 are caught (a REF-vs-REF run reports `LOCKSTEP_RESULT: FAIL`):
`verification/lockstep/run_kill_matrix.sh` runs each against `#(0)`
through `run_lockstep.sh --mode mutant --mutant k`, with the corpus entry
and options its condition needs (5, the interrupt timing, needs the irq
corpus with injected interrupts; 9, FENCE.I's flush, the self-modifying
code corpus on the cache memory configuration; 13, the PTE-read PMP
denial, the random corpus with `--pmp`). 13/13 at the P7 exit.
