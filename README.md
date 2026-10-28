# QuantiumV

A 64-bit RISC-V SoC in SystemVerilog, built from scratch.
Join the [Discord](https://discord.gg/sQjhBvWXjF) if you want to take part.

## What's here

**Core** (`design/pipe/core.sv`, module `core`): a pipelined core that one hart runs on.
Fetch, align (RVC), decode, in-order issue into a reorder buffer, ALU / branch / divide /
floating-point / load-store units, and in-order commit, which owns every architectural effect (register
writes, CSRs, traps, privilege changes, interrupts and debug entry). Single issue; fetch runs back to
back and predicts branches (a target buffer, a history table, a return-address stack); loads execute at
the head of the ROB, and stores to RAM retire into a store buffer that writes them out behind it.
Translated code runs at nearly untranslated speed (fetch reuses its last page, the data side looks up its
TLB before the head), and CSR reads and trap-CSR writes do not flush the pipeline.

- RV64IMAFDC (RV64GC: also Zicsr, Zifencei), with Zcd
- An FPU with IEEE 754 single and double precision: a 4-stage pipeline (fused multiply-add, the other
  arithmetic, conversions, compares) that takes one op per cycle, and divide/square root beside it
- M, S and U modes, with trap delegation
- Sv39 virtual memory (a 4-entry TLB each for instruction fetch and data, one page-table walker, superpages, A/D bits checked rather than updated)
- PMP with 4 regions
- Timer and external interrupts
- RISC-V Debug Module over JTAG, which works with OpenOCD

It doesn't have user-level counters, vectored `mtvec`, or misaligned
access support (those trap). `QV_FPU_EN=0` builds it without F/D.

**SoC** (`design/soc.sv`): the core, write-through L1 I/D caches, and Wishbone
peripherals.

| Address | Device |
|---|---|
| `0x0000_0000` | RAM, 64 MB |
| `0x0400_8000` | UART (NS16550A) |
| `0x0401_0000` | CLINT (SiFive layout) |
| `0x0440_0000` | PLIC (SiFive layout; UART RX is the only source) |

The core resets to address 0 in M-mode.

**Reference core** (`verification/reference/ref_core.sv`): the multi-cycle core that
`design/core.sv` used to be, frozen. Every retired instruction of the pipelined core is
checked against it (lockstep, random programs, ACT, firmware), and the whole regression
also runs against it (`make regress CORE=ref`). It is changed only to fix a bug, through
the errata rule in [`verification/reference/README.md`](verification/reference/README.md).

## Requirements

Linux or WSL with:
- Icarus Verilog
- `riscv64-unknown-elf-gcc`
- Verilator, for lint and the OpenOCD test

## Running a program

```sh
make run PROG=verification/run/examples/hello.c
```

This builds a bare-metal C or assembly program and runs it on the SoC in
simulation, with UART output in your terminal. See
[`verification/run/README.md`](verification/run/README.md).

## Testing

| Command | What it does |
|---|---|
| `make regress [CORE=pipe\|ref]` | The unit and integration testbenches (`pipe`, the default, is the core; `ref` is the frozen reference) |
| `make lint [CORE=...]` | Verilator lint of the full SoC |
| `make act` | The official RISC-V architecture tests: 110/111 pass, and 334/337 with `CONFIG=quantiumv-rv64imafdc` (F, D, Zcd, A, Zifencei). `S-00` fails in both: the configs don't declare Sv39, so Sail reads `sstatus.SUM` as 0 where the core keeps it. `Zalrsc-sc.w`/`sc.d` fail because any store between LR and SC clears the reservation here. |
| `make lockstep` | Runs the core and the reference side by side and compares every retired instruction |
| `make openocd-smoke` | OpenOCD drives the Debug Module over JTAG |

riscv-formal passes all 91 `rv64ic` checks plus liveness and hang, and the 18 AMO checks, on the
core; see [`verification/riscv-formal/quantiumv_pipe/README.md`](verification/riscv-formal/quantiumv_pipe/README.md).
CPI benchmarks are in `verification/perf/`.

## Layout

| Path | Contents |
|---|---|
| `design/` | RTL and its unit testbenches |
| `design/pipe/` | The core (`core.sv`) and its pipeline stages (`qv_*.sv`) |
| `testbench/` | Core-, SoC- and debug-level testbenches |
| `firmware/` | Test programs used by the testbenches |
| `verification/` | Regression, lockstep, compliance, formal, perf, `make run`, and the frozen reference core (`reference/`) |
| `third_party/taxi/` | AXI4 IP used by the standalone Wishbone-to-AXI DRAM model in `verification/taxi/` (Verilator only) |

## Linux

Linux doesn't boot on this RTL yet. The peripherals use the standard
16550, CLINT and PLIC layouts, so stock OpenSBI and Linux drivers should
work. What's missing is an SBI build and a device tree for this memory map.
That work is tracked in [`quantiumv/sdk`](https://github.com/quantiumv/sdk).

## Contributing

Discuss changes on Discord first. Every RTL change comes with tests, and
`make regress` and `make lint` must stay clean.

## License

[MIT](LICENSE)
