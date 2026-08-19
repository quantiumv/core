# taxi (AXI4/AXI4-Lite IP) -- vendored 2026-08-18, Verilator toolchain fork

[taxi](https://github.com/fpganinja/taxi) (Alex Forencich, successor to
`verilog-axi`/`verilog-axis`) is vendored as a git submodule at
`third_party/taxi` for real AXI4/AXI4-Lite fabric IP (crossbar, RAM slave,
register/adapter modules) -- the intended backbone for eventually testing a
real DRAM model over AXI. Vendored, not just referenced externally, unlike
this project's other external-tool integrations
(`verification/riscv-arch-test/`, `verification/riscv-formal/`) -- those are
pure verification frameworks that never ship as part of the design; taxi's
AXI IP is meant to become real, synthesizable RTL inside this SoC, so its
exact source needs to travel with the repo, not be reproduced from a
separately-documented clone step.

**License, already accepted (see project memory `bus-protocol-decision`):**
taxi's interface header files (`taxi_axi_if.sv` etc.) are MIT; its functional
IP (`taxi_axi_ram.sv`, `taxi_axi_crossbar.sv`, etc.) is **CERN-OHL-S-2.0**
(strongly reciprocal -- distributing a product built on it obligates
releasing the complete combined design's source). This repo is MIT; the team
explicitly accepted this reciprocal posture for the whole project.

## Why a separate toolchain, not the existing iverilog flow

taxi's entire AXI4/AXI4-Lite product line (59 of 63 files under
`third_party/taxi/src/axi/rtl/`) is built on SystemVerilog `interface`+
`modport` ports (`taxi_axi_if.wr_slv`, `taxi_axi_if.rd_slv`, etc.). This
project's Icarus Verilog build **cannot parse an interface-typed port
declaration at all** -- confirmed by isolating it down to a 15-line,
taxi-independent repro (a bare `interface`/`modport` port on a trivial
module), which fails identically:
```
syntax error
Errors in port declarations.
```
Not a partial gap -- the foundational pattern the whole library is written
around doesn't compile under iverilog, full stop. **Verilator does support
it natively**, and was already a project dependency (used for the
`--lint-only` gate on every milestone) -- confirmed via a genuine
`taxi_axi_ram` write (`0xDEADBEEF`) + read-back round trip, with real AXI
handshaking exercised (`awready`/`wready`/`bvalid`/`arready`/`rvalid`), not
just elaborated.

**Any taxi-touching testbench MUST be built and run through
`run_taxi_tests.sh`, never added to the iverilog-based `design`/`testbench`
regression file lists** -- it will not compile there.

## Setup

```sh
git submodule update --init third_party/taxi
```
(`.gitmodules` marks this submodule `shallow = true`, so a fresh
`--init` pulls a shallow, ~5MB checkout rather than taxi's full history.)

## Running the tests

```sh
verification/taxi/run_taxi_tests.sh
```
Builds and runs every `*_tb.sv` under `verification/taxi/tb/` via
`verilator --binary -j 0 --timing`, matching this project's existing
`$display`-based PASS/FAIL convention (`check_lib.sv`, pulled in via
`-I testbench` same as every iverilog testbench). Reports a PASS/FAIL/ERR
summary line per testbench, same shape as
`verification/riscv-arch-test/run_act_tests.sh`.

**The working recipe, if building one of these files by hand**:
```sh
verilator --binary -j 0 --timing -Wno-fatal --top-module <tb> <taxi sources...> <tb.sv>
./obj_dir/V<tb>
```
`--binary` builds+links in one step (no cocotb, no hand-written C++ testbench
wrapper needed). **`--timing` is not optional**: every testbench in this
repo uses `#N` delays pervasively (`always #5 clk = ~clk;`, settle-waits like
`#1;`), and Verilator's default cycle-based mode can't compile that style at
all without it.

A testbench may have a companion `<name>.f` file (see `tb/dram_model_tb.f`
for the pattern) listing exactly which source files it needs, one per line,
as **repo-root-relative paths** (e.g. `third_party/taxi/src/axi/rtl/taxi_axi_if.sv`,
`verification/taxi/rtl/dram_model.sv`) -- not taxi-rtl-relative flat
filenames. That was the original convention (matching taxi's own upstream
`.f` files' internal-dependency style) until `dram_model_tb.f` needed to
reference a project-owned RTL file living outside
`third_party/taxi/src/axi/rtl/` -- repo-root-relative paths handle both
cases uniformly.

## Gotcha worth remembering

`taxi_axi_ram`'s (and most other taxi AXI modules') `DATA_W` is **not** its
own module parameter -- it's a `localparam` derived from whichever
`taxi_axi_if` interface instance is connected
(`localparam DATA_W = s_axi_wr.DATA_W;` internally). Passing `.DATA_W(...)`
at instantiation is a hard elaboration error ("attempts to override... but
it is a local parameter"), not a harmless no-op. Only `ADDR_W` (and other
genuinely-independent parameters) are real instantiation parameters --
check the target module's own parameter list before assuming a signal name
is settable.

## Status

`taxi_axi_ram_smoke_tb.sv` -- confirms the toolchain itself works end-to-end
against real taxi functional IP (single write + read-back round trip).

`rtl/dram_model.sv` + `tb/dram_model_tb.sv` -- a Wishbone-slave-shaped
peripheral (same port contract as `design/wb4_sram.sv`) that bridges each WB
request to a real, single-beat AXI4 transaction against a genuine
`taxi_axi_ram` backing store, with hand-written DRAM-realism timing layered
on top: a configurable `ACCESS_LATENCY_CYCLES` extra-wait parameter and a
configurable `REFRESH_INTERVAL_CYCLES`/`REFRESH_BUSY_CYCLES` pair that
periodically blocks starting a new transaction (never interrupts one already
in flight), matching real DRAM's periodic refresh unavailability. Latency/
refresh timing is proven via cycle-count deltas against a zero-latency/
refresh-disabled baseline instance, not a hardcoded absolute cycle count
(hand-tracing `taxi_axi_ram`'s exact registered timing by inspection is
error-prone; the delta approach is immune to any error in the absolute base
number).

`rtl/decoder_dram_harness.sv` + `tb/decoder_dram_tb.sv` -- `dram_model.sv`
**is** now wired into a real `design/wb_addr_decoder.sv` (a real 4-way
decode: RAM/UART/CLINT/DRAM, CLINT narrowed from 64KB to 32KB to free the
window DRAM now uses), proven end-to-end at the bus level through this
harness (real decoder + real wb4_sram/uart_tx/clint/dram_model, no
`core.sv`) -- mirrors `testbench/decoder_clint_harness.sv`'s own precedent
for CLINT's bus-wiring. Still **not** wired into `design/soc.sv` directly,
though -- and unlike CLINT, that isn't just a staging choice deferred to a
later step. `design/soc.sv` is compiled by many existing iverilog
testbenches and must stay iverilog-parseable forever; `dram_model.sv` is
Verilator-only *by construction* (the `interface`-based AXI bridge is
fundamental to its design, not incidental), so `soc.sv` can never
instantiate it directly. A future "real firmware through DRAM" step would
need either a separate Verilator-only `soc`-shaped top-level under
`verification/taxi/`, or a synthesizable/swappable DRAM-slave abstraction
in `design/` with the real backing store substituted only for the taxi
build -- not the same playbook CLINT's own later firmware milestone used.

Links: project memory `bus-protocol-decision` (the original taxi-vs-iverilog
decision history), `verification/riscv-arch-test/`, `verification/riscv-formal/`
(this project's other external-tool integrations, different pattern -- see
the note at the top of this file for why).
