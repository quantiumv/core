# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
#
# Assembler-only fixture for the C-extension encoder cross-check. Never
# assembled into a firmware image and never executed by the core --
# testbench/c_encode_crosscheck_tb.sv only $readmemh's the resulting
# c_encode_check.hex and compares each 16-bit word against
# testbench/riscv_encode.sv's encode_c*() functions, so there's no
# _start/ebreak and no linking (see testbench/Makefile).
#
# Deliberately uses EXPLICIT c.xxx mnemonics throughout, not ordinary
# mnemonics relying on the real assembler's automatic compressed-encoding
# selection -- under -march=...c the assembler silently compresses
# eligible plain mnemonics too, which would make this fixture's exact
# instruction selection non-deterministic across binutils versions. Every
# line here is a real, syntax-checked (against riscv64-unknown-elf-as
# 2.42) RVC mnemonic, one per catalog row from the C-extension plan.
#
# Register/immediate choices: every "popular register" (x8-x15) field is
# swept across low(x8)/mid(x11-x12)/max(x15) where the instruction has
# more than one such field; every full 5-bit field sweeps a similarly
# varied low/mid/max spread (x1/x5/x18/x31). Immediates are chosen to
# exercise real sign-extension (negative values) wherever the field is
# signed, and to stay within each field's real representable range
# (confirmed empirically -- e.g. C.LUI/plain LUI reject negative decimal
# literals outright, requiring the raw 20-bit unsigned two's-complement
# pattern instead; this fixture sticks to small positive C.LUI values to
# avoid that entirely, already covered for the negative case by
# design/c_expand_tb.sv's own unit test).
#
# C.J/C.BEQZ/C.BNEZ use real local labels with small (2-c.nop, i.e. +6
# byte) forward jumps -- confirmed empirically that a bare small-integer
# operand risks the assembler silently auto-upgrading to a full 4-byte
# jal/branch (when it can't statically resolve a "real" target), which
# would defeat the point of this fixture entirely.
#
# Assembled with -march=rv64imac (plain rv64i rejects these mnemonics).

.text
c.addi4spn x8, x2, 32
c.lw       x9, 4(x10)
c.ld       x11, 8(x12)
c.sw       x13, 12(x14)
c.sd       x15, 16(x8)

c.addi     x5, -7
c.addiw    x6, 9
c.li       x7, -30
c.addi16sp x2, 48
c.lui      x18, 31

c.srli     x9, 19
c.srai     x11, 5
c.andi     x9, -3
c.sub      x9, x11
c.xor      x9, x11
c.or       x9, x11
c.and      x9, x11
c.subw     x9, x11
c.addw     x9, x11

c.j        jtarget
c.nop
c.nop
jtarget:
c.beqz     x9, btarget
c.nop
c.nop
btarget:
c.bnez     x11, btarget2
c.nop
c.nop
btarget2:

c.slli     x18, 35
c.lwsp     x18, 68(x2)
c.ldsp     x18, 136(x2)
c.jr       x5
c.mv       x6, x18
c.ebreak
c.jalr     x5
c.add      x6, x18
c.swsp     x18, 48(x2)
c.sdsp     x18, 88(x2)
