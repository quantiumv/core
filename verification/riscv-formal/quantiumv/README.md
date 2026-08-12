# riscv-formal integration (started 2026-08-11, 54/56 isa=rv64i checks PASS)

Formal verification via [riscv-formal](https://github.com/YosysHQ/riscv-formal)
(Yosys + SymbiYosys + a SAT/BMC solver), proving ISA correctness exhaustively
against the spec rather than sampling it via directed/random simulation. This
is a genuinely different, stronger class of verification than everything else
in `verification/` and `testbench/` — see the session that started this for
the full reasoning.

## Status: 54 of 56 generated `isa=rv64i` checks PASS. Full sweep run, all failures root-caused, one real RTL bug found and fixed.

Ran the complete `isa=rv64i` set (56 checks) for the first time: 35 passed
outright, 21 failed. Every failure was root-caused (native witness replay,
see below) and falls into exactly 4 categories:
- **8 branch/jump checks** (`insn_{beq,bne,blt,bge,bltu,bgeu,jal,jalr}_ch0`)
  — formal-harness scope gap, fixed via a `checks.cfg` define. Now PASS.
- **11 load/store checks** (`insn_{lb,lbu,lh,lhu,lw,lwu,ld,sb,sh,sw,sd}_ch0`)
  — two real `core.sv` bugs (one a genuine hardware defect, formal's first
  real find in this integration) plus a formal-harness convention mismatch,
  all fixed together. Now PASS.
- **`ill_ch0`** — a structural formal-model gap (the stock check assumes an
  architecturally-unreachable value on this core), not fixable without a
  larger tap change. Still open, see "Known open findings" below.
- **`reg_ch0`** — solver timeout, not a counterexample. Still open, see
  "Known open findings" below.

**Net result: 54/56 PASS.** See "Resolved finding" sections below for the
full story on each fixed category.

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
  encoding (fine for `isa=rv64i`, needs its own tap before Zca checks — see
  "Resolved finding" below for why this specific gap mattered).
- **Elaboration through Yosys fully resolved** (see "Two real Yosys-frontend
  gaps, both closed" below) — the design elaborates, optimizes, and produces
  an SMT2 model with zero errors.
- **`insn_add_ch0` PASSES for real** — full configured depth (15), real
  `checks.cfg`, `bitwuzla` solver, ~3 minutes wall clock, `Status: passed` /
  `DONE (PASS, rc=0)`. This is the ADD instruction's architectural
  correctness proven exhaustively (every register value, every legal
  memory-response timing within the BMC window), not sampled by directed
  test vectors. See "Resolved finding" below for the FAIL this superseded.

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

## Resolved finding: `insn_add_ch0`'s original FAIL was a missing wrapper constraint, not an RTL bug

The investigation summarized below (VCD/witness archaeology, a hand-built
Icarus replay flagged as unreliable, an off-by-one in identifying the
actually-failing assertion line) is preserved as a record of the debugging
path, since the reliable technique it converges on — Yosys's own native
witness replay — is worth reusing for any future counterexample.

**Actual root cause (confirmed via `yosys -p "read_rtlil
model/design_prep.il; sim -r engine_0/trace.yw -vcd out.vcd -a"`, a clean,
glitch-free replay of the *exact* prepped model the solver reasoned about —
see `parse_witness.py`/`native_sim_replay.sh` in this session's scratch dir
for the replay technique)**: not `spec_rd_wdata == rd_wdata` at all — that
was an off-by-one; the real failing assertion is
`` `rvformal_addr_eq(spec_pc_wdata, pc_wdata) `` (`rvfi_insn_check.sv:178`).
`wrapper.sv` leaves `wb_dat_s2m` (the simulated fetched-instruction bytes)
completely free, per standard riscv-formal convention. For an
`isa=rv64i`-only check, nothing stopped the solver from picking fetch data
that happens to *also* be a legitimately valid compressed (RVC) encoding at
the relevant 16-bit-aligned slot. This core correctly detects that
(`is_compressed`) and advances `pc` by 2 — spec-correct — but `rvfi_insn`
(core.sv's RVFI tap reports the C-expanded 32-bit *equivalent*, not the raw
16-bit encoding) gives the standard `insn_add.v` spec model no way to know
the retired instruction was actually 2 bytes, so it unconditionally checks
`spec_pc_wdata = rvfi_pc_rdata + 4`. Genuine mismatch (2 vs 4), entirely a
formal-harness gap, not a hardware defect.

**Fix** (`wrapper.sv`, matching riscv-formal's own `picorv32` reference
wrapper's precedent for exactly this class of gap): constrain
`wb_dat_s2m`'s low 2 bits at every 16-bit-aligned slot within the 64-bit bus
word to `2'b11`, ruling out compressed encodings for the current
base-ISA-only (`isa=rv64i`) check scope:
```systemverilog
`ifndef RISCV_FORMAL_ALLOW_COMPRESSED
    always @* begin
        assume (wb_dat_s2m[ 1: 0] == 2'b11);
        assume (wb_dat_s2m[17:16] == 2'b11);
        assume (wb_dat_s2m[33:32] == 2'b11);
        assume (wb_dat_s2m[49:48] == 2'b11);
    end
`endif
```
Confirmed: `insn_add_ch0` now `Status: passed` at the real configured depth
(15) with this constraint in place. This guard is scoped to non-Zca checks
on purpose — remove it (and add a proper raw-16-bit `rvfi_insn` tap) once
dedicated Zca check models are added, per the fix's own code comment in
`wrapper.sv`.

**Debugging notes worth keeping**: the VCD Yosys's own `sim -r -vcd` writes
pads every multi-bit signal's declared width by 4 characters in the dump
(e.g. a 32-bit signal's symbol carries a 36-character value) — a real
quirk of that dumper, not a bug in the design; account for it when grepping
VCD output by symbol. A hand-built Icarus replay that force-assigns a
register also driven by a real `always_ff` in the same design produces
delta-cycle race artifacts in Icarus's SVA evaluation — unreliable for
exact-value comparison, only trust it for coarse instruction-identity/
timing checks. Prefer `sim -r <witness.yw>` against `design_prep.il`
(the solver's own prepped model) for anything needing bit-exact replay.

## Resolved finding: all 8 branch/jump checks FAILed on target-alignment semantics, not an RTL bug

Every control-flow check (`insn_{beq,bne,blt,bge,bltu,bgeu,jal,jalr}_ch0`)
failed identically at `rvfi_insn_check.sv:198`, `assert(spec_trap == trap)`
— never the `pc_wdata` line the `insn_add_ch0` fix already covers. Native
witness replay on several of them showed the RTL and the spec model
computed the *exact same* target address (bit-identical `pc_wdata` /
`spec_pc_wdata`), but disagreed on whether that target should trap: the
RTL correctly did not trap on a target that's 2-byte-aligned but not
4-byte-aligned; the spec model expected a misaligned-instruction-fetch
trap.

**Root cause**: riscv-formal's 8 control-flow spec models
(`insns/insn_{beq,...}.v`) compute `ialign16` from
`` `ifdef RISCV_FORMAL_COMPRESSED `` — `1` (2-byte alignment required) if
defined, `0` (strict 4-byte alignment) otherwise. `genchecks.py` only
auto-emits that define when `isa` contains `'c'`, and this project's
`checks.cfg` has `isa rv64i` (no `c`, deliberately — see the fix below).
This core implements Zca (the C extension) **unconditionally**, so
IALIGN=16 is a permanent hardware property, not an optional one — the RTL
was right, the check was enforcing a stricter rule than this core actually
has.

**Fix** (`checks.cfg`'s `[defines]` section): add
`` `define RISCV_FORMAL_COMPRESSED `` explicitly, without changing `isa`
itself. Verified via direct read of the riscv-formal source
(`insns/generate.py`, all 8 affected `.v` models) that this define is
referenced *only* inside those 8 control-flow models, and only feeds
`ialign16`/`spec_trap`'s alignment term — never `spec_rd_wdata` or
anything else — so it's structurally impossible for this to affect any of
the other 46 checks. Deliberately not done by adding `'c'` to `isa`
instead: that would also pull in ~30 Zca-specific `c_*` checks that need
the raw-16-bit `rvfi_insn` tap this project doesn't have yet (see "Next
steps" below). Confirmed: all 8 checks flipped FAIL→PASS.

## Resolved finding: all 11 load/store checks FAILed — two real `core.sv` bugs plus a harness convention mismatch, all fixed together

**Bug 1 (real hardware defect, formal's first genuine find here)**:
`core.sv` never checked data-access alignment at all.
`mem_sel = mem_size_mask << mem_paddr[2:0]` is a plain 8-bit shift with no
carry into a second bus word, so an overflowing (misaligned) access
silently truncated and committed corrupted data instead of either handling
it correctly or trapping — the RISC-V spec requires one or the other. This
was a known, documented, *deliberately deferred* gap (core.sv's own header
comment already flagged "Misaligned DATA access... under-implemented"),
but the deferral had left the core doing the one thing the spec doesn't
allow: silently corrupting data with no trap.

**Fix**: `mem_load_misaligned`/`mem_store_misaligned` (new wires, keyed off
`mem_size` and `mem_paddr`'s low bits, same case-ladder idiom as the
existing `mem_size_mask`) now suppress the bus phase entirely for a
misaligned access — it traps (`mcause` 4 = Load address misaligned, 6 =
Store/AMO address misaligned, `mtval` = faulting address) at the end of
`S_EXEC` instead, reusing the exact trap machinery illegal-instruction/
ecall already use. New end-to-end coverage in
`testbench/core_misaligned_trap_tb.sv` (mirrors
`core_c_illegal_trap_tb.sv`'s pattern): both load- and store-misaligned
cases, confirming the destination register is untouched and the store
never reaches memory at all.

**A real bug caught while implementing the fix, not by formal**: the first
version of this check spuriously fired during an AMO's `S_AMO_WRITE`
phase, because `mem_paddr` (`=alu_result`) gets repurposed for the AMO
modify value the instant that state begins (the same hazard
`amo_addr_q`/`amo_sel_q` already exist to work around elsewhere), and
`is_amo_rmw` stays high through both phases — so the misalignment check
was reading the modify value's low bits *as an address* and occasionally
tripping a bogus store-misaligned trap right at the AMO's real commit.
Caught by `core_a_ext_tb`'s regression timing out (an infinite trap loop
with no handler installed), not by riscv-formal (no AMO checks are
generated for `isa=rv64i`). Fixed by scoping
`mem_load_misaligned`/`mem_store_misaligned` to `state == S_EXEC` — the
only state where the decision is actually consulted.

**Bug 2 (formal-harness-only, verification-instrumentation convention
mismatch)**: the `` `ifdef RISCV_FORMAL `` RVFI memory tap mixed two
incompatible addressing conventions — `rvfi_mem_addr` reported the exact
(possibly unaligned) address while `rvfi_mem_rmask`/`rdata`/`wdata` were
already bus-word-lane-relative (i.e. assumed an *aligned* address). Fixed
by reporting `rvfi_mem_addr` as the dword-aligned address instead, and
adding `` `define RISCV_FORMAL_ALIGNED_MEM `` to `checks.cfg` (verified via
the riscv-formal source that this define is scoped only to the 11
load/store spec models, same isolation proof as `RISCV_FORMAL_COMPRESSED`
above).

**A second-order bug in the first version of that fix**: the natural
choice was to alias `rvfi_mem_addr` to the existing `mem_addr` wire (the
real Wishbone-bus-facing aligned address) — but `mem_addr` is only 32 bits
wide (this core's physical address space is 32-bit by design), while
riscv-formal's spec model computes its own 64-bit expected address
straight from the solver's free `rs1_rdata`. Every load failed at the
address-equality assertion because `rvfi_mem_addr`'s upper 32 bits were
silently zero regardless of what the solver picked for `rs1`'s high bits.
Fixed by computing the aligned address directly from the full-width
`mem_paddr` (`{mem_paddr[63:3], 3'b0}`) instead of reusing the
intentionally-truncated `mem_addr` wire — the real bus address stays
32-bit (correct, untouched), only the RVFI tap needed the wider value.

Confirmed: all 11 load/store checks now PASS, including `insn_lw_ch0`,
which needed a longer solver budget than the other 10 (ordinary
solver-time variance, not a different bug — same class of thing
`insn_blt_ch0` hit earlier, see "Known open findings").

## Known open findings (not RTL bugs, not yet resolved)

- **`ill_ch0`**: `PREUNSAT` — the stock `rvfi_ill_check.sv` template
  assumes `rvfi_insn == 32'h00000000` is a reachable illegal-instruction
  test vector. It structurally isn't, on this core: the non-compressed
  path always has `instruction[1:0] == 2'b11` when `is_compressed==0`, and
  the compressed path substitutes the fixed placeholder `32'h00000013` for
  any illegal/reserved encoding (so RVFI never carries raw garbage) —
  `rvfi_insn` can never be exactly 0. Not fixable via a `wrapper.sv`
  `assume` (the solver has no freedom here; the contradiction is inside
  `core.sv`'s own RVFI-tap logic). Needs either the raw-16-bit `rvfi_insn`
  tap (see "Next steps") or a core-specific replacement check that reasons
  about the raw fetched halfword instead of `rvfi_insn` directly. The real
  illegal-instruction trap behavior is already covered elsewhere
  (`testbench/core_c_illegal_trap_tb.sv`), so there's no evidence of an
  actual hardware gap here.
- **`reg_ch0`**: solver timeout (not a counterexample — no witness trace
  was ever produced). Its property (full 64-bit register-file consistency
  across the entire free-running BMC trace, symbolic over both register
  index and retire order) is structurally heavier than every other
  check that's passed so far. Worth retrying with a much larger wall-clock
  budget and/or `boolector` (riscv-formal's own best-tested default for
  this specific check across its reference cores) before assuming it's
  genuinely intractable at this depth.

## Next steps, roughly in order

1. Scale to `rv64im`, `rv64ima`, `rv64imac`.
2. Add `` `RISCV_FORMAL_CSR_* `` trace ports to `core.sv` one CSR at a time
   for privilege-mode checks — `mstatus`/`mepc`/`mcause`/`sepc`/`scause`
   first, matching the CSRs this project's real MPRV/TSR bugs (see
   [[known-gap-mstatus-fs-warl]] in project memory) were found in, since
   that's exactly the class of bug formal verification is strongest against.
3. Once Zca-specific check models exist: add a raw-16-bit `rvfi_insn` tap,
   remove the `RISCV_FORMAL_ALLOW_COMPRESSED` guard in `wrapper.sv`, and
   revisit `ill_ch0` with a core-specific check that no longer needs it.
4. Retry `reg_ch0` with a larger timeout and/or `boolector`.

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
