# CPI kernels

Seven small C kernels, each timed with `mcycle`/`minstret` around its main
loop. They run on two configurations:

- **sram:** the core alone on flat SRAM (`core_wb4_sram_harness`).
- **cache:** the full SoC with its L1 caches (`soc.sv`).

```sh
verification/perf/run_perf.sh --core fsm     # writes baseline_fsm.csv
verification/perf/run_perf.sh --core pipe    # writes baseline_pipe.csv
```

The kernels are built with `-mno-div`, and division goes through libgcc so
they also run on core_pipe, which has no divider yet. Only setup loops
divide; the timed regions never do.

## Results (2026-10-05)

CPI (cycles per retired instruction):

| Kernel | FSM, sram | pipe, sram | FSM, cache | pipe, cache |
|---|---|---|---|---|
| memcpy | 3.78 | 2.42 | 4.29 | 2.36 |
| crc32 | 3.03 | 1.26 | 3.04 | 1.25 |
| qsort | 3.56 | 2.50 | 3.74 | 2.47 |
| matmul | 3.63 | 1.95 | 3.69 | 1.79 |
| sieve | 3.97 | 2.48 | 4.45 | 2.01 |
| listchase | 3.80 | 2.01 | 3.91 | 1.92 |
| mixedint | 4.00 | 2.25 | 4.34 | 2.14 |

core_pipe (P4) is 1.4–2.4× faster than the FSM on every kernel. Loads and
stores still execute one at a time at the ROB head, and branches resolve
at commit; those are the P9 performance steps.
