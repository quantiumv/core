# CPI kernels

Ten small C kernels, each timed with `mcycle`/`minstret` around its main
loop (the eighth, `trap`, since P10.0: see "S mode under Sv39, and the trap path"; `fmatmul` and `fpmix` since F/D:
see "F/D kernels").
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

## Results (after O4, two-wide, 2026-11, branch `OOO`)

CPI (cycles per retired instruction), M mode:

| Kernel | reference, sram | core, sram | reference, cache | core, cache | core after O1, cache | core before O1, cache | core after O2, cache | core at P10, cache | core before P9, cache |
|---|---|---|---|---|---|---|---|---|---|
| memcpy | 3.77 | 1.65 | 3.90 | 1.15 | 1.17 | 1.17 | 1.53 | 1.74 | 2.36 |
| crc32 | 3.03 | 0.78 | 3.03 | 0.79 | 1.11 | 1.11 | 1.11 | 1.12 | 1.25 |
| qsort | 3.55 | 1.54 | 3.59 | 1.34 | 1.56 | 1.56 | 1.62 | 1.86 | 2.46 |
| matmul | 3.62 | 1.38 | 3.66 | 1.00 | 1.16 | 1.16 | 1.16 | 1.63 | 1.78 |
| sieve | 3.97 | 1.51 | 3.98 | 1.03 | 1.04 | 1.04 | 1.04 | 1.28 | 2.00 |
| listchase | 3.80 | 1.28 | 3.90 | 0.91 | 1.09 | 1.09 | 1.09 | 1.90 | 1.91 |
| mixedint | 3.99 | 1.60 | 4.01 | 1.06 | 1.10 | 1.10 | 1.37 | 1.58 | 2.14 |
| trap (P10.0) | 4.00 | 1.75 | 4.00 | 1.76 | 1.79 | 1.83 | 2.25 | 2.40 | |

The core is 2.3 to 4.3 times faster than the reference on every kernel, and 2.3 times on `trap` (an OS trap path).
It dispatches and commits two instructions a cycle (O4), so CPI can go below 1: `crc32` and `listchase` do on the SoC
(and `crc32`, `matmul` and `sieve` in S mode). The load/store queue (O2) is the step from the "at P10" column to the
"after O2" one, the D$ store pass-through the step from there to "before O1" (the reference runs behind the same D$, so
its cache column moved too), the reservation station (O1) the step to "after O1", and two-wide (O4) the step to the
core's (see "Two-wide").

## F/D kernels

`fmatmul` is an 8x8 double matrix multiply (its inner loop an FMADD.D, `-ffp-contract` contracting the multiply and
add); `fpmix` runs divide, square root and conversions in both precisions over 32 values. They are built with F and D
(`-march=rv64imafdc`, the lp64 ABI of crt0 and libgcc) and turn `mstatus.FS` on before the window (`perf_fp_on()` in
`perf.h`); the other eight kernels keep their flags and code. With F/D built in (`QV_FPU_EN`, the default) the eight
older kernels' rows are byte-for-byte what they were before, in all three CSVs.

| Kernel | reference, sram | core, sram | reference, cache | core, cache | core, S mode, cache |
|---|---|---|---|---|---|
| fmatmul | 4.61 | 2.02 | 4.72 | 2.05 | 2.19 |
| fpmix | 15.25 | 10.91 | 15.51 | 11.01 | 11.01 |

Where the core's cycles go (the CPI stack, sram): `fmatmul` retires in half of its 7,612 cycles; the head waits for a
load 29 % of the time (two loads per FMA, at the head of the ROB) and for the FPU 15 % (each FMADD.D needs the sum of
the one before, four cycles in the FPU's pipeline). `fpmix` waits for the FPU 88 % of its 4,386 cycles: 64 divides
and square roots, one at a time beside the pipeline, about 60 cycles each. The reference runs every FP operation one
at a time; the divide and square root cost the two cores the same, so `fpmix` gains least.

The link scripts place `.srodata` in `.rodata`: GCC keeps double constants there (`.srodata.cst8`), and the hex holds
`.text`, `.rodata` and `.data` only. (The first F/D numbers ran without the constants: every value 0, the divide and
square root on their fast path for zero.) No integer kernel has a `.srodata` section, so their images are unchanged.
The geometric means below are of the seven older kernels. P9 took the geometric mean of the
cycles down by 20 % on the SoC (21 % on the flat SRAM); P10 changes the M-mode kernels by under 1 % (their CSR
window markers) and is about S mode, below. Single issue puts the floor at CPI 1.0; crc32 is within 12 % of it.

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
| core after P9 | 3908 | 5106 | 1.30 |
| core after P10 | 3908 | 3915 | 1.00 |
| core after O1 (every O4 knob at 1) | 3304 | 3311 | 1.00 |
| core (after O4, two-wide) | 3198 | 3262 | 1.02 |

(The regression row runs it at one retirement a cycle, `QV_PIPE_COMMIT_W=1`: 3206 and 3307, 1.03.)

A translated fetch dword and a translated access each take one more cycle
(the answer is registered before it is used); the pipeline hides most of it. P9 made the M-mode loop 19 %
faster and the translated loop as fast as before (0.1 % faster); the ratio went up because the M-mode loop did.
P10 took the translated loop to the M-mode figure: fetch reuses its translated page (P10a: 5106 to 4216) and the
data side looks its translation up before the head (P10b: to 3915); the rest of this section is the P9 history.

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

| loop body | before P9 | first P9 results | after P9 | after P10 |
|---|---|---|---|---|
| load, store (the table above) | 5113 | 5404 | 5106 (3908) | 3915 |
| ALU only | 4803 | 4506 | 4506 (2406) | 2406 |
| two loads | 5113 | 5113 | 5117 (3909) | 3916 |
| two stores | 5703 | 5403 | 5403 (3305) | 3314 |
| load, then store of the loaded value | 5113 | 5404 | 5106 (3908) | 3915 |
| store, then load of another dword | 5703 | 5703 | 5703 (3460) | 3914 |

No shape is slower than before P9 (the two-load loop by 4 cycles in 5113). The SoC has a private fetch path
(`FETCH_YIELD` 0), where none of this applies, and none of the seven kernels runs translated. After P10 every shape
is within 0.3 % of its M-mode cycles (in brackets), except the last (3914 against 3460): its load reaches the head
right behind the store, with no cycle to look its translation up before. One knob combination that is not the
default runs slower than after P9: the lookup before the head without fetch's page reuse (`QV_PIPE_FETCH_PAGE_REUSE=0`)
gives 5409 cycles for the first shape (not analysed: a diagnostic combination; likely the P9 tie between a load
and a translated fetch beat on the shared bus, which page reuse removes by taking most fetch requests out of their
translation phase).

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

### P10a: translated fetch reuses its page

Fetch keeps the physical page of its last successful translation, and a request in the same virtual page skips
its translation phase and may stream (`QV_PIPE_FETCH_PAGE_REUSE`, on by default). Cycles in S mode, against
P10.0, and against the same kernel in M mode:

| kernel | S, cache | with reuse | S/M | S, sram | with reuse | S/M |
|---|---|---|---|---|---|---|
| memcpy | 1806 | 1793 (-0.7 %) | 1.55 | 1626 | 1485 (-8.7 %) | 1.22 |
| crc32 | 14519 | 10059 (-30.7 %) | 1.01 | 14627 | 10147 (-30.6 %) | 1.01 |
| qsort | 10734 | 9505 (-11.4 %) | 1.11 | 11241 | 9936 (-11.6 %) | 1.13 |
| matmul | 8332 | 8090 (-2.9 %) | 1.16 | 8684 | 8157 (-6.1 %) | 1.15 |
| sieve | 9158 | 8995 (-1.8 %) | 1.19 | 11258 | 8998 (-20.1 %) | 1.01 |
| listchase | 5925 | 5928 (+0.1 %) | 1.21 | 6177 | 5662 (-8.3 %) | 1.22 |
| mixedint | 10893 | 10415 (-4.4 %) | 1.50 | 10436 | 9236 (-11.5 %) | 1.18 |
| trap | 22061 | 21260 (-3.6 %) | 1.06 | 23629 | 22831 (-3.4 %) | 1.05 |

The geometric mean of the seven older kernels in S mode falls by 8 % on the SoC and 14 % on the flat SRAM;
the M-mode CSV is unchanged. crc32, a fetch-bound loop, now runs translated as fast as in M mode. The
translation-phase cycles of the counters above all but disappear (listchase: 1042 to 2). On the SoC listchase is
3 cycles slower: fetch now runs ahead translated as it does in M mode, so the refill after the window's first
CSR marker (a serializing redirect) waits for a fetch already under way (20 cycles of refill instead of 14).
What is left of the S-mode cost is mostly the data side: a translated access still asks for its translation at
the head (P10b). On the shared-SRAM harness the Sv39 loop of `core_sv39_cpi_tb` goes from 5106 to 4216 cycles
(M mode 3908), and every one of its six shapes is faster (the ALU-only one now as fast as in M mode, 2406).

### P10b, P10c, and the round as a whole

P10b: the data side looks its translation up in the TLB while the op waits for the head (a lookup only, never a
walk; `QV_PIPE_DTLB_PROBE`), so a hit lets the access start in its first head cycle. P10c: CSR ops that cannot
change what a younger instruction does, the read-only forms and the writes of m/s scratch, epc, cause and tval,
no longer flush and refetch (`QV_PIPE_CSR_NOSER`); a dependent waits for the op's commit, where its value is
made. P10d (PTE reads outside RAM wait for the real path) changes no kernel's cycles. Each step on top of the one
above, S mode:

**cache (the SoC)**

| step | memcpy | crc32 | qsort | matmul | sieve | listchase | mixedint | trap |
|---|---|---|---|---|---|---|---|---|
| P10.0 | 1806 | 14519 | 10734 | 8332 | 9158 | 5925 | 10893 | 22061 |
| + fetch page reuse (P10a) | 1793 (-0.7%) | 10059 (-30.7%) | 9505 (-11.4%) | 8090 (-2.9%) | 8995 (-1.8%) | 5928 (+0.1%) | 10415 (-4.4%) | 21260 (-3.6%) |
| + TLB lookup before the head (P10b) | 1661 (-7.4%) | 10057 (-0.0%) | 8925 (-6.1%) | 7514 (-7.1%) | 7558 (-16.0%) | 4904 (-17.3%) | 9635 (-7.5%) | 21260 (+0.0%) |
| + CSR ops without a flush (P10c) | 1645 (-1.0%) | 10041 (-0.2%) | 8908 (-0.2%) | 7492 (-0.3%) | 7541 (-0.2%) | 4882 (-0.4%) | 9619 (-0.2%) | 13846 (-34.9%) |
| M mode, P10 | 1148 | 9913 | 8566 | 6972 | 7540 | 4883 | 6939 | 13432 |
| S/M, P10 | 1.43 | 1.01 | 1.04 | 1.07 | 1.00 | 1.00 | 1.39 | 1.03 |

**sram** (core on flat SRAM)

| step | memcpy | crc32 | qsort | matmul | sieve | listchase | mixedint | trap |
|---|---|---|---|---|---|---|---|---|
| P10.0 | 1626 | 14627 | 11241 | 8684 | 11258 | 6177 | 10436 | 23629 |
| + fetch page reuse (P10a) | 1485 (-8.7%) | 10147 (-30.6%) | 9936 (-11.6%) | 8157 (-6.1%) | 8998 (-20.1%) | 5662 (-8.3%) | 9236 (-11.5%) | 22831 (-3.4%) |
| + TLB lookup before the head (P10b) | 1357 (-8.6%) | 10145 (-0.0%) | 9369 (-5.7%) | 7629 (-6.5%) | 7584 (-15.7%) | 4638 (-18.1%) | 8456 (-8.4%) | 22831 (+0.0%) |
| + CSR ops without a flush (P10c) | 1340 (-1.3%) | 10129 (-0.2%) | 9353 (-0.2%) | 7613 (-0.2%) | 7567 (-0.2%) | 4622 (-0.3%) | 8440 (-0.2%) | 13015 (-43.0%) |
| M mode, P10 | 1210 | 10001 | 8799 | 7102 | 8940 | 4626 | 7823 | 12813 |
| S/M, P10 | 1.11 | 1.01 | 1.06 | 1.07 | 0.85 | 1.00 | 1.08 | 1.02 |

- In S mode the geometric mean of the seven older kernels falls to 0.834 of P10.0 on the SoC and 0.776 on the flat
  SRAM; five of them now run translated within 7 % of M mode on the SoC. In M mode P10 changes only the CSR
  markers' refill (0.997 of P10.0) and the trap kernel.
- What is left in S mode is memcpy and mixedint on the SoC (1.43 and 1.39 of M): their loads and stores come
  back to back, and the second op of a pair enters the LSU only as the first one retires, at the head at once,
  with no cycle to look its translation up before. Looking it up in the dispatch cycle itself is the follow-up.
- The trap kernel's seven CSR ops per trap no longer refill the pipeline: 33 % fewer cycles on the SoC in M mode,
  41 % on the flat SRAM, 35 to 43 % in S mode. A trap still costs its own redirects (the ecall's trap and the mret).
- S/M compares two builds as well as two modes: `crt0_s.s` is longer, so every kernel sits at other addresses.
  sieve's inner loop (`sb` and the closing `bge`, both 32-bit) straddles two dword boundaries in the M build
  (0x7e-0x89) and none in the S build (0x13c-0x147), which is why on the flat SRAM, where fetch shares the bus, it
  runs faster in S mode than in M mode (0.85).

## The load/store queue (O2, branch `OOO`)

`qv_lsq` queues up to four memory ops in program order in front of the LSU, which still performs them one at a time
and in order, but now as soon as they reach it rather than at the ROB head: a plain load from RAM starts, and a plain
store to RAM is posted (it goes to the store buffer at its commit, as before), once nothing older that could change
the outcome is still unretired (a FENCE, a serializing or system op, a faulting or triggered one). Everything else
(atomics, LR/SC, MMIO, faults, Program Buffer accesses) stays at the head. Four more pieces ride on it: the LSU takes
its next op in the cycle the last one completes (O2b), the queue looks the next op's translation up while the LSU is
on the bus (O2c), a load's value goes straight to issue (O2d), and a FENCE that orders writes before reads drains the
store buffer (O2.1). Knobs: `QV_PIPE_LSQ_DEPTH` (0 is the core before O2, and gives byte-identical CSVs),
`QV_PIPE_LSQ_EARLY`, `_EARLY_ST`, `_HANDOFF`, `_PRE_XL`, `_BYPASS`. Cycles against the core before O2, both modes:

| kernel | M SoC | O2 | change | CPI | M SRAM | S SoC | S SRAM | early loads | early stores | handoffs |
|---|---|---|---|---|---|---|---|---|---|---|
| memcpy | 1148 | 1007 | -12.3 % | 1.528 | -7.4 % | -38.4 % | -13.3 % | 9 | 128 | 121 |
| crc32 | 9913 | 9785 | -1.3 % | 1.107 | -1.3 % | 0.0 % | 0.0 % | 127 | 1 | 0 |
| qsort | 8566 | 7461 | -12.9 % | 1.618 | -11.7 % | -12.0 % | -11.7 % | 582 | 361 | 400 |
| matmul | 6972 | 4988 | -28.5 % | 1.164 | -16.6 % | -26.4 % | -22.6 % | 1088 | 64 | 576 |
| sieve | 7540 | 6118 | -18.9 % | 1.038 | -0.2 % | -18.6 % | -0.2 % | 28 | 1391 | 0 |
| listchase | 4883 | 2806 | -42.5 % | 1.094 | -11.2 % | -32.0 % | -22.2 % | 1025 | 0 | 544 |
| mixedint | 6939 | 6035 | -13.0 % | 1.374 | -9.2 % | -36.2 % | -15.7 % | 124 | 720 | 600 |
| trap | 13432 | 12632 | -6.0 % | 2.254 | -18.7 % | -5.8 % | -15.4 % | 800 | 1000 | 2000 |
| fmatmul | 7740 | 4664 | -39.7 % | 1.236 | -27.2 % | -37.8 % | -28.7 % | 1152 | 61 | 576 |
| fpmix | 4427 | 4356 | -1.6 % | 10.836 | -2.4 % | -0.9 % | -0.9 % | 34 | 3 | 2 |

The last three columns are the M-mode SoC counts of `baseline_pipe_lsq.csv` (`PERF_LSQ`, one per event) at O2; the
D$ store pass-through (below) changed them.

- Geometric mean of the ten: 0.810 (M SoC), 0.890 (M SRAM), 0.779 (S SoC), 0.864 (S SRAM). No kernel is slower in
  any of the four, and instret is unchanged on every row.
- listchase and matmul beat the early-load oracle's figures (-31.4 % and -13.8 %): the oracle kept a lost cycle
  between ops and stores at the head, which the handoff and early posting remove.
- In S mode on the SoC memcpy and mixedint now run within 2 % of M mode (they were 1.43 and 1.39): the queue looks
  the next op's translation up while the LSU is still on the bus. listchase (1.18) and matmul (1.11) gained more in
  M mode than in S mode.
- What is left: the flat SRAM gains less because fetch and data share one bus, and an early access only moves a
  beat; sieve's stores are bound by the store buffer's drain; trap's restores read the dwords its saves just wrote
  and wait for them (1,000 match-wait cycles, 8 % of its window), which forwarding would remove (not built). (The
  D$ store pass-through took memcpy, mixedint and trap off the drain, and trap's match waits to 0: below.)

## The D$ store pass-through (branch `OOO`)

`dcache.sv` used to take a store into a state of its own a cycle after it arrived, send it to memory from there and
acknowledge it a cycle after memory did: four cycles a store, and with the store buffer's registered beat in front a
drain beat held the LSU off for five. Now a store goes to memory in the cycle it arrives and is acknowledged in
memory's response cycle (three cycles a beat); a hit is merged into its line from copies latched while the request was
presented. A store is still in memory when it is acknowledged, so FENCE.I, the tests that read memory after an EBREAK
and lockstep's end-of-test memory compare see what they saw before. Only the cache configuration has a D$; the flat
SRAM rows are unchanged. Cycles, SoC:

| kernel | M before | M after | change | S change | reference change |
|---|---|---|---|---|---|
| memcpy | 1007 | 770 | -23.5 % | -23.4 % | -9.1 % |
| crc32 | 9785 | 9785 | 0.0 % | 0.0 % | -0.0 % |
| qsort | 7461 | 7195 | -3.6 % | -3.1 % | -3.8 % |
| matmul | 4988 | 4988 | 0.0 % | 0.0 % | -0.8 % |
| sieve | 6118 | 6117 | -0.0 % | 0.0 % | -10.7 % |
| listchase | 2806 | 2806 | 0.0 % | 0.0 % | 0.0 % |
| mixedint | 6035 | 4839 | -19.8 % | -19.6 % | -7.6 % |
| trap | 12632 | 10232 | -19.0 % | -18.4 % | -9.7 % |
| fmatmul | 4664 | 4663 | -0.0 % | 0.0 % | -0.7 % |
| fpmix | 4356 | 4356 | 0.0 % | 0.0 % | -0.1 % |
| geomean | | | -7.1 % | -6.9 % | -4.3 % |

- The O1.0 model below predicted exactly this before the RTL was written (its "D$ write 3 cycles" column: memcpy
  -23.5 %, qsort -3.6 %, mixedint -19.8 %, trap -19.0 %, the geometric mean -7.1 %), to the tenth of a point on
  every kernel. instret is unchanged on every row.
- memcpy's loop was a 2-cycle load and a 5-cycle drain beat; mixedint and trap were bound the same way. The early
  loads go up where a beat used to hold the LSU (`baseline_pipe_lsq.csv`, M SoC: memcpy 9 to 132, mixedint 124 to
  780, trap 800 to 1,200), and trap's 1,000 match-wait cycles are gone: its restores no longer find the dwords they
  read still in the buffer.
- The reference runs behind the same D$, so its SoC rows gain too (sieve's stores each waited out the D$ there).

## The reservation station (O1, branch `OOO`)

A uop whose operands are not ready waits in a small station (`qv_rs`, 4 entries; `QV_PIPE_RS_DEPTH=0` is the core
before O1, and its six CSVs are byte-for-byte those from before the switch) instead of stopping everything behind it,
and a memory op waits for its operands in the load/store queue (`QV_PIPE_LSQ_WAIT`). Dispatch and commit stay one a
cycle, in order. Cycles, SoC, then the change in the other builds:

| kernel | M before | M after | change | S change | M, sram | S, sram |
|---|---|---|---|---|---|---|
| memcpy | 770 | 770 | 0.0 % | 0.0 % | +3.0 % | 0.0 % |
| crc32 | 9785 | 9785 | 0.0 % | 0.0 % | 0.0 % | 0.0 % |
| qsort | 7195 | 7188 | -0.1 % | -0.2 % | 0.0 % | -0.0 % |
| matmul | 4988 | 4959 | -0.6 % | -8.6 % | +0.1 % | -5.1 % |
| sieve | 6117 | 6117 | 0.0 % | -0.1 % | -0.1 % | -0.2 % |
| listchase | 2806 | 2786 | -0.7 % | -14.6 % | 0.0 % | 0.0 % |
| mixedint | 4839 | 4835 | -0.1 % | 0.0 % | +1.7 % | +4.1 % |
| trap | 10232 | 10032 | -2.0 % | -1.9 % | -3.8 % | -5.4 % |
| fmatmul | 4663 | 4624 | -0.8 % | -9.3 % | +0.1 % | +1.4 % |
| fpmix | 4356 | 4131 | -5.2 % | -5.7 % | -5.1 % | -5.7 % |
| geomean | | | -1.0 % | -4.2 % | -0.4 % | -1.2 % |

No kernel gets slower on the SoC, in M or S mode, and instret is unchanged on every row.

- It passes the rule a step stays on by (P9's decision 4: at least 3 % on some kernel, no SoC kernel slower): `fpmix`
  in M mode, and `listchase`, `fmatmul`, `matmul`, `fpmix` in S mode. The O1.0 model below predicted the M column (its
  "OOO, RS 8": -0.4 % against -0.6 % on matmul, -0.7, -2.0 and -0.8 % on listchase, trap and fmatmul, -5.5 % on fpmix
  at the size it modelled) and S matmul and fmatmul (-8.4, -9.0 against -8.6, -9.3). It did not predict S `listchase`.
- S `listchase`: both loads of an iteration (`p->value`, `p->next`) wait in the queue for `p`, so the queue
  pre-translates the second while the first is on the bus. The DTLB lookups at the head go from 996 to 513 and the
  waits for an operand at issue from 747 cycles to none. It now takes 2836 cycles against 2786 in M mode.
- `fpmix`: the divides overlap the work behind them, and the ROB starts to fill behind a divide (`is_rob` 0 to 98
  cycles, `is_rs` 3613: what is left waits on the one divide unit).
- The flat SRAM harness, where fetch and data share one bus, loses a little on `memcpy` and `mixedint` (and on S
  `fmatmul`). The memory ops no longer stop issue, so the data side takes the bus earlier and more often and fetch
  gets less of it: the head's wait for the LSU goes down (`memcpy` 353 to 265 cycles, `mixedint` 2041 to 1801) and the
  empty frontend goes up by more (32 to 76, 181 to 541). The SoC has separate paths. Accepted, since the SoC decides.

The size: 4 entries against 2 and 8 change only these rows; every other row is the same at all three.

| | RS 2 | RS 4 | RS 8 |
|---|---|---|---|
| fpmix, M, cache | -3.6 % | -5.2 % | -5.5 % |
| fpmix, M, sram | -3.6 % | -5.1 % | -5.1 % |
| fpmix, S, cache | -3.5 % | -5.7 % | -6.0 % |
| fpmix, S, sram | -3.6 % | -5.7 % | -6.4 % |
| matmul, S, sram | -2.0 % | -5.1 % | -5.1 % |

A ROB of 16 is not built. The model gives `fpmix` -10.7 % and the geometric mean -1.6 % against -1.0 %, and nothing else
moves much: issue stops on a full ROB in 1.2 % of the window cycles on the SoC (`is_rob`, M mode; 16 cycles in all before the station).

## Two-wide (O4, branch `OOO`)

The core dispatches two uops a cycle, issues to two ALU ports and commits two a cycle (`QV_PIPE_DISPATCH_W`,
`QV_PIPE_ALU_PORTS`, `QV_PIPE_COMMIT_W`, all 2 by default). A pair follows the rules of O4.0 (one memory op, one uop
touching FP state, CSR/SYS/FENCE/divide/FP divide/atomic/trapping uops alone, branches and multiplies on port 0; the
second retirement never traps and a pair writes FP state once). With every O4 knob at 1 (and
`QV_PIPE_SB_YIELD_READY=1`) the six CSVs are byte-for-byte O1's. Cycles, SoC, then the change in the other builds,
against O1:

| kernel | M, O1 | M, O4 | change | S change | M, sram | S, sram |
|---|---|---|---|---|---|---|
| memcpy | 770 | 760 | -1.3 % | -0.8 % | -5.7 % | +2.6 % |
| crc32 | 9785 | 6955 | -28.9 % | -19.3 % | -29.8 % | -19.0 % |
| qsort | 7188 | 6172 | -14.1 % | -14.1 % | -8.6 % | -7.2 % |
| matmul | 4959 | 4293 | -13.4 % | -20.0 % | -0.3 % | -1.8 % |
| sieve | 6117 | 6053 | -1.0 % | -23.5 % | -0.4 % | -0.5 % |
| listchase | 2786 | 2323 | -16.6 % | -0.1 % | -20.0 % | -0.1 % |
| mixedint | 4835 | 4654 | -3.7 % | -4.9 % | -2.5 % | -1.7 % |
| trap | 10032 | 9834 | -2.0 % | 0.0 % | -2.0 % | -0.0 % |
| fmatmul | 4624 | 4134 | -10.6 % | -8.3 % | -4.6 % | -11.6 % |
| fpmix | 4131 | 4122 | -0.2 % | -0.2 % | +0.0 % | -0.8 % |
| geomean | | | -9.7 % | -9.6 % | -7.9 % | -4.2 % |

No kernel gets slower on the SoC, and instret is unchanged on every row. The flat SRAM harness, where fetch and data
share one bus, loses 2.6 % on S `memcpy` (not gated: the SoC decides, as for the station).

- The O4.0 model said -10.6 % (M) and -14.5 % (S) against the core before the station, which is -9.8 % and -12.2 %
  against O1: the M figure lands within 0.1 point. S mode falls short by 2.6 points, nearly all of it `sieve` (the
  model -44.6 %, measured -23.5 %) and `matmul`, whose fetch the model copied from a one-wide trace (its frontend
  residuals) rather than modelled. OX.0 refits the model on traces of the two-wide core.
- `sieve` M and `listchase` S barely move: two retirements a cycle need two instructions a cycle from the frontend
  and work the one memory engine does not hold up (sieve M's loop straddles two dwords, see O4.0).
- O4f (`QV_PIPE_SB_YIELD_READY`, default 0): the store buffer's drain yields only to a load near the head, no longer to
  any memory op that is ready (P9d's rule, `=1`). At two-wide the trap handler's restores reached the LSU while one of
  its saves was still in the buffer; the drain kept yielding to the five restores that did not match it, and the sixth,
  which did, then waited a beat. `trap` M 10034 to 9834 cycles (-2.0 %), S back to O1's; every other row identical; at
  one-wide the cycles are identical either way (the side counters move, so it is the fourth knob of "every O4 knob at
  1").
- The Sv39 loop of `core_sv39_cpi_tb`: 3198 cycles in M mode and 3262 in S mode under Sv39 (O1: 3304 and 3311).

## The D$ inside the core and an 8-entry queue (O5a, branch `OOO`)

`QV_PIPE_DCACHE=1` (default 0 until O5/6 closes): a 2 KiB direct-mapped, write-through, no-allocate D$ (`qv_dc`, 64
lines of 32 bytes) beside the LSU instead of on the bus. A plain load from RAM that could start its access (at the
head, or early: translated, aligned, allowed, no store-buffer match) is answered in that very cycle when the D$ holds
its dword, and the LSU takes the next op in the same cycle, so the engine does one load a cycle; a miss refills its line
over the memory port (4 beats, the other masters wait) and the load completes with the refill's dword. The store
buffer's beats update a held line in their response cycle; the LSU's own writes that do not go through the buffer (an
SC, an AMO's write, a Program Buffer store) and the Debug Module's writes (a snoop from `soc.sv`) empty their line. In
the SoC the D$ on the bus (`cache_complex`'s `dcache0`) is then left out (`DC_EN 0`). With the D$ inside, the queue's
early lookup of the next op's translation is handed to the engine in the very cycle the engine takes it (`XL_FWD`):
without it a translated load paid its own lookup cycle in S mode. The queue grows to 8 (`QV_PIPE_LSQ_DEPTH=8`): it is
what `trap` gains from out-of-order memory at this window (4 points). With the knobs off the six CSVs are byte-for-byte
the committed ones. Cycles against the shipping core (O3 + O8), the D$ and the 8-entry queue on:

| kernel | M SoC | S SoC | M flat SRAM | S flat SRAM |
|---|---|---|---|---|
| memcpy | 727 -> 499 (-31.4 %) | 739 -> 508 (-31.3 %) | -17.3 % | -22.3 % |
| crc32 | 5465 -> 5458 (-0.1 %) | 5716 -> 5589 (-2.2 %) | -1.7 % | -3.8 % |
| qsort | 5263 -> 4981 (-5.4 %) | 5625 -> 5221 (-7.2 %) | -14.9 % | -15.6 % |
| matmul | 2967 -> 2699 (-9.0 %) | 3228 -> 2714 (-15.9 %) | -42.4 % | -39.1 % |
| sieve | 4563 -> 4549 (-0.3 %) | 3195 -> 3176 (-0.6 %) | -3.1 % | -6.9 % |
| listchase | 2318 -> 1754 (-24.3 %) | 2828 -> 1807 (-36.1 %) | -56.3 % | -49.4 % |
| mixedint | 3764 -> 2746 (-27.0 %) | 3982 -> 2760 (-30.7 %) | -27.0 % | -25.0 % |
| trap | 9833 -> 8036 (-18.3 %) | 10441 -> 8644 (-17.2 %) | -18.1 % | -17.0 % |
| fmatmul | 3402 -> 2767 (-18.7 %) | 3666 -> 3025 (-17.5 %) | -37.5 % | -32.2 % |
| fpmix | 4114 -> 4103 (-0.3 %) | 4122 -> 4111 (-0.3 %) | +1.0 % | +1.3 % |
| geomean | -14.2 % | -16.9 % | -24.1 % | -22.6 % |

instret is unchanged on every row. The O5.0 model said -14.7 % (M) and -16.9 % (S) on the SoC (D8 holds). The flat
SRAM's fpmix is 40 and 51 cycles slower, all of them the head waiting on the FP unit (`blk_fpu` 3719 -> 3760): with
its loads answered sooner, pipelined FP ops reach the FP unit's one writeback port in the cycles a finished divide wants
it, and the pipeline wins that port. The flat SRAM is reported, not gated.

### What the rest of O5/6 would buy (O5.0)

`ilp.py --fit o8 --set o5` on traces of the shipping core, the frontend modelled (`fe8`: the window aligner replays
the traces within 0.1 %), validated against runs of the core with one memory knob changed and against `run_perf.sh
--oracle dc` (the D$ arm with a D$ that never misses). In M mode every validation row is within 1 point of its
measurement on the geomean (HANDOFF 0 +9.5 / +9.7 %, LSQ 2 +1.8 / +1.2 %, EARLY_ST 0 +0.4 / +0.9 %, SB 8 -0.1 /
+0.0 %, the oracle -18.1 / -17.1 %); the worst kernels are `matmul` at LSQ 2 (5 points) and `mixedint` in the oracle
(4.8). In S mode the rows miss by 3 to 4 points (HANDOFF 0 +13.8 / +9.8 %, EARLY_ST 0 +7.5 / +4.3 %, LSQ 2 +1.4 /
+5.1 %: `sieve` and `listchase`, whose translated accesses the model times from the trace); the oracle is within 0.5
(-20.5 / -20.0 %) when it runs with the D$ knob on, so that the queue hands its lookup to the engine as the D$ that
ships does (`XL_FWD`; without it every translated hit paid a lookup cycle and the oracle measured -13.3 %). The D$ that
ships measures what the model said (-16.9 % against -16.9 %). The decisions below rest on M mode and on those
measurements. The oracle's cycles are `oracle_dc_pipe[_s].csv`. Three of the model's earlier assumptions were wrong and are fixed: two engines could both use one
blocking D$ (the OX.0 figure for O5/6, -7.4 %, came mostly from `listchase` doing that), forwarding never took a store
from the buffer, and a hit held the D$ two cycles. Geometric mean against the shipping core, SoC, M / S:

| configuration | L=1 M | L=1 S | L=20 M | L=20 S |
|---|---|---|---|---|
| the D$ inside the core (`dc`) | -14.3 % | -16.6 % | -10.1 % | -11.9 % |
| ... never missing (the oracle's bound) | -18.1 % | -20.5 % | -30.6 % | -32.3 % |
| ... and the queue at 8 (what ships) | -14.7 % | -16.9 % | -10.1 % | -11.9 % |
| a pipelined engine on the bus instead | -7.5 % | -8.1 % | -1.6 % | -2.8 % |
| `dc` + forwarding from the queue and the buffer | -14.3 % | -16.6 % | -12.7 % | -14.7 % |
| `dc` + critical word first | -14.9 % | -17.2 % | -11.5 % | -13.2 % |
| `dc` + misses that do not block (4 MSHRs) | -14.4 % | -16.8 % | -10.2 % | -12.1 % |
| `dc` + out-of-order memory issue (O6a, queue 8) | -14.7 % | -16.9 % | -10.1 % | -11.9 % |
| ... + forwarding and speculative loads (O6b) | -14.7 % | -16.9 % | -12.7 % | -14.7 % |
| O6a + forwarding + a second D$ port and engine | -14.8 % | -18.0 % | -13.2 % | -15.7 % |
| everything (O6a + O6b, forwarding, CWF, 2 MSHRs) | -16.1 % | -18.4 % | -15.9 % | -17.4 % |

- The D$ inside the core is the lever (rule D4: well past 2 points); it ships, with the queue at 8.
- Out-of-order memory issue (loads in program order among themselves, past stores) buys 0.0 over the in-order engine
  with an 8-entry queue on every kernel: the whole gain of `dc ooo` over `dc` is the queue's size (`trap`, 4 points).
  Loads passing loads, speculative loads, forwarding and a memory-dependence predictor buy 0.0 as well at L=1 (rules
  M1, M2, M3 fail).
- Critical word first (0.6 points) and misses that do not block (0.1-0.2) fail M4 and M5 at L=1; at L=20 forwarding
  is worth 2.6-2.8 points and critical word first with two MSHRs about 3, which the platform (a 1-cycle SRAM behind
  the SoC) does not have.
- A second D$ port: 0.1 (M) and 1.1 (S) points (M6: under 2).
- Sizes (D2): the queue at 8 (`trap` gains 4 points from 4 to 8), the D$ at 2 KiB (1 KiB loses 4 points on
  `listchase`, 4 KiB gains nothing: the kernels' misses are all compulsory).
- The user's decision (2026-11-15): ship the D$ and the 8-entry queue, record the rest as measured not worth it at
  this window, and go on to O7. Out-of-order memory issue and speculative loads are modelled again at the big window
  (see "The big window").

## The big window (O7, branch `OOO`)

The ROB's package depth and tag width come from `QV_ROB_MAX` (8 until O7c), the ROB itself from `QV_PIPE_ROB_DEPTH`
(default: the package depth), the station from `QV_PIPE_RS_DEPTH` and the queue from `QV_PIPE_LSQ_DEPTH`. Only the
sizes change: the station is still one collapsing queue, a recovery still rebuilds the producer tables from the
surviving ROB entries. With the defaults the six CSVs are byte for byte the committed ones. Seven points on the
shipping core with the D$ (O3 + O8 + O5a: ROB 8, RS 4, LSQ 8), geomean cycles against it:

| window | M SoC | S SoC | M flat SRAM | S flat SRAM |
|---|---|---|---|---|
| ROB 16, RS 8, LSQ 8 | -2.2 % | -3.4 % | -1.6 % | -2.6 % |
| ROB 32, RS 4, LSQ 16 | -2.3 % | -3.3 % | -1.2 % | -2.0 % |
| **ROB 32, RS 8, LSQ 8** | **-2.6 %** | **-3.8 %** | **-1.7 %** | **-2.8 %** |
| ROB 32, RS 8, LSQ 16 | -3.0 % | -4.1 % | -1.7 % | -2.8 % |
| ROB 64, RS 8, LSQ 16 | -3.1 % | -4.3 % | -1.7 % | -2.8 % |
| ROB 64, RS 16, LSQ 32 | -3.5 % | -4.6 % | -1.8 % | -2.9 % |

Rule D2 (the smallest power of two where doubling gains under 0.5 points on the geomean and under 2 on every kernel,
SoC, M and S):
- ROB 32: 16 to 32 gains 0.4 points (M and S) but 2.7 / 2.6 on `fmatmul`; 32 to 64 gains 0.1 / 0.2, at most 1.2
  (`memcpy`).
- RS 8: 4 to 8 gains 0.7 / 0.8 (`fpmix` 3.4 and 3.6, `crc32` 2.3 and 4.3). 8 to 16 was measured only together with
  the queue from 16 to 32, at ROB 64: 0.4 / 0.3, and 2.6 / 2.5 on `memcpy`, which never holds a station entry (the
  queue's share); the model gives the station's own 0.1 / 0.0 (`crc32` 0.5).
- LSQ 8: 8 to 16 gains 0.4 / 0.3, at most 1.8 (`memcpy`).

What ships at O7c, against O5a:

| kernel | M SoC | S SoC | M flat SRAM | S flat SRAM |
|---|---|---|---|---|
| memcpy | 499 -> 484 (-3.0 %) | 508 -> 486 (-4.3 %) | +0.0 % | +0.0 % |
| crc32 | 5458 -> 5334 (-2.3 %) | 5589 -> 5348 (-4.3 %) | -2.3 % | -4.4 % |
| qsort | 4981 -> 4895 (-1.7 %) | 5221 -> 5083 (-2.6 %) | -1.0 % | -1.5 % |
| matmul | 2699 -> 2657 (-1.6 %) | 2714 -> 2666 (-1.8 %) | +0.0 % | -0.1 % |
| sieve | 4549 -> 4547 (-0.0 %) | 3176 -> 3173 (-0.1 %) | +0.0 % | +0.0 % |
| listchase | 1754 -> 1747 (-0.4 %) | 1807 -> 1805 (-0.1 %) | +0.0 % | -0.2 % |
| mixedint | 2746 -> 2746 (+0.0 %) | 2760 -> 2747 (-0.5 %) | +0.0 % | -0.1 % |
| trap | 8036 -> 8036 (+0.0 %) | 8644 -> 8644 (+0.0 %) | +0.0 % | +0.0 % |
| fmatmul | 2767 -> 2419 (-12.6 %) | 3025 -> 2462 (-18.6 %) | -9.8 % | -16.4 % |
| fpmix | 4103 -> 3937 (-4.0 %) | 4111 -> 3938 (-4.2 %) | -4.0 % | -4.1 % |
| geomean | -2.6 % | -3.8 % | -1.7 % | -2.8 % |

instret is unchanged on every row, and no kernel is slower in any configuration. The model (`ilp.py` on O5.0's
traces with the window knobs, on top of the D$) said -3.3 % (M) and -4.0 % (S) for this point (D8 holds). Fitted the
other way, on traces of this point (`ilp.py --fit o7`), it reproduces the five other points with a ROB of 16 or more
within about 0.1 points of geomean in both modes, once the error of its own frontend model is set aside (`fe8` replays the
traces 1.4 / 1.1 % fast, `mixedint` by 6.8 points); at ROB 8 it misses `crc32` (+52 % against +2.3 %).

How full the window gets (`_ox.csv`, SoC, M mode; mean and largest occupancy of the ROB and the station, and the share
of cycles dispatch is held by a full ROB (`is_rob`), a full station (`is_rs`), room for only one of a pair (`rob_one`)
or a full queue (`is_lsq`)):

| kernel | ROB 8, RS 4: ROB | RS | is_rob | rob_one | ROB 32, RS 8, LSQ 8: ROB | RS | is_rob | is_lsq |
|---|---|---|---|---|---|---|---|---|
| memcpy | 4.2 / 8 | 0.0 / 1 | 14.2 % | 0.0 % | 8.1 / 21 | 0.0 / 1 | 0.0 % | 11.2 % |
| crc32 | 5.8 / 7 | 2.2 / 4 | 0.0 % | 4.7 % | 11.1 / 13 | 6.4 / 8 | 0.0 % | 0.0 % |
| qsort | 3.0 / 8 | 0.3 / 3 | 1.6 % | 5.8 % | 3.4 / 23 | 0.4 / 4 | 0.0 % | 0.2 % |
| matmul | 5.1 / 8 | 0.9 / 2 | 3.3 % | 1.0 % | 6.4 / 32 | 1.1 / 8 | 0.3 % | 0.8 % |
| sieve | 3.0 / 8 | 0.3 / 2 | 0.1 % | 0.0 % | 3.0 / 15 | 0.3 / 2 | 0.0 % | 0.0 % |
| listchase | 4.2 / 8 | 0.2 / 1 | 12.8 % | 0.6 % | 6.8 / 20 | 0.7 / 4 | 0.0 % | 12.2 % |
| mixedint | 4.0 / 8 | 0.2 / 2 | 0.4 % | 2.2 % | 4.0 / 10 | 0.2 / 2 | 0.0 % | 0.0 % |
| trap | 3.3 / 8 | 0.4 / 4 | 0.2 % | 5.1 % | 3.3 / 25 | 0.4 / 4 | 0.0 % | 0.0 % |
| fmatmul | 6.2 / 8 | 0.1 / 2 | 9.8 % | 21.3 % | 23.4 / 32 | 2.3 / 5 | 0.7 % | 8.9 % |
| fpmix | 5.6 / 8 | 3.7 / 4 | 3.0 % | 3.9 % | 14.1 / 32 | 7.9 / 8 | 1.4 % | 0.0 % |

- `fmatmul` is the kernel the window is for: at ROB 8 dispatch waits on a full ROB in 10 % of its cycles and the ROB
  has room for only one of a pair in 21 % more; at 32 it holds 23 entries on average.
- `memcpy` and `listchase` trade a full ROB for a full queue: at LSQ 8 dispatch waits on the queue in 11-12 % of their
  cycles, and a 16-entry queue removes that for 1.8 and 0.4 points (under D2's bar).
- `fpmix` keeps a full station in 89 % of its cycles at RS 4 and at RS 8: its divides wait for the one FP
  divide/square-root unit and the entries behind them are what the extra four buy (4 points). That is the only kernel
  where `is_rs` reaches 2 %, so the station stays one unified queue (O7 Decision 1).
- `sieve`, `mixedint` and `trap` hold 3 to 4 entries on average at either size: the window is not what limits them.

### O5/6 at the big window (O7 Decision 5)

O5.0 measured the rest of O5/6 at ROB 8, where nothing but the queue's size paid. On the traces of ROB 32, RS 8, LSQ 8
(`ilp.py --fit o7 --set o7`, each configuration against the replayed frontend, `fe8`), points of geomean, M / S, and
the kernel that gains most:

| configuration | M | S | most |
|---|---|---|---|
| out-of-order memory issue, loads in program order (O6a) | 0.2 | 0.2 | `fmatmul` 2.3 / 2.2 |
| ... loads passing loads | 0.2 | 0.2 | `fmatmul` 2.3 / 2.2 |
| forwarding from the queue and the buffer | 0.0 | 0.0 | `qsort` 0.2 / 0.3 |
| O6a + forwarding + a store's address before its data (O6a's split) | 1.0 | 1.0 | `fmatmul` 9.7 / 9.3 |
| O6a + forwarding + speculative loads (O6b, any predictor or none) | 1.0 | 1.0 | `fmatmul` 9.7 / 9.3 |
| ... with the queue at 16 | 1.4 | 1.4 | `fmatmul` 11.2 / 11.3 |
| critical word first | 0.5 | 0.5 | `memcpy` 2.1 / 2.1 |
| misses that do not block (2 or 4) | 0.3 | 0.3 | `listchase` 1.3 / 1.3 |
| O6a + a second D$ port and engine | 0.8 | 1.0 | `fmatmul` 4.9 / 4.5 |

- M1 fails (out-of-order issue 0.2 points, at most 2.3 on a kernel, against 1 and 3), and so does M3 (speculative
  loads 0.7 / 0.7 over O6a with forwarding, against 1); M2, M4, M5 and M6 fail as at ROB 8. O7 Decision 5 asks again
  only if one of M1 and M3 passes, so O6 stays unbuilt, as recorded after O5.0.
- What the big window changes is `fmatmul`: in the model its loads wait behind older stores that wait for their data,
  and a store's address known before its data (M3a: within 0.5 points of speculation, here the same) lets them go;
  together with out-of-order issue that is 9-10 points there and 1 point on the geomean.

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

### Early-load oracle (before the load/store queue, O2.0)

`run_perf.sh --oracle early` (both configurations; `--mode s` too) built the core with `oracle_lsu.sv` in place of
`qv_lsu.sv`: a plain load from RAM starts before it is the ROB head, as soon as it is translated, aligned, allowed and
has no store-buffer match, and its result waits for its commit in a per-tag copy of the LSU's result. It is still one
op at a time with a lost cycle between ops, and it checks no barriers, so it is a timing model, not a core. The bound
column is the window minus the cycles the head waited for the LSU in the baseline's stack (everything memory costs
at the head). `oracle_early_pipe.csv`, `oracle_early_pipe_s.csv`; instret is unchanged on every kernel. (The option
and `oracle_lsu.sv` were removed in O7a: the engine they bounded shipped as O2a, and the copy no longer matched its
ports. The two CSVs are kept as data.)

| kernel | M SoC | early loads | change | M SRAM change | bound (SoC) | S SoC change |
|---|---|---|---|---|---|---|
| memcpy | 1148 | 1020 | -11.1 % | -3.0 % | -39.7 % | 0.0 % |
| crc32 | 9913 | 9786 | -1.3 % | -1.3 % | -3.0 % | 0.0 % |
| qsort | 8566 | 7819 | -8.7 % | -7.8 % | -22.5 % | -6.9 % |
| matmul | 6972 | 6012 | -13.8 % | -3.6 % | -32.2 % | -6.7 % |
| sieve | 7540 | 7512 | -0.4 % | -0.3 % | -19.7 % | 0.0 % |
| listchase | 4883 | 3348 | -31.4 % | -11.2 % | -47.3 % | -10.5 % |
| mixedint | 6939 | 6215 | -10.4 % | -2.3 % | -31.4 % | -0.1 % |
| trap | 13432 | 13432 | 0.0 % | -1.6 % | -35.9 % | 0.0 % |
| fmatmul | 7740 | 5749 | -25.7 % | -16.1 % | -30.6 % | -19.3 % |
| fpmix | 4427 | 4393 | -0.8 % | -1.5 % | -3.3 % | 0.0 % |

At least 5 % on six kernels of the SoC configuration, so the load/store queue is a go. What the oracle leaves: stores
still hold the head (sieve, trap, memcpy's stores), the engine loses a cycle between ops (the handoff), and in S mode
a load meets its translation only once it is in the engine, a cycle before it could start (memcpy, mixedint: O2c).

### Branch traces

`+BRTRACE` (a plusarg of `perf_tb`) makes the monitor print one line per control-flow instruction retired
inside the window; `brpred.py` replays such traces through a history table, a target buffer and a
return-address stack to see what each would buy before building it. Its cost model overestimates (a taken
branch's bubble is mostly hidden by the queues; a mispredict costs about 4.5 cycles in the stack above, not 8).

`check_cpi.py` compares a run's `baseline_pipe.csv` with the committed one: it fails when a kernel's
instret changes or its cycles rise on the SoC configuration.

### What out-of-order issue and two-wide would buy (O1.0)

`run_perf.sh --ilptrace DIR` writes one line per instruction retired in each window (`+ILPTRACE`: the cycles it
entered and left the instruction queue, was issued, reached the LSU, started its access, wrote back and committed),
and `ilp.py --traces DIR` replays the traces through a dataflow model of the core: in-order dispatch into the ROB and
the load/store queue, issue in order or (with a reservation station) out of order, one memory engine in order with the
handoff, the D$ shared by loads and the store buffer's drain (a beat holds the D$ for 3 cycles, 5 before the D$ store
pass-through: `--db`; a load that is ready, or waiting near the ROB head, holds the drain off until the buffer is full
or 16 cycles have passed), commit in order, and the refill after each commit redirect. What the structure does not
explain is kept as a per-instruction residual measured on the core as it is, so the traced configuration replays
exactly.

The model was checked against runs of the core with one knob changed (`--validate`, the SoC configuration, M mode),
before the D$ store pass-through and again after it: it predicts the cycle change of every kernel within 0.3
percentage points (0.2 after) for the queue off (`QV_PIPE_LSQ_DEPTH=0`, now: memcpy +49.1 %, listchase +74 %,
fmatmul +66 %), early accesses off, the handoff off, the bypass off (crc32 +23.5 %) and a store buffer of 2 (trap
+7.8 %); and it predicted the pass-through itself, before it was built, to the tenth of a point. It does not predict
the frontend: with `QV_PIPE_FETCH_STREAM=0` sieve measures +47 % and the model says +1 %, so the two-wide figures
below are given with the frontend's measured gaps kept (`res`, pessimistic) and with an ideal streaming frontend
(`ideal`: a dword a cycle, two instructions a cycle into the queue). The SRAM harness, where fetch and data share one
bus, is not modelled.

Change in cycles against the core after the D$ store pass-through, SoC configuration (S mode in brackets where it
differs by more than 2 points):

| kernel | OOO, RS 8 | + ROB 16 | drain beat 2 cycles | 2-wide in order | 2-wide OOO (res .. ideal) | 2-wide OOO + beat 2 cycles |
|---|---|---|---|---|---|---|
| memcpy | 0.0 % | 0.0 % | -0.9 % | -1.0 % | -1.0 % | -16.5 % |
| crc32 | 0.0 % | 0.0 % | 0.0 % | -30.2 % (-20.6 %) | -30.2 .. -31.5 % (-20.8 .. -30.7 %) | -31.5 % |
| qsort | -0.1 % | -0.1 % | -0.2 % | -14.8 % | -14.8 .. -16.7 % | -18.2 % |
| matmul | -0.4 % (-8.4 %) | -0.4 % (-8.4 %) | 0.0 % | -15.0 % | -18.6 .. -30.7 % (-26.3 .. -29.1 %) | -30.7 % |
| sieve | 0.0 % | 0.0 % | 0.0 % | -1.0 % (-44.7 %) | -1.1 .. -46.5 % (-44.7 .. -46.2 %) | -46.5 % |
| listchase | -0.7 % | -0.7 % | 0.0 % | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) |
| mixedint | 0.0 % | 0.0 % | 0.0 % | -2.5 % | -2.5 .. -6.5 % | -15.2 % |
| trap | -2.0 % | -2.0 % | -2.0 % | -7.8 % (-5.6 %) | -5.8 .. -5.9 % | -19.6 % |
| fmatmul | -0.8 % (-9.0 %) | -1.4 % (-9.0 %) | 0.0 % | -8.4 % (-11.6 %) | -9.3 .. -19.7 % (-18.8 .. -23.5 %) | -19.7 % (-23.5 %) |
| fpmix | -5.5 % | -10.7 % | 0.0 % | -0.8 % | -10.8 .. -11.0 % | -11.0 % |
| geomean | -1.0 % (-2.6 %) | -1.6 % (-3.2 %) | -0.3 % | -10.4 % (-12.6 %) | -11.6 .. -19.9 % (-15.7 .. -18.5 %) | -23.4 % (-22.1 %) |

(2-wide: two dispatches, two ALU pipes, two commits a cycle, a pair only behind a plain retirement, ROB 16, one memory
engine; "drain beat 2 cycles": the store buffer presents a beat in the cycle it decides it, where `qv_sb` registers it
today; the last column has the ideal frontend.)

What it says:
- Out-of-order issue alone still buys about 1 % (2.6 % in S mode): dispatch and commit stay one a cycle, and what the
  head waits for is mostly memory, which the queue already starts early. fpmix (the divides overlap the work behind
  them, more with a bigger ROB), trap and, in S mode, matmul and fmatmul gain.
- The drain no longer binds at one-wide: a 2-cycle beat buys 0.3 %.
- Two-wide in order gains 10.4 % (12.6 % in S mode); out of order adds 1 to 9 points on top (the measured frontend ..
  an ideal one), almost all of it on matmul, fmatmul and fpmix. sieve's M build gains 46 % only with an ideal frontend:
  its loop straddles two dwords (the S build's does not). trap is the one kernel where out of order is worse than in
  order at two-wide, by 2 points.
- At two-wide the drain binds again on the store-heavy kernels: with a 2-cycle beat memcpy goes from -1 % to -16.5 %,
  mixedint from -6.5 % to -15.2 %, trap from -5.9 % to -19.6 %.

Before the D$ store pass-through (the run that chose it; "D$ write 3 cycles" is the pass-through, with the ideal
frontend in the last column):

| kernel | OOO, RS 8 | + ROB 16 | D$ write 3 cycles | 2-wide in order | 2-wide OOO (res .. ideal) | 2-wide OOO + D$ write 3 |
|---|---|---|---|---|---|---|
| memcpy | 0.0 % | 0.0 % | -23.5 % | -1.2 % | -1.2 % | -24.3 % |
| crc32 | 0.0 % | 0.0 % | 0.0 % | -30.2 % (-20.6 %) | -30.2 .. -31.5 % | -31.5 % |
| qsort | -0.1 % | -0.1 % | -3.6 % | -15.2 % | -15.3 .. -17.1 % | -19.7 % |
| matmul | -0.4 % (-8.4 %) | -0.4 % (-8.4 %) | 0.0 % | -13.1 % | -18.6 .. -30.7 % | -30.7 % |
| sieve | 0.0 % | 0.0 % | 0.0 % | -1.0 % | -1.1 .. -3.1 % | -46.5 % |
| listchase | -0.7 % | -0.7 % | 0.0 % | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) | -17.2 % |
| mixedint | 0.0 % | 0.0 % | -19.8 % | -5.0 % | -5.0 .. -6.1 % | -25.0 % |
| trap | 0.0 % | 0.0 % | -19.0 % | -4.7 % | -4.7 .. -4.8 % | -23.8 % |
| fmatmul | -0.8 % (-9.0 %) | -1.4 % (-9.0 %) | 0.0 % | -8.4 % | -9.3 .. -19.7 % | -19.7 % |
| fpmix | -5.5 % | -10.7 % | 0.0 % | -0.8 % | -10.8 .. -11.0 % | -11.0 % |
| geomean | -0.8 % (-2.4 %) | -1.4 % (-3.0 %) | -7.1 % | -10.2 % (-7.2 %) | -11.8 .. -14.9 % | -25.6 % |

Then the D$ write path was the biggest lever at one-wide (a store's drain held the D$ for 5 cycles, a load for 2:
memcpy's loop was exactly those 7 cycles), and store-heavy code gained from two-wide only with it.

### Two-wide with its pair rules (O4.0)

`ilp.py --set o4` runs the two-wide configurations with the pair rules of O4 as knobs (all off by default, so the O1.0
tables above are unchanged): at most one memory op in a dispatch pair (`mem1`), at most one uop touching FP state
(`fp1`), CSR, SYS, FENCE, divide, FP divide/square root, atomic and trapping uops dispatched alone (`alone`), branches and
multiplies on port 0 only (`p0`), no trap, CSR, SYS or FENCE in the second commit slot (`slot2`), at most one FP-state
write per commit pair (`fpw1`), and two commits with one dispatch (`dispatch1`). The fit is on traces with
`QV_PIPE_RS_DEPTH=0`, because it needs the units' own latencies; its "OOO, RS 4" reproduces what the station measured.

Change in cycles against the core before the station, SoC configuration (S mode in brackets):

| kernel | two commits, one dispatch | 2-wide in order, ROB 16 | 2-wide OOO, no rules, ROB 16, RS 8 | every rule, ROB 16, RS 8 | every rule, ROB 8, RS 4 | the same, ideal frontend |
|---|---|---|---|---|---|---|
| memcpy | -0.6 % (-1.0 %) | -1.0 % (-1.2 %) | -1.0 % (-1.2 %) | -1.2 % (-1.2 %) | -1.2 % (-1.2 %) | -1.2 % (-1.5 %) |
| crc32 | -1.3 % (-1.3 %) | -30.2 % (-20.6 %) | -30.2 % (-20.8 %) | -30.2 % (-20.8 %) | -30.2 % (-20.7 %) | -31.5 % (-30.7 %) |
| qsort | -3.7 % (-6.5 %) | -14.8 % (-13.3 %) | -14.8 % (-14.0 %) | -14.5 % (-13.4 %) | -14.5 % (-13.3 %) | -16.0 % (-14.2 %) |
| matmul | -3.4 % (-11.1 %) | -15.0 % (-13.2 %) | -18.6 % (-26.3 %) | -18.6 % (-26.3 %) | -18.5 % (-26.3 %) | -30.7 % (-29.1 %) |
| sieve | -0.2 % (-0.5 %) | -1.0 % (-44.7 %) | -1.1 % (-44.7 %) | -1.1 % (-44.7 %) | -1.1 % (-44.7 %) | -46.5 % (-46.1 %) |
| listchase | -0.9 % (0.0 %) | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) | -17.2 % (-0.1 %) |
| mixedint | -1.3 % (-2.4 %) | -2.5 % (-3.9 %) | -2.5 % (-3.9 %) | -2.5 % (-3.8 %) | -2.5 % (-3.7 %) | -6.4 % (-7.3 %) |
| trap | -2.0 % (-1.9 %) | -7.8 % (-5.6 %) | -5.8 % (-3.8 %) | -1.9 % (0.0 %) | -1.9 % (0.0 %) | -2.0 % (-1.9 %) |
| fmatmul | -2.3 % (-10.5 %) | -8.4 % (-11.6 %) | -9.3 % (-18.8 %) | -9.3 % (-18.8 %) | -8.7 % (-16.5 %) | -14.3 % (-18.1 %) |
| fpmix | -5.2 % (-5.7 %) | -0.8 % (-0.8 %) | -10.8 % (-11.4 %) | -10.7 % (-11.4 %) | -5.6 % (-6.0 %) | -5.8 % (-6.1 %) |
| geomean | -2.1 % (-4.2 %) | -10.4 % (-12.6 %) | -11.6 % (-15.7 %) | -11.2 % (-15.3 %) | -10.6 % (-14.5 %) | -18.5 % (-16.9 %) |

("two commits, one dispatch": ROB 8, RS 4, with the commit rules `slot2` and `fpw1`.)

What it says:
- Each rule alone costs nothing on the geometric mean except `slot2` (0.4 points in both modes): the trap
  kernel's `ecall` and `mret` would otherwise retire beside the instruction before them. The other five together cost
  under 0.1.
- ROB 16 and RS 8 buy 0.6 points (0.8 in S mode), nearly all on fpmix, whose divides overlap more work with more room.
- Two commits with one dispatch buy 2.1 % (4.2 %), 1.2 (1.6) points more than the station alone ("OOO, RS 4"),
  mostly on qsort, matmul and fmatmul.
- The measured frontend is the largest gap: with an ideal one the same core gains 18.5 % (16.9 %) instead of 10.6 %
  (14.5 %), almost all on sieve's M build (its loop straddles two dwords), matmul and crc32. The model keeps the
  measured frontend gaps, which at one-wide include the IQ's back-pressure, so it cannot say how much of that the real
  frontend already has at two-wide: OX.0 measures it on the two-wide core (O4f became the store-buffer rule, see
  "Two-wide").
