# SPDX-License-Identifier: MIT

# Builds testbench/csr_encode_check.hex, testbench/m_encode_check.hex, and
# testbench/priv_encode_check.hex, the real-assembler-encoded golden
# fixtures for riscv_encode_crosscheck_tb.sv (Pillar 2),
# m_encode_crosscheck_tb.sv (Pillar D, M-extension milestone), and
# priv_encode_crosscheck_tb.sv (Pillar D, U/S/M privilege milestone).
# Separate from firmware/Makefile -- these are testbench fixtures, not
# firmware; none link (no crt0, no _start) since only the instructions'
# own relative encoding is under test, not a runnable program.

# -mno-relax: see firmware/Makefile's own comment -- irrelevant to
#   CSR/M/privilege encoding either way, kept for consistency with that
#   file's ASFLAGS.
ASFLAGS_ZICSR = -march=rv64i_zicsr -mabi=lp64 -mno-relax
ASFLAGS_M     = -march=rv64im -mabi=lp64 -mno-relax
# mret/sret/wfi/sfence.vma are privileged-spec instructions, not gated
#   behind any standard extension letter -march recognizes -- confirmed
#   assembling cleanly under rv64i_zicsr, rv64i, and no -march at all.
#   rv64i_zicsr reused here purely for thematic consistency with
#   csr_encode_check.s (these instructions all read/write CSR-backed
#   state), not because it's functionally required.
ASFLAGS_PRIV  = -march=rv64i_zicsr -mabi=lp64 -mno-relax
ASFLAGS_A     = -march=rv64ima -mabi=lp64 -mno-relax
ASFLAGS_C     = -march=rv64imac -mabi=lp64 -mno-relax

all: csr_encode_check.hex m_encode_check.hex priv_encode_check.hex a_encode_check.hex c_encode_check.hex

csr_encode_check.hex: csr_encode_check.s
	riscv64-unknown-elf-as $(ASFLAGS_ZICSR) csr_encode_check.s -o csr_encode_check.o
	# --verilog-data-width=4: one 32-bit instruction word per line, matching
	#   riscv_encode_crosscheck_tb.sv's logic [31:0] golden array. No linking
	#   needed (see header above) -- a bare unlinked .o objcopies cleanly for
	#   this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 csr_encode_check.o csr_encode_check.hex

m_encode_check.hex: m_encode_check.s
	riscv64-unknown-elf-as $(ASFLAGS_M) m_encode_check.s -o m_encode_check.o
	# --verilog-data-width=4: one 32-bit instruction word per line, matching
	#   m_encode_crosscheck_tb.sv's logic [31:0] golden array. No linking
	#   needed (see header above) -- a bare unlinked .o objcopies cleanly for
	#   this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 m_encode_check.o m_encode_check.hex

priv_encode_check.hex: priv_encode_check.s
	riscv64-unknown-elf-as $(ASFLAGS_PRIV) priv_encode_check.s -o priv_encode_check.o
	# --verilog-data-width=4: one 32-bit instruction word per line, matching
	#   priv_encode_crosscheck_tb.sv's logic [31:0] golden array. No linking
	#   needed (see header above) -- a bare unlinked .o objcopies cleanly for
	#   this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 priv_encode_check.o priv_encode_check.hex

a_encode_check.hex: a_encode_check.s
	riscv64-unknown-elf-as $(ASFLAGS_A) a_encode_check.s -o a_encode_check.o
	# --verilog-data-width=4: one 32-bit instruction word per line, matching
	#   a_encode_crosscheck_tb.sv's logic [31:0] golden array. No linking
	#   needed (see header above) -- a bare unlinked .o objcopies cleanly for
	#   this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 a_encode_check.o a_encode_check.hex

c_encode_check.hex: c_encode_check.s
	riscv64-unknown-elf-as $(ASFLAGS_C) c_encode_check.s -o c_encode_check.o
	# --verilog-data-width=2: one 16-bit compressed-instruction word per
	#   line, matching c_encode_crosscheck_tb.sv's logic [15:0] golden
	#   array -- narrower than every prior encode-check fixture's =4 since
	#   these are genuinely 16-bit RVC words, not 32-bit standard ones. No
	#   linking needed (see header above) -- a bare unlinked .o objcopies
	#   cleanly for this relative-encoding-only purpose.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=2 c_encode_check.o c_encode_check.hex
