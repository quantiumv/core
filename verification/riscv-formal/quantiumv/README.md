# riscv-formal integration (started 2026-08-11, 56/56 isa=rv64i checks PASS; AMO 18/18 and C-extension 30/30 now added, M-extension in progress, first CSR trace ports added)

Formal verification via [riscv-formal](https://github.com/YosysHQ/riscv-formal)
(Yosys + SymbiYosys + a SAT/BMC solver), proving ISA correctness exhaustively
against the spec rather than sampling it via directed/random simulation. This
is a genuinely different, stronger class of verification than everything else
in `verification/` and `testbench/` — see the session that started this for
the full reasoning.

## Status: all 56 generated `isa=rv64i` checks PASS. Full sweep run, every failure root-caused, one real RTL bug found and fixed.

Ran the complete `isa=rv64i` set (56 checks) for the first time: 35 passed
outright, 21 failed. Every failure was root-caused (native witness replay,
see below) and falls into exactly 4 categories:
- **8 branch/jump checks** (`insn_{beq,bne,blt,bge,bltu,bgeu,jal,jalr}_ch0`)
  — formal-harness scope gap, fixed via a `checks.cfg` define. Now PASS.
- **11 load/store checks** (`insn_{lb,lbu,lh,lhu,lw,lwu,ld,sb,sh,sw,sd}_ch0`)
  — two real `core.sv` bugs (one a genuine hardware defect, formal's first
  real find in this integration) plus a formal-harness convention mismatch,
  all fixed together. Now PASS.
- **`ill_ch0`** — a genuine `rvfi_insn` spec-compliance gap in `core.sv`
  (compounded by the compressed-exclusion wrapper guard from the
  `insn_add_ch0` fix), both fixed. Now PASS.
- **`reg_ch0`** — not a counterexample, a solver-capability gap: neither
  `bitwuzla` nor `z3` could produce a verdict at all, but `boolector`
  (built from source, see "Environment setup" below) solves it in ~18
  minutes. Now PASS.

**Net result: 56/56 PASS.** See "Resolved finding" sections below for the
full story on each fixed category.

**Update 2026-08-12 (continuation)**: the `RISCV_FORMAL_ALLOW_COMPRESSED`
wrapper guard (added for `insn_add_ch0`, narrowed for `ill_ch0`) has now
been removed entirely — it was fully obsoleted by the `rvfi_insn` fix, not
just narrowable (see its own "Resolved finding" below). Removing it
exposed **two real, previously-undiscovered `core.sv`/`csr_file.sv`
bugs**, both fixed; all 56 checks still pass with the guard gone. This is
formal verification doing exactly the job it's for.

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
  (`rvfi_csr_<name>_*`). `rvfi_insn` correctly reports the raw 16-bit
  encoding for compressed instructions per the RVFI spec (see the `ill_ch0`
  "Resolved finding" below — this was a real gap until 2026-08-12).
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
`insn_blt_ch0` hit earlier, both resolved with a bigger `bitwuzla` budget,
no solver swap needed).

## Resolved finding: `ill_ch0` PREUNSAT — a real `rvfi_insn` spec-compliance gap, plus a wrapper guard that (correctly, at the time) ruled out its own test vector

`ill_ch0`'s stock `rvfi_ill_check.sv` template assumes `rvfi_insn == 0` is
a reachable illegal-instruction test vector (riscv-formal's own canonical
"obviously illegal" pattern — confirmed by reading the RVFI spec directly,
`docs/source/procedure.rst`: "an all-zero `rvfi_insn` value" is the
documented convention for a faulting/undecodable instruction). Before this
fix, that value was doubly unreachable on this core:

1. **`rvfi_insn` itself was wrong.** The official RVFI spec
   (`docs/source/rvfi.rst`) is explicit: "For compressed instructions the
   compressed instruction word must be output on this port" — the RAW
   16-bit encoding (zero-extended), not an expanded equivalent. `core.sv`
   was instead reporting the C-expanded 32-bit `instruction` wire
   unconditionally, which for the canonical illegal-compressed pattern
   (`16'h0000`, C.ILLEGAL) is the inert `32'h00000013` placeholder
   substituted for safety (see `instruction`'s own assignment) — never 0.
   This was a real, if previously low-impact, spec-compliance gap: harmless
   for every isa=rv64i check *except* `ill_ch0`, since `wrapper.sv`'s
   compressed-exclusion guard (below) kept `is_compressed=0` throughout
   every other check's entire BMC trace, making the wrong-tap branch
   unreachable everywhere else.
2. **The wrapper guard added for `insn_add_ch0` (above) also excluded
   `ill_ch0`'s own test vector.** That guard rules out compressed fetches
   entirely by forcing every 16-bit-aligned slot's low 2 bits to `2'b11` —
   but `16'h0000` (bits `00`) is exactly the pattern `ill_ch0` needs the
   solver to be free to pick.

**Fix, both parts**:
- `core.sv`: `rvfi_insn` now reports `{16'b0, first_hw}` when
  `is_compressed`, matching the spec. Zero regression risk to any other
  check — proven, not assumed: the wrapper guard forces `is_compressed=0`
  for their entire trace, so this branch was structurally unreachable for
  all 44 other non-`ill` checks both before and after.
- `checks.cfg`/`wrapper.sv`: added a per-check-instance macro
  (`` -D RISCV_FORMAL_CHECK_@checkch@ `` in `[script-sources]`, where
  `@checkch@` is genchecks.py's own full check-instance name, e.g.
  `insn_add_ch0`, `ill_ch0` — confirmed via source read to be reliably set
  on every check-generation code path, unlike `@check@`, which crashes
  `genchecks.py` with a `KeyError` for `insn_*` checks specifically, since
  those are generated through a different function that never sets it).
  `wrapper.sv`'s compressed-exclusion guard is now also gated
  `` `ifndef RISCV_FORMAL_CHECK_ill_ch0 ``, lifting it *only* for that one
  check — every other check still gets `RISCV_FORMAL_CHECK_<its own
  name>` defined instead, which doesn't match, so the guard stays active
  for them exactly as before.

Confirmed: `ill_ch0` flipped `PREUNSAT` → `PASS`. Spot-checked 5 other
checks (`insn_add_ch0`, `insn_lb_ch0`, `insn_beq_ch0`, `cover`,
`causal_ch0`, spanning every category touched by any change this session)
against the new config — all still pass.

## Resolved finding: `reg_ch0` — a solver-capability gap, not a counterexample, not an RTL issue

`reg_ch0` checks full 64-bit register-file consistency across the entire
free-running BMC trace, symbolic over both register index and retire
order — structurally the heaviest property in this suite, and the only
check where the choice of solver mattered for whether it could produce
*any* verdict at all, not just how fast. Every solver already present in
this environment failed to converge, each isolated with
`ulimit -v 8000000` given the earlier WSL-crash history: `bitwuzla` at up
to 1800s (30 min) — zero progress past "Checking assertions", no crash,
no verdict; `z3` at up to 1500s — crashed after ~2m34s
(`BrokenPipeError` inside `yosys-smtbmc`'s write to the solver process,
the z3 subprocess itself died — `DONE (ERROR, rc=16)`, not a real result
either way).

**Fix**: built `boolector` from source (riscv-formal's own best-tested
default for this specific check across its reference cores — not
available as a pre-built binary here, unlike `bitwuzla`/`sby`/
`yosys-slang`, which all came as ready-made nix-store artifacts). Plain
upstream build, no patches: CaDiCaL SAT backend + btor2tools + boolector
itself, via boolector's own `contrib/setup-*.sh` + `configure.sh` +
`make` — see "Environment setup" below for the exact commands. Confirmed:
`reg_ch0` now `Status: passed` with `boolector`, ~18 minutes wall clock
(1090s).

Not wired into `checks.cfg` as the default solver: `genchecks.py`'s
`solver` option is a single global setting with no per-check-type
override hook (confirmed by reading the source — unlike `[defines
<check>]`/`[script-defines <check>]`, which do support per-check
sections, `solver` is resolved once from `[options]` before any check is
generated). `bitwuzla` stays the global default since it's dramatically
faster for the other 55 checks; running `reg_ch0` specifically needs a
one-line manual solver swap on its generated `.sby` file (see
"Environment setup" below) rather than a `checks.cfg`-level change. Worth
revisiting if `genchecks.py` ever gains a real per-check solver hook, or
if `boolector` turns out fast enough to just use everywhere.

## Resolved finding: removing the compressed-exclusion wrapper guard entirely exposed two real bugs — both fixed, all 56 checks still pass

Started as an attempt to scale `checks.cfg` to `rv64imac`. The plan's first
step was testing whether `RISCV_FORMAL_ALLOW_COMPRESSED` (added for
`insn_add_ch0`, narrowed to exempt only `ill_ch0`) could be removed
entirely now that `rvfi_insn` correctly reports raw compressed encodings
— reasoning: every base-ISA opcode has `bits[1:0]==11` by construction,
which a zero-extended 16-bit compressed value can never satisfy, so no
base-ISA spec model's `spec_valid` pattern should ever be able to
accidentally match a compressed retiring instruction anymore. Removing
the guard and re-running all 56 checks (parallel batches at first, which
introduced solver-contention timeouts unrelated to correctness — see
below) surfaced real counterexamples on `insn_beq_ch0`, `insn_bge_ch0`,
`insn_blt_ch0`, `insn_bltu_ch0`, and `pc_fwd_ch0`. Root-caused both via
native witness replay (Python VCD parsing this time, not manual grep —
more reliable for exact bit values across signal renames).

**Bug 1 — `mepc`/`sepc` were not WARL-masked (`csr_file.sv`, real
hardware defect)**: per spec, `mepc`/`sepc` bit 0 must always read as
zero (this core's IALIGN=16 via Zca means only bit 0 needs masking, not
`bit[1:0]` as an IALIGN=32-only core would need). The CSR-write path
(`mepc_q <= i_csr_wdata;`) applied no masking at all — an ordinary
`csrrw mepc, x1` could set `mepc` to any 64-bit value, including odd. The
witness for `insn_beq_ch0` showed exactly this: `pc_rdata` reaching a
retiring instruction as `31` (odd — architecturally impossible for any
real fetch address), traced back to a preceding `mret` loading an
unmasked odd `mepc` straight into `pc`. Fixed by masking bit 0 on the
CSR-write arm only (`{i_csr_wdata[63:1], 1'b0}`) — the trap-entry arm
(`i_trap_pc`, sourced from `core.sv`'s own `pc`) is already
architecturally guaranteed even, so it's left untouched. Mirrored the
same masking into `csr_file_priv_random_tb.sv`'s shadow model (same
reasoning as the earlier MPRV fix) so the existing 14000-check random
regression continues to test the real invariant instead of a stale one.

**Bug 2 — `commit_now` wasn't gated by `!halted` (`core.sv`, exposed by
the formal harness's own documented modeling convention, not reachable
in real silicon today)**: the PC-register block's own comment already
claimed "state parks in S_FETCH forever [after halt]... so `commit_now`
can never become true again" — true for real hardware (a well-behaved
Wishbone slave has no reason to ever ack once `wb_master_drive` stops
asserting `wb_cyc_o`/`wb_stb_o`), but not actually *enforced* by the
expression itself. riscv-formal's wrapper models `wb_ack_i` as a free,
unconstrained input (standard convention, matches every other
riscv-formal core integration) — nothing stops the solver from asserting
it post-halt anyway, pushing `state` back into `S_EXEC` and producing a
bogus extra `rvfi_valid` pulse with `pc` frozen but `state` still
oscillating. `pc_fwd_ch0`'s witness showed exactly this pattern
(`commit_now` pulsing again one step after `halted` latched). Fixed by
adding `!halted` to `commit_now`'s top-level gate — makes the existing
code comment's claim actually true, closing a real (if narrow,
today-formal-only-reachable) gap rather than leaving it as an unstated
assumption.

Both fixes confirmed via full 38-testbench regression (clean) and
verilator lint (clean) before any formal re-run. **All 56 checks then
confirmed passing with the guard fully removed** — the 8 branch/jump
checks and `pc_fwd_ch0` that surfaced the bugs now pass because the bugs
are fixed, not because a guard hides the scenario. `wrapper.sv` is now
simpler: no `RISCV_FORMAL_ALLOW_COMPRESSED`/`RISCV_FORMAL_CHECK_*`
machinery at all.

**Debugging note worth keeping**: the earlier parallel batch run (4-wide,
then even 2-wide) produced a cluster of *timeouts* (not failures) on
checks already known-good — re-running the same checks sequentially,
uncontended, resolved every one of them. Concurrent heavy SMT solver
processes competing for this WSL VM's CPU is a real, reproducible source
of false timeouts, distinct from the earlier documented WSL-crash risk
(concurrent z3) — don't mistake a contention-timeout for a regression
without a clean, sequential re-run first.

## Resolved finding: AMO (18/18 non-LR/SC atomics) now PASS — one real `core.sv` bug, one spec-model bug, both fixed

Scaling toward `rv64imac` in stages (A: AMO, B: M, C: C-extension — each
isolated via its own hand-built or upstream `isa` manifest, see "Staged
verification" below) rather than attempting the combined string directly,
since `genchecks.py` does a literal `insns/isa_{isa}.txt` filename lookup
(no `isa_rv64imac.txt` exists upstream, and no LR/SC spec model exists at
all — genuinely unimplemented upstream, `# FIXME: LR.W / SC.W` in
`generate.py`, confirmed via `docs/source/rvfi.rst` that this is a
check-generation gap, not an RVFI port gap). **Decision: verify the 18
non-LR/SC AMO instructions (AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU ×
`.W`/`.D`), leave LR/SC out of scope** — `insn_amo()` in `generate.py` is a
fully-written, ready generator for exactly these, just never wired up
(commented out alongside the LR/SC FIXME). Patch mechanism matches this
project's own "config lives in the repo, framework lives external"
convention already used for `yosys-slang`: `riscv-formal-amo.patch`,
applied via `patch -p1 -d ~/riscv-formal < .../riscv-formal-amo.patch`
(see "Environment setup" below).

Two `core.sv` changes were needed to make the RVFI tap AMO-aware, following
the same idiom already established for plain loads/stores:
- Widened `amo_addr_q` from 32 bits to full `WORD_SIZE` (mirrors
  `mem_paddr`'s own precedent — real hardware only ever consumes the low 32
  bits via `wb_addr_o = amo_addr_q[31:0]`, the extra width exists purely
  for the RVFI tap, `` `ifdef ``-gated).
- Added an `is_amo_rmw`-priority arm to the RVFI memory tap
  (`rvfi_mem_addr`/`rmask`/`wmask`/`rdata`/`wdata`), since decode-driven
  `is_load` stays true for an AMO's entire lifetime including the
  `S_AMO_WRITE` commit cycle, where `mem_paddr`/`mem_sel` are repurposed
  for the modify value, not the address.

**Real bug found and fixed: `amo_wdata`'s byte-lane shift silently
corrupted `.W` AMO writes at any legally word-aligned-but-not-dword-aligned
address** (i.e. `addr[2]=1`, `addr & 7 == 4`) — a genuine, previously
undiscovered hardware defect, predating this session's AMO work entirely.
`amo_addr_q` is deliberately captured already-rounded to an 8-byte dword
boundary (`{mem_paddr[63:3], 3'b0}`, needed for both the real 32-bit bus
address and the RVFI tap), so its low 3 bits are *always* zero —
`amo_wdata = amo_new_value << (amo_addr_q[2:0] * 8)` therefore never
actually shifted. `insn_amoswap_w_ch0`/`amoadd_w`/`amoxor_w` failed with
exactly this pattern: witness replay (native Yosys sim against the
solver's own prepped model + a custom VCD parser — see "Debugging
methodology" below) showed `rvfi_rs1_rdata` ending in `...ffc` (word-aligned,
`addr[2:0]==100`), the spec correctly computing a shifted write value, and
`core.sv` reporting the *unshifted* one. Never caught before because no
formal check ever exercised AMO writes, and no simulation testbench
happened to test this exact address pattern — exactly the class of bug
this whole formal push exists to find (see
[[known-gap-mstatus-fs-warl]] for the same principle applied to the
earlier MPRV/TSR CSR bugs). **Fix**: added a new `amo_byte_off_q` register
capturing the *true*, unrounded `mem_paddr[2:0]` at the same capture edge,
used for `amo_wdata`'s shift instead of the always-zero
`amo_addr_q[2:0]`. Verified via full 38-testbench regression (clean —
confirms the untested corner) and verilator lint before re-running formal.

**Spec-model bug found and fixed (in the patch, not `core.sv`):
`amominu_w`/`amomaxu_w`'s unsigned comparison used the full, unsliced
64-bit `rvfi_mem_rdata`**, which broke once the byte-lane bug above was
fixed. `insn_amo()`'s generated `wire [31:0] mem_result = expr;` truncates
correctly regardless, but the *comparison itself* (`rvfi_mem_rdata <
rvfi_rs2_rdata[31:0]`) runs on the untruncated operand. This core's
`amo_rdata_q` correctly *sign-extends* the `.W` old value into the upper
bits (exactly what makes the `$signed()`-based `amomin_w`/`amomax_w`
comparisons correct across every alignment) — but that same sign extension
makes an *unsigned* `<`/`>` on the raw 64-bit value see a huge number for
any old value with bit 31 set, picking the wrong winner even though the
core's actual 32-bit result was ISA-correct. Confirmed by hand-computing
the expected AMOMINU.W result from the failing witness and finding it
matched the core's output exactly — the checker was wrong, not the RTL.
**Fix**: sliced `rvfi_mem_rdata[31:0]` explicitly in the `amominu_w`/
`amomaxu_w` comparisons (patch only, `.D` variants need no change since
their `oprange` is the full register width already).

**Gotcha worth flagging for any future `generate.py` re-run**: `header()`
accumulates instruction names into `isa_database` per active `current_isa`
value, and the script unconditionally writes `isa_<name>.txt` for every
key at the end of its run — this silently clobbers a hand-built manifest
of the same name (`isa_rv64ia.txt` went from 67 lines to 9 the first time
this was hit). The repo's copy is the source of truth; re-copy it into
`~/riscv-formal/insns/` after every `generate.py` run.

**Result: all 18 AMO checks PASS** (verified via `isa=rv64ia`, a hand-built
manifest — see `isa_rv64ia.txt`).

## Resolved finding: C-extension (30/30) PASS cleanly — first real exercise of the `rvfi_insn` raw-encoding tap and `RISCV_FORMAL_ALIGNED_MEM` for compressed loads/stores

Ran the full Zca instruction set (`isa=rv64ic`, upstream manifest, no
patching needed) — 30 checks generated (`c_addi4spn` through `c_sdsp`).
29/30 passed on the first sequential run; `insn_c_ld_ch0` needed a longer
solver budget (30 min vs. the 10 min default) — the same ordinary
solver-time variance already documented for `insn_lw_ch0` above, not a
different bug. **All 30 now PASS.** This is the first time this session's
`rvfi_insn` fix (reporting the raw 16-bit compressed encoding) and the
`RISCV_FORMAL_ALIGNED_MEM` define (aligned-bus-address + misaligned-trap
convention) have actually been exercised by compressed-instruction-specific
spec models rather than just base-ISA models running alongside compressed
instructions in the trace — clean pass across all of them (loads, stores,
ALU-immediate, register-register, branches, jumps, stack-pointer forms)
is a meaningfully stronger confirmation than the earlier "56/56 with
compressed instructions incidentally in the trace" result.

## Status: M-extension (mul/div/rem family) — in progress, hit real solver-hardness/scale limits distinct from anything above

`isa=rv64im` (upstream manifest) generates 13 new checks. These split into
two structurally different problems, neither a sign of an RTL bug:

**Divide/remainder family (`div`/`divu`/`rem`/`remu`/`divw`/`divuw`/`remw`/
`remuw`)** — this core's divider (`design/divider.sv`) is a deliberately
simple 1-bit-per-cycle restoring divider: `WORD_SIZE` (64) cycles for
*every* division, unconditionally, no early exit, no fast path for the `W`
variants (see the module's own header comment — simplicity and
per-cycle-checkability were the explicit design goals, not synthesis or
speed). The blanket `insn 15` depth default is nowhere near enough cycles
for one of these to ever retire — a structural `PREUNSAT`
("Assumptions are unsatisfiable") at check-generation time, confirmed via
each check's own `logfile.txt`, not a real correctness gap. **Fix so far**:
per-instruction depth overrides in `checks.cfg`'s `[depth]` section
(`insn_div 80`, etc. — `get_depth_cfg()` in `genchecks.py` matches
`insn_<name>` patterns specifically, confirmed by reading the source),
giving the full 64-cycle divide plus margin. This resolved the PREUNSAT —
assumptions are now satisfiable at depth 80 — but exposed a second,
separate problem: at that much deeper an unroll, `bitwuzla` exhausted an
8GB `ulimit -v` safety cap mid-solve (`std::bad_alloc`, confirmed via
logfile, not a hang) even though the check itself needs the depth. Bumped
to 16GB then 20GB (this environment has ~21GB physically available); still
timing out past 30 minutes on the assertion-proving phase itself even once
the memory ceiling stopped being the blocker. Currently retrying with
`boolector` and a much longer (up to 20h) budget per the project owner's
explicit call — genuinely open whether it converges.

**Multiply family (`mul`/`mulh`/`mulhsu`/`mulhu`/`mulw`)** — no depth or
memory problem (`Checking assertions in step 15` is reached quickly, same
as every other check), but the SAT problem itself is the well-known
hard case for bit-blasting solvers on nonlinear 64×64 multiplication.
Both `bitwuzla` (30 min, zero progress signal) and `boolector` (30 min,
then a full 20-hour run, also zero progress signal) failed to converge on
`insn_mul_ch0` specifically — unlike `reg_ch0` above, where `boolector`
succeeded where `bitwuzla`/`z3` failed outright, solver choice alone isn't
fixing this one. Continuing to work through the remaining checks with long
`boolector` budgets per the project owner's explicit authorization; **this
core's multiply implementation is already verified via simulation and the
ACT4 riscv-arch-test compliance suite** (both predate this formal push —
see [[project-overview]] in project memory), so this is exclusively about
closing the *exhaustive proof* gap, not an open correctness question.

## Status: first CSR trace ports added (mepc/mcause/sepc/scause) — real RTL work lands clean, but the generic `any` checker can't cleanly verify trap-target CSRs on this core (upstream tooling gap, not an RTL issue)

Added the first `rvfi_csr_<name>_*` ports: `mepc`, `mcause`, `sepc`, `scause`.
`mstatus` deliberately deferred (12 real fields, 5 different write sources —
its own round later, see `csr_file.sv`'s header comment on the new port
group). `design/csr_file.sv` gained `o_mcause`/`o_scause` (mirroring the
existing `o_mepc`/`o_sepc` pattern) plus four `` `ifdef RISCV_FORMAL ``-only
`*_next` ports — combinational transcriptions of each register's own
`always_ff` priority-mux, needed because RVFI wants both the
pre-instruction (`rdata`) and post-instruction (`wdata`) value in the same
cycle `rvfi_valid` pulses, but the real `always_ff` only makes the new
value visible the *following* cycle. `design/core.sv` threads these through
and adds the 16 new ports (4 CSRs × rmask/wmask/rdata/wdata). Full 39/40
regression + verilator lint (both without and with `` -DRISCV_FORMAL ``)
confirmed zero effect on normal builds — see "Environment setup" below for
the exact commands, since the established `iverilog`/`verilator`
invocations needed real reconstruction this round (file compile order,
`-s <top>` pinning, per-testbench CWD requirements — none of it specific to
this change, all pre-existing project quirks worth documenting once).

**`checks.cfg` gotcha, same class as `generate.py`'s manifest-clobbering
note above**: CSR checks go through `genchecks.py`'s `check_cons()` — the
*same* code path as `reg`/`pc_fwd`/`pc_bwd`, needing a **two-number**
`[depth]` entry (`start depth`), not the single value `insn`-family checks
use. Missing this entirely causes `check_cons()`'s own `depth_cfg` lookup
to silently return `None` and skip check generation — no error, no check
files, nothing in the check count. Confirmed by reading `genchecks.py`
directly after the checks came up missing on the first attempt. Also: a
CSR listed in `[csrs]` with no test string generates a check referencing a
checker file (`rvfi_csrc_check.sv`) that doesn't exist in this checkout —
use an explicit test type (`any`, matching the built-in default for
`mscratch`) for every `[csrs]` line.

**Real finding: the generic `any` CSR-consistency checker
(`rvfi_csrc_any_check.sv`) has no privilege-mode or trap-semantics
awareness at all, making it structurally unable to cleanly verify
trap-target CSRs on a multi-privilege core — confirmed via witness replay,
not assumed.** Two distinct manifestations, both root-caused:
1. **Privilege-gated access traps.** The checker assumes every CSRRW/RS/RC
   targeting the CSR's address always completes as a literal write. On this
   core, `core.sv`'s own access check (`csr_priv_violation`, `core.sv:1020`:
   `is_csr && (imm_2[9:8] > current_priv)`) correctly traps
   (illegal-instruction) when a CSR is targeted from below its required
   privilege. `mepc`/`mcause` are M-mode-only; `sepc`/`scause` need S-or-M.
   The solver, free to pick any privilege level, found exactly this —
   confirmed via native witness replay on `csrc_any_mcause_ch0`: the
   "failing" trace showed a `csrrw x12, mcause, x1` issued from S/U-mode
   correctly trapping (`mcause` becomes `2`, the illegal-instruction
   exception code) instead of writing `x1`'s value, and hand-computing the
   expected result confirmed the core's behavior was ISA-correct — the
   checker's assumption was wrong, not the RTL. **Partially mitigated**: a
   `checks.cfg` `[assume !csrc_any_(mepc|mcause)_ch0]` /
   `[assume !csrc_any_(sepc|scause)_ch0]` pair scopes each check's whole
   trace to the privilege level where the access actually succeeds
   (`rvfi_mode`, already an existing RVFI port, is directly visible at
   `assume_stmts.vh`'s inclusion scope inside `rvfi_testbench` — confirmed
   by reading that file directly, not assumed). **Non-obvious gotcha**:
   `genchecks.py`'s `[assume <pattern>]` matching is inverted from the
   intuitive reading — a *bare* pattern **excludes** matching checks; only
   a `!`-prefixed pattern **includes only** matches. Confirmed by tracing
   `check_cons`'s own matching loop by hand with concrete examples, not
   assumed — an easy convention to get backwards.
2. **Trap-driven writes the checker can't see at all — the harder,
   unresolved half.** mepc/mcause/sepc/scause aren't *only* written by
   explicit CSR instructions — they're the trap mechanism's own target
   registers, written on every trap-to-that-level regardless of what
   instruction is executing. `rvfi_csrc_any_check.sv` only tracks writes
   via decoding `rvfi.insn` as a CSRRW/RS/RC opcode pattern; it has no path
   to observe (or exclude) an *implicit* trap-driven write. Between a
   captured explicit write and the checker's next expected read, the
   solver can freely inject an unrelated trap that legitimately overwrites
   the register again — breaking the checker's "last captured write
   persists until the next write" assumption regardless of privilege
   scoping. Confirmed via witness replay on `csrc_any_sepc_ch0`/
   `csrc_any_scause_ch0` (fails at a *different* assertion than the
   privilege case — the cross-instruction consistency check, not the
   same-cycle self-consistency one). `mepc` also still fails even under the
   privilege-scoped assume, most likely its own separate, narrower gap: the
   WARL bit-0 masking (`design/csr_file.sv`'s `mepc_q`/`sepc_q`, this
   session's own earlier fix) means the checker's "written value equals
   read-back value" assumption is *also* false whenever the raw write value
   was odd — riscv-formal supports a `_mask="..."` check-test suffix for
   exactly this (confirmed present in `check_cons`'s parsing,
   `genchecks.py:571-580`), not yet applied. **This is why upstream's own
   `csr_spec 1.12` default config lists `mepc`/`mcause` with no test type
   at all** (`"mepc": None` in `genchecks.py`'s `spec_csrs` dict) — riscv-
   formal's own authors don't appear to have a working generic check for
   trap-target CSRs either; this isn't a gap specific to this project's
   configuration.

**Not an open correctness question for this core**: `mepc`/`sepc`'s WARL
masking and `mcause`/`scause`'s trap-capture writers are already covered by
`design/csr_file_priv_random_tb.sv` (2000 randomized iterations, 14000
checks, all passing — its own header describes it as "the sole standalone
proof that csr_file.sv's own atomic-update logic... is correct") plus the
ACT4 riscv-arch-test compliance suite and the directed
`core_priv_tb`/`core_priv_toolchain_tb`/`core_csr_toolchain_tb` testbenches.
What's blocked is specifically the *exhaustive proof* tier riscv-formal is
meant to add on top — not a sign the RTL itself is unverified. Stopping
here per the project owner's explicit direction rather than chasing a
heavier trap-suppressing `[assume]` (which would meaningfully weaken what
the check proves, not just scope it) or a from-scratch custom checker.

## Next steps, roughly in order

1. Resolve or accept-as-documented-limitation the M-extension
   solver-hardness issues above.
2. Build the final combined `isa_rv64imac.txt` manifest (union of AMO + M +
   C instruction names) and confirm the full set passes together once all
   three stages are individually clean — catches anything stage-isolation
   might have missed.
3. `mstatus` RVFI trace port — deferred from this round, see its own note
   above.
4. If ever revisited: try the `_mask="..."` suffix for `mepc`/`sepc` (fixes
   the WARL self-consistency failure specifically) — `mcause`/`scause`
   would still need a fundamentally different check (or a custom one) to
   handle trap-driven writes, which `_mask` alone doesn't address.

## Environment setup (WSL)

```
git clone --depth 1 https://github.com/YosysHQ/riscv-formal.git ~/riscv-formal
```

**Full regression + verilator lint** (the project's own gate for every
`core.sv`/`csr_file.sv` change, re-derived this round since it isn't a
checked-in script — see the top-level `README.md`'s own documented lint
command for the canonical single-file-set version this expands on):
```sh
# from the repo root -- decoder.sv MUST compile before core.sv (its own
# `include chain defines the INSTR_CODE/etc macros core.sv consumes,
# order-dependent since defines persist for the rest of the compile);
# core_wb4_sram_harness.sv/pc_trigger_sample_monitor.sv are real
# instantiated modules some testbenches need, NOT `include-only helpers
# like check_lib.sv/wb_driver.sv/halt_wait.sv/riscv_encode.sv (those must
# NOT also be passed as separate files, or they elaborate in $unit scope
# and error) -- `-s <top>` pins the actual top module so stray uninstantiated
# modules in the file set (e.g. wb4_sram.sv's own $readmemh initial block)
# don't run as spurious extra top-level simulations. Some testbenches
# (encode-crosscheck golden fixtures, firmware .hex loads) need CWD=testbench/
# at RUN time specifically -- compile from repo root, run vvp from testbench/.
iverilog -g2012 -I design -I testbench -s <tb_module_name> -o /tmp/<tb>.out \
  design/decoder.sv design/alu.sv design/c_expand.sv design/csr_file.sv \
  design/divider.sv design/register_file.sv design/uart_tx.sv \
  design/wb4_sram.sv design/wb_addr_decoder.sv design/core.sv design/soc.sv \
  testbench/core_wb4_sram_harness.sv testbench/pc_trigger_sample_monitor.sv \
  <path/to/the_tb.sv>
(cd testbench && vvp /tmp/<tb>.out)
```
Verilator lint needs the *glued* `-Idesign -Itestbench` form (a space after
`-I` silently fails to resolve the `` `include `` chain, unlike `iverilog`
which accepts either) and the same decoder-before-core file order:
```sh
verilator --lint-only -Wall -Idesign -Itestbench --top-module soc \
  design/decoder.sv design/alu.sv design/c_expand.sv design/csr_file.sv \
  design/divider.sv design/register_file.sv design/uart_tx.sv \
  design/wb4_sram.sv design/wb_addr_decoder.sv design/core.sv design/soc.sv
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

**`boolector`** (required only for `reg_ch0`, see its own "Resolved
finding" above): unlike the three above, NOT a pre-built nix-store
artifact in this environment — built from source (plain upstream build,
no patches needed):
```
git clone --depth 1 https://github.com/boolector/boolector ~/boolector
cd ~/boolector
./contrib/setup-cadical.sh      # SAT backend
./contrib/setup-btor2tools.sh
./configure.sh
cd build && make -j"$(nproc)"
ln -sf ~/boolector/build/bin/boolector ~/.local/bin/boolector
```
Takes a few minutes. `nix build nixpkgs#boolector` would likely also work
if `nix` itself is on `PATH` in a future environment (it wasn't in this
one — only pre-populated `/nix/store` artifacts existed, no working `nix`
CLI) — worth trying first since it'd be faster than a source build.

To (re-)generate checks and try running one, from `~/riscv-formal/cores/`:
```
mkdir -p quantiumv && cp <this-dir>/wrapper.sv <this-dir>/checks.cfg quantiumv/
cd quantiumv && python3 ../../checks/genchecks.py
cd checks && ulimit -v 8000000 && timeout 300 sby -f insn_add_ch0.sby
```
`reg_ch0` specifically needs `boolector`, not the `bitwuzla` every other
check uses (see its own "Resolved finding" above for why this isn't just
a `checks.cfg` setting) — swap solvers on its own generated `.sby` file:
```
cd checks
sed 's/smtbmc bitwuzla/smtbmc boolector/' reg_ch0.sby > reg_ch0_boolector.sby
ulimit -v 8000000 && timeout 1800 sby -f reg_ch0_boolector.sby
```
(`ulimit -v` + `timeout`: see the WSL-crash history above — always run this
way, not bare.)

**AMO checks** need the vendored `generate.py` patched first (see its own
"Resolved finding" above):
```
patch -p1 -d ~/riscv-formal < <this-dir>/riscv-formal-amo.patch
cd ~/riscv-formal/insns && python3 generate.py
cp <this-dir>/isa_rv64ia.txt ~/riscv-formal/insns/isa_rv64ia.txt   # generate.py clobbers this, see its own gotcha note above
```
Div/rem-family checks (`insn_div_ch0` etc.) need both the `[depth]`
override already in this dir's `checks.cfg` (regenerate checks after any
`checks.cfg` change: `cd ~/riscv-formal/cores/quantiumv && python3
~/riscv-formal/checks/genchecks.py`) and a raised memory ceiling —
`ulimit -v 16000000` or higher, not the `8000000` used elsewhere in this
doc, or `bitwuzla` crashes with `std::bad_alloc` partway through the
deeper unroll.

Links: [[act4-riscv-arch-test-setup]] (the project's OTHER external-tool
integration, same "config lives in the repo, framework lives external"
pattern) [[known-gap-mstatus-fs-warl]] (the real CSR bugs that motivated
wanting formal verification in the first place)
