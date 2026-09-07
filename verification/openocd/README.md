# Milestone 10b: OpenOCD full-stack integration test

The final milestone in the 10-milestone EBREAK/JTAG staged plan (see the
project's own plan file / [[trigger-module-milestone]] and
[[milestone-10a-read-strobe]] memory entries for the full history). Runs a
real, unmodified OpenOCD 0.12.0 against a Verilator simulation of the real,
unmodified `design/soc.sv`, driving the actual JTAG pins through OpenOCD's
`remote_bitbang` protocol — not a backdoor, not a mock.

## Quick start (from WSL)

```bash
verification/openocd/run_m10_smoke_test.sh
```

Builds `firmware/m10_debug_test.hex`, builds the Verilator harness, runs the
12-item acceptance checklist, tears everything down, and exits 0 iff every
check passed. Requires `riscv64-unknown-elf-{as,ld,objdump,objcopy}`,
`verilator` (5.x, with timing support), and `openocd` (0.12.x) on `PATH`.

## Files

- `sim_soc_top.sv` — thin wrapper around the real `design/soc.sv`, adding
  only the same `#1`-delayed firmware-override `$readmemh` every
  `*_toolchain_tb.sv` in this project already uses (see that file's own
  header). Zero other logic.
- `sim_main.cpp` — the first hand-written Verilator `--cc --exe` harness in
  this project (`verification/taxi/` is 100% `--binary` mode). Implements
  the OpenOCD `remote_bitbang` TCP protocol directly against
  `sim_soc_top`'s JTAG pins, with `clk` free-running at a fixed rate
  independent of TCK (this design's CDC is already proven robust to any
  relative rate — see `testbench/jtag_dmi_e2e_tb.sv`'s own header).
- `quantiumv.cfg` — OpenOCD Tcl config: `remote_bitbang` transport,
  `jtag newtap` with the real IDCODE (`0x00001001`, from
  `design/jtag_tap.sv`'s own `IDCODE_VAL`), `riscv set_mem_access sysbus`.
- `m10_smoke.tcl` — the 12-item acceptance checklist.
- `run_m10_smoke_test.sh` — orchestration (build, launch, test, teardown,
  one pass/fail exit code).

## A real Verilator timing gotcha, found the hard way

`sim_soc_top.sv`'s firmware-override `$readmemh` sits behind a `#1` delay.
Under Verilator's `--timing` mode, that delay is a real coroutine suspension
— it only resumes once the C++ driver's own simulated time actually passes
1. **A driver that just calls `top->eval()` in a bare loop, without ever
calling `contextp->timeInc()`, never advances that time at all** — the
override silently never runs, and `design/wb4_sram.sv`'s own unconditional
load of `firmware/crt0.hex` is the only image that ever executes, no matter
what hex file the harness intended to substitute. This is exactly what
happened on the first real attempt here: the harness "worked" (no crash,
plausible-looking output) while actually running the wrong program the
entire time, only caught by tracing `core0.pc` directly and recognizing
`hello.c`'s own real character-output loop instead of the intended
debug-test program's address range. `sim_main.cpp`'s `tick_clk()` now calls
`contextp->timeInc(1)` before every `eval()` — load-bearing, not a stylistic
choice.

## Two real RTL bugs this integration test found

The first was found during *planning* (before any code was written) and
fixed in Milestone 10a, already shipped separately. The second was found
*during this milestone's own live testing* (10a's own gate never exercises
`step` through a real, finite-speed debugger) and is fixed as part of 10b:

1. **`sbcs.sbreadondata` / `abstractauto.autoexecdata` were storage-only**
   (`design/dm.sv`, pre-existing since Milestone 8/5) — a multi-word memory
   read via OpenOCD's default access chain would have silently returned
   word 0 repeated. Fixed in Milestone 10a via a real DMI read-strobe
   (`design/dm_dmi.sv`'s `o_reg_re`, derived for free from its own existing
   transport FSM) threaded into `design/dm.sv`. See
   [[milestone-10a-read-strobe]] for the full derivation.
2. **`dmstatus.allresumeack` couldn't survive a single-step's own re-halt**
   (`design/dm.sv`, pre-existing since Milestone 5) — it was a live
   `= !i_hart_halted` approximation, not a real sticky bit. A single-step
   completes (resume → execute one instruction → re-halt) faster than any
   external DMI poll can observe the transient "running" window, so
   OpenOCD's own `step` command — which polls for `allresumeack==1` before
   it will even check for the step's own following re-halt — failed
   outright with `unable to resume hart 0` the first time this milestone's
   own script ran it, even though the step itself executed perfectly
   correctly. Fixed with a real sticky `resumeack_q`: set the cycle a
   resume is accepted, cleared only on the *next* debugger-initiated
   haltreq/resumereq — not on the hart re-halting per se, which for
   single-step is the intended, immediate outcome, not something that
   should erase the very ack the debugger is still waiting to observe.
   Verified via the standard revert-and-recheck discipline
   (`testbench/dm_tb.sv`'s new dedicated regression, plus the real OpenOCD
   `step` command itself, which failed before the fix and passes after).

Neither gap was reachable by any of this project's 40+ prior backdoor-DMI
testbenches, which read internal state with no polling-speed limitation at
all — both are genuinely specific to driving this design through a real,
finite-speed external debugger, which is the entire reason this milestone
exists.

## Known, accepted, out-of-scope artifacts

- **"found 1024 harts"** — this core's own `dmstatus.anynonexistent`/
  `allnonexistent` are correctly hardwired 0 per the single-hart scope
  boundary (see the plan file's own "Multi-hart support" exclusion);
  OpenOCD's own hart-discovery loop has no other signal telling it to stop
  scanning, so it enumerates up to its own default cap. Harmless — OpenOCD
  still correctly targets hart 0 for every real operation.
- **"Error: Failed to read priv register."** (harmless, printed during item
  9 while the hart is genuinely running) — OpenOCD's own background state
  refresh attempts to read the current privilege level, which is
  legitimately unavailable while not halted. Doesn't affect the actual test
  outcome.
- **`misa` reads `0x8000000000000100`** during `examine` (only the `I` bit
  set) — this project's own ACT4/riscv-formal suites already validate
  `misa` correctness at length elsewhere; not part of this milestone's own
  acceptance criteria, not investigated further here.

## Scope boundary

Zero `design/` changes in 10b itself (all real RTL changes — the read-strobe
and the resumeack fix — landed in Milestone 10a, already shipped and
regression-proven independently of this OpenOCD-dependent test). This
directory's own files are the only ones this milestone adds.
