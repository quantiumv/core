/*
 * zicntr_test.s -- Zicntr on the running core (either build, QV_ZICNTR_EN): cycle, time and instret read mcycle,
 * the platform's mtime (core_zicntr_tb drives i_time with TIME) and minstret, the count before the reading
 * instruction. Below M a read needs the counter's mcounteren bit, and in U (and in the reserved privilege 2'b10,
 * which MRET can load) its scounteren bit as well; a write is illegal at every privilege (read-only CSRs).
 * Each check stores (actual, expected) at RES + 8 + 16 * i; RES itself gets the number of checks at the end.
 * testbench/core_zicntr_tb.sv compares the pairs and the count.
 *
 * Traps go to mtrap: it records mcause and mtval at LT, counts the trap and skips the instruction; an ECALL (from
 * any privilege below M) instead returns to M at s11. t4-t6 belong to the handler.
 */
    .option norvc
    .equ RES,   0x6000
    .equ LT,    0x6F00          # +0 cause, +8 tval, +24 count
    .equ TIME,  0x0123456789ABCDEF

    .macro CHECK act, exp
    sd      \act, 0(s0)
    sd      \exp, 8(s0)
    addi    s0, s0, 16
    .endm
    .macro CLEAR_LT
    li      t5, LT
    sd      x0, 0(t5)
    sd      x0, 8(t5)
    sd      x0, 24(t5)
    .endm
    # a run of the code at \target at the privilege MPP = \mpp; it ends with an ECALL, back in M at the next label 1
    .macro RUN mpp, target
    la      s11, 1f
    la      a5, \target
    csrw    mepc, a5
    li      a5, 0x1800
    csrc    mstatus, a5
    li      a5, (\mpp << 11)
    csrs    mstatus, a5
    mret
1:
    .endm
    # whether \reg is still -1 (its read trapped), against \exp
    .macro TRAPPED reg, exp
    addi    t0, \reg, 1
    seqz    t0, t0
    li      t1, \exp
    CHECK   t0, t1
    .endm
    # mcounteren = \mce, scounteren = \sce, then cycle, time and instret read at privilege \mpp by \code;
    # \c, \t, \i: 1 where that read must trap
    .macro CASE mpp, mce, sce, c, t, i, code=reads
    li      a5, \mce
    csrw    mcounteren, a5
    li      a5, \sce
    csrw    scounteren, a5
    CLEAR_LT
    RUN     \mpp, \code
    TRAPPED a2, \c
    TRAPPED a3, \t
    TRAPPED a4, \i
    .endm

    .section .text
    .globl main
main:
    li      s0, RES + 8
    la      a1, mtrap
    csrw    mtvec, a1

    # ---------------- M: every counter, no enable needed ----------------
    li      a2, -1
    li      a3, -1
    li      a4, -1
    csrr    a2, cycle
    csrr    a3, time
    csrr    a4, instret
    TRAPPED a2, 0               # 1
    TRAPPED a3, 0               # 2
    TRAPPED a4, 0               # 3
    li      t1, TIME
    CHECK   a3, t1              # 4: time is the platform's mtime
    csrr    a0, instret         # the count before it: 6 instructions later the count is 7 higher
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
    csrr    a1, instret
    sub     a1, a1, a0
    li      t1, 7
    CHECK   a1, t1              # 5
    csrr    a0, minstret
    csrr    a1, instret
    sub     a1, a1, a0
    li      t1, 1
    CHECK   a1, t1              # 6: instret is minstret
    csrr    a0, mcycle
    csrr    a1, cycle
    sub     a1, a1, a0
    sltiu   t0, a1, 64
    snez    t2, a1
    and     t0, t0, t2
    li      t1, 1
    CHECK   t0, t1              # 7: cycle is mcycle, a few cycles on
    CLEAR_LT
    csrw    time, x0            # read-only: illegal even in M
    li      t5, LT
    ld      a2, 24(t5)
    li      t1, 1
    CHECK   a2, t1              # 8: one trap
    ld      a2, 0(t5)
    li      t1, 2
    CHECK   a2, t1              # 9: illegal instruction

    # ---------------- S: mcounteren decides ----------------
    CASE    1, 0, 0, 1, 1, 1    # 10-12
    li      t5, LT
    ld      a2, 0(t5)
    li      t1, 2
    CHECK   a2, t1              # 13: illegal instruction
    ld      a2, 8(t5)
    li      t1, 0xc0202773      # csrr a4, instret: mtval is the instruction
    CHECK   a2, t1              # 14
    CASE    1, 7, 0, 0, 0, 0    # 15-17
    CASE    1, 2, 0, 1, 0, 1    # 18-20: TM only
    # ---------------- U: mcounteren and scounteren ----------------
    CASE    0, 7, 0, 1, 1, 1    # 21-23
    CASE    0, 7, 7, 0, 0, 0    # 24-26
    CASE    0, 5, 3, 0, 1, 1    # 27-29: only CY is set in both
    CASE    0, 0, 7, 1, 1, 1    # 30-32
    # ---------------- privilege 2'b10: as U ----------------
    CASE    2, 7, 0, 1, 1, 1    # 33-35
    CASE    2, 7, 7, 0, 0, 0    # 36-38
    CASE    2, 7, 0, 0, 0, 0, p2_self   # 39-41: it sets scounteren itself, then reads
    csrw    mcounteren, x0
    csrw    scounteren, x0

    # ---------------- the end ----------------
    li      a0, RES + 8
    sub     a0, s0, a0
    srli    a0, a0, 4
    li      a1, RES
    sd      a0, 0(a1)
    ebreak
1:  j       1b

    # ---------------- below M ----------------
reads:
    li      a2, -1
    li      a3, -1
    li      a4, -1
    csrr    a2, cycle
    csrr    a3, time
    csrr    a4, instret
    ecall
    # privilege 2'b10 may write scounteren (an S CSR): the next read sees it
p2_self:
    li      a2, -1
    li      a3, -1
    li      a4, -1
    csrwi   scounteren, 7
    csrr    a2, cycle
    csrr    a3, time
    csrr    a4, instret
    ecall

    .balign 4
mtrap:
    csrr    t6, mepc
    lwu     t5, 0(t6)
    li      t4, 0x00000073      # an ECALL: back to M at s11
    beq     t5, t4, 2f
    li      t5, LT
    csrr    t4, mcause
    sd      t4, 0(t5)
    csrr    t4, mtval
    sd      t4, 8(t5)
    ld      t4, 24(t5)
    addi    t4, t4, 1
    sd      t4, 24(t5)
    addi    t6, t6, 4
    csrw    mepc, t6
    mret
2:  li      t5, 0x1800
    csrs    mstatus, t5
    csrw    mepc, s11
    mret
