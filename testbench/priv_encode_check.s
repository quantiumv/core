# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
#
# Assembler-only fixture for Pillar D (automated privilege-instruction
# encoder cross-check). Never assembled into a firmware image and never
# executed by the core -- testbench/priv_encode_crosscheck_tb.sv only
# $readmemh's the resulting priv_encode_check.hex and compares each word
# against testbench/riscv_encode.sv's `INSTR_HEX_MRET/`INSTR_HEX_SRET/
# `INSTR_HEX_WFI (fixed patterns) and encode_r() with `FUNCT7_SFENCE_VMA
# (swept operands), so there's no _start/ebreak and no linking (see
# testbench/Makefile).
#
# mret/sret/wfi have zero operand fields -- each is a single fixed 32-bit
# pattern -- so they each appear exactly once. This pillar's real value
# for those three is confirming the hand-derived INSTR_HEX_MRET/SRET/WFI
# literals in testbench/riscv_encode.sv (independently hand-verified this
# session via bit-field decomposition, but never checked against a real
# assembler until now) actually match what riscv64-unknown-elf-as
# produces.
#
# sfence.vma takes real rs1/rs2 operands, so it's swept across a spread
# mirroring csr_encode_check.s's own low/mid/max register-index spread
# (1/2, 16/17, 30/31), plus the two asymmetric all-zero-on-one-side forms
# (rs1=x0 with rs2 nonzero, and vice versa) and the rs1=x0,rs2=x0 "flush
# everything" case the spec calls out as the common global-flush idiom --
# six sfence.vma lines total, so a bit-packing bug that only shows up when
# one field is zero and the other isn't wouldn't be silently missed.
#
# Assembled with -march=rv64i_zicsr: confirmed (this session, via a
# throwaway assemble-only check) that mret/sret/wfi/sfence.vma all assemble
# cleanly under -march=rv64i_zicsr, -march=rv64i, and even with no -march
# flag at all -- these are privileged-spec instructions, not gated behind
# any of the standard extension letters binutils' -march recognizes, so
# they're accepted regardless. -march=rv64i_zicsr is used here purely for
# consistency with csr_encode_check.s's own flag (these instructions read/
# write CSR-backed state like mstatus/sstatus, so the Zicsr-flavored flag
# is the closest thematic fit even though it isn't functionally required).

.text
mret
sret
wfi
sfence.vma x0,  x0
sfence.vma x1,  x2
sfence.vma x16, x17
sfence.vma x30, x31
sfence.vma x0,  x31
sfence.vma x31, x0
