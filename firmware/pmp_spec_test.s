/*
 * pmp_spec_test.s -- errata E4-E8 (found by the ACT refresh that declared PMP and Sv39), on the running core:
 *   E7  pmpcfg1, pmpcfg3-15 and pmpaddr16-63 do not exist (illegal); pmpcfg2 and pmpaddr4-15 read 0
 *   E4  mtvec/stvec MODE is WARL {0, 1}: a write of 2 or 3 keeps the old mode; MODE 1 vectors interrupts to
 *       BASE + 4 * cause (M: MTI, S: a delegated SEI)
 *   E5  PMP: an access that only partly overlaps the lowest matching region fails, in M mode too
 *   E6  PMP on a fetch checks each 2-byte parcel of the instruction; a fault on the second parcel has
 *       mtval = pc + 2
 *   E8  mcounteren/scounteren keep CY, TM and IR (bits 2:0) only
 * Each check stores (actual, expected) at RES + 8 + 16 * i; RES itself gets the number of checks at the end.
 * testbench/core_pmp_spec_tb.sv compares the pairs and the count. The testbench drives i_mtip while the word
 * at MAGIC is 1 and i_seip while it is 2.
 *
 * Traps go to mtrap (the vector table's entry 0): it records mcause, mepc and mtval at LT, counts the trap and
 * returns to M mode at s11. t4-t6 belong to the handlers.
 */
    .equ RES,   0x6000
    .equ LT,    0x6F00          # +0 cause, +8 epc, +16 tval, +24 count, +32 M vector mark, +40 S vector mark
    .equ MAGIC, 0x6F80

    .macro CHECK act, exp
    sd      \act, 0(s0)
    sd      \exp, 8(s0)
    addi    s0, s0, 16
    .endm
    .macro CLEAR_LT
    li      t5, LT
    sd      x0, 0(t5)
    sd      x0, 8(t5)
    sd      x0, 16(t5)
    sd      x0, 24(t5)
    .endm
    # an S-mode run of the code at \target: traps come back at the next label 1
    .macro RUN_S target
    la      s11, 1f
    la      a5, \target
    csrw    mepc, a5
    li      a5, 0x1800
    csrc    mstatus, a5
    li      a5, 0x0800          # MPP = S
    csrs    mstatus, a5
    mret
1:
    .endm

    .section .text
    .globl main
main:
    li      s0, RES + 8
    la      a1, vt
    csrw    mtvec, a1           # direct, base = the vector table (entry 0 is mtrap)
    li      t5, LT
    sd      x0, 32(t5)
    sd      x0, 40(t5)
    li      t6, MAGIC
    sd      x0, 0(t6)

    # ---------------- E7: the PMP CSRs that do not exist ----------------
    CLEAR_LT
    la      s11, 1f
    csrr    a0, 0x3a1           # pmpcfg1
1:  ld      a2, 0(t5)
    li      a3, 2
    CHECK   a2, a3              # 1: pmpcfg1 is illegal
    CLEAR_LT
    li      a0, -1
    la      s11, 1f
    csrr    a0, 0x3a2           # pmpcfg2: exists, reads 0
1:  ld      a2, 24(t5)
    CHECK   a2, x0              # 2: no trap
    CHECK   a0, x0              # 3: reads 0
    CLEAR_LT
    la      s11, 1f
    csrr    a0, 0x3c0           # pmpaddr16
1:  ld      a2, 0(t5)
    CHECK   a2, a3              # 4: pmpaddr16 is illegal
    CLEAR_LT
    li      a0, -1
    la      s11, 1f
    csrr    a0, 0x3bf           # pmpaddr15: exists, reads 0
1:  ld      a2, 24(t5)
    CHECK   a2, x0              # 5
    CHECK   a0, x0              # 6
    CLEAR_LT
    la      s11, 1f
    csrw    0x3ae, a0           # pmpcfg14
1:  ld      a2, 0(t5)
    CHECK   a2, a3              # 7: illegal

    # ---------------- E4: xtvec MODE ----------------
    la      a1, vt
    ori     a2, a1, 3
    csrw    mtvec, a2
    csrr    a4, mtvec
    CHECK   a4, a1              # 8: MODE 3 keeps mode 0, takes the base
    ori     a2, a1, 1
    csrw    mtvec, a2
    csrr    a4, mtvec
    CHECK   a4, a2              # 9: MODE 1 is legal
    ori     a2, a1, 2
    csrw    mtvec, a2
    csrr    a4, mtvec
    ori     a2, a1, 1
    CHECK   a4, a2              # 10: MODE 2 keeps mode 1
    csrw    mtvec, a1
    la      a1, st
    ori     a2, a1, 3
    csrw    stvec, a2
    csrr    a4, stvec
    CHECK   a4, a1              # 11
    ori     a2, a1, 1
    csrw    stvec, a2
    csrr    a4, stvec
    CHECK   a4, a2              # 12
    ori     a2, a1, 2
    csrw    stvec, a2
    csrr    a4, stvec
    ori     a2, a1, 1
    CHECK   a4, a2              # 13
    csrw    stvec, a1

    # ---------------- E5: a partial overlap fails, in M mode too ----------------
    li      a0, 0x5004 >> 2
    csrw    pmpaddr0, a0
    li      a0, 0x17            # NA4, RWX, unlocked: [0x5004, 0x5007]
    csrw    pmpcfg0, a0
    li      a0, 0x5000
    CLEAR_LT
    la      s11, 1f
    sd      x0, 0(a0)           # [0x5000, 0x5007]: partly in the region
1:  ld      a2, 0(t5)
    li      a3, 7
    CHECK   a2, a3              # 14: store access fault
    ld      a2, 16(t5)
    CHECK   a2, a0              # 15: mtval = the address
    CLEAR_LT
    la      s11, 1f
    ld      a4, 0(a0)
1:  ld      a2, 0(t5)
    li      a3, 5
    CHECK   a2, a3              # 16: load access fault
    CLEAR_LT
    la      s11, 1f
    sw      x0, 4(a0)           # all in the region: M, unlocked
    sd      x0, 8(a0)           # in no region: M
1:  ld      a2, 24(t5)
    CHECK   a2, x0              # 17: neither traps
    csrw    pmpcfg0, x0

    # ---------------- E6: fetch PMP per parcel (S mode, unlocked regions) ----------------
    li      a0, 0xfff           # region 3: NAPOT [0, 0x8000), RWX
    csrw    pmpaddr3, a0
    li      a6, 0x1f000000 | (0x11 << 8)    # region 1: NA4, R only (no X); region 3 as above
    # 18-20: a 32-bit instruction at dword + 2, its second parcel in the denied word dword + 4
    la      a0, f1
    addi    a0, a0, 4
    srli    a0, a0, 2
    csrw    pmpaddr1, a0
    csrw    pmpcfg0, a6
    CLEAR_LT
    RUN_S   f1_go
    ld      a2, 0(t5)
    li      a3, 1
    CHECK   a2, a3              # 18: instruction access fault
    ld      a2, 8(t5)
    la      a4, f1_go
    CHECK   a2, a4              # 19: mepc = its pc
    ld      a2, 16(t5)
    addi    a4, a4, 2
    CHECK   a2, a4              # 20: mtval = pc + 2
    # 21-23: a 32-bit instruction at dword + 6, its second parcel in the next dword, denied
    la      a0, f2
    addi    a0, a0, 8
    srli    a0, a0, 2
    csrw    pmpaddr1, a0
    CLEAR_LT
    RUN_S   f2_go
    ld      a2, 0(t5)
    CHECK   a2, a3              # 21
    ld      a2, 8(t5)
    la      a4, f2_go
    CHECK   a2, a4              # 22
    ld      a2, 16(t5)
    addi    a4, a4, 2
    CHECK   a2, a4              # 23
    # 24-26: a 16-bit instruction right below the denied word runs; the next one, in it, faults
    la      a0, f3
    addi    a0, a0, 4
    srli    a0, a0, 2
    csrw    pmpaddr1, a0
    CLEAR_LT
    RUN_S   f3_go
    ld      a2, 0(t5)
    CHECK   a2, a3              # 24
    ld      a2, 8(t5)
    la      a4, f3_w
    CHECK   a2, a4              # 25: mepc = the word
    ld      a2, 16(t5)
    CHECK   a2, a4              # 26: mtval = the word
    # 27-28: a 32-bit instruction right below the denied word runs too
    la      a0, f4
    addi    a0, a0, 4
    srli    a0, a0, 2
    csrw    pmpaddr1, a0
    CLEAR_LT
    RUN_S   f4_go
    ld      a2, 0(t5)
    CHECK   a2, a3              # 27
    ld      a2, 8(t5)
    la      a4, f4_w
    CHECK   a2, a4              # 28

    # ---------------- E4: vectored interrupts ----------------
    li      a0, 0x1f000000      # region 3 alone, for the S-mode part
    csrw    pmpcfg0, a0
    # 29-30: M-mode MTI with mtvec MODE 1 goes to vt + 4 * 7
    la      a1, vt
    ori     a1, a1, 1
    csrw    mtvec, a1
    CLEAR_LT
    la      s11, 2f             # an MTI that went to entry 0 instead (or any trap) comes back after the loop
    li      a0, 0x80
    csrs    mie, a0
    li      t6, MAGIC
    li      a0, 1
    sd      a0, 0(t6)           # the testbench raises i_mtip
    csrsi   mstatus, 8
    li      t4, 20000
1:  ld      a2, 32(t5)
    bnez    a2, 2f
    addi    t4, t4, -1
    bnez    t4, 1b
2:  csrci   mstatus, 8
    li      a3, 0x77
    CHECK   a2, a3              # 29: the MTI entry ran
    ld      a2, 24(t5)
    CHECK   a2, x0              # 30: and nothing came through entry 0
    la      a1, vt
    csrw    mtvec, a1
    # 31-32: S-mode SEI, delegated, with stvec MODE 1 goes to st + 4 * 9
    li      a0, 0x200
    csrw    mideleg, a0
    csrs    mie, a0
    la      a1, st
    ori     a1, a1, 1
    csrw    stvec, a1
    li      a0, 2
    li      t6, MAGIC           # (the handlers use t6)
    sd      a0, 0(t6)           # the testbench raises i_seip
    csrsi   sstatus, 2          # SIE, for S mode
    CLEAR_LT
    RUN_S   s_wait
    ld      a2, 40(t5)
    li      a3, 0x99
    CHECK   a2, a3              # 31: the SEI entry ran
    ld      a2, 0(t5)
    li      a3, 9
    CHECK   a2, a3              # 32: and S came back with its ecall
    csrw    mideleg, x0

    # ---------------- E8: mcounteren/scounteren keep CY, TM and IR ----------------
    li      a0, -1
    li      a3, 7
    csrw    mcounteren, a0
    csrr    a2, mcounteren
    CHECK   a2, a3              # 33: all ones written, 0x7 read
    csrw    scounteren, a0
    csrr    a2, scounteren
    CHECK   a2, a3              # 34
    li      a0, -8
    csrw    mcounteren, a0
    csrr    a2, mcounteren
    CHECK   a2, x0              # 35: bits 63:3 written, 0 read
    csrw    scounteren, a0
    csrr    a2, scounteren
    CHECK   a2, x0              # 36
    li      a0, 5
    csrw    mcounteren, a0
    csrsi   mcounteren, 2
    csrr    a2, mcounteren
    CHECK   a2, a3              # 37: csrs on the kept bits
    csrw    scounteren, a0
    csrci   scounteren, 1
    csrr    a2, scounteren
    li      a3, 4
    CHECK   a2, a3              # 38: csrc on the kept bits
    csrw    mcounteren, x0
    csrw    scounteren, x0

    # ---------------- the end ----------------
    li      a0, RES + 8
    sub     a0, s0, a0
    srli    a0, a0, 4
    li      a1, RES
    sd      a0, 0(a1)
    ebreak

    # ---------------- S-mode code ----------------
    # f1: a 32-bit nop at dword + 2 (raw encodings, so nothing is compressed or moved)
    .balign 8
f1: .2byte  0x0001              # c.nop
f1_go:
    .4byte  0x00000013          # addi x0, x0, 0: second parcel at f1 + 4, denied
    .2byte  0x0001
    ecall                       # a core that ran the nop comes back here instead
    .balign 8
f2: .2byte  0x0001
    .2byte  0x0001
    .2byte  0x0001
f2_go:
    .4byte  0x00000013          # at f2 + 6: second parcel at f2 + 8, denied
    .2byte  0x0001
    ecall
    .balign 8
f3: .2byte  0x0001
f3_go:
    .2byte  0x0001              # c.nop at f3 + 2: runs
f3_w:
    .2byte  0x0001              # f3 + 4: the denied word
    .2byte  0x0001
    ecall
    .balign 8
f4:
f4_go:
    .4byte  0x00000013          # [f4, f4 + 3]: runs
f4_w:
    .4byte  0x00000013          # f4 + 4: the denied word
    ecall
    # waits for the vectored SEI (t5 = LT), then goes back to M
s_wait:
    li      t4, 20000
1:  ld      a2, 40(t5)
    bnez    a2, 2f
    addi    t4, t4, -1
    bnez    t4, 1b
2:  ecall

    # ---------------- M vector table: entry 0 takes every exception ----------------
    .balign 256
vt:
    j       mtrap               # 0
    .rept 6
    j       vbad                # 1-6
    .endr
    j       mti                 # 7: MTI
    .rept 8
    j       vbad                # 8-15
    .endr
mtrap:
    csrr    t6, mcause
    li      t5, LT
    sd      t6, 0(t5)
    csrr    t6, mepc
    sd      t6, 8(t5)
    csrr    t6, mtval
    sd      t6, 16(t5)
    ld      t6, 24(t5)
    addi    t6, t6, 1
    sd      t6, 24(t5)
    csrw    mie, x0             # interrupts are only for the two vector tests: a stray one must not come again
    li      t6, MAGIC
    sd      x0, 0(t6)           # and the testbench drops its pins
    li      t6, 0x1800          # back to M, at s11
    csrs    mstatus, t6
    csrw    mepc, s11
    mret
mti:
    li      t5, LT
    li      t6, 0x77
    sd      t6, 32(t5)
    li      t6, 0x80
    csrc    mie, t6             # i_mtip may still be high for a while
    li      t6, MAGIC
    sd      x0, 0(t6)           # the testbench drops i_mtip
    mret
vbad:
    li      t5, LT
    li      t6, 0xbad
    sd      t6, 32(t5)
    sd      t6, 40(t5)
    li      t6, 0x880           # MTIE, SEIE off
    csrc    mie, t6
    mret

    # ---------------- S vector table ----------------
    .balign 256
st:
    .rept 9
    j       sbad                # 0-8
    .endr
    j       sei                 # 9: SEI
    .rept 6
    j       sbad                # 10-15
    .endr
sei:
    li      t5, LT
    li      t6, 0x99
    sd      t6, 40(t5)
    li      t6, 0x200
    csrc    sie, t6
    li      t6, MAGIC
    sd      x0, 0(t6)           # the testbench drops i_seip
    sret
sbad:
    li      t5, LT
    li      t6, 0x5bad
    sd      t6, 40(t5)
    ecall
