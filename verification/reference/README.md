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
  nothing here has changed since. A mismatch means either an accidental
  edit (revert it) or a deliberate errata fix that forgot to
  regenerate the manifest (regenerate it -- see below).
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
selects mutant `k`, once P3.4's own kill-matrix mutants are written
into `ref_core.sv` (gated on `QV_MUTANT`'s value at the specific
injection points each mutant targets) -- see the plan's own "Proving
the harness catches bugs" section under P3.4. No mutants exist yet;
`QV_MUTANT` is a declared, currently-unused parameter until then.
