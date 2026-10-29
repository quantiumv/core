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
| `p6_lockstep_dense.json` | the same plus `--ebreak-rate 0.1` | the same plus `--dbg-density 1` |
| `p6_lockstep_dbgexc.json` | the same, `--corpus dbg`: the directed programs `dbg_exc.s` and `dbg_res.s`, the only ones that can take an action-0 trigger | `--irq-mode 0 --dbg-mode 1 --dbg-features 191` |
| `p7_lockstep.json` | `--isa imac --priv msu --pmp --irq --smc --sv39` | `--irq-mode 2 --irq-density 1 --dbg-mode 1 --dbg-features 191 --timeout 2000000` |
| `p7_lockstep_extra.json` | an M-mode body (`--priv m --pmp --smc --sv39`: MPRV, a locked pocket binding M); `--priv msu --pmp --irq --smc` without `--sv39` (satp Bare below M); `--priv msu --irq --smc --sv39` without `--pmp` (the bus-error region is reachable); `--priv msu --pmp --smc --sv39` without `--irq` (a pocket of its own over the high probe page) | `--irq-mode 0` where the profile has no `--irq` |
| `p7_lockstep_slow.json` | the first profile (and the no-`--pmp` one) on the cache with 8 wait states, where the caches answer with ack and err together | `--timeout 3000000` |

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

Sv39 (the data side and the instruction side are both translated; same pages, same faults, same causes and
mtvals per instruction):
- The FSM translates once per instruction (the pc, and pc + 8 for a 32-bit one that crosses); the pipe translates
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
- A page fault in the second dword of a 32-bit instruction that crosses reports pc + 8, as ref_core.sv does; a low-dword
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
