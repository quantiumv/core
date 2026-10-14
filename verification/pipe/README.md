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
```

A spec lists `old`/`new` text pairs. A mutant is killed if the testbench or
the gate fails (or does not compile or times out). One marked `"equivalent"`
changes nothing observable and is expected to survive; the spec says why.
The specs are named for the slice that added them (`p5a_...`).
