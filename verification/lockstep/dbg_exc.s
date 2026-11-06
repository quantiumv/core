/*
 * dbg_exc.s -- straight-line program for the lockstep harness's debug script with action-0 triggers
 * (--dbg-features bit 256). An action-0 execute trigger is a breakpoint exception whose handler skips the
 * instruction, so the program has to be safe to have any instruction of its body skipped: no loop counters, no
 * pointers built in two steps, only forward branches, every body instruction 4 bytes (.option norvc). The set-up
 * (pointers, mtvec) lives below 0x40, the body from 0x40: the script arms an action-0 trigger only in
 * [0x40, 0x8000), never in the set-up and never in the trap handler.
 *
 * The body mixes what a trigger can land on, and what a trigger exception outranks: ALU ops, multiplies and
 * divides (including a divide by zero), loads and stores of every size, a misaligned load and store (causes 4 and
 * 6 ahead of which a trigger exception, cause 3 with tval = the pc, must rank), accesses that get a bus error
 * (causes 5 and 7), an LR / store / SC sequence (a store that traps still clears the reservation), an AMO, CSR
 * accesses, FENCE and FENCE.I, an illegal word (a trigger exception ranks below it), forward branches and jumps,
 * ECALL and EBREAK. The handler skips whatever trapped.
 * The body repeats 80 times (about 4500 retirements) so that most of the script's halts land in it rather than in the
 * spin loop at the end: a run of `j .`, where a skipped one lands on the next, which loops too.
 *
 * Build (as the other directed programs; see run_lockstep.sh's build_dbg_entries):
 *   riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax dbg_exc.s -o dbg_exc.o
 *   riscv64-unknown-elf-ld -T gen/link.ld -o dbg_exc.elf dbg_exc.o
 *   riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.misc \
 *       --verilog-data-width=8 dbg_exc.elf dbg_exc.hex
 */
.option norvc

.section .text.entry
.global _start
_start:
    la      x27, sandbox            # data base (8-byte aligned)
    li      x26, 0x08000000         # outside RAM and MMIO: the harness answers with a bus error
    la      x5, m_handler
    csrw    mtvec, x5
    li      x10, 0x1234
    li      x11, -77

    .balign 64                      # the body starts at 0x40 (the assembler pads code with nops)
    .rept 80
    addi    x12, x10, 5
    add     x13, x12, x11
    xor     x14, x13, x12
    slli    x15, x14, 3
    srli    x16, x15, 2
    sub     x17, x16, x10
    mul     x18, x17, x11
    div     x19, x18, x12
    rem     x20, x18, x13
    sd      x18, 0(x27)
    ld      x21, 0(x27)
    sw      x19, 16(x27)
    lw      x24, 16(x27)
    sb      x20, 25(x27)
    lbu     x25, 25(x27)
    lw      x28, 1(x27)             # misaligned load: cause 4
    sw      x28, 3(x27)             # misaligned store: cause 6
    ld      x29, 0(x26)             # bus error: cause 5
    sd      x29, 8(x26)             # bus error: cause 7
    lr.d    x30, (x27)
    sd      x30, 40(x27)            # a store between LR and SC clears the reservation
    sc.d    x31, x18, (x27)
    lr.d    x30, (x27)
    sw      x30, 48(x27)            # a second store between an LR and its SC: a trigger exception on it still clears the reservation
    sc.d    x31, x18, (x27)
    amoadd.d x28, x19, (x27)
    csrrw   x30, mscratch, x14
    csrrs   x31, mscratch, x0
    fence
    fence.i
    .word   0xFFFFFFFF              # illegal instruction: a trigger exception must rank below it (cause 2)
    lr.d    x30, (x27)
    amoadd.d x28, x19, (x27)        # an AMO between the LR and the SC clears the reservation, trapped or not
    sc.d    x31, x18, (x27)
    beq     x0, x0, 1f
    addi    x10, x10, 1             # skipped by the branch
1:  bne     x10, x0, 2f
    addi    x11, x11, 1
2:  jal     x0, 3f
    addi    x12, x12, 1
3:  ecall
    ebreak
    divu    x13, x12, x0            # divide by zero: no trap
    remu    x14, x12, x0
    lh      x15, 6(x27)
    sh      x15, 30(x27)
    addi    x10, x10, 7
    addi    x11, x11, -3
    .endr
    .rept 64
    j       .
    .endr

.section .text.handlers
.global m_handler
m_handler:
    csrr    x5, mepc
    addi    x5, x5, 4
    csrw    mepc, x5
    mret

.section .data.sandbox
sandbox:
    .zero   128
