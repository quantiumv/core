# QuantiumV top-level developer entry points. Every target here shells
# out to a script under verification/ -- see each script's own header
# for what it actually does. All of them need the WSL toolchain
# (iverilog/vvp, riscv64-unknown-elf-gcc, Verilator, and openocd for
# `openocd-smoke`) -- run this Makefile from inside WSL bash, not from
# PowerShell.
#
# CORE picks the build under test: pipe (the default) is the pipelined core,
# design/pipe/core.sv; ref is the frozen multi-cycle reference,
# verification/reference/ref_core.sv (the lockstep reference and white-box
# canary).

CORE ?= pipe

.PHONY: regress lint act openocd-smoke lockstep formal-sync run

# make run PROG="prog.c [more.c ...]" [CORE=pipe|ref] [TRACE=1] [CYCLES=N]
# -- build a bare-metal program and run it on the full SoC; see
# verification/run/README.md.
run:
	@test -n "$(PROG)" || { echo 'usage: make run PROG="prog.c ..." [CORE=pipe|ref] [TRACE=1] [CYCLES=N]' >&2; exit 2; }
	bash verification/run/run_prog.sh --core $(CORE) $(if $(TRACE),--trace) $(if $(CYCLES),--cycles $(CYCLES)) $(PROG)

regress:
	verification/regress/run_regress.sh --core $(CORE)

lint:
	verification/regress/lint.sh --core $(CORE)

act:
	CORE=$(CORE) verification/riscv-arch-test/run_act_tests.sh

openocd-smoke:
	CORE=$(CORE) verification/openocd/run_m10_smoke_test.sh

# Lockstep: the pipelined core on side B against the reference on side A,
# every retirement compared, zero bus delay (the safe default -- see
# lockstep_wb_delay.sv's own KNOWN GAP comment before passing
# LOCKSTEP_ARGS="--delay-max N" with N>0). Pass LOCKSTEP_ARGS for anything
# else run_lockstep.sh takes. The mutant and corruption self-tests of the
# harness itself put the reference on both sides:
# `make lockstep LOCKSTEP_DUT=ref LOCKSTEP_ARGS="--mode mutant --mutant 3"`.
LOCKSTEP_DUT ?= pipe
lockstep:
	verification/lockstep/run_lockstep.sh --mode selfproof --dut $(LOCKSTEP_DUT) $(LOCKSTEP_ARGS)

# riscv-formal: copy CORE=pipe|ref into ~/riscv-formal and generate its
# checks; run them with verification/riscv-formal/run_sweep.sh. See
# verification/riscv-formal/quantiumv_pipe/README.md.
formal-sync:
	bash verification/riscv-formal/sync_core.sh $(CORE)
