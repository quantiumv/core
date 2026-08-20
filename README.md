# QuantiumV

A RISC-V SoC, built collaboratively from scratch in SystemVerilog.

Join on [Discord](https://discord.gg/sQjhBvWXjF) if you're interested in the project!

---

## Current state

**RV64IMAC + Zicsr, full M/S/U privilege modes, real timer interrupts**,
non-pipelined, single-hart, fully verified. The core is a multi-cycle
Wishbone-master FSM (fetch → execute → memory, one instruction fully retires
before the next begins -- no forwarding, no hazards to design around yet)
driving a real Wishbone bus out through an L1 instruction/data cache pair to
a real memory-mapped peripheral set.

### Architecture

- `design/decoder.sv`, `design/alu.sv`, `design/register_file.sv`,
  `design/divider.sv`, `design/c_expand.sv` -- the datapath: instruction
  decode, ALU (full RV64I arithmetic/logic/shift ops including the `*W`
  word-width family plus RV64M multiply/divide), a 32-entry general-purpose
  register file, a standalone multi-cycle divider, and the RV64C
  compressed-instruction decompressor.
- `design/csr_file.sv` -- every CSR the current privilege/interrupt/cache/
  debug feature set needs: the M-mode base set (`misa`, `mvendorid`/
  `marchid`/`mimpid`/`mhartid`, `mscratch`, `mcycle`, `minstret`), the full
  M/S trap stack (`mstatus`/`sstatus`, `mtvec`/`stvec`, `mepc`/`sepc`,
  `mcause`/`scause`, `mtval`/`stval`, `medeleg`/`mideleg`), the real
  interrupt CSRs (`mie`/`mip`, spliced live against the CLINT's
  timer-pending signal), and the Debug-mode CSRs (`dcsr`/`dpc`/
  `dscratch0`/`dscratch1`) -- storage and access-control exist, but
  nothing can legally enter Debug Mode yet (see below).
- `design/core.sv` -- ties the above together as a Wishbone bus master,
  including real synchronous-trap and timer-interrupt-taking logic, atomic
  memory operations (LR/SC/AMO), bus-error-to-access-fault trapping, and
  FENCE.I. No private instruction/data memory of its own; every fetch and
  load/store goes out over the bus (through the cache, see below).
- `design/icache.sv`, `design/dcache.sv`, `design/cache_complex.sv` -- a
  direct-mapped, physically-indexed/physically-tagged, write-through L1
  instruction/data cache pair sitting between `core` and the address
  decoder. FENCE.I (Zifencei) flushes the I$ for self-modifying-code
  coherence; the D$ never needs an equivalent flush (write-through keeps a
  store hit's cached copy and the backing SRAM in lockstep).
- `design/wb4_sram.sv`, `design/uart_tx.sv`, `design/uart_rx.sv`,
  `design/clint.sv`, `design/wb_addr_decoder.sv` -- the real Wishbone
  slaves (a flat 64-bit-word memory; a simulation-only UART, transmit and
  receive; an `mtime`/`mtimecmp` timer driving real machine-timer
  interrupts) plus the address decoder routing between them.
- `design/soc.sv` -- top-level integration: `core` + cache + address
  decoder + `wb4_sram` + `uart_tx`/`uart_rx` + `clint`. `clk`/`rst` are its
  only ports (no real serial pins exist yet -- the UART model transmits via
  `$write` and receives via a testbench-only backdoor task).

Sv39 virtual memory doesn't exist yet -- every address currently runs
untranslated. A hardware Debug Module (JTAG/DMI, in the spirit of the
RISC-V External Debug Support spec) is in progress: `EBREAK` is already a
real, resumable synchronous trap, UART RX is wired up as its planned
transport, and the Debug-mode CSRs (`dcsr`/`dpc`/`dscratch0`/`dscratch1`)
exist with real access control -- any access from anywhere currently
traps, since there's no Debug Mode to legally be in yet. The halt/resume
FSM and the DM/JTAG stack itself are still ahead. See `design/csr_file.sv`'s
and `design/core.sv`'s own header comments for the exact current scope.

`verification/taxi/` also carries a standalone Wishbone-to-AXI4 bridge and
behavioral DRAM timing model, built on a vendored `taxi` AXI4 IP submodule
-- proven independently via its own Verilator-only test flow, but not yet
wired into `design/soc.sv` (that RTL is Verilator-only, since it
instantiates a SystemVerilog `interface`, which Icarus cannot parse; `soc.sv`
itself must stay 100% Icarus-compatible).

### Verification

A large testbench suite (unit-level for every datapath/cache/peripheral
module in isolation, integration-level driving the real Wishbone bus and
the real cache hierarchy, several running real `riscv64-unknown-elf`
-assembled/toolchain-built programs), all passing, run through a
non-committed regression script (there's no single top-level build script
checked in yet -- see *Building and simulating* below). Shared
infrastructure lives in `testbench/`: `check_lib.sv` (a `check()`
primitive), `wb_driver.sv` (a Wishbone bus-cycle task), `halt_wait.sv`
(timeout-guarded halt waiting), and several reusable harness/monitor
modules -- pulled into new testbenches via `` `include `` rather than
hand-rolled each time.

Beyond the project's own testbenches, every ISA feature is additionally
cross-checked against two independent, external references:

- **`verification/riscv-arch-test/`** -- the official RISC-V Architecture
  Test (ACT4) compliance suite, run as real self-checking ELFs through a
  dedicated runner. The large majority pass; the handful that don't are
  understood, documented, spec-legal config/UDB mismatches, not RTL bugs.
- **`verification/riscv-formal/`** -- formal, unbounded-cycle-count
  verification via SymbiYosys/RVFI taps on `design/core.sv`, covering the
  base RV64I integer pipeline, the A-extension (atomics), and the
  C-extension (compressed instructions).

Real code coverage has also been measured (line/branch/toggle/expression,
via Verilator) across the design, not just claimed -- see individual
milestone notes for current numbers, which move as new features land.

---

## Building and simulating

Everything here is developed and verified against **Icarus Verilog**
(`iverilog`/`vvp`) and **Verilator**, run through WSL on Windows. There is
no single top-level build script checked into the repo yet -- compile the
specific file set a given testbench needs directly, e.g.:

```sh
iverilog -g2012 -I design -I testbench -o /tmp/soc_tb.out \
  design/decoder.sv design/alu.sv design/c_expand.sv design/csr_file.sv \
  design/divider.sv design/register_file.sv design/uart_tx.sv \
  design/uart_rx.sv design/wb4_sram.sv design/wb_addr_decoder.sv \
  design/icache.sv design/dcache.sv design/cache_complex.sv \
  design/clint.sv design/core.sv design/soc.sv testbench/soc_tb.sv
cd design && vvp /tmp/soc_tb.out
```

`-I design -I testbench` resolves every `` `include `` (Icarus does not
resolve include paths relative to the including file, only via `-I`). Run
from inside `design/` when a testbench instantiates `wb4_sram` directly, so
its `$readmemh` of `../firmware/crt0.hex` resolves.

A Verilator lint pass over the full SoC:

```sh
verilator --lint-only -Wall -Idesign -Idesign/defaults --top-module soc \
  design/decoder.sv design/alu.sv design/c_expand.sv design/csr_file.sv \
  design/divider.sv design/register_file.sv design/uart_tx.sv \
  design/uart_rx.sv design/wb4_sram.sv design/wb_addr_decoder.sv \
  design/icache.sv design/dcache.sv design/cache_complex.sv \
  design/clint.sv design/core.sv design/soc.sv
```

(Verilator wants `-Idesign`, no space; Icarus accepts either form.)

`firmware/` holds a real C toolchain build (`riscv64-unknown-elf-gcc`/`-as`/
`-ld`) producing the hex images some testbenches load -- see
`firmware/Makefile`. `verification/taxi/` (the Wishbone-to-AXI4 bridge and
DRAM model) is Verilator-only and has its own separate test runner --
never add a `taxi`-touching testbench to the file lists above, it will not
compile under Icarus.

---

## Roadmap

RV64**IMAC** + Zicsr + U/S/M privilege + Sv39, non-pipelined and in-order,
before any pipelining/OoO work starts -- deliberately, so out-of-order
correctness has a trusted in-order reference to debug against.

RV64IMAC + Zicsr + full U/S/M privilege modes + real timer interrupts are
done, each verified via a multi-pillar pattern (unit test, hand-assembled
end-to-end core testbench, real-toolchain encoder cross-check, real-
toolchain end-to-end firmware test) and cross-checked against both the
official riscv-arch-test compliance suite and formal (riscv-formal)
verification. Sv39 virtual memory is next on the privilege/memory side --
a different teammate's work, built on top of the U/S/M privilege seams
(`fetch_paddr`/`mem_paddr`, `satp`, `mstatus.MPRV/SUM/MXR`) this core
already carries specifically for that handoff.

In parallel, a hardware Debug Module (JTAG/DMI) is being built out in
staged milestones: `EBREAK` is now a real, resumable synchronous trap,
UART RX exists as its planned transport, and the Debug-mode CSRs
(`dcsr`/`dpc`/`dscratch0`/`dscratch1`) exist with real access control;
the halt/resume FSM and the JTAG TAP/DMI/Program-Buffer stack itself are
still ahead.

Bus protocol stays Wishbone at the core; AXI4 is a fabric-edge concern (see
the standalone bridge/DRAM model under `verification/taxi/`), not a
core-level one.
