    .section .text
    .globl main

# Real-toolchain-encoded M-extension (RV64M, integer multiply/divide)
# verification program (Pillar C of the M-extension verification-
# strengthening plan) -- the multiply/divide sibling of csr_test.s.
# Exercises all 13 real M-extension mnemonics (mul/mulh/mulhsu/mulhu/
# mulw, div/divu/rem/remu, divw/divuw/remw/remuw) through the real
# riscv64-unknown-elf-as assembler, as opposed to testbench/core_m_ext_tb.sv's
# hand-packed instruction encodings.
#
# This core has no trap/branch-to-fail mechanism (ECALL is a no-op), so
# exactly like csr_test.s, every instruction's result is kept alive in a
# distinct register and all 13 are checked from outside, by the
# testbench, once the program halts. There are only 12 standard
# callee-saved "s" registers (s0/fp, s1-s11) and this program needs 13
# live results, so the 13th (REMUW) is kept in t3 instead -- safe here
# because main() never calls another function after computing it, so
# nothing in this program or in crt0.s's trailing ebreak sequence can
# clobber it before the testbench reads it out of the register file.
# s0 doubles as a plain result register too: this program never needs a
# frame pointer (no stack frames, no locals spilled to memory).
#
# Operand pairs are deliberately the exact same ones already hand-derived
# and hardware-proven in testbench/core_m_ext_tb.sv (see that file's
# inline memory-layout comment for the full derivation of each expected
# result) -- reusing already-verified values here removes any risk of a
# fresh hand-derivation mistake in *this* file, and means a mismatch
# between this program's results and core_m_ext_tb.sv's already-proven
# results points squarely at either the real assembler's encoding or
# this core's fetch/decode of a real-toolchain-built image, not at the
# underlying arithmetic (already covered by design/alu_tb.sv,
# design/divider_tb.sv, and core_m_ext_tb.sv itself).
#
# ra/sp/gp/tp are never touched here, so `ret` falls back correctly into
# crt0.s's trailing ebreak, halting the core the same way every other
# firmware image in this repo does.
main:
    # ---- MUL: -1 * 2 = -2 ----
    li      t0, -1
    li      t1, 2
    mul     s1, t0, t1              # s1  = 0xFFFFFFFFFFFFFFFE

    # ---- MULH: high 64 bits of (INT64_MIN * 2) ----
    li      t0, 1
    slli    t0, t0, 63              # t0 = INT64_MIN (0x8000000000000000)
    li      t1, 2
    mulh    s2, t0, t1              # s2  = 0xFFFFFFFFFFFFFFFF

    # ---- MULHSU: high 64 bits of (-1 (signed) * 2^64-1 (unsigned)) ----
    li      t0, -1                  # t0 = -1, read as SIGNED by mulhsu's rs1
    li      t1, -1                  # t1 = 0xFFFFFFFFFFFFFFFF, read as UNSIGNED by mulhsu's rs2
    mulhsu  s3, t0, t1              # s3  = 0xFFFFFFFFFFFFFFFF

    # ---- MULHU: high 64 bits of (2^64-1 (unsigned) * 2^64-1 (unsigned)) ----
    mulhu   s4, t0, t1              # reuse t0/t1 (both read as UNSIGNED this time): s4  = 0xFFFFFFFFFFFFFFFE

    # ---- MULW: low 32 bits of (0xFFFFFFFF * 2), sign-extended ----
    li      t0, -1
    slli    t0, t0, 32
    srli    t0, t0, 32              # t0 = 0x00000000FFFFFFFF
    li      t1, 2
    mulw    s5, t0, t1              # s5  = 0xFFFFFFFFFFFFFFFE

    # ---- DIV: -100 / 7, rounds toward zero ----
    li      t0, -100
    li      t1, 7
    div     s6, t0, t1              # s6  = -14

    # ---- DIVU: 2^64-1 / 3, unsigned ----
    li      t0, -1                  # t0 = 0xFFFFFFFFFFFFFFFF, read as UNSIGNED by divu
    li      t1, 3
    divu    s7, t0, t1              # s7  = 0x5555555555555555

    # ---- REM: -100 rem 7 ----
    li      t0, -100
    li      t1, 7
    rem     s8, t0, t1              # s8  = -2

    # ---- REMU: 100 rem 7, unsigned ----
    li      t0, 100
    li      t1, 7
    remu    s9, t0, t1              # s9  = 2

    # ---- DIVW: low 32 bits of (INT32_MIN / 2), sign-extended ----
    li      t0, 1
    slli    t0, t0, 31              # t0 (low 32 bits) = 0x80000000 = INT32_MIN
    li      t1, 2
    divw    s10, t0, t1             # s10 = 0xFFFFFFFFC0000000

    # ---- DIVUW: low 32 bits of (0xFFFFFFFF / 3), unsigned, sign-extended ----
    li      t0, -1
    slli    t0, t0, 32
    srli    t0, t0, 32              # t0 = 0x00000000FFFFFFFF
    li      t1, 3
    divuw   s11, t0, t1             # s11 = 0x0000000055555555

    # ---- REMW: low 32 bits of (-2147483643 rem 2), sign-extended ----
    li      t0, 1
    slli    t0, t0, 31
    addi    t0, t0, 5               # t0 (low 32 bits) = 0x80000005 = -2147483643
    li      t1, 2
    remw    s0, t0, t1              # s0  = 0xFFFFFFFFFFFFFFFF (-1) -- 13 results, 12 "s" registers: s0 doubles up here

    # ---- REMUW: low 32 bits of (0xFFFFFFFE rem 3), unsigned, sign-extended ----
    li      t0, -1
    slli    t0, t0, 32
    srli    t0, t0, 32
    addi    t0, t0, -1              # t0 = 0x00000000FFFFFFFE
    li      t1, 3
    remuw   t3, t0, t1              # t3  = 2 -- 13th result, kept in t3 since s0-s11 are all already spoken for

    ret
