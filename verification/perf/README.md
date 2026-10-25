# CPI kernels

Seven small C kernels, each timed with `mcycle`/`minstret` around its main
loop. They run on two configurations:

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

## Results (2026-10-05)

CPI (cycles per retired instruction):

| Kernel | reference, sram | core, sram | reference, cache | core, cache |
|---|---|---|---|---|
| memcpy | 3.78 | 2.42 | 4.29 | 2.36 |
| crc32 | 3.03 | 1.26 | 3.04 | 1.25 |
| qsort | 3.56 | 2.50 | 3.74 | 2.47 |
| matmul | 3.63 | 1.95 | 3.69 | 1.79 |
| sieve | 3.97 | 2.48 | 4.45 | 2.01 |
| listchase | 3.80 | 2.01 | 3.91 | 1.92 |
| mixedint | 4.00 | 2.25 | 4.34 | 2.14 |

The core (since P4) is 1.4–2.4× faster than the reference on every kernel. Loads and
stores still execute one at a time at the ROB head, and branches resolve
at commit; those are the P9 performance steps.

The core's numbers are unchanged through P5, P6, P7 and the P8 switchover
(`baseline_pipe.csv` reproduces exactly from a clean run, and `baseline_ref.csv`
is the old `baseline_fsm.csv`): with satp Bare, translation costs nothing,
and a redirect that changes the translation context waits one fetch cycle only
while satp is on or being written.

What Sv39 costs (`testbench/core_sv39_cpi_tb.sv`, run by the regression): the
same loop of 300 iterations (8 instructions: ALU, a load, a store, a branch)
in M-mode and in S-mode under an identity 1 GiB leaf, in cycles:

| core | M-mode | S-mode, Sv39 | ratio |
|---|---|---|---|
| reference (`ref_core.sv`) | 8400 | 11400 | 1.35 |
| core | 4805 | 5113 | 1.06 |

A translated fetch dword and a translated access each take one more cycle
(the answer is registered before it is used); the pipeline hides most of it.
Overlapping the instruction-TLB lookup with the previous fetch beat is a follow-up (see the P9 plan).

## CPI stack (P9.0)

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
the LSU's request waits while fetch holds the shared SRAM, meaningful in the `sram` configuration only):

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

### Ideal-store oracle

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
the P9 plan predicted. The bound is at least 5 % on three kernels, so the store buffer (P9d) is a go.

`check_cpi.py` compares a run's `baseline_pipe.csv` with the committed one: it fails when a kernel's
instret changes or its cycles rise on the SoC configuration.
