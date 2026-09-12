# QuantiumV

A RISC-V SoC, built collaboratively from scratch in SystemVerilog.

Join on [Discord](https://discord.gg/sQjhBvWXjF) if you're interested in the project!

**Contents:** [Current state](#current-state) · [Architecture](#architecture) ·
[Verification](#verification) · [Building and simulating](#building-and-simulating) ·
[Booting Linux](#booting-linux) · [Roadmap](#roadmap) · [Contributing](#contributing) ·
[License](#license)

---

## Current state

**RV64IMAC + Zicsr, full M/S/U privilege modes, Sv39 virtual memory, physical
memory protection (PMP), a real interrupt-driven external-device path
(CLINT timer + PLIC + UART RX), and a full hardware Debug Module (JTAG/DMI)**
-- non-pipelined, single-hart, and verified to a real standard throughout
(see *Verification* below), not just claimed working. The core is a
multi-cycle Wishbone-master FSM (fetch -> execute -> memory, one instruction
fully retires before the next begins -- no forwarding, no hazards to design
around yet) driving a real Wishbone bus out through an L1 instruction/data
cache pair to a real memory-mapped peripheral set.

The Debug Module has been proven against a real, unmodified **OpenOCD
0.12.0** end to end, over real JTAG pins, driven through a hand-written
Verilator C++ harness -- halt/resume/single-step, GPR/CSR read-write,
software and hardware (Trigger Module) breakpoints, System Bus Access
memory read-write (including bulk transfers, both while halted and while
the hart is running), and Program Buffer download-and-execute.

### Architecture

- `design/decoder.sv`, `design/alu.sv`, `design/register_file.sv`,
  `design/divider.sv`, `design/c_expand.sv` -- the datapath: instruction
  decode, ALU (full RV64I arithmetic/logic/shift ops including the `*W`
  word-width family plus RV64M multiply/divide), a 32-entry general-purpose
  register file, a standalone multi-cycle divider, and the RV64C
  compressed-instruction decompressor.
- `design/csr_file.sv` -- every CSR the current privilege/interrupt/cache/
  MMU/PMP/debug feature set needs: the M-mode base set, the full M/S trap
  stack (`mstatus`/`sstatus`, `mtvec`/`stvec`, `mepc`/`sepc`, `mcause`/
  `scause`, `mtval`/`stval`, `medeleg`/`mideleg`), the real interrupt CSRs
  (`mie`/`mip`, spliced live against CLINT's timer-pending and PLIC's
  external-interrupt-pending signals), `satp` (real WARL/MODE) plus
  `mstatus.SUM`/`MXR`/`TVM` for Sv39, 4 PMP regions (`pmpcfg0`/
  `pmpaddr0-3`), the Trigger Module (2 `mcontrol6` hardware watchpoint
  slots), and the Debug-mode CSRs (`dcsr`/`dpc`/`dscratch0`/`dscratch1`).
- `design/core.sv` -- ties the above together as a Wishbone bus master:
  real synchronous-trap and interrupt-taking logic (timer + external,
  MEI>MTI>SEI priority), atomic memory operations (LR/SC/AMO),
  bus-error-to-access-fault trapping, FENCE.I, a 3-level Sv39 page-table
  walker with a 4-entry TLB (fetch- and mem-side translation, superpage
  support, full PMP composition against the translated physical address),
  PMP enforcement on every fetch/load/store, and the Debug Module's
  halt/resume/single-step FSM, Program Buffer execution, and Trigger
  Module comparators. No private instruction/data memory of its own; every
  fetch and load/store goes out over the bus (through the cache, see
  below) or, for translated accesses, through the page-table walker first.
- `design/icache.sv`, `design/dcache.sv`, `design/cache_complex.sv` -- a
  direct-mapped, physically-indexed/physically-tagged, write-through L1
  instruction/data cache pair sitting between `core` and the address
  decoder. FENCE.I (Zifencei) flushes the I$ for self-modifying-code
  coherence; the D$ never needs an equivalent flush (write-through keeps a
  store hit's cached copy and the backing SRAM in lockstep); Sv39
  page-table-entry reads route through the same D$ path with zero extra
  plumbing.
- `design/dm.sv`, `design/dm_dmi.sv`, `design/jtag_tap.sv` -- the Debug
  Module: a real IEEE 1149.1 JTAG TAP + DMI transport (the project's first
  clock-domain crossing), the DM register file (`dmcontrol`/`dmstatus`/
  `abstractcs`/`command`/`sbcs`/`sbaddress`/`sbdata`/`progbuf*`, real spec
  bit positions cross-checked against the RISC-V Debug Spec's own
  machine-readable register XML), and Access Register/Program Buffer
  abstract-command execution.
- `design/wb_arbiter2.sv` -- a fixed-priority 2-master Wishbone arbiter
  (DM's System Bus Access over `core`'s own bus master), sitting upstream
  of the address decoder so it needs zero changes to arbitrate.
- `design/wb4_sram.sv`, `design/uart16550.sv`, `design/clint.sv`,
  `design/plic.sv`, `design/wb_addr_decoder.sv` -- the real Wishbone
  slaves, all three MMIO-facing ones now genuinely register-compatible
  with real hardware: a flat 64-bit-word memory (64MB in the real SoC); a
  real NS16550A-register-model UART (simulation-only transmit/receive
  mechanism -- `$write`/a testbench backdoor, not real serial timing --
  but real IER/IIR/LCR/MCR/LSR/MSR/SCR semantics, including a real
  IER-gated RDA interrupt and a real one-shot THR-empty interrupt); a real
  SiFive-CLINT-layout `mtime`/`mtimecmp`/`msip` timer driving real
  machine-timer interrupts; a PLIC with 1 real interrupt source -- UART
  RX -- and 2 real hart contexts, M-mode and delegated S-mode,
  register-compatible with the real SiFive PLIC-1.0.0 layout -- plus the
  address decoder routing between them.
- `design/soc.sv` -- top-level integration: `core` + cache + `wb_arbiter2`
  + address decoder + `wb4_sram` + `uart16550` + `clint` + `plic`
  + `dm`/`jtag_tap`. Its first-ever real external pins are the JTAG
  signals (`jtag_tck`/`tms`/`tdi`/`tdo`/`trst_n`); `clk`/`rst` were
  previously its only ports (no real serial pins exist yet -- the UART
  model transmits via `$write` and receives via a testbench-only backdoor
  task).

`verification/taxi/` also carries a standalone Wishbone-to-AXI4 bridge and
behavioral DRAM timing model, built on a vendored `taxi` AXI4 IP submodule
-- proven independently via its own Verilator-only test flow, but not yet
wired into `design/soc.sv` (that RTL is Verilator-only, since it
instantiates a SystemVerilog `interface`, which Icarus cannot parse; `soc.sv`
itself must stay 100% Icarus-compatible).

### Verification

A large testbench suite (unit-level for every datapath/cache/peripheral/
MMU/debug module in isolation, integration-level driving the real Wishbone
bus and the real cache hierarchy, several running real
`riscv64-unknown-elf`-assembled/toolchain-built programs), all passing, run
through a non-committed regression script (there's no single top-level
build script checked in yet -- see *Building and simulating* below).
Shared infrastructure lives in `testbench/`: `check_lib.sv` (a `check()`
primitive), `wb_driver.sv` (a Wishbone bus-cycle task), `halt_wait.sv`
(timeout-guarded halt waiting), and several reusable harness/monitor
modules -- pulled into new testbenches via `` `include `` rather than
hand-rolled each time.

Sv39 additionally went through a dedicated randomized/property-based test
(a from-scratch shadow model of the walk algorithm, cross-validated against
every hand-verified case before generating thousands of random page-table/
access scenarios) and the project's first real-toolchain-compiled MMU test
(a page table built at runtime by a real, `riscv64-unknown-elf`-assembled
program, not hand-packed into simulation memory) -- both added, and both
independently re-verified by a separate adversarial-review pass, after the
initial 6-milestone implementation had already been through static review.

Beyond the project's own testbenches, every ISA feature is additionally
cross-checked against two independent, external references:

- **`verification/riscv-arch-test/`** -- the official RISC-V Architecture
  Test (ACT4) compliance suite, run as real self-checking ELFs through a
  dedicated runner. The large majority pass; the handful that don't are
  understood, documented, spec-legal config/UDB mismatches, not RTL bugs.
- **`verification/riscv-formal/`** -- formal, unbounded-cycle-count
  verification via SymbiYosys/RVFI taps on `design/core.sv`, covering the
  base RV64I integer pipeline, the A-extension (atomics), and the
  C-extension (compressed instructions). M-extension formal coverage is
  deliberately deprioritized (genuine solver-hardness, not neglect); Sv39
  is not yet formally covered for the same reason -- a 3-level page-table
  walker needs a solver-model state space far beyond what the project's
  current bounded-check depths can meaningfully explore.

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
iverilog -g2012 -I design -I design/defaults -I testbench -o /tmp/soc_tb.out \
  design/decoder.sv design/alu.sv design/c_expand.sv design/cache_complex.sv \
  design/clint.sv design/core.sv design/csr_file.sv design/dcache.sv \
  design/divider.sv design/dm.sv design/dm_dmi.sv design/icache.sv \
  design/jtag_tap.sv design/plic.sv design/register_file.sv design/soc.sv \
  design/uart16550.sv design/wb4_sram.sv \
  design/wb_addr_decoder.sv design/wb_arbiter2.sv testbench/soc_tb.sv
cd design && vvp /tmp/soc_tb.out
```

`-I design -I design/defaults -I testbench` resolves every `` `include ``
(Icarus does not resolve include paths relative to the including file, only
via `-I`). Run from inside `design/` when a testbench instantiates
`wb4_sram` (or the real `soc`) directly, so its `$readmemh` of
`../firmware/*.hex` resolves.

A Verilator lint pass over the full SoC:

```sh
verilator --lint-only -Wall -Idesign -Idesign/defaults --top-module soc \
  design/decoder.sv design/alu.sv design/c_expand.sv design/cache_complex.sv \
  design/clint.sv design/core.sv design/csr_file.sv design/dcache.sv \
  design/divider.sv design/dm.sv design/dm_dmi.sv design/icache.sv \
  design/jtag_tap.sv design/plic.sv design/register_file.sv design/soc.sv \
  design/uart16550.sv design/wb4_sram.sv \
  design/wb_addr_decoder.sv design/wb_arbiter2.sv
```

(Verilator wants `-Idesign`, no space; Icarus accepts either form.)

`firmware/` holds a real C/assembly toolchain build (`riscv64-unknown-elf-
gcc`/`-as`/`-ld`) producing the hex images some testbenches load -- see
`firmware/Makefile`. `verification/taxi/` (the Wishbone-to-AXI4 bridge and
DRAM model) is Verilator-only and has its own separate test runner --
never add a `taxi`-touching testbench to the file lists above, it will not
compile under Icarus.

---

## Booting Linux

**Not yet possible on real `core` RTL** -- said plainly, because it's easy
to overclaim otherwise once the pieces start looking close. What's
actually true today:

- `design/soc.sv`'s real RAM was grown from 32KB to **64MB** specifically
  for Linux-boot readiness (a kernel + minimal initramfs needs far more
  than 32KB), with UART/CLINT/DRAM/PLIC's addresses shifted up to make
  room -- see `design/wb_addr_decoder.sv`'s own header for the exact map.
- The target software stack itself -- a real Linux kernel + OpenSBI +
  BusyBox, built via [Buildroot](https://buildroot.org) -- has been proven
  to boot to a genuine, verified interactive shell, but **on QEMU's own
  standard `riscv64 virt` machine**, not on `core`. This validates that the
  OS/firmware recipe works at all, fully decoupled from (and much faster
  to iterate on than) the real RTL simulation path, before ever attempting
  the harder problem.
- All three of `design/plic.sv`, `design/clint.sv`, and `design/uart16550.sv`
  are now genuinely register-compatible with real hardware: PLIC matches
  the real SiFive PLIC-1.0.0 layout, CLINT matches the real SiFive-CLINT/
  ACLINT offsets (`msip0`@`+0x0000`, `mtimecmp0`@`+0x4000`, `mtime`@
  `+0xBFF8`), and the UART is a real, spec-faithful NS16550A register model
  (8 registers packed into one dword, real IER-gated RDA interrupts, a real
  one-shot THR-empty interrupt). OpenSBI's `platform/generic` and Linux's
  stock 16550/CLINT/PLIC drivers should all work against `core` with zero
  bespoke driver code now, once a correct device tree exists to describe it.

Concretely still missing before a real `core`-hosted boot is even
attemptable: an SBI (OpenSBI's `platform/generic`, now plausible given the
above, or a hand-rolled bridge) actually pointed at `core`, and a device
tree describing `core`'s own memory map -- both genuinely required (RISC-V
Linux's own boot protocol needs a real FDT pointer and an S-mode entry
regardless of how compatible the peripherals are underneath). Nobody has
yet attempted running a real boot through cycle-accurate RTL simulation
either -- that could take an enormous number of simulated cycles, genuinely
untested territory.

The actual staged plan for all of this, and the concrete next steps, live
in the separate [`quantiumv/sdk`](https://github.com/quantiumv/sdk)
repo -- see its own README and `ROADMAP.md` for the real Track A
(bare-metal firmware SDK, already built) / Track B (Linux enablement,
in progress) breakdown, and for instructions on reproducing the QEMU
software-recipe validation yourself.

---

## Roadmap

RV64**IMAC** + Zicsr + U/S/M privilege + Sv39, non-pipelined and in-order,
before any pipelining/OoO work starts -- deliberately, so out-of-order
correctness has a trusted in-order reference to debug against. **All of
that is now done**: RV64IMAC + Zicsr + full U/S/M privilege + Sv39 virtual
memory + PMP + real timer/external interrupts, each verified via a
multi-pillar pattern (unit test, hand-assembled end-to-end core testbench,
real-toolchain encoder cross-check, real-toolchain end-to-end firmware
test, and for Sv39 additionally randomized/property-based testing) and
cross-checked against both the official riscv-arch-test compliance suite
and (where solver cost allows) formal verification.

The hardware Debug Module (JTAG/DMI) built out alongside it is also
**done**: halt/resume/single-step, GPR/CSR access, software and hardware
breakpoints, Program Buffer execution, and System Bus Access, proven
end-to-end against a real, unmodified OpenOCD.

Linux enablement is the active next phase -- see *Booting Linux* above and
the `quantiumv/sdk` repo's own `ROADMAP.md` for the real staging (SBI
platform port, device tree, and closing the CLINT/UART standards-
compliance gap are the concrete remaining pieces on the `core` side).

Bus protocol stays Wishbone at the core; AXI4 is a fabric-edge concern (see
the standalone bridge/DRAM model under `verification/taxi/`), not a
core-level one.

---

## Contributing

This is a collaborative, from-scratch build -- [Discord](https://discord.gg/sQjhBvWXjF)
is where design decisions get discussed and work gets coordinated before a PR
shows up, not an afterthought support channel. Come say what you're
interested in; the *Roadmap* section above and the per-module header
comments throughout `design/` are the best starting map of what's settled,
what's in flight, and what's still open.

A few conventions worth knowing before sending a change: every new RTL
feature ships with real tests, not just a claim it works (see
*Verification* above) -- a full local regression plus a Verilator lint
pass, both clean, is the bar every prior milestone has held itself to, and
new privilege/CSR/interrupt/MMU logic additionally gets cross-checked
against riscv-arch-test and, where practical, riscv-formal. Module header
comments explain *why*, not just *what* -- keep that up when you add or
change one.

## License

[MIT](LICENSE).
