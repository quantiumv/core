# QuantiumV

A 64-bit RISC-V SoC in SystemVerilog, built from scratch.
Join the [Discord](https://discord.gg/sQjhBvWXjF) if you want to take part.

## What's here

**Core** (`design/core.sv`): an in-order, multi-cycle core that one hart runs on.

- RV64IMAC, Zicsr, Zifencei
- M, S and U modes, with trap delegation
- Sv39 virtual memory (4-entry TLB, superpages, A/D bits checked rather than updated)
- PMP with 4 regions
- Timer and external interrupts
- RISC-V Debug Module over JTAG, which works with OpenOCD

It doesn't have F/D, user-level counters, vectored `mtvec`, or misaligned
access support (those trap).

**SoC** (`design/soc.sv`): the core, write-through L1 I/D caches, and Wishbone
peripherals.

| Address | Device |
|---|---|
| `0x0000_0000` | RAM, 64 MB |
| `0x0400_8000` | UART (NS16550A) |
| `0x0401_0000` | CLINT (SiFive layout) |
| `0x0440_0000` | PLIC (SiFive layout; UART RX is the only source) |

The core resets to address 0 in M-mode.

**Pipelined core** (`design/pipe/`, in progress): a ROB-based replacement for
`core.sv`. It currently runs RV64I, multiply, RVC, Zicsr and Zifencei in
M-mode. Every retired instruction is checked against a frozen copy of
`core.sv` (`verification/reference/`). It will replace `core.sv` once it
reaches feature parity.

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
| `make regress [CORE=fsm\|ref\|pipe]` | The unit and integration testbenches |
| `make lint [CORE=...]` | Verilator lint of the full SoC |
| `make act` | The official RISC-V architecture tests: 110/111 pass. `S-00` fails because there is no FPU (`mstatus.FS` is hardwired to 0). |
| `make lockstep` | Runs two cores side by side and compares every retired instruction |
| `make openocd-smoke` | OpenOCD drives the Debug Module over JTAG |

riscv-formal passes all 91 `rv64ic` checks; see
[`verification/riscv-formal/quantiumv/README.md`](verification/riscv-formal/quantiumv/README.md).
CPI benchmarks are in `verification/perf/`.

## Layout

| Path | Contents |
|---|---|
| `design/` | RTL and its unit testbenches |
| `design/pipe/` | The pipelined core |
| `testbench/` | Core-, SoC- and debug-level testbenches |
| `firmware/` | Test programs used by the testbenches |
| `verification/` | Regression, lockstep, compliance, formal, perf and `make run` |
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
