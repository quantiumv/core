# riscv-formal on the core

`design/pipe/core.sv` run through the same riscv-formal suite as the frozen FSM reference,
`verification/reference/ref_core.sv` (`../quantiumv/`, `sync_core.sh ref`): the `isa rv64ic` check set (91
checks), plus riscv-formal's `liveness` and `hang` checks. The wrapper (`../quantiumv/wrapper.sv`) is shared,
because the two cores' ports are identical; only the config differs. In this file "the FSM" is `ref_core.sv`.

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
verification/riscv-formal/sync_core.sh pipe-sv39     # with address translation (one entry per TLB), for the cheap checks below
verification/riscv-formal/sync_core.sh ref           # the FSM reference (../quantiumv/); run_sweep.sh ref, sweep_status.sh ref
```

A sweep takes a couple of hours, so under WSL start it as a `systemd-run --user` unit (processes started from a
`wsl.exe` call die with it) and from a copy of `run_sweep.sh`: bash reads a script while it executes it, so
editing the original mid-sweep kills the sweep and the checks it was running. Keep the PC awake; the solvers stop
while it sleeps.

`sync_core.sh` deletes the core's old results when it regenerates; `run_sweep.sh` skips any check whose
log already says `DONE (PASS)`, so an interrupted sweep resumes. The RTL file list is
`verification/regress/design_files.list`, not a copy of its own. (The model names `pipe`, `pipe-full`, `pipe-amo`
and `pipe-sv39`, and the `quantiumv_pipe*` directory names, are older than P8's switchover and stay.)

## What differs from the FSM config

- **Small configuration.** `-D QV_FORMAL_SMALL` gives the ROB 4 entries and the instruction queue 2
  (8 and 4 otherwise). `pipe-full` drops it for the spot checks.
- **Translation is compiled out (`-D QV_FORMAL_NO_SV39`).** The sweep's model has no page-table walker and no TLBs;
  fetch and the load/store unit are their Bare paths. The 80 `insn_*` and `insn_c_*` checks pin `satp` to Bare with an
  `assume`, so for them this is the same machine; the 13 others leave `satp` free (`reg`, `pc_fwd`, `pc_bwd`, `causal`,
  `unique`, `cover`, `ill`, the four `csrc_any_*`, `liveness`, `hang`) and are proved here on the Bare paths only. With the
  TLBs and the walker in the model every check would grow, and `reg` alone is 80 minutes of CPU time as it is.
  Translation is covered by the `pipe-sv39` model below, the walker's module proof, unit testbenches with mutation
  specs, and the lockstep against `ref_core`.
- **`pipe-sv39`: the cheap checks, with translation in.** `sync_core.sh pipe-sv39` drops `QV_FORMAL_NO_SV39` and keeps
  `QV_FORMAL_SMALL`, which also gives each TLB one entry. It runs the checks that leave `satp` free and are cheap
  (`pc_fwd`, `pc_bwd`, `causal`, `ill`, `unique`, the four `csrc_any_*`) and `cover`. `reg` is left out (80 minutes of
  CPU time before translation is in), and so are `liveness` and `hang`: a translated walk is longer than their 40-cycle
  window by design. These checks reach 15 to 20 cycles from reset and the first retirement comes at about 9, which is
  too short to write `satp` and then translate a fetch. So they show that the translation hardware leaves the Bare
  behavior alone, that the assertions in the core's `RISCV_FORMAL` block hold in that window (a held translation request
  does not change; the walker and the load/store unit never drive the memory port in the same cycle), and, with `cover`,
  that the model is not vacuous. The walker itself is proved by `ptw_props` (see Module proofs).
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
  (`rvfi_unique_check.sv`). The first retirement of the core is 8 to 10 cycles after reset, so the
  FSM's trigger of 5 is unsatisfiable (`PREUNSAT`); 10 is not, and the check then looks 10 cycles on.
- **`liveness 1 10 40` and `hang 1 40` run with no divide in the stream** (`QV_FORMAL_NO_DIV` in the
  wrapper). A divide takes about 66 cycles, longer than either window, so with one the properties fail
  by design. The FSM's hang check gets the same assumption, so the two are read against each other.
  The FSM's liveness window (90) does include a divide, and its depth-90 solver run needs more memory
  than the sweep's 8 GB limit (`bad_alloc`); the core's does not try it.
- **Fairness** (`RISCV_FORMAL_FAIRNESS`, liveness and hang only): every bus request is answered within 3
  cycles and no debug halt or resume is requested. The 91 checks keep fully free acks.
- Interrupts and debug requests are free in every check (the wrapper drives `i_mtip`, `i_debug_halt_req`
  and `i_debug_resume_req` as free inputs; `i_meip` and `i_seip` stay at their default of 0), so the proofs
  cover interrupt entry, halt entry and resume too. The Debug Module's register-access and Program Buffer
  inputs are not driven (they sit at their defaults), and `reg` excludes `rvfi_any_debug_entry` as for the
  FSM, since Access Register would share its read port. PMP and `satp` are pinned for the `insn_*` and `c_*`
  families exactly as for the FSM.

## Module proofs

`verification/formal/pipe/run.sh [--mutants]` proves four units on their own with SymbiYosys
(k-induction, plus deep BMC and cover tasks): `qv_fetch` (never abandons a request, never pushes a stale
response, at most one request outstanding), `qv_lsu` (an access starts only at the ROB head and never
for a misaligned or PMP-denied uop, never abandons a request, one bus access per uop, the AMO sequence and
its lock), `qv_dbg` (a Program Buffer run implies Debug Mode, a resume is accepted only while halted and
not running, one word in flight at a time, the word index follows the retirements, the step arm is loaded
by a resume and consumed by a halt) and `qv_ptw`, the page-table walker (a PTE read stays on the bus,
unchanged, until it is answered, and cyc is low in its response cycle; a beat starts only after a cycle
with the load/store unit idle and only for an address the PMP allows at S privilege; a walk is at most three
beats; a walk its client cancelled never reports a result). The `--mutants` run shows each property set
fails on known-bad versions of its unit.

## Results

The core with the P7 features (Sv39: instruction and data TLBs and a page-table walker, on top of P6's Debug Mode
and P5's DIV, A, U/S/M privilege and delegation, interrupts and PMP; the RTL under `design/` is unchanged since
`5948021` apart from `f18e2d7`, which only adds assertions that exist under `RISCV_FORMAL`), checks generated by
`sync_core.sh pipe` from that RTL and `checks.cfg` (neither has changed since) and run on 2026-10-22/23 with
`run_sweep.sh pipe -j 4 --timeout 86400`, on a machine shared with the lockstep gates. Every check ran on the same configuration: ROB 4 and IQ 2,
`QV_FORMAL_NO_MUL`, `QV_FORMAL_NO_SV39`, `memory_map`, bitwuzla.

**93 of 93 PASS**: the 91 checks of the `rv64ic` set plus `liveness` and `hang`. 10.0 hours of solver CPU time in
all (the longest single check, `reg`, took 80 minutes of CPU; the P6 sweep took 9.8 hours and 72 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 3:00 .. 11:31 |
| `insn_c_*` (Zca) | 31 | 31 | 2:48 .. 12:34 |
| `reg` | 1 | 1 | 79:40 .. 79:40 |
| `pc_fwd` | 1 | 1 | 1:01 .. 1:01 |
| `pc_bwd` | 1 | 1 | 1:03 .. 1:03 |
| `causal` | 1 | 1 | 0:54 .. 0:54 |
| `unique` | 1 | 1 | 1:44 .. 1:44 |
| `cover` | 1 | 1 | 12:55 .. 12:55 |
| `ill` | 1 | 1 | 1:23 .. 1:23 |
| `csrc_any_*` (mepc, mcause, sepc, scause) | 4 | 4 | 1:37 .. 1:54 |
| `liveness` | 1 | 1 | 9:33 .. 9:33 |
| `hang` | 1 | 1 | 7:51 .. 7:51 |

- `cover` (`cnt_insns == 2` at depth 15) is reachable, so the retire channel is not vacuous.
- `liveness 1 10 40`: after any retirement at cycle 10 the next one follows by cycle 40. `hang 1 40`: the
  first retirement happens by cycle 40 after reset. Both hold with interrupts, privilege changes, PMP and
  FENCE.I free, under the fairness assumptions above (every bus request answered within 3 cycles, no debug
  requests) and with no divide in the stream.
- The debug inputs are free in the 91 checks, so every proof also covers a halt, a resume and the debug
  entries (`i_debug_halt_req` and `i_debug_resume_req` are driven freely by the wrapper); the Program Buffer
  and Access Register ports are not driven and are covered by the `qv_dbg` module proof, simulation and the
  lockstep script. Nothing needed an assumption beyond P5's.
- FSM baseline (`../quantiumv/`, run on boolector without `memory_map`): `hang` passes in 3 minutes of CPU.
  Its `liveness 1 10 90`, whose window is long enough to include a divide, dies of `std::bad_alloc` at the
  sweep's 8 GB limit, and still does with bitwuzla and `memory_map` at 15 GB, so the core's window of 40 has
  no FSM counterpart.

### Other runs

- **Full-size spot checks** (ROB 8, IQ 4; `sync_core.sh pipe-full`): `causal` (1 min of CPU), `insn_c_lw` (5 min),
  `insn_lw` (10 min), `insn_jalr` (16 min) and `reg` (2 h) all PASS at full size too.
- **Sv39 model** (`sync_core.sh pipe-sv39`: translation in, one entry per TLB): 10 checks PASS, 34 minutes of CPU time in
  all: `causal` (1:22), `pc_bwd` (1:14), `pc_fwd` (1:58), `ill` (1:56), `unique` (2:18), the four `csrc_any_*` (2:14 .. 2:43)
  and `cover` (15:28). What that shows is spelled out under "What differs from the FSM config".
- **AMO checks** (`sync_core.sh pipe-amo`, then `run_sweep.sh pipe-amo --only '^insn_amo'`; window 20 cycles):
  all 18 PASS against riscv-formal's own spec model for AMOSWAP, ADD, XOR, AND, OR, MIN, MAX, MINU and MAXU in
  `.W` and `.D` (4.9 hours of CPU time, longest 54 minutes). LR and SC have no upstream spec model; the LSU
  module proof, simulation and lockstep cover them.
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`): `qv_fetch`, `qv_lsu`, `qv_dbg` and `qv_ptw` prove,
  bmc and cover all PASS, and all 29 known-bad versions are caught (6 of them walker mutants).

### After the P8 switchover

The module is `core` in `design/pipe/core.sv` since P8, and the RTL is the one above: preprocessed with comments
stripped, the two trees differ only in blank lines and a lint pragma around the module name. The configs lost
`-D QV_PIPE_AS_CORE`, and the wrapper's divide assumption now selects on `QV_REF_AS_CORE`. That branch compiles only
under `[defines liveness]` and `[defines hang]`, so those two were re-run first, from freshly generated checks, and
the cheapest check of every other model after them: `pipe` `liveness` and `hang`, `pipe-full` `causal`, `pipe-sv39`
`causal` and `pipe-amo` `insn_amoand_d` all PASS. The reference config (`sync_core.sh ref`: `ref_*.sv` and
`ref_macros.svh`, `-D QV_REF_AS_CORE`) elaborates and proves `causal`, `insn_add` and `pc_fwd`, and its `hang` passes on
boolector in 2:43 of CPU time as before (on bitwuzla it runs out of memory at step 40 and the sweep reports ERROR). The
module proofs were run again (12 proofs PASS, all 29 known-bad versions caught).

The full re-sweep on the switched tree then ran in the background (`-j 4`, bitwuzla, 24 h timeout, from freshly
generated checks) and is clean: `pipe` 93/93, `pipe-sv39` 9/9, `pipe-amo` 18/18, `pipe-full` 5/5 (`reg`, `causal`,
`insn_lw`, `insn_jalr`, `insn_c_lw`). The same results as before the switch, as the unchanged RTL says they must be.
