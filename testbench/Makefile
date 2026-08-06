# SPDX-License-Identifier: MIT

# Builds testbench/csr_encode_check.hex, the real-assembler-encoded golden
# fixture for riscv_encode_crosscheck_tb.sv (Pillar 2). Separate from
# firmware/Makefile -- this is a testbench fixture, not firmware; it never
# links (no crt0, no _start) since only the instructions' own relative
# encoding is under test, not a runnable program.

# -mno-relax: see firmware/Makefile's own comment -- irrelevant to CSR
#   encoding either way, kept for consistency with that file's ASFLAGS.
ASFLAGS = -march=rv64i_zicsr -mabi=lp64 -mno-relax

all:
	riscv64-unknown-elf-as $(ASFLAGS) csr_encode_check.s -o csr_encode_check.o
	# --verilog-data-width=4: one 32-bit instruction word per line, matching
	#   riscv_encode_crosscheck_tb.sv's logic [31:0] golden array. No linking
	#   needed (see header above) -- a bare unlinked .o objcopies cleanly for
	#   this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 csr_encode_check.o csr_encode_check.hex
