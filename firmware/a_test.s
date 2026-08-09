    .section .text
    .globl main

# Real-toolchain-encoded A-extension (RV64A, atomics) verification program
# (Pillar C of the A-extension plan) -- the atomics sibling of m_test.s.
# Exercises all 22 real A-extension mnemonics (lr.w/d, sc.w/d, and the 9
# read-modify-write AMO ops each in .w/.d) through the real
# riscv64-unknown-elf-as assembler AND a real linked image with real
# `.data` memory, as opposed to testbench/core_a_ext_tb.sv's hand-packed
# instruction encodings operating on hand-picked SRAM addresses.
#
# Unlike m_test.s/csr_test.s (pure register traffic), this program
# genuinely needs memory to operate on -- firmware/link.ld's existing
# `.data` section provides it with zero linker changes; see the amo_data
# block below.
#
# This core has no trap/branch-to-fail mechanism, so exactly like
# m_test.s, every instruction's result is kept alive in a distinct
# register and all 22 are checked from outside, by the testbench, once
# the program halts. There are only 12 standard callee-saved "s"
# registers (s0/fp, s1-s11) and this program needs 22 live results, so
# the remaining 10 are kept in a0-a7 and t4/t5 -- safe here because
# main() never calls another function after computing them, so nothing
# in this program or in crt0.s's trailing ebreak sequence can clobber
# them before the testbench reads them out of the register file (same
# reasoning m_test.s's own header already documents for its 13th result
# in t3).
#
# Operand pairs are deliberately the exact same ones already hand-derived
# and hardware-proven in testbench/core_a_ext_tb.sv (see that file's
# inline memory-layout comment for the full derivation of each expected
# result) -- reusing already-verified values here removes any risk of a
# fresh hand-derivation mistake in *this* file, and means a mismatch
# between this program's results and core_a_ext_tb.sv's already-proven
# results points squarely at either the real assembler's encoding or
# this core's fetch/decode of a real-toolchain-built image, not at the
# underlying arithmetic (already covered by design/alu_tb.sv and
# core_a_ext_tb.sv itself). LR/SC reservation semantics beyond the basic
# success/no-reservation-failure pair (e.g. the reservation-clear-on-
# intervening-store regression) are already exhaustively covered by
# core_a_ext_tb.sv's white-box-adjacent test -- this file's job is
# narrower: prove the real toolchain + this core's fetch/decode agree.
#
# ra/sp/gp/tp are never touched here, so `ret` falls back correctly into
# crt0.s's trailing ebreak, halting the core the same way every other
# firmware image in this repo does.

    .section .data
    .align 3
amo_data:
    .dword 0   # 0:  LR.W scratch
    .dword 0   # 8:  LR.D scratch
    .dword 0   # 16: LR->SC success scratch
    .dword 0   # 24: SC-no-LR scratch
    .dword 0   # 32: AMOSWAP.W
    .dword 0   # 40: AMOSWAP.D
    .dword 0   # 48: AMOADD.W
    .dword 0   # 56: AMOADD.D
    .dword 0   # 64: AMOXOR.W
    .dword 0   # 72: AMOXOR.D
    .dword 0   # 80: AMOOR.W
    .dword 0   # 88: AMOOR.D
    .dword 0   # 96: AMOAND.W
    .dword 0   # 104: AMOAND.D
    .dword 0   # 112: AMOMIN.W
    .dword 0   # 120: AMOMIN.D
    .dword 0   # 128: AMOMAX.W
    .dword 0   # 136: AMOMAX.D
    .dword 0   # 144: AMOMINU.W
    .dword 0   # 152: AMOMINU.D
    .dword 0   # 160: AMOMAXU.W
    .dword 0   # 168: AMOMAXU.D

    .section .text
main:
    la      t2, amo_data

    # LR/SC/AMO have NO immediate-offset operand -- the address is rs1
    # alone (see firmware/link.ld's/design/core.sv's own "imm_1 IS the
    # address" note in the A-extension plan). Unlike the plain sw/sd
    # setup stores below (which DO take an immediate offset), each atomic
    # op's own address is computed into t3 via addi first.

    # ---- LR.W: preload low32=0x80000001 (sign bit set), confirm sign-extension ----
    li      t0, 0x80000001
    sw      t0, 0(t2)
    addi    t3, t2, 0
    lr.w    s1, (t3)                # s1 = 0xFFFFFFFF80000001

    # ---- LR.D ----
    li      t0, -16
    sd      t0, 8(t2)
    addi    t3, t2, 8
    lr.d    s2, (t3)                # s2 = -16

    # ---- LR->SC success ----
    li      t0, 0x55
    sd      t0, 16(t2)
    addi    t3, t2, 16
    lr.w    t1, (t3)                # sets reservation, not checked
    li      t1, 0x66
    sc.w    s3, t1, (t3)            # s3 = 0 (success)

    # ---- SC with no prior LR: fails ----
    li      t0, 0x77
    sd      t0, 24(t2)
    addi    t3, t2, 24
    li      t1, 0x88
    sc.w    s4, t1, (t3)            # s4 = 1 (failure, no reservation)

    # ---- AMOSWAP.W ----
    li      t0, 0x10
    sw      t0, 32(t2)
    addi    t3, t2, 32
    li      t1, 0x20
    amoswap.w s5, t1, (t3)          # s5 = 0x10 (old)

    # ---- AMOSWAP.D ----
    li      t0, 100
    sd      t0, 40(t2)
    addi    t3, t2, 40
    li      t1, 200
    amoswap.d s6, t1, (t3)          # s6 = 100 (old)

    # ---- AMOADD.W: INT32_MAX + 1, genuine 32-bit wraparound ----
    li      t0, 0x7FFFFFFF
    sw      t0, 48(t2)
    addi    t3, t2, 48
    li      t1, 1
    amoadd.w s7, t1, (t3)           # s7 = 0x7FFFFFFF (old)

    # ---- AMOADD.D ----
    li      t0, 5
    sd      t0, 56(t2)
    addi    t3, t2, 56
    li      t1, 3
    amoadd.d s8, t1, (t3)           # s8 = 5 (old)

    # ---- AMOXOR.W / AMOXOR.D: 6 xor 3 = 5 ----
    li      t0, 6
    sw      t0, 64(t2)
    addi    t3, t2, 64
    li      t1, 3
    amoxor.w s9, t1, (t3)           # s9 = 6 (old)
    li      t0, 6
    sd      t0, 72(t2)
    addi    t3, t2, 72
    li      t1, 3
    amoxor.d s10, t1, (t3)          # s10 = 6 (old)

    # ---- AMOOR.W / AMOOR.D: 6 or 3 = 7 ----
    li      t0, 6
    sw      t0, 80(t2)
    addi    t3, t2, 80
    li      t1, 3
    amoor.w s11, t1, (t3)           # s11 = 6 (old) -- last of the 12 "s" registers
    li      t0, 6
    sd      t0, 88(t2)
    addi    t3, t2, 88
    li      t1, 3
    amoor.d a0, t1, (t3)            # a0 = 6 (old)

    # ---- AMOAND.W / AMOAND.D: 6 and 3 = 2 ----
    li      t0, 6
    sw      t0, 96(t2)
    addi    t3, t2, 96
    li      t1, 3
    amoand.w a1, t1, (t3)           # a1 = 6 (old)
    li      t0, 6
    sd      t0, 104(t2)
    addi    t3, t2, 104
    li      t1, 3
    amoand.d a2, t1, (t3)           # a2 = 6 (old)

    # ---- AMOMIN.W: signed min(3, -5) = -5, a real change from old ----
    li      t0, 3
    sw      t0, 112(t2)
    addi    t3, t2, 112
    li      t1, -5
    amomin.w a3, t1, (t3)           # a3 = 3 (old)

    # ---- AMOMIN.D ----
    li      t0, 30
    sd      t0, 120(t2)
    addi    t3, t2, 120
    li      t1, -50
    amomin.d a4, t1, (t3)           # a4 = 30 (old)

    # ---- AMOMAX.W: signed max(-5, 3) = 3, a real change from old ----
    li      t0, -5
    sw      t0, 128(t2)
    addi    t3, t2, 128
    li      t1, 3
    amomax.w a5, t1, (t3)           # a5 = -5, sign-extended (old)

    # ---- AMOMAX.D ----
    li      t0, -50
    sd      t0, 136(t2)
    addi    t3, t2, 136
    li      t1, 30
    amomax.d a6, t1, (t3)           # a6 = -50 (old)

    # ---- AMOMINU.W: SAME -5-bit-pattern-vs-3 pair as AMOMIN.W, unsigned interpretation ----
    li      t0, -5
    sw      t0, 144(t2)
    addi    t3, t2, 144
    li      t1, 3
    amominu.w a7, t1, (t3)          # a7 = -5, sign-extended on read (old) -- last of a0-a7

    # ---- AMOMINU.D ----
    li      t0, -50
    sd      t0, 152(t2)
    addi    t3, t2, 152
    li      t1, 30
    amominu.d t4, t1, (t3)          # t4 = -50 (old)

    # ---- AMOMAXU.W: SAME -5-bit-pattern-vs-3 pair as AMOMAX.W, unsigned interpretation ----
    li      t0, 3
    sw      t0, 160(t2)
    addi    t3, t2, 160
    li      t1, -5
    amomaxu.w t5, t1, (t3)          # t5 = 3 (old)

    # ---- AMOMAXU.D ----
    li      t0, 30
    sd      t0, 168(t2)
    addi    t3, t2, 168
    li      t1, -50
    amomaxu.d t6, t1, (t3)          # t6 = 30 (old) -- 22nd and final result

    ret
