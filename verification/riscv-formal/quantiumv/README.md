# riscv-formal integration (started 2026-08-11, not yet passing)

Formal verification via [riscv-formal](https://github.com/YosysHQ/riscv-formal)
(Yosys + SymbiYosys + a SAT/BMC solver), proving ISA correctness exhaustively
against the spec rather than sampling it via directed/random simulation. This
is a genuinely different, stronger class of verification than everything else
in `verification/` and `testbench/` — see the session that started this for
the full reasoning.

## Status: toolchain fully working, elaboration blocked by two real Yosys-frontend gaps

**What works, confirmed end-to-end:**
- `design/core.sv` now carries a native, spec-shaped RVFI (RISC-V Formal
  Interface) output port list, gated entirely behind `` `ifdef RISCV_FORMAL ``
  (search core.sv for that guard) — **zero effect on any normal build**;
  confirmed via a full 38-testbench regression run with the change in place.
  Pure combinational taps off signals that already drive the real commit
  (`commit_now`, `reg_write_data`, `current_priv`, `mem_paddr`/`mem_sel`,
  etc.) — no new pipeline stage, matches RVFI's documented
  one-`rvfi_valid`-pulse-per-retired-instruction model directly, since
  `commit_now` already has exactly that shape (including for multi-cycle
  loads/stores/divides — they just take longer to *reach* that one cycle).
  First slice only: covers the base-ISA (`isa=rv64i`) check family, no CSR
  trace ports yet (`rvfi_csr_<name>_*`, needs adding per-CSR once base
  checks are green), and `rvfi_insn` feeds the C-expanded 32-bit
  `instruction` wire rather than a compressed instruction's raw 16-bit
  encoding (fine for `isa=rv64i`, needs its own tap before Zca checks).
- `wrapper.sv` (this dir) + `checks.cfg` (this dir): a real, working
  `genchecks.py` run against them generates all 56 expected check `.sby`
  files with zero errors (base RV64I insn/reg/pc_fwd/pc_bwd/unique/causal/
  cover/ill checks).
- `sby` (SymbiYosys) itself successfully drives Yosys through file-copying,
  script generation, and the actual `read -sv` elaboration step.

**Where it's currently blocked**: Yosys 0.61's Verilog-2005-based frontend
(even in `-sv` mode) has two confirmed, isolated-and-reproduced gaps against
this codebase's modern SystemVerilog style — both are legal SV that iverilog/
Verilator already handle correctly elsewhere in this project's own test
suite, so these are Yosys frontend limitations, not RTL bugs:
1. **Nested macro token-pasting** — `decoder.sv`'s
   `` `define IS_INSTR(instr, name) ((instr & `INSTR_MASK_``name) == `INSTR_``name) ``
   (the `` ` `` `` `` `` token-paste operator building a NEW macro name from an
   argument, then expanding *that*) silently fails in Yosys: the
   token-pasted macro reads as "undefined" even though the underlying file
   defining it was `` `include ``d correctly. Reproduced in total isolation
   with a 2-line repro (`` `define FOO_BAR ...; `define M(name) `FOO_``name ``)
   — confirmed Yosys-specific, iverilog handles the identical construct fine.
2. **`return {concat, expr};` inside an `automatic` function** —
   `design/c_expand.sv`'s small helper functions (`creg()`, `mk_r()`, etc.)
   use `return` with a concatenation literal; Yosys's frontend throws a raw
   `syntax error, unexpected '{'` on this shape specifically.

**Workaround attempted, partially working**: pre-expanding the whole design
through `iverilog -E` (which handles both constructs correctly) before
handing the flattened output to Yosys. This resolves gap #1 completely
(confirmed: `iverilog -E -I design -D RISCV_FORMAL -o combined.sv
design/alu.sv design/decoder.sv design/register_file.sv design/csr_file.sv
design/divider.sv design/c_expand.sv design/core.sv`, run as ONE combined
multi-file pass — doing it per-file breaks cross-file macro persistence,
since e.g. `core.sv` relies on `` `INSTR_CODE ``/etc. having already been
defined by `decoder.sv`'s own include chain earlier in the same compile).
Gap #2 (`c_expand.sv`'s `return {...}`) survives straight-through expansion
since it isn't a macro issue at all — needs its own fix, not yet attempted.

## Next steps (not yet done)

1. Decide how to handle gap #2: either patch a Yosys-only flattened copy of
   `c_expand.sv`'s handful of small functions to assign a return-name
   variable instead of using `return {...}` (Verilog-2005-style, avoiding
   touching the real, shipped `design/c_expand.sv` at all — this would live
   in the pre-expansion pipeline, not the real RTL), or check whether a
   newer Yosys release (0.61 is what's installed; check upstream) has
   already fixed this frontend gap for free before hand-patching anything.
2. Once elaboration succeeds for one check (`insn_add_ch0` is the natural
   first target — simplest possible instruction), get a genuine PASS/FAIL
   verdict from `sby`, not just successful elaboration.
3. Scale to the full `isa=rv64i` set (56 checks already generate cleanly),
   then `rv64im`, `rv64ima`, `rv64imac`, then add `` `RISCV_FORMAL_CSR_* ``
   trace ports to `core.sv` one CSR at a time for privilege-mode checks —
   `mstatus`/`mepc`/`mcause`/`sepc`/`scause` first, matching the CSRs this
   session's real MPRV/TSR bugs (see [[known-gap-mstatus-fs-warl]] in
   project memory) were found in, since that's exactly the class of bug
   formal verification is strongest against.

## Environment setup (WSL)

```
git clone --depth 1 https://github.com/YosysHQ/riscv-formal.git ~/riscv-formal
```

Yosys 0.61 and z3 were already present in this WSL environment. SymbiYosys
(`sby`) is a *separate* repo from Yosys itself (not a pip package, not
bundled) — a `sby` binary happened to already exist as a nix-store artifact
at `/nix/store/5f4l0kgczm4kn3r2rm09arby2g44fmj4-yosys-sby-0.62/bin/sby` in
this environment; it needs `PYTHONPATH` pointed at that same package's
`share/yosys/python3/` directory to run (its own sub-modules like
`sby_cmdline.py` live there) — a plain symlink onto `PATH` is NOT enough,
needs a real wrapper script exporting `PYTHONPATH` first. If that nix-store
path isn't present in a future environment, riscv-formal's own install docs
say: `git clone https://github.com/YosysHQ/sby && make install` against an
existing Yosys.

To (re-)generate checks and try running one, from `~/riscv-formal/cores/`:
```
mkdir -p quantiumv && cp <this-dir>/wrapper.sv <this-dir>/checks.cfg quantiumv/
cd quantiumv && python3 ../../checks/genchecks.py
cd checks && sby insn_add_ch0.sby
```

Links: [[act4-riscv-arch-test-setup]] (the project's OTHER external-tool
integration, same "config lives in the repo, framework lives external"
pattern) [[known-gap-mstatus-fs-warl]] (the real CSR bugs that motivated
wanting formal verification in the first place)
