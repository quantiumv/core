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
