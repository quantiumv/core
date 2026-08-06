# QuantiumV

A RISC-V SoC, built collaboratively from scratch in SystemVerilog.

Join on [Discord](https://discord.gg/sQjhBvWXjF) if you're interested in the project!

---

## Current state

**RV64I base ISA + Zicsr (CSR instructions)**, non-pipelined, single-hart, fully
verified. The core is a multi-cycle Wishbone-master FSM (fetch → execute →
memory, one instruction fully retires before the next begins -- no forwarding,
no hazards to design around yet) driving a real Wishbone bus out to two real
peripherals.

### Architecture

- `design/decoder.sv`, `design/alu.sv`, `design/register_file.sv`,
  `design/csr_file.sv` -- the datapath: instruction decode, ALU (full RV64I
  arithmetic/logic/shift ops including the `*W` word-width family), a 32-entry
  general-purpose register file, and the 8 machine-mode CSRs this milestone
  backs (`misa`, `mvendorid`/`marchid`/`mimpid`/`mhartid`, `mscratch`,
  `mcycle`, `minstret`).
- `design/core.sv` -- ties the above together as a Wishbone bus master. No
  private instruction/data memory of its own; every fetch and load/store goes
  out over the bus.
- `design/wb4_sram.sv`, `design/uart_tx.sv`, `design/wb_addr_decoder.sv` --
  the two real Wishbone slaves (a flat 64-bit-word memory, and a
  simulation-only UART that transmits via `$write`) plus the address decoder
  routing between them.
- `design/soc.sv` -- top-level integration: `core` + `wb_addr_decoder` +
  `wb4_sram` + `uart_tx`, `clk`/`rst` are its only ports.

Privilege modes, traps/interrupts, and virtual memory (Sv39) don't exist yet --
every access currently runs unconstrained, `ECALL` is a no-op, and the CSRs
backed today are exactly the ones meaningful without that infrastructure. See
`design/csr_file.sv`'s own header for the full scope note.

### Verification

17 testbenches (unit-level for the ALU/register file/CSR file in isolation,
integration-level driving the real Wishbone bus, one running a real
`riscv64-unknown-elf`-assembled program), all passing. Shared infrastructure
lives in `testbench/`: `check_lib.sv` (a `check()` primitive), `wb_driver.sv`
(a Wishbone bus-cycle task), `halt_wait.sv` (timeout-guarded halt waiting),
`pc_trigger_sample_monitor.sv` and `core_wb4_sram_harness.sv` (reusable
monitor/harness modules) -- pulled into new testbenches via `` `include ``
rather than hand-rolled each time.

Real code coverage has been measured (line/branch/toggle/expression, via
Verilator) across every live design file, not just claimed. Current whole-design
coverage: 97.6% line, 99.0% branch, 100% expression -- what's left uncovered
is understood and benign (a couple of structurally-unreachable default arms,
one genuinely unused ALU op, one buffer-full guard that'd need over 256 writes
in a single test to trigger).

---

## Building and simulating

Everything here is developed and verified against **Icarus Verilog**
(`iverilog`/`vvp`) and **Verilator**, run through WSL on Windows. There is no
single top-level build script yet -- compile the specific file set a given
testbench needs directly, e.g.:

```sh
iverilog -g2012 -I design -I testbench -o /tmp/soc_tb.out \
  design/alu.sv design/decoder.sv design/register_file.sv design/csr_file.sv \
  design/core.sv design/wb4_sram.sv design/uart_tx.sv design/wb_addr_decoder.sv \
  design/soc.sv testbench/soc_tb.sv
cd design && vvp /tmp/soc_tb.out
```

`-I design -I testbench` resolves every `` `include `` (Icarus does not
resolve include paths relative to the including file, only via `-I`). Run
from inside `design/` when a testbench instantiates `wb4_sram` directly, so
its `$readmemh` of `../firmware/crt0.hex` resolves.

A Verilator lint pass over the full SoC:

```sh
verilator --lint-only -Wall -Idesign -Itestbench --top-module soc \
  design/alu.sv design/decoder.sv design/register_file.sv design/csr_file.sv \
  design/core.sv design/wb4_sram.sv design/uart_tx.sv design/wb_addr_decoder.sv \
  design/soc.sv
```

(Verilator wants `-Idesign`, no space; Icarus accepts either form.)

`firmware/` holds a real C toolchain build (`riscv64-unknown-elf-gcc`/`-as`/
`-ld`) producing the hex images some testbenches load -- see
`firmware/Makefile`.

---

## Roadmap

RV64**IMAC** + Zicsr + U/S/M privilege + Sv39, non-pipelined and in-order,
before any pipelining/OoO work starts -- deliberately, so out-of-order
correctness has a trusted in-order reference to debug against. M (multiply/
divide) is next: no privilege or trap prerequisites, unlike A or C eventually
will need. Bus protocol stays Wishbone at the core; AXI4 is a future fabric
concern at the edge, not a core-level one.
