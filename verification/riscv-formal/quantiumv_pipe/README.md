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
verification/riscv-formal/sync_core.sh pipe-amo      # isa rv64ia, for the 18 AMO checks: run_sweep.sh pipe-amo --only '^insn_amo'
```

A sweep takes a couple of hours, so under WSL start it as a `systemd-run --user` unit (processes started from a
`wsl.exe` call die with it) and from a copy of `run_sweep.sh`: bash reads a script while it executes it, so
editing the original mid-sweep kills the sweep and the checks it was running. Keep the PC awake; the solvers stop
while it sleeps.

`sync_core.sh` deletes the core's old results when it regenerates; `run_sweep.sh` skips any check whose
log already says `DONE (PASS)`, so an interrupted sweep resumes. The RTL file list is
`verification/regress/pipe_design_files.list`, not a copy of its own.

## What differs from the FSM config

- **Small configuration.** `-D QV_FORMAL_SMALL` gives the ROB 4 entries and the instruction queue 2
  (8 and 4 otherwise). `pipe-full` drops it for the spot checks.
- **Multipliers are wiring.** `-D QV_FORMAL_NO_MUL` turns the ALU's three 64x64 products into plain
  wiring (`design/alu.sv`; the define exists nowhere else). No rv64ic check depends on a product's value,
  and with the multipliers in the model every check took about twice as long (`insn_and` on boolector: 73 min
  of CPU time against 39). It is an abstraction, not a restriction of the instruction stream: a multiply still
  flows through issue, the ROB, bypass and commit with an arbitrary value.
- **Memories are mapped (`memory_map`).** `[script-link]` in `checks.cfg` turns every memory (register
  file, ROB, producer table, CSR state) into flops and muxes before the SMT2 is written, so the solver never
  does array reasoning. The semantics are unchanged (a bug injected into the ALU's ADD is still caught, in
  under a minute). On this core array reasoning was the bottleneck: `hang` went from more than 5 hours of CPU
  time without finishing even its satisfiability pre-check to 8 minutes, `insn_c_beqz` from 28 minutes to 8.
- **Bitwuzla, not boolector.** About twice as fast on this core (`insn_and`, same model: 35 min of CPU against 73
  on boolector). It needs the patched `smtio.py` that `run_sweep.sh` puts on `PYTHONPATH`; without it
  yosys-smtbmc dies with `BrokenPipeError`, the failure the FSM sweep hit and answered by using boolector.
  Both are in `checks.cfg`; `sweep_status.sh pipe --detail` prints the solver and model each check actually
  ran with.
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

core_pipe with the P5 features (DIV, A, U/S/M privilege and delegation, interrupts, PMP; `design/` is
unchanged since `a05fb01`), checks generated by `sync_core.sh pipe` from `checks.cfg` at `42738b4` and run on
2026-10-15 with `run_sweep.sh pipe -j 8 --timeout 86400`. Every check ran on the same configuration: ROB 4 and
IQ 2, `QV_FORMAL_NO_MUL`, `memory_map`, bitwuzla.

**93 of 93 PASS**: the 91 checks of the `rv64ic` set plus `liveness` and `hang`. 10.3 hours of solver CPU time
in all, about 80 minutes of wall time at `-j 8` (the longest single check, `reg`, took 79 minutes of CPU).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 2:52 .. 13:30 |
| `insn_c_*` (Zca) | 31 | 31 | 2:39 .. 10:18 |
| `reg` | 1 | 1 | 79:24 .. 79:24 |
| `pc_fwd` | 1 | 1 | 1:06 .. 1:06 |
| `pc_bwd` | 1 | 1 | 1:04 .. 1:04 |
| `causal` | 1 | 1 | 0:58 .. 0:58 |
| `unique` | 1 | 1 | 1:53 .. 1:53 |
| `cover` | 1 | 1 | 12:49 .. 12:49 |
| `ill` | 1 | 1 | 1:12 .. 1:12 |
| `csrc_any_*` (mepc, mcause, sepc, scause) | 4 | 4 | 1:43 .. 1:52 |
| `liveness` | 1 | 1 | 8:05 .. 8:05 |
| `hang` | 1 | 1 | 7:13 .. 7:13 |

- `cover` (`cnt_insns == 2` at depth 15) is reachable, so the retire channel is not vacuous.
- `liveness 1 10 40`: after any retirement at cycle 10 the next one follows by cycle 40. `hang 1 40`: the
  first retirement happens by cycle 40 after reset. Both hold with interrupts, privilege changes, PMP and
  FENCE.I free, under the fairness assumptions above (every bus request answered within 3 cycles, no debug
  requests) and with no divide in the stream.
- FSM baseline (`../quantiumv/`, run on boolector without `memory_map`): `hang` passes in 3 minutes of CPU.
  Its `liveness 1 10 90`, whose window is long enough to include a divide, dies of `std::bad_alloc` at the
  sweep's 8 GB limit, and still does with bitwuzla and `memory_map` at 15 GB, so core_pipe's window of 40 has
  no FSM counterpart.

### Other runs

- **Full-size spot checks** (ROB 8, IQ 4; `sync_core.sh pipe-full`): `causal` (1 min), `insn_c_lw` (5 min),
  `insn_lw` (11 min), `insn_jalr` (33 min) and `reg` (1.5 h) all PASS at full size too.
- **AMO checks** (`sync_core.sh pipe-amo`, then `run_sweep.sh pipe-amo --only '^insn_amo'`; window 20 cycles):
  all 18 PASS against riscv-formal's own spec model for AMOSWAP, ADD, XOR, AND, OR, MIN, MAX, MINU and MAXU in
  `.W` and `.D` (4.8 hours of CPU time, longest 23 minutes). LR and SC have no upstream spec model; the LSU
  module proof, simulation and lockstep cover them.
- **An earlier, interrupted pass over the same RTL** (boolector with the real multipliers for its first 30
  checks, bitwuzla for the rest) finished 86 checks, all PASS and none FAIL, ERROR or TIMEOUT. The table above is
  a fresh run of all 93 on one configuration.
