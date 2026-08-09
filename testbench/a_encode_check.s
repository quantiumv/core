# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
#
# Assembler-only fixture for the A-extension encoder cross-check. Never
# assembled into a firmware image and never executed by the core --
# testbench/a_encode_crosscheck_tb.sv only $readmemh's the resulting
# a_encode_check.hex and compares each word against
# testbench/riscv_encode.sv's encode_amo(), so there's no _start/ebreak and
# no linking (see testbench/Makefile).
#
# All 22 A-extension mnemonics appear exactly once, each on a distinct
# register pair/triple chosen to sweep rd/rs1/rs2 across low (x1-x3), mid
# (x16-x22), and max (x28-x31) indices plus x0, mirroring
# m_encode_check.s's own low/mid/max spread. LR's rs2 field is always
# implicitly 0 (no operand) -- confirms the real assembler also always
# emits rs2=00000 for LR, matching this project's own decoder mask not
# needing to (and correctly not) constrain that field.
#
# A SEPARATE final group deliberately sweeps aq/rl on representative
# instructions (lr.w.aq, sc.d.rl, amoadd.w.aqrl, amoxor.d with neither) --
# proving the real assembler's aq/rl bit encoding matches this project's
# own decoder mask, which accepts (decodes but ignores) any aq/rl value
# rather than constraining it, per the "no ordering hazard to guard on
# this core" design decision.
#
# Assembled with -march=rv64ima (plain rv64i rejects these mnemonics).

.text
lr.w      x1,  (x2)
lr.d      x31, (x30)
sc.w      x16, x17, (x18)
sc.d      x0,  x5,  (x6)
amoswap.w x7,  x0,  (x8)
amoswap.d x9,  x10, (x0)
amoadd.w  x11, x31, (x1)
amoadd.d  x30, x2,  (x17)
amoxor.w  x18, x29, (x3)
amoxor.d  x12, x16, (x31)
amoor.w   x19, x20, (x21)
amoor.d   x22, x22, (x22)
amoand.w  x28, x29, (x30)
amoand.d  x31, x0,  (x31)
amomin.w  x2,  x3,  (x1)
amomin.d  x17, x18, (x16)
amomax.w  x29, x30, (x31)
amomax.d  x20, x21, (x19)
amominu.w x23, x24, (x25)
amominu.d x26, x27, (x28)
amomaxu.w x1,  x31, (x0)
amomaxu.d x0,  x1,  (x31)

lr.w.aq       x4,  (x5)
sc.d.rl       x6,  x7,  (x8)
amoadd.w.aqrl x9,  x10, (x11)
amoxor.d      x12, x13, (x14)
