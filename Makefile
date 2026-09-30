# QuantiumV top-level developer entry points. Every target here shells
# out to a script under verification/ -- see each script's own header
# for what it actually does. All of them need the WSL toolchain
# (iverilog/vvp, riscv64-unknown-elf-gcc, Verilator, and openocd for
# `openocd-smoke`) -- run this Makefile from inside WSL bash, not from
# PowerShell.
#
# Part of the pipelining track's P3.0 infrastructure step -- see the
# plan at C:\Users\Potato\.claude\plans\
# research-the-c-extension-reflective-candle.md.

CORE ?= fsm

.PHONY: regress lint act openocd-smoke lockstep formal-sync

regress:
	verification/regress/run_regress.sh --core $(CORE)

lint:
	verification/regress/lint.sh --core $(CORE)

act:
	verification/riscv-arch-test/run_act_tests.sh

openocd-smoke:
	verification/openocd/run_m10_smoke_test.sh

# P3.4: REF-vs-REF self-proof over the whole corpus, zero bus delay (the
# safe default -- see lockstep_wb_delay.sv's own KNOWN GAP comment before
# passing LOCKSTEP_ARGS="--delay-max N" with N>0). Pass LOCKSTEP_ARGS for
# anything else run_lockstep.sh takes, e.g.
# `make lockstep LOCKSTEP_ARGS="--mode mutant --mutant 3"`.
lockstep:
	verification/lockstep/run_lockstep.sh --mode selfproof $(LOCKSTEP_ARGS)

# Not implemented yet -- syncs design/{pipe/,reference/} + wrapper.sv/
# checks.cfg into a riscv-formal checkout. The existing manual sync
# process (for today's single FSM core) is documented in
# verification/riscv-formal/quantiumv/README.md.
formal-sync:
	@echo "make formal-sync: not implemented yet for ref/pipe cores -- see" >&2
	@echo "verification/riscv-formal/quantiumv/README.md for the current" >&2
	@echo "manual FSM-only sync steps." >&2
	@exit 1
