# riscv-formal on core_pipe

`design/pipe/core_pipe.sv` run through the same riscv-formal suite as the FSM core (`../quantiumv/`):
the `isa rv64ic` check set (91 checks), plus riscv-formal's `liveness` and `hang` checks. The
wrapper (`../quantiumv/wrapper.sv`) is shared, because the two cores' ports are identical; only the
config differs.

## Running it

From the repo root, under WSL (the riscv-formal checkout, its local patches and the solvers are set up
as in `../quantiumv/README.md`):

```sh
verification/riscv-formal/sync_core.sh pipe          # copy the RTL list, wrapper and checks.cfg in, regenerate the checks
verification/riscv-formal/run_sweep.sh pipe -j 8 --timeout 86400   # resumable; prints a PASS/FAIL/TIMEOUT table at the end
verification/riscv-formal/sweep_status.sh pipe --summary             # the same table without running anything
verification/riscv-formal/run_sweep.sh pipe --only '^(reg_ch0|causal_ch0)\.sby$'   # a subset
verification/riscv-formal/sync_core.sh pipe-full     # the same without QV_FORMAL_SMALL, for spot checks
```

`sync_core.sh` deletes the core's old results when it regenerates; `run_sweep.sh` skips any check whose
log already says `DONE (PASS)`, so an interrupted sweep resumes. The RTL file list is
`verification/regress/pipe_design_files.list`, not a copy of its own.

## What differs from the FSM config

- **Small configuration.** `-D QV_FORMAL_SMALL` gives the ROB 4 entries and the instruction queue 2
  (8 and 4 otherwise). `pipe-full` drops it for the spot checks.
- **`unique 1 10 20`.** riscv-formal's unique check assumes a retirement at its trigger cycle
  (`rvfi_unique_check.sv`). The first retirement of core_pipe is 8 to 10 cycles after reset, so the
  FSM's trigger of 5 is unsatisfiable (`PREUNSAT`); 10 is not, and the check then looks 10 cycles on.
- **`liveness 1 10 40` and `hang 1 40` run with no divide in the stream** (`QV_FORMAL_NO_DIV` in the
  wrapper). A divide takes about 66 cycles, longer than either window, so with one the properties fail
  by design. The FSM's hang check gets the same assumption, so the two are read against each other.
  The FSM's liveness window (90) does include a divide, and its depth-90 solver run needs more memory
  than the sweep's 8 GB limit (`bad_alloc`); core_pipe's does not try it.
- **Fairness** (`RISCV_FORMAL_FAIRNESS`, liveness and hang only): every bus request is answered within 3
  cycles and no debug halt or resume is requested. The 91 checks keep fully free acks.
- Interrupts are free in every check (the wrapper drives `i_mtip`, `i_meip` and `i_seip` as free inputs),
  so the proofs cover interrupt entry too. PMP and `satp` are pinned for the `insn_*` and `c_*` families
  exactly as for the FSM.

## Module proofs

`verification/formal/pipe/run.sh [--mutants]` proves two units on their own with SymbiYosys
(k-induction, plus deep BMC and cover tasks): `qv_fetch` (never abandons a request, never pushes a stale
response, at most one request outstanding) and `qv_lsu` (an access starts only at the ROB head and never
for a misaligned or PMP-denied uop, never abandons a request, one bus access per uop, the AMO sequence and
its lock). The `--mutants` run shows each property set fails on known-bad versions of its unit.

## Results

**Not final yet.** The sweep of the P5 RTL (everything through the interrupt and PMP work, core_pipe at the
commit that added `sweep_status.sh`) was started on 2026-10-14 with `run_sweep.sh pipe -j 8 --timeout 86400`
and takes on the order of a day; `verification/riscv-formal/sweep_status.sh pipe` prints the live table.
When it finishes, this section gets the table, the `liveness`/`hang` runs against the FSM baseline (the FSM's
`hang` passes under the same no-divide assumption), and the five full-size spot checks (`reg`, `causal`,
`insn_lw`, `insn_jalr`, `insn_c_lw` on `sync_core.sh pipe-full`).

The earlier sweep, of the pre-P5 RTL (no divider, atomics, privilege, interrupts or PMP yet), reached 89 of 93
PASS with 0 FAIL before it was stopped; `unique_ch0` was an `ERROR (PREUNSAT)` from the trigger described above,
and `reg_ch0`, `liveness_ch0` and `hang` had not finished. Those results were discarded when the checks were
regenerated for the new RTL.
