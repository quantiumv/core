# CPI kernels

Eight small C kernels, each timed with `mcycle`/`minstret` around its main
loop (the eighth, `trap`, since P10.0: see "S mode under Sv39, and the trap path").
They run on two configurations:

- **sram:** the core alone on flat SRAM (`core_wb4_sram_harness`).
- **cache:** the full SoC with its L1 caches (`soc.sv`).

```sh
verification/perf/run_perf.sh --core pipe    # the core; writes baseline_pipe.csv (the default)
verification/perf/run_perf.sh --core ref     # the frozen multi-cycle reference; writes baseline_ref.csv
```

The kernels are built with `-mno-div`, and division goes through libgcc. The core
has had a divider since P5, but the kernels keep the flag so the numbers stay
comparable with the first baseline. Only setup loops divide; the timed regions
never do.

`run_perf.sh` reuses a built testbench and kernel images unless `--force` is given
(and `make clean` in this directory for the kernels): re-run from clean after any
RTL change.

## Results (P9, 2026-10)

CPI (cycles per retired instruction):

| Kernel | reference, sram | core, sram | reference, cache | core, cache | core before P9, cache |
|---|---|---|---|---|---|
| memcpy | 3.77 | 1.85 | 4.28 | 1.76 | 2.36 |
| crc32 | 3.03 | 1.13 | 3.03 | 1.12 | 1.25 |
| qsort | 3.55 | 1.91 | 3.73 | 1.86 | 2.46 |
| matmul | 3.62 | 1.66 | 3.69 | 1.63 | 1.78 |
| sieve | 3.97 | 1.51 | 4.45 | 1.28 | 2.00 |
| listchase | 3.80 | 1.80 | 3.90 | 1.91 | 1.91 |
| mixedint | 3.99 | 1.78 | 4.33 | 1.58 | 2.14 |
| trap (P10.0) | 4.00 | 3.89 | 4.43 | 3.58 | |

The core is 2 to 3.5 times faster than the reference on every kernel but `trap`, where it is only 1.2 times
faster on the SoC: every CSR op serializes (a flush and a refill), and the trap path is mostly CSR ops. The
geometric means below are of the seven older kernels. P9 took the geometric mean of the
cycles down by 20 % on the SoC (21 % on the flat SRAM). Single issue puts the floor at CPI 1.0; crc32 is
within 12 % of it.

What each P9 step bought, in cycles of each kernel's timed region (each row on top of the one above; the
change is against that row; `check_cpi.py` compares two CSVs):

**cache (the SoC)**

| step | memcpy | crc32 | qsort | matmul | sieve | listchase | mixedint |
|---|---|---|---|---|---|---|---|
| before P9 | 1555 | 11091 | 11385 | 7661 | 11823 | 4909 | 9415 |
| + store buffer | 1174 (-24.5%) | 11088 (-0.0%) | 10659 (-6.4%) | 7464 (-2.6%) | 11779 (-0.4%) | 4909 (+0.0%) | 7253 (-23.0%) |
| + streaming fetch | 1160 (-1.2%) | 9933 (-10.4%) | 10058 (-5.6%) | 6996 (-6.3%) | 8928 (-24.2%) | 4901 (-0.2%) | 7068 (-2.6%) |
| + branch target buffer | 1160 (+0.0%) | 9933 (+0.0%) | 9585 (-4.7%) | 6990 (-0.1%) | 7551 (-15.4%) | 4901 (+0.0%) | 6952 (-1.6%) |
| + return-address stack | 1160 (+0.0%) | 9933 (+0.0%) | 9293 (-3.0%) | 6990 (+0.0%) | 7551 (+0.0%) | 4901 (+0.0%) | 6952 (+0.0%) |
| + branch history table | 1160 (+0.0%) | 9933 (+0.0%) | 8583 (-7.6%) | 6990 (+0.0%) | 7554 (+0.0%) | 4901 (+0.0%) | 6952 (+0.0%) |

**sram** (core on flat SRAM, fetch and data sharing one bus)

| step | memcpy | crc32 | qsort | matmul | sieve | listchase | mixedint |
|---|---|---|---|---|---|---|---|
| before P9 | 1593 | 11170 | 11540 | 8359 | 14627 | 5148 | 9877 |
| + store buffer | 1593 (+0.0%) | 11169 (-0.0%) | 11384 (-1.4%) | 8303 (-0.7%) | 14627 (+0.0%) | 5148 (+0.0%) | 9874 (-0.0%) |
| + streaming fetch | 1346 (-15.5%) | 10013 (-10.4%) | 10393 (-8.7%) | 7886 (-5.0%) | 12422 (-15.1%) | 5656 (+9.9%) | 8371 (-15.2%) |
| + branch target buffer | 1222 (-9.2%) | 10013 (+0.0%) | 9828 (-5.4%) | 7114 (-9.8%) | 8952 (-27.9%) | 4639 (-18.0%) | 7835 (-6.4%) |
| + return-address stack | 1222 (+0.0%) | 10013 (+0.0%) | 9542 (-2.9%) | 7114 (+0.0%) | 8952 (+0.0%) | 4639 (+0.0%) | 7835 (+0.0%) |
| + branch history table | 1222 (+0.0%) | 10013 (+0.0%) | 8812 (-7.7%) | 7114 (+0.0%) | 8952 (+0.0%) | 4639 (+0.0%) | 7835 (+0.0%) |

- The store buffer: stores to RAM retire at once and drain behind the loads (the drain gives way to a load
  near the head of the ROB). It beats the ideal-store bound below on memcpy because the drain also leaves
  the D$ free for the next load. On the flat SRAM it gains little: the bus beats are the same.
- Streaming fetch: back-to-back requests, a four-entry fetch buffer, an eight-entry instruction queue.
  On the flat SRAM it makes fetch and the memory port fight harder for the one bus: `listchase` loses
  10 % there until the BTB gives the cycles back. (With the SoC's caches fetch has the I$ to itself.)
- The branch target buffer follows a taken branch with the next fetch request, no bubble; sieve's loop
  closes with a 32-bit branch that straddles two dwords, which the buffer files under the second one.
- The return-address stack and the history table only matter to `qsort` (116 returns, a few hundred
  data-dependent branches). The table costs `sieve` 3 cycles of 7551 on the SoC (aliasing).
- The geometric mean of the SoC cycles is 0.804 of before, of the flat SRAM 0.792. With every knob off
  (`QV_PIPE_SB_DEPTH=0 QV_PIPE_FETCH_STREAM=0 QV_PIPE_BP=0`, passed as `run_perf.sh --defines "..."`) the CSV is
  the previous baseline, byte for byte.
- `listchase` (dependent loads) does not move: its time is the load-to-use latency of a load that starts at the
  head of the ROB, which only an early-load queue (the O2 load/store queue) shortens. That, and the
  execute-time redirect of a mispredicted branch (saves the cycles one waits behind older instructions:
  6 % of qsort, under 2 % of anything else), were not built in P9; see the P9 plan.

The core's numbers were unchanged through P5, P6, P7 and the P8 switchover; P9 is the only step that moved
them (`baseline_ref.csv` is the old `baseline_fsm.csv`). With satp Bare, translation costs nothing, and a
redirect that changes the translation context waits one fetch cycle only while satp is on or being written.

What Sv39 costs (`testbench/core_sv39_cpi_tb.sv`, run by the regression): the
same loop of 300 iterations (8 instructions: ALU, a load, a store, a branch)
in M-mode and in S-mode under an identity 1 GiB leaf, in cycles, on the
shared-SRAM harness (fetch and data on one bus):

| core | M-mode | S-mode, Sv39 | ratio |
|---|---|---|---|
| reference (`ref_core.sv`) | 8400 | 11400 | 1.35 |
| core before P9 (all knobs off) | 4805 | 5113 | 1.06 |
| core | 3908 | 5106 | 1.30 |

A translated fetch dword and a translated access each take one more cycle
(the answer is registered before it is used); the pipeline hides most of it. P9 made the M-mode loop 19 %
faster and the translated loop as fast as before (0.1 % faster); the ratio went up because the M-mode loop did.

A translated fetch uses the shared port in two of every three cycles (its translation phase is the gap), so
on this harness a loop in S-mode is bound by the port, and who wins a tie matters. With the store buffer a store
retires at once, which lets the load behind it reach the ROB head a cycle earlier, and its access could start in
the very cycle fetch's request begins its bus beat. The memory port wins that tie, and fetch waited out the whole
access (two cycles; before P9 the access started in fetch's response cycle and cost it one): that was +6 %
(5404 cycles) in the first P9 results. The LSU now gives way for that one cycle (`fetch_start_q` in `core.sv`; only on a
shared bus, `FETCH_YIELD`, and only with the store buffer, so the knobs-off timing is P8's). Per knob
(`run_regress.sh --defines`), with the rule:

| knobs on | M-mode | S-mode, Sv39 |
|---|---|---|
| none | 4805 | 5113 |
| streaming | 4356 | 5113 |
| predictors | 4209 | 5113 |
| streaming + predictors | 3909 | 5113 |
| store buffer | 4805 | 5410 |
| store buffer + streaming | 3908 | 5404 |
| all (default) | 3908 | 5106 |

Streaming and the predictors leave the translated fetch alone (every dword keeps its translation phase), so
they do nothing here. The two rows with the store buffer but without the predictors keep most of the loss (the drain
beat meets fetch's next request in the same way; giving the drain the same rule did not help the default
configuration and is not built). The same loop in other shapes (S-mode cycles; M-mode in brackets for the default):

| loop body | before P9 | first P9 results | now |
|---|---|---|---|
| load, store (the table above) | 5113 | 5404 | 5106 (3908) |
| ALU only | 4803 | 4506 | 4506 (2406) |
| two loads | 5113 | 5113 | 5117 (3909) |
| two stores | 5703 | 5403 | 5403 (3305) |
| load, then store of the loaded value | 5113 | 5404 | 5106 (3908) |
| store, then load of another dword | 5703 | 5703 | 5703 (3460) |

No shape is slower than before P9 (the two-load loop by 4 cycles in 5113). The SoC has a private fetch path
(`FETCH_YIELD` 0), where none of this applies, and none of the seven kernels runs translated. Overlapping the
instruction-TLB lookup with the previous fetch beat is the other follow-up.

## S mode under Sv39, and the trap path (P10.0)

`run_perf.sh --mode s` builds the same kernels for S mode (`<kernel>_s.*`, `crt0_s.s`, `link_s.ld`) and writes
`baseline_pipe_s.csv`. `crt0_s.s` maps the 64 KB image 1:1 with 4 KiB leaves, writes satp, and `mret`s to `main` in
S. S cannot read `mcycle` or `minstret`, so under `PERF_SMODE` `perf.h` reads `sscratch` and `instret` (which reads
0) instead. Those reads mark the window, and the result is the window the monitor counts, cycles and retirements
(`perf_tb.sv` `SMODE`). Every kernel retires exactly what it retires in M (`check_cpi.py --same-instret`). There is
no reference row: the monitor is not part of the reference build.

The eighth kernel, `trap`, is an OS trap path: 200 `ecall`s, each taken by an M-mode handler shaped like Linux's
entry and exit (swap `sp` with `mscratch`, save six registers, read `mcause`, `mepc`, `mtval` and `mstatus`, write
`mepc + 4`, restore, swap back, `mret`). In the S build the `ecall`s come from S.

Cycles, M mode against S mode under Sv39 (P9 RTL):

| kernel | M, cache | S, cache | S/M | M, sram | S, sram | S/M |
|---|---|---|---|---|---|---|
| memcpy | 1160 | 1806 | 1.56 | 1222 | 1626 | 1.33 |
| crc32 | 9933 | 14519 | 1.46 | 10013 | 14627 | 1.46 |
| qsort | 8583 | 10734 | 1.25 | 8812 | 11241 | 1.28 |
| matmul | 6990 | 8332 | 1.19 | 7114 | 8684 | 1.22 |
| sieve | 7554 | 9158 | 1.21 | 8952 | 11258 | 1.26 |
| listchase | 4901 | 5925 | 1.21 | 4639 | 6177 | 1.33 |
| mixedint | 6952 | 10893 | 1.57 | 7835 | 10436 | 1.33 |
| trap | 20041 | 22061 | 1.10 | 21825 | 23629 | 1.08 |

The trap kernel's CPI is 3.6 on the SoC: 100 cycles per trap, 36 % of them refilling after its seven serializing
CSR ops.

What the P10 steps can save at most, from the monitor's counters (cache configuration; `baseline_pipe_s_stack.csv`
and `baseline_pipe_stack.csv`):

| kernel | translated fetch requests | in the last translated page | translation-phase cycles | translated accesses that hit after waiting (P10b) | serializing CSR refill cycles (P10c, M) |
|---|---|---|---|---|---|
| memcpy | 443 | 441 | 443 (25 %) | 256 (14 %) | 10 |
| crc32 | 5007 | 5005 | 5007 (34 %) | 1 (0 %) | 10 |
| qsort | 3791 | 3789 | 3791 (35 %) | 485 (5 %) | 10 |
| matmul | 2507 | 2505 | 2507 (30 %) | 576 (7 %) | 10 |
| sieve | 3055 | 3053 | 3055 (33 %) | 1389 (15 %) | 10 |
| listchase | 1042 | 1040 | 1042 (18 %) | 1024 (17 %) | 10 |
| mixedint | 3200 | 3198 | 3200 (29 %) | 1440 (13 %) | 10 |
| trap | 1211 | 1009 | 1211 (5 %) | 0 | 7210 (36 %) |

- Fetch (P10a): every translated request but the first in each page is in the page the last translation found,
  under the same context: the small kernels never leave their page. Every such request pays a translation-phase
  cycle (an ITLB hit) and never streams. The phase cycles overlap other work, so they bound the gain from above,
  but they are a quarter to a third of every kernel.
- Data (P10b): a translated access asks for its translation only at the head, a cycle before it can start. The
  count is the accesses whose head lookup hit after the op had waited before the head, the cycles a lookup made
  while waiting would save: at least 3 % on five kernels, so P10b is built.
- CSRs (P10c): the seven kernels have only their two window markers. The trap kernel has 4 read-only CSR ops and
  3 trap-CSR writes per trap, and the refill after them is 36 % of its cycles.
- A full ROB stops issue in at most 39 cycles of any S-mode window (mixedint): growing the ROB is not worth it.

## CPI stack

`perf_stack.sv` (instantiated by `perf_tb.sv`, not part of the reference build) splits every cycle of a
kernel's window into one class, and `run_perf.sh` writes the counts to `baseline_pipe_stack.csv`. The
window is the kernel's own: the cycles after the commit of its first `csrr mcycle` up to and including
the commit of its second, so the classes add up to the `mcycle` delta and the retirements in it to the
kernel's `instret` (the monitor prints a warning when either fails; none does).

- **retire**: an instruction commits.
- **LSU**: the ROB head is a load or store still being performed (or a divide).
- **ALU/BRU/SYS**: the head is still being executed, or is complete and commit holds it.
- **after align redirect**, **after commit redirect**: the ROB is empty in the refill shadow of a
  redirect (until the first issue after it): the aligner's static prediction, or commit's redirect for
  a mispredict, a serializing instruction, a trap or an interrupt.
- **frontend**: the ROB is empty and no redirect explains it.

Share of the window, in percent (the CSV also holds the side counters, among them `bus_wait`, the cycles
the LSU's request waits while fetch holds the shared SRAM, meaningful in the `sram` configuration only).

After P9 (`baseline_pipe_stack.csv`):

| kernel | cycles | retire | LSU | ALU/BRU/SYS | after align | after commit | frontend | mispredicts cond/jal/jalr |
|---|---|---|---|---|---|---|---|---|
| **cache** (the SoC) | | | | | | | | |
| memcpy | 1160 | 56.8 | 39.3 | 0.9 | 0.7 | 2.3 | 0.0 | 5/0/0 |
| crc32 | 9933 | 89.0 | 3.0 | 1.3 | 0.0 | 6.7 | 0.0 | 129/0/0 |
| qsort | 8583 | 53.7 | 22.4 | 3.2 | 1.4 | 18.7 | 0.6 | 333/0/2 |
| matmul | 6990 | 61.3 | 32.2 | 1.1 | 0.0 | 5.5 | 0.0 | 73/0/0 |
| sieve | 7554 | 78.0 | 19.7 | 0.3 | 0.0 | 1.8 | 0.2 | 24/0/0 |
| listchase | 4901 | 52.3 | 47.2 | 0.1 | 0.0 | 0.4 | 0.0 | 1/0/0 |
| mixedint | 6952 | 63.2 | 31.3 | 0.9 | 0.0 | 4.5 | 0.0 | 61/0/0 |
| **sram** (core on flat SRAM) | | | | | | | | |
| memcpy | 1222 | 53.9 | 41.9 | 0.8 | 0.7 | 2.2 | 0.5 | 5/0/0 |
| crc32 | 10013 | 88.3 | 3.8 | 1.3 | 0.0 | 6.5 | 0.0 | 129/0/0 |
| qsort | 8812 | 52.3 | 23.9 | 3.2 | 1.4 | 18.5 | 0.7 | 333/0/2 |
| matmul | 7114 | 60.2 | 33.3 | 1.1 | 0.0 | 5.4 | 0.0 | 73/0/0 |
| sieve | 8952 | 65.9 | 16.7 | 15.5 | 0.0 | 1.5 | 0.5 | 24/0/0 |
| listchase | 4639 | 55.3 | 44.3 | 0.1 | 0.0 | 0.4 | 0.0 | 1/0/0 |
| mixedint | 7835 | 56.1 | 36.8 | 1.6 | 0.0 | 4.0 | 1.5 | 61/0/0 |

What is left: the load-to-use latency of loads that start at the head of the ROB is the biggest class on
every memory kernel (17 to 47 %), then the refill after a mispredict (crc32's 129 loop exits, qsort's 333
data-dependent branches, 4 to 19 %). Both are O1/O2 work: an early-load queue, and kill-by-age with an
execute-time redirect.

Before P9, the same table (the column heads are the same):

| kernel | cycles | retire | LSU | ALU/BRU/SYS | after align | after commit | frontend | mispredicts cond/jal/jalr |
|---|---|---|---|---|---|---|---|---|
| **cache** (the SoC) | | | | | | | | |
| memcpy | 1555 | 42.4 | 54.0 | 0.6 | 0.5 | 2.3 | 0.2 | 5/0/0 |
| crc32 | 11091 | 79.7 | 2.7 | 9.3 | 2.3 | 4.9 | 1.1 | 129/0/0 |
| qsort | 11385 | 40.5 | 24.3 | 4.7 | 3.5 | 25.0 | 1.9 | 439/0/116 |
| matmul | 7661 | 55.9 | 31.8 | 1.2 | 0.0 | 5.0 | 6.0 | 73/0/0 |
| sieve | 11823 | 49.9 | 48.3 | 0.4 | 0.0 | 1.2 | 0.2 | 23/0/0 |
| listchase | 4909 | 52.2 | 47.1 | 0.1 | 0.0 | 0.6 | 0.0 | 1/0/0 |
| mixedint | 9415 | 46.7 | 46.1 | 2.5 | 0.0 | 3.4 | 1.3 | 61/0/0 |
| **sram** (core on flat SRAM) | | | | | | | | |
| memcpy | 1593 | 41.4 | 40.4 | 4.4 | 0.5 | 1.8 | 11.5 | 5/0/0 |
| crc32 | 11170 | 79.1 | 3.4 | 9.2 | 2.3 | 4.8 | 1.1 | 129/0/0 |
| qsort | 11540 | 40.0 | 23.5 | 5.5 | 3.7 | 25.2 | 2.2 | 439/0/116 |
| matmul | 8359 | 51.3 | 37.6 | 1.1 | 0.0 | 4.5 | 5.5 | 73/0/0 |
| sieve | 14627 | 40.3 | 29.5 | 0.4 | 0.0 | 0.9 | 28.9 | 23/0/0 |
| listchase | 5148 | 49.8 | 49.7 | 0.1 | 0.0 | 0.4 | 0.0 | 1/0/0 |
| mixedint | 9877 | 44.5 | 39.5 | 2.4 | 0.0 | 3.2 | 10.3 | 61/0/0 |

What it says:

- On the SoC a memory operation holding the ROB head is the biggest loss on six of the seven kernels
  (24 to 54 % of the cycles); only crc32 is not memory-bound. A load that hits holds the head for 3
  cycles and a store through the write-through D$ for 5.
- Mispredicts are the second loss, and mostly one kernel: qsort spends 25 % of its cycles refilling
  after commit's redirects (555 of them, 116 of them `ret`s, which are never predicted); crc32 loses
  about 5 % to its 129 loop exits.
- Starvation of the frontend with an empty ROB is small on the SoC (6 % at most), because the ROB is
  rarely empty. That does not mean fetch is fast enough: sieve's loop spans three dwords, which fetch
  delivers in 8 cycles, about what the commit path needs for it, so each bound hides the other, and the
  empty fetch buffer shows it (it is empty in half of sieve's cycles).
- On the shared SRAM the same loops are bus-bound: fetch takes two bus cycles per dword, and the
  LSU's request waits 8 to 12 % of the time for the arbiter. Sieve is starved by the frontend 29 % of
  its cycles there.
- A mispredicted branch that commit redirects on reaches the head the cycle after it finishes unless
  older instructions are still to commit; the cycles it waits beyond that (the most an execute-time
  redirect can save) are 6.0 % of qsort, 3.2 % of mixedint and 1.3 % of memcpy and matmul on the SoC.

### Ideal-store oracle (before the store buffer)

`run_perf.sh --oracle store` builds the cache configuration with `oracle_dcache.sv` in place of the
D$: a store is acknowledged like a load hit and written straight into the SRAM array, with no
downstream beat, so it costs nothing and contends with nothing. Its cycles are an upper bound for what
a store buffer can gain (`oracle_store_pipe.csv`; `check_cpi.py --new verification/perf/oracle_store_pipe.csv
--old verification/perf/baseline_pipe.csv --configs cache` prints the comparison):

| kernel | baseline | ideal stores | change |
|---|---|---|---|
| memcpy | 1555 | 1299 | -16.5 % |
| crc32 | 11091 | 11089 | 0.0 % |
| qsort | 11385 | 10785 | -5.3 % |
| matmul | 7661 | 7527 | -1.7 % |
| sieve | 11823 | 11801 | -0.2 % |
| listchase | 4909 | 4909 | 0.0 % |
| mixedint | 9415 | 8033 | -14.7 % |

Free stores help memcpy, mixedint and qsort, and sieve not at all (its fetch bound hides the gain), as
the P9 plan predicted. The bound is at least 5 % on three kernels, so the store buffer (P9d) was a go; it
did better than the bound on memcpy (-24.5 %) and mixedint (-23.0 %), since its drain also keeps the D$ free
for the loads behind it.

### Branch traces

`+BRTRACE` (a plusarg of `perf_tb`) makes the monitor print one line per control-flow instruction retired
inside the window; `brpred.py` replays such traces through a history table, a target buffer and a
return-address stack to see what each would buy before building it. Its cost model overestimates (a taken
branch's bubble is mostly hidden by the queues; a mispredict costs about 4.5 cycles in the stack above, not 8).

`check_cpi.py` compares a run's `baseline_pipe.csv` with the committed one: it fails when a kernel's
instret changes or its cycles rise on the SoC configuration.
