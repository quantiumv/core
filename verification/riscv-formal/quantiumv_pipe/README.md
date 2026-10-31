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

### After P9 (performance)

The core with P9 (a store buffer, back-to-back fetch with a four-entry fetch buffer and an eight-entry queue, and a
target buffer, return-address stack and history table; the RTL under `design/` is the tree of `e973b09`, which the
whole exit gate ran on), checks regenerated by `sync_core.sh` from it and run on 2026-10-26 with `run_sweep.sh`
(`-j 4`, bitwuzla, 24 h timeout, the models one after the other and, for time, the last three alongside the long
`reg`). The sizes in the model are the small ones: ROB 4, IQ 2, fetch buffer 2, store buffer 2, target buffer 2,
return-address stack 2, history table 8.

**`pipe`: 93 of 93 PASS**, 9.3 hours of solver CPU time in all (the longest check, `reg`, took 58 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 2:20 .. 15:39 |
| `insn_c_*` (Zca) | 31 | 31 | 2:30 .. 13:18 |
| `reg` | 1 | 1 | 58:18 |
| `pc_fwd` | 1 | 1 | 0:51 |
| `pc_bwd` | 1 | 1 | 0:50 |
| `causal` | 1 | 1 | 0:44 |
| `unique` | 1 | 1 | 1:28 |
| `cover` | 1 | 1 | 18:25 |
| `ill` | 1 | 1 | 1:11 |
| `csrc_any_*` | 4 | 4 | 1:17 .. 1:26 |
| `liveness` | 1 | 1 | 6:59 |
| `hang` | 1 | 1 | 6:02 |

- **Full-size spot checks** (`pipe-full`: ROB 8, IQ 4, fetch buffer 4, no `QV_FORMAL_SMALL`): `causal` (7:48), `insn_c_lw`
  (15:59), `insn_lw` (18:12), `insn_jalr` (34:01) and `reg` (2 h 25 min) all PASS.
- **Sv39 model** (`pipe-sv39`): 10 of 10 PASS, 0.9 hours: `causal` (1:29), `pc_bwd` (1:39), `pc_fwd` (2:31), `ill`
  (2:23), `unique` (4:03), the four `csrc_any_*` (2:22 .. 2:59) and `cover` (28:32; it reaches its cover statement, so
  the model is not vacuous). `cover` is named `cover.sby`, with no `_ch0`: a filter written as `cover_ch0` skips it,
  which is how the P8 re-sweep's "9/9" for this model came about.
- **AMO checks** (`pipe-amo`): 18 of 18 PASS, 6.2 hours, longest 32 minutes.
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`): `qv_fetch`, `qv_lsu`, `qv_dbg`, `qv_ptw` and the new
  `qv_sb` (store buffer) prove, bmc and cover, 15 of 15 PASS, and all 48 known-bad versions are caught (12 for
  fetch, among them three for the target buffer's hint; 11 for lsu, 8 for dbg, 6 for ptw, 11 for sb).

What the models above do **not** exercise: the wrapper gives `core` no RAM window (`PMA_RAM_SIZE` defaults to 0), so the
store buffer is in the model but no store is ever posted to it, and the posting, the drain and the loads that wait for
it are not part of the 93 checks or of `liveness`. They are covered by the `qv_sb` and `qv_lsu` module proofs
(`sb_props.sv`, `lsu_props.sv`), the unit testbenches and their mutation specs, and the lockstep against `ref_core`
(whose harnesses all set the window). The streaming fetch and the three predictors are in the model at the small sizes.

- **Store buffer live** (`sync_core.sh pipe-sb`: the same model with `-D QV_PIPE_PMA_RAM_SIZE=2147483648`, a window
  over the first 2 GiB, so every store below it is posted; the wrapper then assumes a drain beat gets no bus error,
  which is what the buffer asserts of RAM). The checks that can see the buffer: **23 of 23 PASS**: `liveness` (11:19
  CPU) and `hang` (11:26), so the 40-cycle windows hold with drains going on; `cover` (25:06); `causal`, `unique`,
  `ill`, `pc_fwd`, `pc_bwd` and the four `csrc_any_*` (1:18 .. 2:27); and the stores and loads: `insn_sb`, `insn_sh`,
  `insn_sw`, `insn_sd`, `insn_c_sw`, `insn_c_sd`, `insn_c_swsp`, `insn_c_sdsp`, `insn_lw`, `insn_ld` and `insn_jalr`
  (8:35 .. 19:19). The rest of the 93 were not run in this model: the property of an instruction check is what
  retires, and RVFI reports a posted store from the load/store unit's result, the same as an unposted one. The
  drain's order, the loads' wait for it and the bus discipline are what `sb_props.sv` proves, and mutants of the
  buffer are killed by its unit specs and the lockstep.

### After P10 (performance leftovers)

The core with P10 (a translated fetch reuses the last page, an early DTLB probe, read-only CSR ops and writes to the
eight trap CSRs no longer serialize, and fetch-side PTE reads outside the RAM window wait for the real path; the RTL
under `design/` is the tree of `35751d7`, which the whole exit gate ran on), checks regenerated by `sync_core.sh` and
run on 2026-10-27/28 with `run_sweep.sh` (`-j 4`, bitwuzla, 24 h timeout, the models one after the other; the machine
was shared with the lockstep exit gate, so the CPU times are higher than P9's). The sizes in the model are P9's small
ones.

**`pipe`: 93 of 93 PASS**, 13.2 hours of solver CPU time in all (the longest check, `reg`, took 80 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 3:21 .. 24:42 |
| `insn_c_*` (Zca) | 31 | 31 | 2:38 .. 16:11 |
| `reg` | 1 | 1 | 79:59 |
| `pc_fwd` | 1 | 1 | 1:13 |
| `pc_bwd` | 1 | 1 | 1:09 |
| `causal` | 1 | 1 | 1:05 |
| `unique` | 1 | 1 | 2:16 |
| `cover` | 1 | 1 | 21:10 |
| `ill` | 1 | 1 | 1:18 |
| `csrc_any_*` | 4 | 4 | 3:30 .. 4:07 |
| `liveness` | 1 | 1 | 9:51 |
| `hang` | 1 | 1 | 7:48 |

- **Full-size spot checks** (`pipe-full`): `causal` (7:27), `insn_c_lw` (15:30), `insn_lw` (16:25), `insn_jalr`
  (32:51) and `reg` (1 h 28 min) all PASS.
- **Sv39 model** (`pipe-sv39`): 10 of 10 PASS, 0.6 hours: `causal` (0:58), `pc_bwd` (1:06), `ill` (1:08), `pc_fwd`
  (1:16), `unique` (1:43), the four `csrc_any_*` (2:03 .. 3:05) and `cover` (18:24). The model has fetch page reuse
  and the DTLB probe in it; the `RISCV_FORMAL` invariants of `core.sv` that hold the two to their context (a reused
  page is used only under the satp and privilege it was filled under, with no SFENCE.VMA or debug entry since; a
  probed data translation is used only under an unchanged data context) are asserted in every check of this model.
- **Store buffer live** (`pipe-sb`): 23 of 23 PASS, 2.6 hours: `liveness` (11:51), `hang` (6:39), `cover` (14:31),
  `causal`, `unique`, `ill`, `pc_fwd`, `pc_bwd` and the four `csrc_any_*` (0:45 .. 2:36), and the stores and loads
  (4:43 .. 20:36).
- **AMO checks** (`pipe-amo`): 18 of 18 PASS, 6.3 hours, longest 50 minutes.
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`): 15 of 15 PASS, and all 50 known-bad versions are
  caught (the walker's two new ones: a fetch beat outside the window that ignores the wait, and a waiting fetch walk
  that never gives way to a data walk).

P10d's window rule is not in any of these models: `pipe-sv39` has translation but no RAM window, `pipe-sb` a window
but no translation. It rests on `ptw_props.sv` (which gets a window and a free `nonspec` input), the walker's unit
testbench and mutation spec, `core_sv39_pma_walk_tb` and the lockstep.

### After F/D

The core with F, D and Zcd (on by default, `QV_FPU_EN`; the RTL under `design/` is the tree of `33a2420`, unchanged
since), checks regenerated by `sync_core.sh` and run on 2026-10-29 with `run_sweep.sh` (`-j 8`, bitwuzla, 20,000 s
timeout, the models one after the other). riscv-formal has no F/D instruction models, so the arithmetic is not checked
here; it is checked against TestFloat and Sail (`verification/fpu/`). The models other than `pipe-fpu` are built with
`QV_FORMAL_NO_FPU`, which takes the FPU, the FP decode and the FP CSR state out. What differs from P10 in them is misa,
which now has the letters of what is implemented (erratum E3; F and D only when the FPU is in), and C.FLD/C.FSD/C.FLDSP/
C.FSDSP, which `c_expand` now always expands and decode then rejects as illegal. Their results are P10's, as they
should be.

**`pipe`: 93 of 93 PASS**, 14.8 hours of solver CPU time in all (the longest check, `reg`, took 61 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 4:28 .. 27:00 |
| `insn_c_*` (Zca) | 31 | 31 | 4:01 .. 16:47 |
| `reg` | 1 | 1 | 61:10 |
| `pc_fwd` | 1 | 1 | 1:31 |
| `pc_bwd` | 1 | 1 | 1:27 |
| `causal` | 1 | 1 | 0:48 |
| `unique` | 1 | 1 | 2:48 |
| `cover` | 1 | 1 | 22:22 |
| `ill` | 1 | 1 | 1:40 |
| `csrc_any_*` | 4 | 4 | 3:15 .. 4:00 |
| `liveness` | 1 | 1 | 11:28 |
| `hang` | 1 | 1 | 10:32 |

- **F/D in** (`sync_core.sh pipe-fpu`: the `pipe` model with the FPU built in under `QV_FORMAL_FPU_ABSTRACT`, which keeps
  the FPU's control, latency, order and kill, but makes every result and flag value free, cuts the divide and square
  root to 3 iterations, and makes the FP register reads free). FP ops, FP loads and stores, the fcsr CSRs and FS then
  run in every check, with their own producer table, the third operand, the FPU's writeback port and bypass, and the
  out-of-order completion of a divide. The wrapper's `liveness`/`hang` assumption keeps FP divide and square root out,
  as it keeps the integer divide out. The checks that see the integer state those ops could disturb: **25 of 25 PASS**,
  4.9 hours: `reg` (60:14), `liveness` (13:38), `hang` (14:04), `cover` (31:16), the integer loads and stores
  (`insn_lb`, `lbu`, `lh`, `lhu`, `lw`, `lwu`, `ld`, `sb`, `sh`, `sw`, `sd`: 9:20 .. 14:44) and `insn_jalr` (24:34),
  `causal`, `unique`, `ill`, `pc_fwd`, `pc_bwd` and the four `csrc_any_*` (1:21 .. 4:08). An FP instruction is
  checked here only as far as RVFI reports it: its integer destination, if any, its trap and its pc. What it writes
  to an FP register is compared in lockstep against `ref_core`, at every retirement.
- **Full-size spot checks** (`pipe-full`): `causal` (7:07), `insn_c_lw` (13:41), `insn_lw` (17:27), `insn_jalr` (25:59)
  and `reg` (1 h 09 min) all PASS.
- **Sv39 model** (`pipe-sv39`): 10 of 10 PASS, 0.8 hours: `causal` (1:17), `ill` (1:47), `pc_bwd` (1:53), `pc_fwd`
  (2:01), `unique` (2:49), the four `csrc_any_*` (3:59 .. 4:12) and `cover` (21:06).
- **Store buffer live** (`pipe-sb`): 23 of 23 PASS, 3.1 hours: `liveness` (13:31), `hang` (11:47), `cover` (23:57),
  `causal`, `unique`, `ill`, `pc_fwd`, `pc_bwd` and the four `csrc_any_*` (1:02 .. 4:40), and the integer loads and
  stores (8:20 .. 12:56).
- **AMO checks** (`pipe-amo`): 18 of 18 PASS, 6.8 hours, longest 38 minutes.
- **The reference** (`sync_core.sh ref`, `QV_FORMAL_NO_FPU`): `causal` (2:09), `insn_add` (1:13) and `pc_fwd` (0:42)
  PASS. Its `hang` passes on boolector in 2:24, as at P8: on bitwuzla it was stopped after 28 minutes of CPU
  (it runs out of memory there).
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`, from the checkout): 18 of 18 PASS, the new
  `qv_exu_fpu` proof (`fpu_props.sv`, the FPU's control with its values free) among them, and all 59 known-bad versions
  are caught (9 of them FPU mutants). Run from a `git archive` snapshot, the pre-fix fetch mutant cannot be built (it
  reads `ade0d1c^` from the history) and reports ERROR, not caught.

### After errata E4-E9

The tree of `f555cb6`: the six errata both cores got once ACT declared Sv39 and PMP (`mtvec`/`stvec` MODE and vectored
interrupts, PMP partial matches in M mode, fetch PMP per 2-byte parcel, the PMP CSRs RV64 lacks, `mcounteren`/
`scounteren` and `menvcfg`/`senvcfg`; `../../pipe/README.md`). Checks regenerated by `sync_core.sh` and run on
2026-10-30 with `run_sweep.sh` (`-j 8`, bitwuzla, 20,000 s timeout). The `pipe` sweep was cut off at 29 of 93 by a
WSL restart and resumed; the 8 checks that were running then started again, and their times below are the second
run's. The errata touch CSRs, PMP and trap entry, which every model below sees; `pipe-fpu`, `pipe-sb` and `pipe-amo`
were not re-run.

**`pipe`: 93 of 93 PASS**, 17.8 hours of solver CPU time in all (the longest check, `reg`, took 78 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 5:09 .. 33:14 |
| `insn_c_*` (Zca) | 31 | 31 | 4:18 .. 31:06 |
| `reg` | 1 | 1 | 78:26 |
| `pc_fwd` | 1 | 1 | 1:30 |
| `pc_bwd` | 1 | 1 | 1:25 |
| `causal` | 1 | 1 | 1:16 |
| `unique` | 1 | 1 | 2:45 |
| `cover` | 1 | 1 | 29:43 |
| `ill` | 1 | 1 | 2:06 |
| `csrc_any_*` | 4 | 4 | 4:21 .. 4:32 |
| `liveness` | 1 | 1 | 10:32 |
| `hang` | 1 | 1 | 11:38 |

- **Full-size spot checks** (`pipe-full`): `causal` (8:40), `insn_c_lw` (16:50), `insn_lw` (21:56), `insn_jalr` (32:44)
  and `reg` (2 h 09 min) all PASS.
- **Sv39 model** (`pipe-sv39`): 10 of 10 PASS, 1.2 hours: `pc_bwd` (2:56), `pc_fwd` (2:57), `causal` (3:08), `ill`
  (3:10), `unique` (3:54), the four `csrc_any_*` (6:04 .. 6:34) and `cover` (27:02).
- **The reference** (`sync_core.sh ref`): `causal` (5:12), `insn_add` (2:12), `pc_fwd` (1:10), `ill` (1:08) and the
  four `csrc_any_*` (3:28 .. 3:47) PASS. Its `hang` passes on boolector in 12:37 (2:24 before the errata); on bitwuzla
  it was stopped after 52 minutes of CPU, as at F/D, and the sweep lists it as ERROR.
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`, from the checkout): 18 of 18 PASS, and all 59
  known-bad versions are caught.

### After errata E10 and Zicntr

The tree of `84dfaa5`: erratum E10 (an access to a CSR that does not exist is illegal) and Zicntr (`cycle`, `time`,
`instret`, on by default; the wrapper drives the new `i_time` input freely). The checks were regenerated by
`sync_core.sh` from a snapshot and run on 2026-10-31 with `run_sweep.sh` (`-j 8`, bitwuzla, 20,000 s timeout). The
`pipe` model gains six `csr_ill_*` checks (`[illegal_csrs]` in `checks.cfg`): every access to `c03`, `14d` and `800`
traps in M, S and U, and every access to `600`, `30c` and `7a5` traps in M. That makes 99 checks.

**`pipe`: 99 of 99 PASS**, 20.6 hours of solver CPU time in all (the longest check, `reg`, took 86 minutes).

| checks | count | PASS | CPU time per check, min:sec (shortest .. longest) |
|---|---|---|---|
| `insn_*` (RV64I) | 49 | 49 | 5:44 .. 36:45 |
| `insn_c_*` (Zca) | 31 | 31 | 4:02 .. 20:18 |
| `reg` | 1 | 1 | 86:21 |
| `pc_fwd` | 1 | 1 | 1:33 |
| `pc_bwd` | 1 | 1 | 1:31 |
| `causal` | 1 | 1 | 2:42 |
| `unique` | 1 | 1 | 2:52 |
| `cover` | 1 | 1 | 43:02 |
| `ill` | 1 | 1 | 3:15 |
| `csrc_any_*` | 4 | 4 | 7:35 .. 8:22 |
| `csr_ill_*` | 6 | 6 | 4:30 .. 4:55 |
| `liveness` | 1 | 1 | 10:26 |
| `hang` | 1 | 1 | 19:22 |

- **Full-size spot checks** (`pipe-full`): all PASS: `causal` (8:44), `insn_c_lw` (17:15), `insn_lw` (20:52),
  `insn_jalr` (28:02) and `reg` (1 h 51 min).
- **Sv39 model** (`pipe-sv39`): 10 of 10 PASS:
  - `pc_bwd` (2:30), `ill` (2:34), `causal` (2:39), `pc_fwd` (2:47) and `unique` (3:29);
  - the four `csrc_any_*` (4:55 .. 5:11);
  - `cover` (35:28).
- **The reference** (`sync_core.sh ref`): all PASS:
  - `causal` (6:06), `insn_add` (1:37), `pc_fwd` (1:00) and `ill` (0:57);
  - the four `csrc_any_*` (2:53 .. 3:04);
  - the six `csr_ill_*` (0:46 .. 0:54).

  Its `hang` passes on boolector in 13:25; bitwuzla was not run on it, since it runs out of memory there.
- **Module proofs** (`verification/formal/pipe/run.sh --mutants`, from the checkout): 18 of 18 PASS, and all 59
  known-bad versions are caught.
