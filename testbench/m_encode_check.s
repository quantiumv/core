# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
#
# Assembler-only fixture for Pillar D (automated M-extension encoder
# cross-check). Never assembled into a firmware image and never executed
# by the core -- testbench/m_encode_crosscheck_tb.sv only $readmemh's the
# resulting m_encode_check.hex and compares each word against
# testbench/riscv_encode.sv's encode_r(), so there's no _start/ebreak and
# no linking (see testbench/Makefile).
#
# All 13 M mnemonics appear exactly once, each on a distinct register
# triple chosen to sweep rd/rs1/rs2 across low (x1-x3), mid (x16-x22),
# and max (x28-x31) indices plus x0, mirroring csr_encode_check.s's own
# low/mid/max spread but extended to three register fields instead of
# two. Deliberately includes rd=x0 (mulhu), rs1=x0 (mulw), rs2=x0 (div),
# and rd==rs1==rs2 aliased to the same register (remw) -- corner cases a
# naive field-position bug could still slip through if every line used
# three distinct, "normal" registers.
#
# Assembled with -march=rv64im (plain rv64i rejects these mnemonics).

.text
mul    x1,  x2,  x3
mulh   x31, x30, x29
mulhsu x16, x17, x18
mulhu  x0,  x5,  x6
mulw   x7,  x0,  x8
div    x9,  x10, x0
divu   x11, x31, x1
rem    x30, x2,  x17
remu   x18, x29, x3
divw   x12, x16, x31
divuw  x19, x20, x21
remw   x22, x22, x22
remuw  x31, x0,  x31
