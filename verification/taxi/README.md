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

A testbench may have a companion `<name>.f` file (see
`tb/taxi_axi_ram_smoke_tb.f` for the pattern) listing exactly which taxi AXI
source files it needs, one filename per line, relative to
`third_party/taxi/src/axi/rtl/` -- the same flat-filename convention taxi's
own upstream `.f` files already use for their own internal dependencies.

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
**No WB->AXI4 bridge or DRAM model exists yet** -- this vendoring + toolchain
setup is the prerequisite step, not the DRAM-testing work itself.

Links: project memory `bus-protocol-decision` (the original taxi-vs-iverilog
decision history), `verification/riscv-arch-test/`, `verification/riscv-formal/`
(this project's other external-tool integrations, different pattern -- see
the note at the top of this file for why).
