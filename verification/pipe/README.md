# The core checked against ref_core.sv

`run_rvfi_diff.sh` runs random programs on `verification/reference/ref_core.sv`
(the frozen multi-cycle core, built as `core` with `-DQV_REF_AS_CORE`) and on
`design/pipe/core.sv`, and compares the two retirement streams record by
record. `gen_alu.py` makes the programs; `cmp_rvfi.py` does the comparison.

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
| `p6_lockstep.json` | `--isa imac --priv msu --pmp --irq --smc` | `--irq-mode 2 --irq-density 1 --dbg-mode 1 --dbg-features 191` |
| `p6_lockstep_extra.json` | the same (`--priv m` for the debug-CSR legality mutants, which only an M-mode body reaches) | the same |
| `p6_lockstep_dense.json` | the same plus `--ebreak-rate 0.1` | the same plus `--dbg-density 1` (and, for a trigger against an interrupt, `--irq-density 4 --dbg-features 703`: triggers on the instruction after dpc's) |
| `p6_lockstep_dbgexc.json` | the same, `--corpus dbg`: the directed programs `dbg_exc.s` and `dbg_res.s`, the only ones that can take an action-0 trigger | `--irq-mode 0 --dbg-mode 1 --dbg-features 191` |
| `p7_lockstep.json` | `--isa imac --priv msu --pmp --irq --smc --sv39` | `--irq-mode 2 --irq-density 1 --dbg-mode 1 --dbg-features 191 --timeout 2000000` |
| `p7_lockstep_extra.json` | an M-mode body (`--priv m --pmp --smc --sv39`: MPRV, a locked pocket binding M); `--priv msu --pmp --irq --smc` without `--sv39` (satp Bare below M); `--priv msu --irq --smc --sv39` without `--pmp` (the bus-error region is reachable); `--priv msu --pmp --smc --sv39` without `--irq` (a pocket of its own over the high probe page; with `--probe-half` it covers only the first half) | `--irq-mode 0` where the profile has no `--irq` |
| `p7_lockstep_slow.json` | the first profile (and the no-`--pmp` one) on the cache with 8 wait states, where the caches answer with ack and err together | `--timeout 3000000` |
| `p7_lockstep_win0.json` | `p7_lockstep`'s first profile and the one without `--irq`, built with the one-entry aligner `qv_align` (the defaults build `qv_align2` since O8) | `--defines "QV_PIPE_ALIGN_WIN=0 QV_PIPE_GSHARE_H=0"` plus the same |
| `p7_lockstep_long.json` | `p7_lockstep`'s first profile, up to 256 programs, for what 64 do not reach | the same |

`p6_lockstep.json` holds every mutant of the P6 unit specs. 85 of its 134 are killed by the random programs
alone and 49 survive them; each survivor is annotated (`unit_only`) with the reason, either the spec that kills it
(the three other P6 specs above) or why no generated program can show it (the Debug Module never produces the
input, the decoder or commit makes the difference unobservable, the RVFI fields differ for a reason both cores
get right). Run all four specs for the full record.

`p7_lockstep.json` holds every mutant of the ten P7 unit specs (`qv_pte`, `qv_tlb`, `qv_ptw`, `qv_xlate`, and the translation
rows of `qv_lsu`, `qv_commit`, `qv_fetch`, `qv_align`, `qv_decode`): 250. On the final stimulus (a full run with
`--skip-annotated`, after the last generator fix, `5964d87`) the generated programs kill 180 within 64 programs: 167 in the main
profile, 13 more in `p7_lockstep_extra.json` and `p7_lockstep_slow.json` (listed there, and as `unit_only` with the spec that
kills them in the main one). A mutant counts as killed when the run fails, hangs, or stops on an assertion: the
`RISCV_FORMAL` block of the core is compiled into the lockstep build, so the invariants that a held translation request does
not change, and that the walker and the LSU never drive the memory port together, stop the run (the lockstep reports an error
with no result line). The other 70 survive the 64 programs: 11 are marked `"equivalent"` in their unit spec, and 59 carry a
`unit_only` reason. Every unit-spec mutant is also killed by its unit testbench. The reasons fall in four groups:
- *only the number of walks or flushes changes* (31): an extra TLB flush (7), the order the TLB replaces entries in, an
  over-strict tag compare, a second entry for one address, the TLB's state before reset in a two-state simulation, a fill that
  races a flush, a tag taken from the live address (11 in all), what `qv_xlate` does when asked while translation is off or the
  TLB hits or a fault is held (6), which of two simultaneous walker requests goes first (2), a slot reused or a fault answered a
  cycle later (2), a redirect that waits one cycle more (3);
- *an orphan walk or a coincidence with no request waiting* (11): what the walker does after a cancel or below a faulting
  pointer (a cancel that does not mark the walk stale needs a request for another address held when the beat completes: the
  exit gate's 2000 programs kill it, the 1082nd, the 64 of this campaign do not), a fill for a request that was just cancelled,
  a held fetch whose translation starts a beat for the right address, a misaligned op that is walked before it traps (its trap
  comes first), a flush while the head waits for its walk;
- *not reachable through the core's wiring or design* (7): the instruction-side translator is given SUM = 0, no translation
  runs at M privilege, a fetch never asks for write, an entry with W and no R is malformed whether it is read as a leaf or as a
  pointer, a store walked as a load is judged again on the TLB hit, an access fault that is not taken as an answer ends in the
  same cause 1 through a bus error, a fetch that also needs R (no generated page is execute-only: the code pages are readable
  because the handlers read the code, and a fetch-probe page that works is R and X; `qv_pte_tb` compares with `ref_core.sv`'s
  expressions on random inputs);
- *needs a rarer combination, or is covered elsewhere* (10): a redirect has to wait only when it turns fetch translation on (the
  MRET into the body is killed; an interrupt, a trap, an SRET and a serializing instruction never go from untranslated to
  translated), a straddling fetch whose two frames sit in pockets with the same verdict, a high-page fault in a pocket that
  forbids X, a Program Buffer run's PMP bypass (`p6_lockstep.json`) and SFENCE.VMA (`qv_commit_tb`).

What made the difference was stimulus (`qvgen --sv39`): bits of a PTE and of a physical address the ordinary map never sets
(V clear with a good leaf at every level, reserved, PBMT and N bits in leaves and in pointers, a physical address with one high
bit, a pointer to a far table or to the bus-error region), aliases of mapped pages with wrong upper bits, misaligned hole
accesses, SUM/MXR flip pairs, an NA4 PMP word through one PTE, fetch probes through far tables and through windows above the
image, and S and U bodies that run through a 2 MiB window at a virtual address that is not their physical one. The first pass
(the stimulus before these) killed 149; the survivors were re-run on later versions of the stimulus (20 more) and in the two
extra specs (13). The numbers above are from one more full run on the final stimulus, made after the exit gate had asked for
two generator fixes (see the next section): two mutants killed before are not killed in 64 programs any more.

### What the P7 exit gate found

Two faults in the generator and none in the RTL. Each showed as a gate result and was traced on the built binary
(`+RVFI_TRACE`):
- A body that switches `satp` between two table sets (every write is followed by an SFENCE.VMA, rule R1) can take an
  interrupt or a halt between the `csrw satp` and its SFENCE.VMA. The page-fault handler had set A in the table set that was
  current, so the two sets disagreed about a code page: the FSM walks again and faults, the pipe still holds the entry it
  had, and both are legal. `qvgen` no longer clears A on the code pages of such a body (`ac71e17`).
- An M-mode body does not translate, so a store through the alias of a low address (`emit_noncanonical`: wrong upper bits,
  low bits 0x500) wrote the real address and zeroed the program's own code. The program then counted a loop down from -1
  and ran to the cycle limit, with both cores agreeing on all 865,808 retirements. An M body's non-canonical accesses are
  loads only now (`5964d87`).

### What the P8 exit gate found

One more fault in the generator and none in the RTL. The gate ran the switched core against `ref_core` on fresh seeds
(`--seed 2`, programs 20001 to 22500, the full Sv39 profile with interrupts and the debug script) on the four memory
configurations: 10,000 runs, of which 9,996 end at `tohost` with 487 million retirements compared (15 million of them
interrupt entries). The other four are one program, `random_20446`, in every configuration. It never ends, and the cores
agree on every retirement of it (8.5 million in a 40-million-cycle run).

The body's `sret` idiom sets `sepc` to the next instruction and `SPP` to S, then executes `sret`. Here the `sret` was the first
word of a page whose A bit was clear. The fetch fault overwrote `sepc`, the page-fault handler's own `sret` cleared `SPP`, and
the retried `sret` dropped to U at its own pc, where the page cannot be executed: a fetch fault again, ended by a resume at
`x25` in U mode, for good. `csrs` and `sret` now share an aligned 8-byte block when fetch faults are on (`edf53d3`), so they
are on one page; the same program ends after 40,427 retirements. A fresh batch from the fixed generator (`--seed 3`, programs
30001 to 30500, four configurations, 2,000 runs, 100 million retirements) passes in full.

### F/D

F, D and Zcd are in both cores (`QV_FPU_EN`, on by default; `0` builds either core without them). The arithmetic is
common to the two: the reference runs private copies of the same FPU (`verification/reference/gen_copies.sh`), so
lockstep cannot see a wrong result. That is checked on its own, against TestFloat and Sail vectors
(`verification/fpu/`), by the Sail diff and by ACT. Lockstep checks everything around it:
- decode's classification;
- the two producer tables and the third operand;
- the FPU's own ROB port and the bypass;
- FP register writes and fflags accrual at commit;
- FS;
- NaN-boxing loads;
- the Debug Module's FPR access.

The harness compares, at every retirement, a word of {the FP register written, its number, FS, frm, fflags} and the
value written, and all 32 FP registers at the end (corruption fields 13 and 14).

What it found while the pipe was brought up, all in the pipe and none in the reference:
- an FP instruction carried its rs2 field into RVFI even where that field is not a register (FCVT's conversion type);
- an illegal FP word reported source registers, which the reference (it decodes such a word as `0x00000000`) does not.

Elsewhere:
- ACT's `ExceptionsZc` (F/D config) read an FP register that only a faulting C.FLD was to load: Sail resets the FP
  registers to 0, so both cores do now (`33a2420`).
- `qvgen --sail-safe` no longer probes `tselect`, which Sail treats as an ordinary M-mode CSR (`f3934cc`).
- The divergence table printed SUM and MXR swapped for side B (the compare was right).

Mutants: `f5_lockstep.json`, 18 on the integration, 17 killed by the FP-profile lockstep and one equivalent (an FP
commit cannot clear an integer claim, the tag compare forbids it). One of them, the FMA's third operand read without
waiting for its producer, survived 64 programs until `qvgen` made an FMA's rs3 the newest FP result more often.

The gate, with F/D on by default (2026-10-29). Lockstep, the core against the reference, Verilator, four memory
configurations:
- The FP profile (`--isa imafdc --priv msu --pmp --irq --smc --sv39` with interrupts and the debug script, `--seed
  17`): 500 x 4 = 2,000/2,000 runs, 91.5 M retirements, 2.9 M interrupt entries.
- The integer profile with the FPU built in (ACT, the firmware and 300 random programs, `--seed 18`): 1,672/1,672.
- The smc, irq and debug corpora: clean.

Before that, with `QV_FPU_EN=1` given explicitly and the default still off:
- the reference against itself on the FP profile: 300 x 4 = 1,200/1,200;
- the core against the reference with the FPU off: 1,672/1,672;
- the kill matrix: 17/17 (14-17 are the F/D mutants);
- the corruption self-test: every field class, 13 and 14 included.

Sail agrees with both cores on 45 FP programs each (30 S/U-mode, 15 M-mode) and on 25 integer ones. ACT, F/D config
(`CONFIG=quantiumv-rv64imafdc`): 334/337 on both cores. `S-00` fails because the config does not declare Sv39, so Sail
reads `sstatus.SUM` as 0. `Zalrsc-sc.w`/`sc.d` fail because any store between LR and SC clears the reservation. The
rv64im config stays as tracked. Regression: core 132/132, reference 76/76.

The exit gate (2026-10-29), the core against the reference, Verilator, four memory configurations, on a snapshot of
`0e3491a` (the RTL is the tree of `33a2420`):
- The FP profile with interrupts and the debug script (`--seed 21`): 2,500 x 4, 9,996 pass, 460 M retirements, 14.7 M
  interrupt entries. The other four are one program, `random_210022`, in every configuration: it never ends, and the
  cores agree on every retirement of it (2.6 million in a 12-million-cycle run). Its `sret` idiom had a 32-bit `li`
  crossing into a code page with A clear between `csrw sepc` and `sret`; the fetch fault went to S and overwrote `sepc`,
  so the `sret` returned into its own window for ever. P8's fix had kept only `csrs` and `sret` together; the whole
  window is one aligned 32-byte block now (`2235435`), and the regenerated program ends after 38,281 retirements.
- `--mem-dense` (`--seed 22`): 1,000 x 4, 3,998 pass, 335 M retirements. The other two are `random_220742` in the two
  8-wait-state configurations, where it reached the 12-million-cycle budget at 724,099 retirements, all matched. With
  40 million cycles it passes at 828,337 retirements, as it does without wait states.
- Late interrupt and halt visibility (`--irq-late --dbg-late`): 2,000/2,000 (81 M retirements). Interrupt injection off:
  2,000/2,000. An M-mode body: 2,000/2,000. Icarus, 24 x 4: 96/96.
- The reference against itself, 50 x 4: 200/200. The corruption self-test catches every field class (1-14) at the
  targeted record; the kill matrix catches 17 of 17.
- The corpora, from the fixed generator: the F/D ACT ELFs (`--corpus act-fd`, 337) x 4: 1,348/1,348; ACT, the firmware
  and 100 random FP programs x 4: 872/872; the smc, irq and dbg corpora x 4: clean. A fresh batch (`--seed 32`, FP
  profile, 500 x 4): 2,000/2,000 (89 M retirements, 2.8 M interrupt entries).

The FPU itself: the full TestFloat set (`verification/fpu/README.md`), 1,346,913,440 vectors, 0 failures. riscv-formal
after F/D: every model clean (`../riscv-formal/quantiumv_pipe/README.md`).

### ACT with Sv39 and PMP: errata E4 to E9

Both ACT configs declare Sv39 (with Svade) and PMP (4 entries, G = 0) since `766840c`. Sail then holds the PMP and
Sv39 tests to the real rules, and six places where both cores were wrong showed up. Each is fixed in both, as an
erratum (`../reference/README.md`, the errata log):
- E7 (`56646b4`): the PMP CSRs RV64 does not have (`pmpcfg1`, `pmpcfg3`-`pmpcfg15`, `pmpaddr16`-`pmpaddr63`) are
  illegal.
- E4 (`eb3a662`): `mtvec`/`stvec` MODE is WARL {0, 1}, and an interrupt taken with MODE 1 goes to BASE + 4 * cause.
- E5 (`8643c4d`): a PMP region that holds part of an access fails it, in M mode too.
- E6 (`9e1f90e`): fetch PMP checks each 2-byte parcel, and a fault in a 32-bit instruction's second parcel reports
  pc + 2 (B10's pc + 8 is gone).
- E8 (`a0f066e`): `mcounteren`/`scounteren` keep CY, TM and IR (bits 2:0); they stored all 64 bits.
- E9 (`134ed92`): `menvcfg`/`senvcfg` keep FIOM (bit 0); they were unmapped. The bit has no effect, since neither
  core lets an I/O access pass a memory access or the reverse.

E8 and E9 were found one after the other by the F/D config's `S-00`, which stops at its first failed check. It still
fails after them, on `satp`: Sail always has a 16-bit ASID and the cores have none (the reason
`sv39_satp_access_test` fails), which is right for TLBs without ASID tags. With FIOM writable it matches Sail up to
that check.

ACT after E4-E7: 198/200 (rv64im) and 422/426 (F/D), the same on both cores; the failures are listed in the top-level
README.

What else they touched:
- `qvgen` gave `mtvec`/`stvec` MODE 1 on some seeds, which the cores used to ignore. With E4 an interrupt went to
  BASE + 4 * cause, into the middle of the handler, and the program never ended (the `f5_lockstep` baseline on
  `random_10002`, with both cores agreeing). A MODE-1 xtvec now points at a table of 16 jumps to the handler
  (`1da317e`).
- The seven decode mutation specs had not compiled since F5 (their file lists lacked `qv_fp_dec.sv`); fixed with the
  re-anchoring in `211b0a8`. Two decode mutants on the second parcel's page then survived (crossing decided by `pc[2]`
  alone; the second parcel always on the second dword's page). `qv_decode_tb` gained the two non-crossing cases
  (`b0d5ef1`), and every touched spec is killed in full.
- The lockstep ACT lists name the regenerated ELFs (`6dd99b0`): 200 and 426.

The gate for E4-E7 (2026-10-30), the core against the reference, Verilator, four memory configurations, on a
snapshot of `211b0a8`:
- The FP profile (`--isa imafdc --priv msu --pmp --irq --smc --sv39` with interrupts and the debug script, `--seed
  31`): 500 x 4 = 2,000/2,000, 92.5 M retirements, 2.9 M interrupt entries.
- An M-mode body with PMP (`--isa imafdc --priv m --pmp --irq --smc`, `--seed 32`): 300 x 4 = 1,200/1,200, 16.2 M
  retirements.
- The corpora x 4: the F/D ACT ELFs (426) 1,704/1,704; ACT (200), the firmware and 100 random FP programs (307)
  1,228/1,228; the smc, irq and dbg corpora clean.
- The reference against itself, 50 x 4: 200/200. The corruption self-test catches every field class (1-14) at the
  targeted record; the kill matrix catches 17 of 17.
- Regression on `297a84f`: core 133/133, reference 77/77.

After E8 and E9 (`f555cb6`): regression core 133/133, reference 77/77; ACT 198/200 and 422/426, the same on both
cores; lockstep, fresh seeds, on a snapshot of `f555cb6`: the FP profile 200 x 4 = 800/800 (37.1 M retirements, 1.2 M
interrupt entries), act-fd 1,704/1,704 and the 307-program corpus 1,228/1,228.

### Erratum E10 and Zicntr

- E10 (`78d77d1`): an access to a CSR that does not exist is an illegal instruction, from every privilege level, the
  read-suppressed forms and rd = x0 included. Both cores read 0 there before and did not trap, which S-mode Linux and
  OpenSBI cannot live with: OpenSBI probes Sstc, Smstateen and others by reading a CSR and watching for the trap, and
  emulates `time` only when reading it traps. The set that exists is Sail's under the ACT configs
  (`../reference/probes/csr_table.txt`, from `csr_probe.py`), in `design/pipe/qv_csr_exists.sv`, which the reference
  uses as a renamed copy; the reference README's errata log has the details and the three places it differs from Sail.
- Zicntr (`1f64710`, on by default since `31d24c6`, `QV_ZICNTR_EN`): `cycle`, `time` and `instret` read `mcycle`, the
  core's new `i_time` input and `minstret`. Below M a read needs its `mcounteren` bit, and in U (and the reserved
  privilege 2'b10) its `scounteren` bit too. In the SoC `i_time` is the CLINT's mtime.
- In lockstep each side's `time` counts that side's own retirements, so a `time` read returns the same value on both
  sides at the same retirement (both cores read a CSR in the cycle it retires); the real mtime counts clock cycles,
  which the two cores spend differently. `qvgen` reads `cycle` only into x0 for the same reason: whether the read traps
  is compared, the value is not. The ACT Zicntr tests read `cycle` into registers, so the lockstep ACT lists leave them
  out; ACT runs them on both cores.

The gate (2026-10-31), the core against the reference, Verilator, four memory configurations, on a snapshot of
`84dfaa5`:
- Regression: core 136/136, reference 78/78. Lint clean. The perf CSVs (M and S builds) are byte-identical. The RVFI
  diff: 150/150.
- ACT: 202/204 and 426/430, the same on both cores (the four Zicntr tests pass). OpenOCD smoke: 29/29 on both cores.
- Lockstep, fresh seeds:
  - the FP profile 500 x 4 = 2,000/2,000 (90.8 M retirements, 2.8 M interrupt entries);
  - an M-mode body with PMP 300 x 4 = 1,200/1,200 (16.8 M retirements);
  - the corpora x 4: act-fd 1,704/1,704, ACT + firmware + 100 random 1,228/1,228, and the smc, irq and dbg corpora clean.
- The reference against itself, 50 x 4: 200/200. The corruption self-test catches every field class (1-14). The kill
  matrix catches 18 of 18 (mutant 18: U ignores `scounteren`).
- Mutation:
  - `e10_unit_csr_exists` 23/23, `zicntr_unit_decode` 11/11, `zicntr_unit_csr_file` 6/6, and every decode spec in full;
  - `zicntr_lockstep` 12/12. Two of those needed stimulus first: an M-mode body for M's ungated read, and the
    privilege-2 `scounteren` idiom (`59bd40f`). That generator was then checked on its own: FP profile 200 x 4, M body
    100 x 4 and REF vs REF 25 x 4, all clean.
- riscv-formal: `../riscv-formal/quantiumv_pipe/README.md`.

### O2: the load/store queue (branch `OOO`)

What the head waited for in memory ops was 20-47 % of the kernels' cycles, and reservation stations alone (O1) would
have recovered only a few per cent of it, so O2 came first. An oracle LSU that started plain RAM loads before the head
(`run_perf.sh --oracle early`, `oracle_lsu.sv`, both since removed) bounded the gain at 9-31 % on six kernels; then, each slice behind its
own knob (every one off reproduces the core before it, cycle for cycle; all four perf CSVs are byte-identical with
`QV_PIPE_LSQ_DEPTH=0`):
- O2.1 (`d0b7ed0`): a FENCE ordering writes before reads drains the store buffer at commit.
- O2a-0 (`641f437`): `qv_lsq` holds the memory ops from dispatch to retirement (4 entries) and hands `qv_lsu`, still
  the one engine, one at a time; each op's result waits in its entry until it retires.
- O2a-1 (`8637771`, `QV_PIPE_LSQ_EARLY`, `_EARLY_ST`): a plain load from RAM starts, and a plain store to RAM is
  posted, before the head once no barrier is older; the queue's posted entries join the store buffer's match;
  `o_debug_mode` waits for the port to be quiet.
- O2b (`29764f7`, `QV_PIPE_LSQ_HANDOFF`): the LSU takes its next op in the cycle the last completes on the bus or is
  posted.
- O2c (`50591f0`, `QV_PIPE_LSQ_PRE_XL`): while the LSU leaves the data TLB's port free, the queue looks up its oldest
  op there (no walk) and the LSU takes it translated.
- O2d (`e2acd16`, `QV_PIPE_LSQ_BYPASS`): the LSU's writeback is a bypass source in issue.
- O2e (forwarding from older stores) is not built: the queue's counters (`baseline_pipe*_lsq.csv`) show loads waiting
  for an older store to their dword in one kernel only (trap, about 8 % of its cycles on the SoC).

The gate (2026-11-01), the core against the reference, Verilator, four memory configurations, on a snapshot of
`6b78b8b`:
- Perf: with `QV_PIPE_LSQ_DEPTH=0` the four CSVs are byte-identical to the ones before O2; with the queue on no kernel
  is slower in either build or configuration (`../perf/README.md`).
- Regression: core 147/147 with the queue on, with it off, and with each of `QV_PIPE_LSQ_EARLY`, `_HANDOFF`,
  `_PRE_XL` and `_BYPASS` off; reference 78/78. Lint clean. The RVFI diff: 150/150.
- Lockstep, fresh seeds:
  - the FP profile 500 x 4 = 2,000/2,000 (87.7 M retirements, 2.71 M interrupt entries); with `--mem-dense`
    2,000/2,000 (186.4 M, 5.31 M); the late modes 2,000/2,000 (83.1 M, 2.45 M); an M-mode body with PMP 300 x 4 =
    1,200/1,200;
  - 100 x 4 each with the queue off, with early accesses and the handoff off, with early stores and the handoff off,
    and with pre-translation and the bypass off: 400/400 each;
  - the corpora x 4: act-fd 1,704/1,704, ACT + firmware + 100 random 1,228/1,228, dbg 800/800, smc and irq clean.
- Mutation: `o21_unit_commit` 10/10, `o2a_unit_lsq` 24/24 (+2 equivalent), `o2a_unit_lsu` 16/16, `o2a_unit_lsu_ld`
  1/1, `o2a_unit_lsu_nosb` 3/3, `o2b_unit_lsu` 7/7, the pre-translation specs 14/14, the bypass specs 8/8. The
  older LSU and commit patterns that O2 moved are re-anchored, and every pattern of every spec still matches
  (`check_patterns.py` 1,056/1,056).
- Module proofs (`verification/formal/pipe/run.sh --mutants`): 20 of 20 tasks PASS, the queue's `bmc` and `cover`
  among them, and all 68 known-bad versions are caught (9 of them the queue's).
- riscv-formal: `../riscv-formal/quantiumv_pipe/README.md`.

### O1: out-of-order issue (branch `OOO`)

Dispatch and commit stay one a cycle and in order; what changes is that a uop whose operands are not ready no longer
stops everything behind it. Each slice is behind a knob, and `QV_PIPE_RS_DEPTH=0` is the core before O1 cycle for
cycle (the six perf CSVs are byte-identical to the ones before the switch):
- O1.0 (`057d2a2`, `9fdd2c9`): `+ILPTRACE` and a trace-driven model (`../perf/ilp.py`) said out-of-order issue alone
  buys about 1 % on the kernels, and that the D$ write path was the bigger lever at one-wide; the D$ store
  pass-through (`ad0b820`) came first.
- O1.1 (`9e5af95`, then `f541ab2`, `2441a3b`): the RVFI source values stop living in an issue-time shadow. The plan
  read them from `regfile0` at commit; that made every riscv-formal instruction check as hard as `reg` (`insn_add`
  over 2 h of CPU against about 5 min), so the core keeps each uop's operands by ROB index instead: recorded at
  dispatch when they are ready, and when the unit takes them when they had to wait.
- O1a (`9ddc83c`): `qv_rs`, a 4-entry station (2 under `QV_FORMAL_SMALL`). Oldest ready first on each port (ALU or
  BRU, divide, FPU), divides and FP divide/square root in program order, woken by every writeback bus and by a commit
  bus (a CSR result, which exists only at commit).
- O1b (`26ef0c2`): issue sends a uop to its unit at dispatch when it can, and to the station otherwise.
- O1c (`b46c1d2`, `QV_PIPE_LSQ_WAIT`): a memory op dispatches with its address or store data still to come and waits
  for them in the load/store queue, woken like the station; the engine is offered the oldest op only once both
  operands exist (a load's own writeback counts in its cycle, so pointer chasing keeps its handoff).
- O1d (ROB 16) is not built: issue stops on a full ROB in 1.2 % of the window cycles on the SoC, and the model gives
  -1.6 % against -1.0 % for the geometric mean.
- The station is on by default from `23e74da`. Results: `../perf/README.md` ("The reservation station").

Unit tests and proofs: `qv_rs_tb` and `qv_lsq_opw_tb` predict every port every cycle against exact golden models;
`rs_props` (k-induction: a per-tag ghost, each uop delivered exactly once with its producers' values, no lost wakeup,
oldest first, divides in order) and `lsq_props` with `LSQ_OPW` (the engine takes an op only once both operands exist,
with their values; a BMC at depth 10). Mutation: `o1a_unit_rs` 29/29 and 11 formal mutants, `o1b_unit_issue` 10/10
(+1 equivalent), `o1c_unit_lsq` 11/11. Stimulus: `qvgen --ooo` and `gen_alu.py --ooo` (long producers
followed by independent work and delayed consumers, WAW/WAR in a divide's shadow, two divides with the younger ready
first, addresses and store data from a divide, CSR reads feeding loads, pointer chasing).

The exit gate (2026-11-05 to 2026-11-10), the core against the reference, Verilator, four memory
configurations, on a snapshot of `7eb955f`:
- Perf: with `QV_PIPE_RS_DEPTH=0` the six CSVs are byte-identical to the ones before the switch; with the station on
  no SoC kernel is slower and instret is unchanged.
- Regression: core 162/162 with the station on and with it off; reference 79/79. Lint clean. The RVFI diff with
  `--ooo`: 150/150. OpenOCD smoke 29/29 on both cores; `make run` on both.
- ACT: 202/204 and 426/430 on the core, the known fails (S-00 and `sv39_satp_access_test` in both configs, the two
  Zalrsc SC tests in the FD config).
- Lockstep, fresh seeds:
  - the FP profile 2,500 x 4 = 10,000/10,000 (453.4 M retirements, 14.18 M interrupt entries); with `--ooo` 2,000/2,000
    (85.0 M, 2.75 M); with `--mem-dense` 4,000/4,000 (370.6 M, 10.60 M); the late modes 2,000/2,000 (80.8 M, 2.49 M);
    interrupts off 2,000/2,000 (31.3 M); an M-mode body 2,000/2,000 (27.2 M, 0.92 M);
  - 100 x 4 each with the station off, with the queue's wait off and with an 8-entry station: 400/400 each;
  - the corpora x 4 (act-fd 1,704, act + fw + 100 random 1,228, smc, irq, dbg 800) all pass; Icarus 24 x 4 96/96;
    REF vs REF 200/200, the corruption self-test catches every field class at the targeted retirement, the kill
    matrix 18/18.
- Mutation: the end-to-end specs `p5a_e2e` 12/12, `p5b_e2e` 14/14, `f5_lockstep` 17/17. `check_patterns.py` found four
  patterns in `o1b_unit_issue` and `o2c_unit_lsq` that O1c had left matching nothing; they are re-anchored
  (`c38347e`, both specs 11/11 again) and all 1,127 match.
- Module proofs and riscv-formal: run separately (they take days); their results go to
  `../riscv-formal/quantiumv_pipe/README.md` ("After O1").

### O4: two-wide (branch `OOO`)

Two uops are dispatched, issued to two ALU ports and committed a cycle. Each step is behind a knob, and with every O4
knob at 1 (`QV_PIPE_COMMIT_W`, `QV_PIPE_DISPATCH_W`, `QV_PIPE_ALU_PORTS`, and `QV_PIPE_SB_YIELD_READY=1`) the six perf
CSVs are byte-identical to O1's:
- O4.0 (`f61f4c5`): the pair rules as model knobs. Together they cost under half a point, so all of them went in:
  one memory op and one FP-state uop per dispatch pair, CSR/SYS/FENCE/divide/FP divide/atomic/trapping uops alone,
  branches and multiplies on port 0; the second retirement never traps, and a pair writes FP state once.
- O4a (`9239d02`, `519bdc5`, `60ceeb7`): the width knobs and an RVFI channel per retirement; the tracer prints one
  line per channel; lockstep mode B, where the reference sees interrupts, halts and MAGIC clears only at the
  boundaries of the core's retirement groups (a level raised after retirement K would otherwise stop the reference
  after K and the core after K+1). The late modes stay cycle-delayed on the core's side, so a core that samples late
  still diverges.
- O4b (`2e49d50`, `d61090b`): two retirements a cycle. `qv_commit`'s pair rule (the head retires plainly; the second
  is complete, takes no trap, is no CSR, SYS, FENCE or atomic; one posted store, one control-flow instruction and one
  FP write per pair), two pops in the ROB and the queue, a second producer-table clear, and the LR/SC reservation
  cleared by a store in either slot.
- O4c (`b58765c`): two dispatches. `qv_decode2` holds two uops; a slot-1 uop that reads slot 0's destination takes a
  station entry (its value exists only next cycle) and its operand is never late (a stale late bit would wake only on
  the commit bus, which carries slot 1 only, and the core would hang).
- O4d (`2eedfd4`, `dbe87b6`): one copy of the waiting-operand rules, shared by issue, the station and the queue; the
  second ALU port (no multiplier, no branches).
- O4e (`84b5831`, `0591205`): two-wide by default. The 23 regression rows that place events at exact retirements run
  at one retirement a cycle (`-DQV_PIPE_COMMIT_W=1`), and the one-channel riscv-formal models pin it.
- O4f (`656580e`): the store buffer's drain yields only to a load near the head (`QV_PIPE_SB_YIELD_READY=0`); see
  `../perf/README.md` ("Two-wide").
- Results: `../perf/README.md` ("Two-wide").

Unit tests and proofs: `qv_commit_pair_tb` (the pair rule), `qv_dispatch2_tb` (the dispatch pair rules and port
allocation against a golden model), `qv_decode2_tb`, the ROB, IQ and station rows at two pushes and two pops, `rs2_props`
(the station with two pushes and two ALU ports: port 1 exactly once, never a multiply, no lost wakeup), `sb_props` at
the new drain rule. Mutation: `o4b_unit_commit` 42/42, `o4c_unit_issue` 53/53, `o4c_unit_decode2` 11/11, `_fifo` 5/5,
`_rob` 9/9, `o4d_unit_issue` 16/16, `_rs` 12/12, `_wake` 13/13, `_wake_lsq` 5/5, `o4f_unit_sb` 3/3; seven `rs2` and one
`sb` formal mutants. Stimulus: `qvgen --pair` (runs of independent ALU ops, dependent and same-destination pairs, a
multiply, a memory op or a branch in either slot, an FP op beside an integer one, LR / ALU / store / SC).

The exit gate (2026-11-11 to 2026-11-13), the core against the reference, Verilator, four memory configurations, on a
snapshot of `272882c` (two-wide by default):
- Perf: with every O4 knob at 1 the six CSVs are byte-identical to O1's; at the default no SoC kernel is slower and
  instret is unchanged.
- Regression: core 183/183 at the default and 183/183 with every O4 knob at 1; reference 79/79. Lint clean (three
  builds). The RVFI diff with `--ooo`: 150/150. OpenOCD smoke 29/29 on both cores; `make run` on both.
- ACT: 202/204 and 426/430, the known fails (S-00 and `sv39_satp_access_test` in both configs, the two Zalrsc SC tests
  in the FD config).
- Lockstep, mode B, fresh seeds (`--pair --ooo` on the FP Sv39 profile with interrupts and the debug script):
  - 2,500 x 4: 9,996 pass (342.9 M retirements, 11.07 M interrupt entries); with `--mem-dense --pair` 1,000 x 4:
    3,996 (250.8 M, 7.28 M); the late modes 500 x 4: 1,996 (61.2 M, 1.86 M); interrupts off 500 x 4: 2,000/2,000
    (24.6 M); an M-mode body 500 x 4: 2,000/2,000 (22.1 M, 0.74 M); every O4 knob at 1, 100 x 4: 396 (14.3 M); one
    retirement a cycle, 100 x 4: 400/400 (14.4 M);
  - the corpora x 4 (act-fd 1,704, act + fw + 100 random 1,228, smc, irq, dbg 800) all pass; Icarus 24 x 4 96/96;
    REF vs REF 200/200; the corruption self-test catches every field class at the targeted retirement; the kill
    matrix 18/18.
  - The 4 programs the gate flagged, one each in the 2,500 x 4, mem-dense, late-mode and every-knob-at-1 stages, were
    invalid stimulus, not the core: `qvgen --pair`'s "a load or a store beside an ALU op" put an ALU op between the address
    setup and the access, and the ALU op could write the address register (`li x21, ...; subw x21, ...; sd x17,
    0(x21)`), a wild store into the trap handler's code with no FENCE.I. Where the I$ held the old code the cores
    fetched different bytes (a FAIL on the cache configuration); where both saw the new bytes they agreed on every
    retirement and the corrupted handler never ended (a TIMEOUT). `smc_hazard.py` and a scan of every retirement
    found the store in all four. Fixed in `ce711b2`; on the fixed generator the four programs, regenerated, pass on all four
    configurations, and fresh batches pass in full: FP + pair + ooo 500 x 4, mem-dense 300 x 4, the late modes
    200 x 4 and every O4 knob at 1 100 x 4 (3,600 programs).
- Mutation: `check_patterns.py` 1,283/1,283; the end-to-end specs `p5a_e2e` 12/12, `p5b_e2e` 14/14, `f5_lockstep`
  17/17.
- Module proofs and riscv-formal: run separately; their results go to `../riscv-formal/quantiumv_pipe/README.md`
  ("After O4").

### O3: recovery at execute (branch `OOO`)

A mispredicted branch recovers when it writes back, not when it retires: the next cycle (the kill cycle) everything
younger is killed and fetch restarts at the resolved target; commit then retires the branch without a redirect. Behind
`QV_PIPE_EXEC_REDIRECT` (default 1 since O3i; with it at 0 the six perf CSVs are byte-identical to O4's).
- O3a-c (`e6ad670`, `63b6ce0`): the kill network. The ROB marks every tag younger than the branch (`o_kill_vec`, in the
  ROB's own pointer width) and rolls its tail back to the entry after it; the ALU and branch units, the divider, the
  FPU's pipeline and its divide/square-root unit, the station, the load/store queue and the LSU drop what they hold for
  a killed tag in the kill cycle (an early load on the bus drains, writing nothing back; nothing killed starts). The next
  allocations reuse the killed tags, so nothing may carry one past the kill cycle. `e6ad670` first fixed the LSU's
  distance to the head, which was taken in the tag's width and so wrong for a ROB smaller than 8 (the formal models).
- O3d (`1d00d11`): the producer tables are rebuilt from the surviving ROB entries, not checkpointed: each register's
  producer is the youngest survivor that writes it (`late` for a CSR op), from this cycle's new head through the
  branch. Exactly the state the claims and the tag-matched clears keep, with no limit on branches in flight.
- O3e (`319077d`): the speculative return-address stack is circular (an index, a count and the entries); each
  instruction carries the stack as it left it (`ras_snap_t`) to the ROB, and a recovery restores the index, the count
  and the top entry (`QV_PIPE_RAS_REPAIR` 2; 1 in the formal models). With no restore it is the old shift stack.
- O3f (`405d4f2`): the redirect. `x_q` catches a mispredicting writeback of the branch unit; in the next cycle the
  ROB, issue (the rebuild), the queue and the RAS recover, align, the IQ and decode are flushed, nothing is dispatched,
  and fetch takes the target (a redirect from commit wins over it, and it over the aligner's). A commit redirect in
  either cycle wins: it flushes the branch too. An older branch that writes back in a kill cycle survives it and is
  caught for the next. Program Buffer runs keep the commit redirect.
- The early restart (`e16cc89`, `QV_PIPE_XR_EARLY`, default 1 since O3i): fetch and the frontend restart in the mispredict's
  writeback cycle, straight from the branch unit, while the kill stays in the next cycle; the model put it at 1.4
  points and it measured -1.4 % (M) and -1.3 % (S) on the SoC.
- Stimulus: `qvgen --xr` (`128e667`): forward branches that are always taken but resolve late (a divide by x0, or a
  load of the branch's own encoding), so the static prediction mispredicts and the block they skip runs only
  speculatively: stores, loads, AMOs and LR/SC to the sandbox, divides, FP divides, FENCE and FENCE.I, CSR reads,
  ECALL / EBREAK / illegal words, a device read, a nested branch that recovers first; the join reads what the block
  wrote. Everything in a block is harmless if it ever runs for real.
- Results: `../perf/README.md` ("Recovery at execute").

Unit tests: `qv_rob_tb` (kills at every pointer position, a kill as the branch retires, flush beats kill, the
recovered mark), `qv_exu_bru_tb` / `qv_exu_div_tb` / `qv_exu_fpu_tb` (kills in every unit and stage), `qv_rs_tb`
(random suffix kills), `qv_lsq_tb` (rollback, a reused tag), `qv_lsu_early_tb` (a waiting op dropped, an early load
drained, a kill in the would-be start cycle and in the response cycle), `qv_lsu_sb_tb` with a ROB of 4 (the distance
fix), `qv_rebuild_tb` (issue and the ROB through random kills, the tables against their definition after every
edge, ROB 8/4/2), `qv_ras_tb` at REPAIR 1 and 2 (the old checks unchanged, the snapshots, restores), `qv_commit_tb` /
`qv_commit_pair_tb` (a recovered mispredict retires without a redirect, and still alone).
Proofs: `kill_props` (issue's tables and the ROB's kill together, at ROB 2, 4 and 8), `ras_props` (the circular stack against
the shift stack it replaced, proved), and the kills added to `rs_props`, `rs2_props`, `lsu_props`, `lsq_props` and
`fpu_props`; their 17 known-bad versions are caught (`ed51c45`). The queue's kill BMC reached depth 13 of 14 (its last
step takes hours); the others prove. The core's `RISCV_FORMAL` block asserts the kill cycle's rules (nothing killed is requested,
offered or written back, nothing is dispatched, the branch is a live recovered mispredict whose target fetch takes) and
that what the LSU and the divider hold is always a live entry.
Mutation: 18 unit specs `o3*_unit_*.json`, 55 killed and 1 equivalent; `o3_lockstep.json` 14 of 15 killed
and one equivalent (the early restart flushes decode a cycle before the kill, so nothing can dispatch in it).
Gate, with both knobs on (on a snapshot of `ff03e52`): perf with the knobs off byte-identical; regression 190/190, and
190/190 with the O4 knobs at 1; RVFI diff 150/150; lockstep, the FP Sv39 profile with `--pair --ooo --xr`, 2000/2000
over the four configurations, the late modes 1200/1200, interrupts off and the M-mode body 300 x 4 each, the O4 knobs
at 1, the registered restart and the knobs off 100 x 4 each, the corpora x 4 (the 426 ACT ELFs, ACT + firmware + 100
random, smc, irq, dbg), REF vs REF 50 x 4 on the same stimulus. The M-mode stage found a generator bug, not a core bug: an ALU op placed before the always-taken branch could
write the branch's own register, so the wrong path ran for real and its device read diverged (`e676840`).
riscv-formal: the models with recovery at execute and the early restart (`pipe`, the RAM-window, two-wide and
station-off models) run separately; their results go to `../riscv-formal/quantiumv_pipe/README.md` ("O3").

### O8: the frontend (branch `OOO`)

Three knobs, each on by default since O8 closed; with all three at 0 the six perf CSVs are byte-identical to O4's. No fetch
target queue: the fetch buffer's depth changes nothing on the kernels (the I$ answers a hit the next cycle and fetch
already streams). 16-byte fetch (O8d) was not built (`../perf/README.md`, "Global history").
- O8b (`df88b8a`, `QV_PIPE_ALIGN_WIN`): `qv_align2` aligns over the fetch buffer's head and the entry behind it when
  that one is its sequential successor (no hint ends the head, no fault on either), so its two slots take any two
  instructions in those 16 bytes and a 32-bit instruction crossing a dword goes out without a stash cycle. When the
  next entry cannot be used it still stashes the head's last halfword and pops the head, as before (a walk outside RAM
  for the next dword waits for the frontend to be empty, so holding the head would deadlock). `qv_fetch` (additive)
  shows the second entry and pops two; with the window it sends a request from an idle bus in the cycle it issues it
  (`b51300a`; `62591e1` keeps that from raising `cyc` in reset); `c733123` removes a branch the proof showed dead.
- O8c (`95b3321`, `QV_PIPE_BTB_CTR`): a 2-bit direction counter per BTB entry; a conditional entry steers fetch only
  while its counter says taken, and a fall-through counts down instead of removing the entry.
- O8a (`fe842cd`, `93d4d2e`, `QV_PIPE_GSHARE_H`): `qv_gshare`, 4,096 counters indexed by the pc and 12 bits of
  history, read in the aligner (one conditional branch an aligner cycle); only a strong counter overrides the per-pc
  table. Each instruction carries the history before it (in `ras_snap_t`): a recovery at execute restores the branch's
  history and its resolved direction, a commit flush copies the committed history. At every training commit the core
  checks that the instruction's snapshot equals the committed history (a `$fatal` in simulation, an assertion in the
  formal models), so every run checks the history; it found that a branch predicted taken to its own fall-through
  never mispredicts, which now counts as not taken.
- Tests: the aligner testbenches drive `qv_align2` too (`9ecc5ac`, the window rows), the hint testbench checks that a
  hint is taken up on exactly its own instruction (`2ef2a30`), `qv_btb_tb` with the counter (`de10d09`), `qv_gshare_tb`
  against a model at both sizes (`7a50ce5`, `4ecc2d9`); `qvgen --win` (`b76a3dc`: 32-bit instructions crossing
  dwords, branch targets at every halfword, two branches in a dword).
- Mutation: `o8b_unit_align2` 18/18 (17 by the hint testbench, 1 by the `align2` proof), `o8c_unit_btb` 10/10,
  `o8a_unit_gshare` 15/15; four `p9c` BTB patterns and two fetch patterns re-anchored.
- Proofs: `align2` (`95d193c`: `qv_align2` against a model fetch buffer whose data are a function of their pc; what it
  emits is the program-order decode, nothing skipped or repeated, by k-induction on a small model) with `fetch`'s
  window tasks, and `gh` (`5d0ed85`: the history against a ghost of the predictions in flight through kills and
  flushes, by k-induction), with four `align2`, eight window `fetch` and five `gh` known-bad versions in `run.sh
  --mutants`. Their results and the riscv-formal models with the O8 knobs: `../riscv-formal/quantiumv_pipe/README.md`
  ("O8").
- Results: `../perf/README.md` ("The window aligner", "The BTB's direction counter", "Global history").

The gates, the core against the reference, Verilator, four memory configurations:
- O8b (on a snapshot of `3cb2a4a`, the window and O3's knobs on): with the knob off the six CSVs byte-identical;
  regression 194/194 at the default width and with every O4 knob at 1 (one row ran into its 1,800 s limit on the loaded
  machine and passed alone); the RVFI diff 150/150; REF vs REF on the `--win` stimulus 50 x 4 twice (the FP and the
  M-mode bodies); lockstep with `--pair --ooo --xr --win` on the FP Sv39 profile 500 x 4, the late modes 300 x 4,
  interrupts off 300 x 4, an M-mode body 300 x 4, every O4 knob at 1 100 x 4, the window off on its stimulus 100 x 4,
  the corpora x 4 (act-fd 426, act + fw + 100 random 307, smc, irq, dbg 200): all pass. `check_patterns.py`
  1,352/1,352.
- O8 as a whole (on a snapshot of `cd7f5b2`, all three knobs and O3's on): with the knobs off the six CSVs
  byte-identical; regression 197/197 and 197/197 with every O4 knob at 1; the RVFI diff 150/150; lockstep 500 x 4, the
  late modes, interrupts off and an M-mode body 300 x 4 each, every O4 knob at 1 100 x 4, the corpora x 4: all pass.
  `check_patterns.py` 1,395/1,395.

### O5a: the D$ inside the core (branch `OOO`)

`QV_PIPE_DCACHE=1` puts a D$ beside the LSU, and `QV_PIPE_LSQ_DEPTH=8` grows the queue (both the defaults since O5/6
closed; with `QV_PIPE_DCACHE=0 QV_PIPE_LSQ_DEPTH=4` the six perf CSVs are O8's byte for byte). The rest of O5/6
(out-of-order memory issue, speculative loads, forwarding, critical word first, misses that do not block, a second
port) was measured not worth it
at this window and is not built (`../perf/README.md`, "The D$ inside the core").
- O5a-0 (`527fbda`): `qv_dc`, direct-mapped, write-through, no allocate (2 KiB: 64 lines of 32 bytes; 2 x 2 under
  `QV_FORMAL_SMALL`). A lookup has no handshake (the dword comes back in the cycle its address is presented); a miss
  refills its line over the memory port in four beats, one at a time, each dropped in its response cycle; the store
  buffer's beats update a held line in their response cycle; the LSU's own writes that bypass the buffer empty their
  line; a snoop (a Debug Module write) empties its line and, if it is the line being refilled, keeps the refill from
  installing it. `cache_complex`'s `DC_EN 0` passes its data port straight to memory.
- O5a-1 (`9f7eb38`): in `qv_lsu` (`DC_EN`, additive), a plain RAM load that could start its access completes in that
  very cycle on a hit and the engine takes the next op at once; a miss asks for the refill and completes with its
  dword. A flush or a kill during a refill waits for it in DRAIN (a refill is never abandoned), and a refill is a RAM
  read, so an interrupt or a halt may find one in flight. Atomics, device accesses and Program Buffer accesses still
  go to the bus at the head. The core adds the D$ as a fourth master of the memory port (the LSU, the walker, the
  store buffer and the refill never drive it together), the walker and the buffer's drain wait for it, and the Debug
  Module sees the hart halted only once no refill is in flight. In the SoC, `cache_complex`'s own D$ is left out
  (`DC_EN 0`) and the Debug Module's RAM writes snoop the D$. The queue hands a same-cycle lookup hit to the engine
  (`XL_FWD`): without it every translated hit in S mode paid a lookup cycle.
- Tests (`b8fe256`, `044624c`): `qv_dc_tb` against a golden memory (directed cases and 40,000 random cycles at three
  sizes, slow and erroring memories, snoops racing refills), `cache_complex_tb` with `DC_EN 0`, `qv_lsu_dc_tb`,
  `core_dc_tb` (load-to-use, a pointer chase over held lines with no bus access, stores draining while loads of their
  line hit, two lines that share an index, an interrupt and a halt during a refill; the hart never shows as halted
  while a refill runs), a fifth phase of `soc_sba_running_tb` (Debug Module writes to lines the hart
  reads); `core_lsq_tb`'s bus-order checks become relations with the D$ on; `qvgen --dc` (two lines of the sandbox
  2 KiB apart: every dword of a line just missed, evictions, stores to held and to evicted lines, atomics, LR and SC on
  held lines); the lockstep build audits the D$ against RAM at every halt.
- Mutation (`a92989a`, `c6733d1`): `o5a_unit_dc` 18/18, `o5a_unit_lsu` 15/15, `o5a_unit_lsq` 3/3; the LSU and queue
  specs whose lines O5a-1 touched are re-anchored.
- Proofs (`3258160`): `dc_props` (`qv_dc` against a shadow of one dword: every valid copy equals what the core may see,
  a fill equals memory at the beat that read it, no install after a snoop or an error, the beat protocol), proved at
  2 x 2 and checked to a bound at 4 x 4, with 11 known-bad versions; the `pipe-dc` riscv-formal model (the RAM window
  and the D$ on). Their results: `../riscv-formal/quantiumv_pipe/README.md`.

The gate (2026-11-15 to 2026-11-16), on a snapshot of `3140501` with the shipping knobs (O3, O8) and the D$ and the
8-entry queue on:
- Perf: every knob off, the six CSVs byte-identical; with the D$ and the queue, no SoC kernel slower (see the perf
  README).
- Regression 206/207 and, with every O4 knob at 1, 207/207; the one is `core_sv39_random_tb` running into its row's
  1,800 s limit on the loaded machine, and by hand it passes both ways (3,000 iterations, 9,137 checks). Lint clean.
  The RVFI diff with `--ooo`: 150/150.
- Lockstep, the FP Sv39 profile with `--pair --ooo --xr --win --dc --mem-dense`, interrupts and the debug script:
  500 x 4 (499 each: one seed's program did not build), the late modes 300 x 4 (299 each, likewise), interrupts off
  300 x 4, an M-mode body 300 x 4, every O4 knob at 1 100 x 4, the D$ off on the same stimulus 100 x 4, the corpora x 4
  (act-fd 426, act + fw + 100 random 306, smc, irq, dbg 200), REF vs REF 50 x 4: all pass. `check_patterns.py`
  1,431/1,431.
- What the gate found, none of it in the RTL:
  - The M-mode body failed 137 of 300 programs on both cache configurations and none on the SRAM ones, and REF vs REF
    failed the same programs. Without Sv39, `--mem-dense` reads the UART's status register for real, and lockstep's
    cache configuration takes side B's data accesses, devices included, through `cache_complex`'s D$, which refills
    the device's whole line: the MMIO-read logs can never match. `qvgen --no-dev-read` (`facb124`, passed by
    `run_lockstep.sh` on the cache configuration) turns the read into the value it reads; with it the M-mode body
    passes 300/300 on both.
  - One program (`random_5270032`, 775,000 retirements and 28,000 interrupts) ran out of its 12 M-cycle budget at delay
    8 on both memories; it passes at delay 0, and at delay 8 with 40 M cycles on both.

### O7: the big window (branch `OOO`)

The window grows by sizes only: the station stays one collapsing queue, a recovery still rebuilds the producer tables
from the surviving ROB entries, and the queue and the store buffer are unchanged.
- O7a (`d54bc8c`, `b02defa`, `7c6009e`): the ROB's package depth and tag width come from `QV_ROB_MAX` (`qv_pkg.sv`, 32
  since O7c, 8 before) and the core's ROB from `QV_PIPE_ROB_DEPTH` (default: the package depth; 4 in the formal models). A ROB
  larger than its package, smaller than 2 or not a power of two stops the elaboration. Everything that walks the ROB
  (the kill vector, the survivors, the rebuild, the producer tables, the queue's kill and age scans, the LSU's distance
  to the head, the RVFI source values) already read its size from the package or its own parameter; only the station's
  occupancy is new (an issue-level wire for the perf monitor). `run_perf.sh` puts the defines into its build key, so a
  run that changes only `--defines` no longer reuses an earlier build, and the early-load oracle of O2.0 (`--oracle
  early`, which no longer built) is gone.
- Tests (`fa9258e`, `c4e846e`): rows at package 32 and 64 (the ROB at 32, 16 and 8 inside a package of 32; the station
  at 8; the queue at 16 and 32; the units, the commit pair rule and dispatch; the core-level queue, D$ and multiply
  rows at ROB 32); `qv_rebuild_tb`
  kills in alternating phases so a 32-entry ROB is full at a kill, and must see kills that keep or remove more than half
  of it; `qvgen --deep` (long producers, then runs of 10 to 30 independent ops with a reused destination and memory
  ops, a branch over a second run, a late consumer); the lockstep build prints the window it reached (`LS_WIN:`) and
  the gate fails a size whose programs never fill its ROB, never keep or remove more than half of it in a recovery, or
  never fill the queue. A generated body that runs into the trap handlers at address 0x8000 is made again shorter.
- Mutation (`41815b0`): `o7a_unit_rob` 2/2, `o7a_unit_rob_kv` 1/1, `o7a_unit_issue` 1/1, `o7a_unit_lsq` 1/1,
  `o7a_unit_lsu` 1/1, each a literal that is right at package 8 and wrong above it (the survivor loop, the survivor
  count's width, the kill vector's range, the rebuild loop, the queue's index width, the distance to the head);
  `o7a_lockstep` 2/2 at ROB 32 (the RVFI source values indexed by 3 bits of the tag: a mismatch at retirement 127;
  the history check reading the snapshot of the tag modulo 8: the check's own `$fatal`).
- Proofs (`e62d401`): every module proof and riscv-formal model reads the package with `-D QV_ROB_MAX=8`, and every
  formal top checks the package depth, so a forgotten pin stops the elaboration instead of growing the model;
  `pipe-full` also pins the station and the queue at their old depths. The models' results stand.
- O7b: the sizes measured (`../perf/README.md`, "The big window"): ROB 32, RS 8, LSQ 8.
- O7c: these sizes are the defaults (`QV_ROB_MAX` 32, `QV_PIPE_RS_DEPTH` 8; the queue's 8 came with O5/6), after the
  defaults of O3 (O3i), O8 and O5/6 (O5/6z) went on in that order, each with its six perf CSVs.

The O7 gate (2026-11-16 to 2026-11-17), the core against the reference, Verilator, four memory configurations, on a
snapshot of `c4e846e` with `facb124` and `o7a_lockstep.json`, the shipping knobs (O3, O8, the D$) on and the window at
ROB 32, RS 8, LSQ 8:
- Perf at the defaults: the six CSVs byte-identical. Lint clean at the defaults and at the window.
- Regression 238/238 at the window and 238/238 at the defaults; `core_sv39_random_tb` by hand at the window (3,000
  iterations, 9,137 checks). The RVFI diff with `--ooo`: 150/150.
- Lockstep on the FP Sv39 profile with `--pair --ooo --xr --win --dc --mem-dense --deep`, interrupts and the debug
  script: 500 x 4, the late modes 300 x 4, interrupts off 300 x 4, an M-mode body 300 x 4; the same stimulus at ROB 16
  (RS 8, LSQ 8), at ROB 64 (RS 16, LSQ 32), with a ROB of 16 in a package of 32 and at the defaults (ROB 8), 100 x 4
  each; the corpora x 4 (act-fd 426, act + fw + 100 random 307, smc, irq, dbg 200); REF vs REF on the `--deep`
  stimulus 50 x 4: all pass. Two programs of the 100 random ones (`random_7380012`, `random_7380081`: 775,000 and
  907,000 retirements, 28,000 and 36,000 interrupts) ran out of their 12 M-cycle budget at delay 8 on both memories;
  they pass at delay 0, and at delay 8 with 40 M cycles on both.
- The window was reached at every size: the ROB full (in 1,984 of the 2,000 programs at ROB 32), recoveries that kept
  and that removed more than half of it (75,402 and 51,348 of 1.44 M at ROB 32), the queue full.
- `check_patterns.py` 1,439/1,439.

### The complete core: the default flips and the exit gate (branch `OOO`)

The four milestones' knobs became the defaults in the order the plan gave, each as one RTL commit and one results
commit with its six perf CSVs (and the two counter CSVs, `_ox`), each measured equal to its own gate's numbers:
- O3i (`35b7474`): `QV_PIPE_EXEC_REDIRECT`, `QV_PIPE_XR_EARLY` 1.
- O8 (`7e1087d`): `QV_PIPE_ALIGN_WIN` 1, `QV_PIPE_BTB_CTR` 1, `QV_PIPE_GSHARE_H` 12.
- O5/6z (`4d75eb5`): `QV_PIPE_DCACHE` 1 (in `core.sv` and `soc.sv`, so the SoC's bus D$ is left out),
  `QV_PIPE_LSQ_DEPTH` 8. With it (`1bfb618`) the lockstep's D$ audit runs unless `QV_PIPE_DCACHE=0`, and `pipe-sb`
  keeps its loads on the bus.
- O7c (`1b5740c`): `QV_ROB_MAX` 32, `QV_PIPE_RS_DEPTH` 8.

What the exit gate found and fixed:
- `d19ad6d` (and the testbench check `62589bb`): with the SoC's bus D$ left out (`cache_complex` `DC_EN` 0), its idle
  `dcache0` still saw the data port's responses and fired its own "response while idle" check on every one. Icarus only
  prints it, but Verilator stops on it, so the OpenOCD smoke died at its first SBA write (item 8) at the new defaults.
  The D$'s response inputs are gated by `DC_EN` too; OpenOCD is 29/29 again.
- `1be5530`: `lsu prove` was UNKNOWN since O5a (`fill_q` free in the induction step with the D$ arm off); a lemma.
- `428264d`: three module-proof mutants whose lines O3 had rewritten matched nothing; re-anchored, caught.
- `2559e8a`: `p7b_unit_ptw` [6] (a one-byte PMP span for a PTE read) survived its testbench, before the flips too; a
  4-byte region over the PTE's second half kills it.
- `825e239`: since O8's flip the one-entry aligner `qv_align` is not built at the defaults, so its lockstep mutants
  (`p7d_unit_align` in `p7_lockstep` and `p7_lockstep_extra`) cannot show; `p7_lockstep_win0.json` runs them with
  `QV_PIPE_ALIGN_WIN=0`: 13/13 killed.
- `f9a5f9c`: `p5d_lockstep` [27] (the interrupt vector keeps the MODE bits) is unobservable since E4's vector tables.

The gate, on a snapshot of `ab054ef` (the cache_complex fix `d19ad6d` came after it: OpenOCD on `2559e8a`):
- Lint clean at the defaults, with every knob off and on the reference. Perf with every knob off: the six CSVs O4's
  byte for byte.
- Regression: pipe 238/238 and ref 81/81 (seven pipe rows ran past their row time limits on the loaded machine:
  each passes on its own with a 3 h limit, `core_sv39_random_tb` 3,000 iterations, 9,137 checks). RVFI diff with
  `--ooo` 150/150. `make run` on both cores. ACT: 202/204 and 426/430, as committed.
- Mutation at the new defaults: the 110 unit specs 1,373/1,373 (after `2559e8a`); end to end p5a 12/12, p5b 14/14,
  p10c 4/4; the lockstep specs (`--skip-annotated`) all killed or annotated, with `p7_lockstep_win0` 13/13. Six
  lockstep mutants survived that also survive on the tree before the flips (`4dd6c7e`), each killed by its unit
  testbench: a loss of lockstep coverage since P6/P7, not from the flips. The follow-up (`035b32f`..`d3ea65e`)
  placed each:
  - `p6_lockstep` [131] and [132] (the Program Buffer's PMP bypass) need 96 programs: moved to `p6_lockstep_extra`,
    beside [133].
  - `p7_lockstep` [71] (a TLB fill drops R: an execute-only page read with MXR set, then clear) needs 256: the new
    `p7_lockstep_long.json`.
  - `p7_lockstep_extra` [18] (the second parcel's offset) could not show while the high probe page's pocket covered
    the whole page: qvgen `--probe-half` (opt-in, default streams unchanged) puts it over the first half, and an
    entry with it kills [18] within 64 programs (the unmutated core passes 256).
  - `p7_lockstep` [237] (the second parcel always takes the second dword's page) is equivalent in the core: both
    aligners give an instruction that stays in its dword `pg_hi = pg_lo`. Annotated.
  - `p6_lockstep` [52] (a trigger entry that does not give way to an interrupt sampled with it) needs a trigger-marked
    head at a sample point that takes an interrupt: the first one after a resume, with the trigger on the instruction
    after dpc's and an interrupt left pending by the halt. 256 programs did not reach it, nor 256 at
    `--irq-density 4`; debug-script feature 512 (opt-in: a trigger only 2 or 4 bytes past dpc) with density 4 kills
    it within 24, in `p6_lockstep_dense` (the unmutated core passes 256).
- Module proofs on `2559e8a`: 48/48 PASS, 131 known-bad versions caught (`../riscv-formal/quantiumv_pipe/README.md`).
- Lockstep, Verilator, the four configurations (sram/cache x 0/8 wait states), on a snapshot of `1ca38a3`, at the
  smaller size chosen after the second WSL restart (2026-11-22). Before the restarts the full-size gate had passed
  about 9,000 of A's 10,000 runs and about 1,500 of L's 2,000, nothing failing; those results went with `/tmp`.
  - A, the complete core's profile (`--isa imafdc --priv msu --pmp --irq --smc --sv39 --pair --ooo --xr --win --dc
    --mem-dense --deep`, interrupts at density 1), 1,000 x 4: 4,000/4,000. The ROB (32) was full in 3,987 runs;
    2.57 M recoveries at execute, 135,696 keeping more than half of it and 85,520 removing more than half.
  - L (late modes), I (interrupts off), M (an M-mode body), 300 x 4 each: 1,200/1,200 each. Z, every knob off (O4),
    100 x 4: 400/400.
  - The corpora x 4: act-fd 426, act + fw + 100 random 307, smc, irq, dbg 200, all passing. One random program
    (9450011) ran past the 12 M-cycle limit at 8 wait states with 729 k of its 816 k retirements matched; with 40 M
    cycles it passes in all four.
  - Icarus 24 x 4: 96/96, six of them only with a longer wall limit. `run_lockstep.sh` stops a simulation after
    1 h of real time, and Icarus took longer on 9460001 at 8 wait states and on 9460022 in all four configurations;
    with 6 h they pass (232,361 and 249,652 retirements matched). On such a program Icarus also prints about half a
    million `ERROR: design/pipe/core.sv:18xx` lines: the core's `always @*` assertions (O1 to O3) seen on half-updated
    values at a clock edge, which Verilator (stopping on a failed assertion) never reports. That slows Icarus; making
    them sample settled values is a follow-up.
  - REF vs REF 50 x 4: 200/200. The corruption self-test catches every field class at the targeted record
    (retirement fields 1-8 and 13, event-log fields 9-12); the `ref_core` kill matrix 18/18; `check_patterns.py`
    1,439/1,439.

## Where the core differs from ref_core.sv

Architectural behavior is the same: the lockstep gate compares every retirement, a CSR snapshot, the bus
write log and, with `--dbg-mode 1`, the debug-script event log. These differences are known and acceptable.
Below, "the FSM" is `ref_core.sv`, the multi-cycle core that `design/core.sv` used to be, and "the pipe" is
the core, `design/pipe/core.sv`.

Not architectural:
- The pipe prefetches; the FSM does not. Without a FENCE.I, what each fetches from freshly written code is
  unspecified, so a generated program must never store into the code except in the SMC idiom (which has
  the FENCE.I). `lockstep/smc_hazard.py` classifies a failed run's trace as this hazard or not. (The
  first P6 gate found qvgen's `lr rd, (rs1)` with rd == rs1 doing it through the loaded word.)
- Fetch PMP is checked per instruction in decode, not before the bus request; a denied fetch never retires.
- A DIV or FENCE.I that traps on an action-0 trigger: the FSM starts the divider and flushes the icache
  before trapping, the pipe does neither (the flush is harmless).

P9 (store buffer and branch prediction; the retired stream is the same, the timing is not):
- A plain store to RAM (the physical window `PMA_RAM_BASE/SIZE` the harness tells the core: the SoC's 64 MB, the SRAM
  harness's memory, the lockstep's 1 MiB; the default window is empty and nothing is buffered) retires before its
  bus write. Its write comes from `qv_sb` in order, one beat at a time, and gives way to a load near the head of the
  ROB. The FSM writes before it retires. So the bus-write log is the same in content and order but a store is
  logged later than its retirement, by a few cycles; a lockstep run therefore halts side B at the last record
  and lets it drain before the final memory comparison (`stop_i`).
- Anything that could see the difference waits: a load whose dword has a store in the buffer (no forwarding: the
  comparator checks the whole raw bus word), an atomic, a load or store outside the window, a Program Buffer
  access, a PTE read, FENCE.I, and an EBREAK. `o_debug_mode` is raised only once the buffer is empty, so the
  Debug Module's System Bus Access of a halted hart sees every retired store. An interrupt or a halt leaves
  the buffer draining.
- A bus error cannot be reported for a buffered store: inside the window the memory does not fault (asserted in
  `qv_sb` under `RISCV_FORMAL`, which the lockstep build compiles in; the riscv-formal models keep the window empty).
  The generated programs' faulting accesses (past the 1 MiB) are outside the window.
- The pipe predicts branches with a target buffer (fetch follows a taken branch with no bubble), a history table
  and a return-address stack, and fetches back to back. A prediction is only a guess that the branch unit
  checks; the aligner confirms or corrects a target-buffer hint, so an aliased or stale entry costs time only.
  The predictors are trained by retirements only (never in a Program Buffer run), so the fetch stream they
  produce is a function of the retired history, and a FENCE.I needs no special handling.

O2 (the load/store queue; the retired stream is the same, the timing is not):
- The memory ops between dispatch and retirement wait in `qv_lsq` (4 entries), and `qv_lsu` performs them one at a
  time in program order, taking the next as the last completes on the bus or is posted. Once no barrier is older (a
  FENCE, a serializing uop, a system op, a uop that traps or has a trigger), a plain load from RAM reads memory, and a
  plain store to RAM is posted, before it is the head of the ROB; the FSM does every access at its head. So loads can
  read RAM on a wrong path (the window must be safe to read as well as to write: it is in all three harnesses), and an
  early load in flight when an interrupt or a halt is taken is drained and done again later: such a RAM word is read
  twice. Faults, atomics, MMIO, Program Buffer accesses and page walks still wait for the head.
- A load waits for an older store to its dword that is posted and not retired (in the queue), as for one in the store
  buffer, then reads memory: no forwarding, as before. `o_debug_mode` is raised only once the port is quiet (an early
  load drained) as well as the buffer empty.
- A FENCE whose predecessor set has W and successor set has R (not FENCE.TSO) waits at commit for the store buffer to
  be empty; before O2.1 a younger RAM load could read memory while an older store to another dword was still buffered,
  which only the Debug Module's System Bus Access could have seen.

Sv39 (the data side and the instruction side are both translated; same pages, same faults, same causes and
mtvals per instruction):
- The FSM translates once per instruction (the pc, and pc + 2 for a 32-bit one that crosses); the pipe translates
  once per fetched dword and once per data access. The number of TLB lookups and fills differs, so a test that
  counts them counts walks (`core_sv39_tlb_tb`), not lookups.
- The pipe has two 4-entry TLBs (instruction and data, round-robin each) against the FSM's one unified 4-entry
  TLB. Neither flushes on a satp write, a privilege change or a trap: only SFENCE.VMA does (a clean one: a
  TVM-trapped SFENCE.VMA flushes nothing).
- The pipe walks speculatively: a fetch past a taken branch, or on a wrong path, translates and fills the
  instruction TLB; the FSM never does. A dword past a branch can become a fault marker that never reaches the head
  and so never traps. Generated programs keep to two rules, so both cores agree: every PTE store, satp write or root
  swap is followed by an SFENCE.VMA before anything depends on it (R1; an interrupt or a halt between the `csrw satp`
  and its SFENCE.VMA runs code that depends on it: the FSM re-walks a page whose A bit differs between the two table
  sets, the pipe still holds the old entry, and both are legal), and no non-leaf PTE and no executable leaf
  leads to a device (R2: the tables and the code are in RAM; the deliberate far pointers and leaves go to an
  address above 2^32 that the PMP always denies, or to the bus-error region). Where the core is given a RAM window
  (the SoC, the SRAM harness, lockstep), an instruction-side PTE read outside it waits until the fetch is on the
  architectural path (P10d, `qv_ptw.sv`), so a speculative walk through a junk pointer never reads a device
  register; the FSM, walking only for what it executes, reads such a PTE at the same point. Only the timing
  differs, and R2 stays (the two cores still walk different numbers of times).
  `lockstep/smc_hazard.py` also triages a divergence that follows a violation of either rule.
- A redirect that changes what translation depends on (a trap, an xRET, an interrupt, a serializing instruction)
  makes fetch wait one cycle before it issues from the target, so the request is translated against the new
  privilege, satp and TLB. It is skipped while satp is Bare and the retiring instruction is not a satp access.
- Fetch keeps the physical page of its last translation and reuses it for the next request in the same virtual page
  (P10a) until a context-changing redirect, an SFENCE.VMA or a halt; like any TLB entry it may outlive an ITLB
  eviction. The data side looks its translation up in the TLB before the op is the ROB head (P10b; a lookup only,
  never a walk), so a hit costs no cycle at the head.
- CSR ops that cannot change what a younger instruction does -- the read-only forms, and writes to m/s scratch, epc,
  cause and tval -- do not serialize (P10c); the FSM never overlaps anything. A dependent of such an op waits for its
  commit (its value is made there). Retirement order and every value are the same; only the timing differs.
- The walker and the LSU share the memory port: the LSU wins every gap between two PTE reads, a PTE read is never
  abandoned (a cancelled walk's beat completes and its result is dropped), and a data walk can wait for a whole
  instruction-side walk. PTE reads are PMP-checked at S privilege, read only, and a denial or a bus error is an
  access fault of the original access's class.
- A fault in the second parcel of a 32-bit instruction reports pc + 2 (errata E6), as ref_core.sv does; a low-dword
  PMP denial ends the fetch before the high dword is looked at, so it wins over a high-dword page fault.

RVFI fields the FSM reports stale, which the comparator masks or the stimulus avoids:
- `insn` on cause-1 and cause-12 records, `mem_*` on trapping AMO records, mip bits 7, 9 and 11 under `--irq-late`.
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
