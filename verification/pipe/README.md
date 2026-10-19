# core_pipe checks against core.sv

`run_rvfi_diff.sh` runs random programs on `design/core.sv` and on
`design/pipe/core_pipe.sv` (built as `core`), and compares the two
retirement streams record by record. `gen_alu.py` makes the programs;
`cmp_rvfi.py` does the comparison.

```sh
verification/pipe/run_rvfi_diff.sh --seeds 50 [--first S] [--len L] \
    [--serialize 0|1] [--bypass 0|1] [--no-div] [--pipe-dir DIR] [--outdir DIR]
```

The gate is 50 seeds in each of three configs: the default, `--serialize 1`,
and `--bypass 0`. `--serialize 1` issues one instruction at a time and
`--bypass 0` removes the forwarding path, so a failure that goes away with
either one is a hazard bug rather than a functional one.

## Mutants

A change to `design/pipe/` should break something. The mutation tools apply
textual edits and report which ones the checks catch.

```sh
verification/pipe/mutate.py      verification/pipe/mutants/p5a_unit_exu_div.json  # one unit testbench
verification/pipe/mutate_pipe.py verification/pipe/mutants/p5a_e2e.json [N,N,...] # the whole core, via run_rvfi_diff.sh
verification/pipe/mutate_lockstep.py verification/pipe/mutants/p5c_lockstep.json [N,N,...|baseline] # pipe-vs-ref lockstep
```

A spec lists `old`/`new` text pairs. A mutant is killed if the testbench or
the gate fails (or does not compile or times out). One marked `"equivalent"`
changes nothing observable and is expected to survive; the spec says why.
The specs are named for the slice that added them (`p5a_...`).

`mutate_lockstep.py` takes mutants from the unit specs (`"from": "p5c_unit_decode.json", "only": [2, 5]`)
and runs each over qvgen programs with the spec's profile; the profile (and the extra run_lockstep.sh
arguments) can be overridden per entry. A mutant first runs over the first few programs and a survivor
over more (`"counts": [8, 24, 64]`), so an easy kill is cheap. `baseline` runs the unmutated core first,
which has to pass. A mutant the programs cannot reach (a fetch span variant no generated pocket sits
next to, say) survives here and is covered by the unit testbench instead; the spec lists only the ones
the programs are expected to catch.

The qvgen profiles the specs use (`verification/lockstep/gen/qvgen.py`):

| spec | profile | run_lockstep.sh arguments |
|---|---|---|
| `p5c_lockstep.json` | `--isa imac --priv msu --smc` | |
| `p5d_lockstep.json` | `--isa imac --priv msu --smc --irq` | `--irq-mode 2 --irq-density 1 --irq-late` |
| `p5e_lockstep.json` | `--isa imac --priv msu --pmp --smc` (and `--priv m` for the lock bit and MPRV) | |

## Where core_pipe differs from core.sv

Architectural behavior is the same: the lockstep gate compares every retirement, a CSR snapshot, the bus
write log and, with `--dbg-mode 1`, the debug-script event log. These differences are known and acceptable.

Not architectural:
- The pipe prefetches; the FSM does not. Without a FENCE.I, what each fetches from freshly written code is
  unspecified, so a generated program must never store into the code except in the SMC idiom (which has
  the FENCE.I). `lockstep/smc_hazard.py` classifies a failed run's trace as this hazard or not. (The
  first P6 gate found qvgen's `lr rd, (rs1)` with rd == rs1 doing it through the loaded word.)
- Fetch PMP is checked per instruction in decode, not before the bus request; a denied fetch never retires.
- A DIV or FENCE.I that traps on an action-0 trigger: the FSM starts the divider and flushes the icache
  before trapping, the pipe does neither (the flush is harmless).

RVFI fields the FSM reports stale, which the comparator masks or the stimulus avoids:
- `insn` on cause-1 records, `mem_*` on trapping AMO records, mip bits 7, 9 and 11 under `--irq-late`.
- `mem_*` of a trapped action-0 load, store or AMO: the FSM reports the would-be access, the pipe zeros
  (the comparator skips the memory fields of trap records).
- A Program Buffer abort reports `rvfi_trap` 0, so its memory fields are compared. They differ for a
  misaligned SC, AMO, LR or load and for a faulting load or AMO read (stale bus registers in the FSM), so the
  script's snippets avoid those; `dm_tb` covers them.

Debug Module corners the pipe resolves differently; the DM's spacing of DMI operations keeps JTAG from
reaching them:
- `i_progbuf_start` in the same cycle as a resume: the pipe resumes and ignores the start, the FSM accepts
  both and leaves a run active with `in_debug_mode` 0. A start while a run is active or at its last commit
  is ignored by the pipe.
- A Program Buffer word rewritten while a run is in flight: the pipe executes the word it latched at
  injection, the FSM the live one. A debugger that polls `busy` never does this.
- After a debugger writes code with no FENCE.I, the pipe's icache can hold stale lines beyond the halt pc
  that the FSM would not (the FSM has nothing prefetched).
