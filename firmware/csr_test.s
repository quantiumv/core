    .section .text
    .globl main

# Real-toolchain-encoded Zicsr verification program (Pillar 1 of the
# verification-strengthening plan) -- adapts the official riscv-tests
# rv64si/csr.S test cases 2-12 (upstream target: sscratch; this core has
# no S-mode, so the target here is its one plain read/write CSR,
# mscratch) to this core's calling convention. Upstream's TEST_CASE
# macro checks-and-branches-to-fail after every single instruction; this
# core has no trap/branch-to-fail mechanism to lean on (ECALL is a
# no-op), so instead every step's result is kept alive in a distinct
# callee-saved register (s1-s11) and all eleven are checked from outside,
# by the testbench, once the program halts.
#
# Three steps (s8/s9/s10) deliberately alias rd==rs1, e.g.
# "csrrw s8, mscratch, s8" -- the same register supplies the CSR's new
# value AND receives its old one back. That only comes out correct if
# the hardware reads rs1 before it overwrites rd; this is upstream's own
# rationale for including these forms at all.
#
# ra/sp/gp/tp are never touched here, so `ret` falls back correctly into
# crt0.s's trailing ebreak, halting the core the same way every other
# firmware image in this repo does.
main:
    csrwi   mscratch, 3            # mscratch = 3

    csrr    s1, mscratch           # s1  = 3          (old)
    csrrci  s2, mscratch, 1        # s2  = 3          (old); mscratch = 3 & ~1        = 2
    csrrsi  s3, mscratch, 4        # s3  = 2          (old); mscratch = 2 | 4         = 6
    csrrwi  s4, mscratch, 2        # s4  = 6          (old); mscratch = 2

    li      t0, 0xbad1dea
    csrrw   s5, mscratch, t0       # s5  = 2          (old); mscratch = 0xbad1dea

    li      t0, 0x0001dea
    csrrc   s6, mscratch, t0       # s6  = 0xbad1dea  (old); mscratch = 0xbad1dea & ~0x0001dea = 0xbad0000

    li      t0, 0x000beef
    csrrs   s7, mscratch, t0       # s7  = 0xbad0000  (old); mscratch = 0xbad0000 | 0x000beef  = 0xbadbeef

    # rd==rs1 aliasing: rs1 must be read before rd is overwritten, or
    # these come out wrong.
    li      s8, 0xbad1dea
    csrrw   s8, mscratch, s8       # s8  = 0xbadbeef  (old); mscratch = 0xbad1dea

    li      s9, 0x0001dea
    csrrc   s9, mscratch, s9       # s9  = 0xbad1dea  (old); mscratch = 0xbad1dea & ~0x0001dea = 0xbad0000

    li      s10, 0x000beef
    csrrs   s10, mscratch, s10     # s10 = 0xbad0000  (old); mscratch = 0xbad0000 | 0x000beef  = 0xbadbeef

    csrr    s11, mscratch          # s11 = 0xbadbeef  (final mscratch value)

    ret
