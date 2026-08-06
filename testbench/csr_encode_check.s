# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
#
# Assembler-only fixture for Pillar 2 (automated encoder cross-check).
# Never assembled into a firmware image and never executed by the core --
# testbench/riscv_encode_crosscheck_tb.sv only $readmemh's the resulting
# csr_encode_check.hex and compares each word against
# testbench/riscv_encode.sv's encode_csr(), so there's no _start/ebreak
# and no linking (see testbench/Makefile).
#
# Sweeps rd/rs1 across low/mid/max register indices (1/2, 16/17, 30/31),
# uimm across 0/15/31, and CSR addresses across all 8 CSRs
# design/csr_file.sv backs plus two boundary/unmapped addresses (0x7C0,
# 0xFFF) -- deliberately not just the 8 addresses this core happens to
# back, so a bit-packing bug in the address field itself wouldn't be
# silently missed. All 6 Zicsr instruction forms appear at least once.
#
# Assembled with -march=rv64i_zicsr (plain rv64i rejects CSR mnemonics).

.text
csrrw  x1,  mscratch,  x2
csrrw  x31, mcycle,    x30
csrrs  x16, minstret,  x17
csrrs  x0,  misa,      x5
csrrc  x3,  mvendorid, x4
csrrc  x2,  0x7C0,     x1
csrrwi x1,  marchid,   0
csrrwi x31, mimpid,    31
csrrsi x16, mhartid,   15
csrrsi x0,  0xFFF,     0
csrrci x30, mscratch,  31
csrrci x17, 0x7C0,     15
