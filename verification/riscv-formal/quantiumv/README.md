# riscv-formal integration (started 2026-08-11, pipeline working, first real finding under investigation)

Formal verification via [riscv-formal](https://github.com/YosysHQ/riscv-formal)
(Yosys + SymbiYosys + a SAT/BMC solver), proving ISA correctness exhaustively
against the spec rather than sampling it via directed/random simulation. This
is a genuinely different, stronger class of verification than everything else
in `verification/` and `testbench/` — see the session that started this for
the full reasoning.

## Status: full pipeline runs end-to-end. `insn_add_ch0` produces a real counterexample, not yet root-caused.

**What works, confirmed end-to-end:**
- `design/core.sv` carries a native, spec-shaped RVFI (RISC-V Formal
  Interface) output port list, gated entirely behind `` `ifdef RISCV_FORMAL ``
  (search core.sv for that guard) — **zero effect on any normal build**;
  confirmed via a full 38-testbench regression run with the change in place.
  Pure combinational taps off signals that already drive the real commit
  (`commit_now`, `reg_write_data`, `current_priv`, `mem_paddr`/`mem_sel`,
  etc.) — no new pipeline stage, matches RVFI's documented
  one-`rvfi_valid`-pulse-per-retired-instruction model directly, since
  `commit_now` already has exactly that shape. First slice only: covers the
  base-ISA (`isa=rv64i`) check family, no CSR trace ports yet
  (`rvfi_csr_<name>_*`), and `rvfi_insn` feeds the C-expanded 32-bit
  `instruction` wire rather than a compressed instruction's raw 16-bit
  encoding (fine for `isa=rv64i`, needs its own tap before Zca checks).
- **Elaboration through Yosys fully resolved** (see "Two real Yosys-frontend
  gaps, both closed" below) — the design elaborates, optimizes, and produces
  an SMT2 model with zero errors.
- **A real BMC run completes and returns a verdict** — `insn_add_ch0`
  (the simplest possible RV64I check) runs `sby` end-to-end with the
  `bitwuzla` solver in ~2 minutes and returns `FAIL` with a genuine
  counterexample trace, not a tooling error. See "Open finding" below.

## Two real Yosys-frontend gaps, both closed (not RTL bugs — confirmed via isolated repros)

Yosys 0.61/0.62's own built-in Verilog-2005-based frontend (`read -sv`,
even in `-sv` mode) cannot parse two constructs this codebase genuinely
uses, both legal modern SystemVerilog that iverilog/Verilator already
handle correctly elsewhere in this project's own test suite:
1. **Nested macro token-pasting** — `decoder.sv`'s
   `` `define IS_INSTR(instr, name) ((instr & `INSTR_MASK_``name) == `INSTR_``name) ``
   (the `` ` `` `` `` `` token-paste operator building a NEW macro name from an
   argument, then expanding *that*). Reproduced in total isolation with a
   2-line repro.
2. **`return {concat, expr};` inside an `automatic` function** —
   `design/c_expand.sv`'s small helper functions (`creg()`, `mk_r()`, etc.).
   Raw Yosys syntax error, unrelated to macros.

**Fix**: use [yosys-slang](https://github.com/povik/yosys-slang) — a
separate, complete SystemVerilog frontend plugin (built on the `slang`
compiler project) — instead of Yosys's own frontend. Confirmed: the FULL
design (all 7 files, `` `ifdef RISCV_FORMAL `` included) elaborates and
optimizes through `read_slang --single-unit` with **zero errors**, resolving
both gaps simultaneously with **zero changes to any real RTL file**.
A newer built-in Yosys (0.62, also present in this environment) does NOT fix
either gap on its own — confirmed by direct test; only swapping frontends
fixes it. See `checks.cfg`'s `[script-defines]`/`[script-sources]` for the
exact working invocation (`genchecks.py` hardcodes its own `read -sv <check
glue file>.sv` line with no override hook, so the real design + `wrapper.sv`
are loaded separately via `read_slang` in `[script-sources]`, which runs
right after). Two more small things needed to make `read_slang` see the same
macros the check-glue file's frontend independently pulls in (different
frontend = different preprocessor, no shared state): `wrapper.sv` needs its
own `` `include "defines.sv" `` (riscv-formal's own per-check-generated file,
already `` `include``ing `rvfi_macros.vh` too — see `wrapper.sv`'s own
comment), and `--single-unit` is required or `core.sv` can't see macros
defined via `decoder.sv`'s own include chain (cross-file macro persistence,
same convention this whole project's real iverilog build already relies on).

## Solver choice matters enormously — z3 is not viable here, crashed WSL once

Default `solver` (unset in `checks.cfg`) is `boolector`, not installed in
this environment. Tried `z3` (was on `PATH`) first: **z3 ran for 25+ minutes
on the simplest possible check (`insn_add_ch0`) with zero incremental
progress** (confirmed via the engine's own logfile — stuck on the very first
query the entire time), and a second concurrent z3 run **crashed the WSL
service itself** (`Wsl/Service/E_UNEXPECTED`, recovered cleanly via `wsl
--shutdown` from PowerShell, no data loss). `bmc3` (Yosys/ABC's own native
BMC engine, no external SMT solver) is incompatible with these
riscv-formal-generated checks specifically — they use a `skip` option only
valid for `smtbmc`/`btor`-family engines. **`bitwuzla`** (also already
present in this environment, matches what riscv-formal's own `nerv`
reference core uses) is the fix: the identical check that hung z3 for 25+
minutes completes in **~2 minutes** at depth 15. If future work in this dir
seems to hang, check the solver first — this class of slowdown is solver-
specific, not a sign of a genuinely harder problem. **Always run `sby` with
a wrapping timeout and a `ulimit -v`** (see `checks.cfg`'s own environment
notes below) given the WSL-crash history.

## Open finding, not yet root-caused: `insn_add_ch0` FAILs

`bitwuzla` finds a genuine assertion failure (`rvfi_insn_check.sv:178`,
`spec_rd_wdata == rd_wdata` — the core's computed ADD result doesn't match
the independently-derived spec model) at both depth 6 and depth 15
(ruling out "too shallow a BMC window" as the explanation). ADD itself is
about as foundational and already-well-tested as RTL gets in this project
(`core_alu_ops_tb.sv` and others cover it directly), so a genuine ALU bug is
the least likely explanation. Leading hypothesis, NOT yet confirmed: this
core's C-extension capture registers (`instr_line_q`, `crossed_q`,
`instr_hi_q` — see `design/core.sv`) deliberately have no `rst` branch (an
accepted design choice documented in their own code comments, since real
hardware/testbenches always perform a genuine `S_FETCH` before ever reading
them). BMC's adversarial initial-state exploration is not bound by that same
"always fetch before read" guarantee — the very first counterexample's
initial state (`engine_0/trace_tb.v`, written by the solver itself) shows
`state = 3'b111` (outside the FSM's legal 0–4 range) and `crossed_q = 1'b1`
before reset has ever taken effect, which is exactly the kind of
solver-chosen initial garbage this design's own reset-completeness
assumptions don't cover. Not yet traced through to confirm this is the
actual mechanism, though — could also be a genuine free/unconstrained-input
modeling gap in `wrapper.sv` (no memory consistency model at all, matching
`nerv`'s own reference wrapper's convention, but worth double-checking
against this specific failure before concluding it's the FSM-reset issue).

**Next step for whoever picks this up**: read `engine_0/trace_tb.v` for
`insn_add_ch0` cycle-by-cycle (163 lines currently, small enough to read
directly) to see exactly which cycle `rvfi_valid` first pulses and what
`state`/`crossed_q`/`instr_line_q` look like on that exact cycle — confirm
or rule out the reset-completeness hypothesis before touching any RTL. If
confirmed, the fix is almost certainly adding explicit `rst` handling to
`crossed_q`/`instr_hi_q` in `core.sv` (currently: "garbage before the first
real fetch is an accepted, existing non-issue" — true for simulation
testbenches, evidently NOT true for formal's adversarial initial state).

## Next steps, roughly in order

1. Root-cause and resolve the `insn_add_ch0` FAIL above.
2. Get the full `isa=rv64i` set (56 checks) passing.
3. Scale to `rv64im`, `rv64ima`, `rv64imac`.
4. Add `` `RISCV_FORMAL_CSR_* `` trace ports to `core.sv` one CSR at a time
   for privilege-mode checks — `mstatus`/`mepc`/`mcause`/`sepc`/`scause`
   first, matching the CSRs this project's real MPRV/TSR bugs (see
   [[known-gap-mstatus-fs-warl]] in project memory) were found in, since
   that's exactly the class of bug formal verification is strongest against.

## Environment setup (WSL)

```
git clone --depth 1 https://github.com/YosysHQ/riscv-formal.git ~/riscv-formal
```

Yosys 0.61 and z3 were already present. **`sby`** (SymbiYosys) is a
*separate* repo from Yosys (not a pip package, not bundled) — a `sby`
binary happened to already exist as a nix-store artifact at
`/nix/store/5f4l0kgczm4kn3r2rm09arby2g44fmj4-yosys-sby-0.62/bin/sby`; it
needs `PYTHONPATH` pointed at that same package's `share/yosys/python3/`
directory to actually run (its own sub-modules like `sby_cmdline.py` live
there) — a plain symlink onto `PATH` is NOT enough, needs a real wrapper
script exporting `PYTHONPATH` first (see `~/.local/bin/sby`). If that
nix-store path isn't present in a future environment: `git clone
https://github.com/YosysHQ/sby && make install` against an existing Yosys.
**`yosys-slang`** (required, see above): built plugin at
`/nix/store/07xn6zd11qvkp8h65gwycfisr3x9hk4f-yosys-slang/share/yosys/plugins/slang.so`
in this environment. **`bitwuzla`** (required solver, see above): binary at
`/nix/store/zrcmy1ak6dzhjc48nw3iyi49y34zkj3f-bitwuzla-unstable-2022-10-03/bin/bitwuzla`,
symlinked to `~/.local/bin/bitwuzla`. All three nix-store paths are
environment-specific — if they're not present in a future environment,
search `/nix/store` for the package name, or build from source
(`YosysHQ/sby`, `povik/yosys-slang`, `bitwuzla/bitwuzla` upstream repos).

To (re-)generate checks and try running one, from `~/riscv-formal/cores/`:
```
mkdir -p quantiumv && cp <this-dir>/wrapper.sv <this-dir>/checks.cfg quantiumv/
cd quantiumv && python3 ../../checks/genchecks.py
cd checks && ulimit -v 8000000 && timeout 300 sby -f insn_add_ch0.sby
```
(`ulimit -v` + `timeout`: see the WSL-crash history above — always run this
way, not bare.)

Links: [[act4-riscv-arch-test-setup]] (the project's OTHER external-tool
integration, same "config lives in the repo, framework lives external"
pattern) [[known-gap-mstatus-fs-warl]] (the real CSR bugs that motivated
wanting formal verification in the first place)
