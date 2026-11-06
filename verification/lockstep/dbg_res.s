/*
 * dbg_res.s -- straight-line program for the lockstep harness's debug script with action-0 triggers
 * (--dbg-features bit 256), made of LR / store / SC sequences. Same rules as dbg_exc.s: any instruction of the body
 * can be skipped by the trap handler, every body instruction is 4 bytes, the set-up lives below 0x40.
 *
 * What it is for: a store, SC or AMO that traps on an action-0 execute trigger still clears the LR/SC
 * reservation (the FSM's clear has no fault guard), so an SC after it must fail. The trigger has to land on the
 * store between an LR and its SC, which is rare in dbg_exc.s but every third instruction here.
 *
 * Build (see run_lockstep.sh's build_dbg_entries):
 *   riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax dbg_res.s -o dbg_res.o
 *   riscv64-unknown-elf-ld -T gen/link.ld -o dbg_res.elf dbg_res.o
 *   riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.misc \
 *       --verilog-data-width=8 dbg_res.elf dbg_res.hex
 */
.option norvc

.section .text.entry
.global _start
_start:
    la      x27, sandbox            # data base (8-byte aligned)
    la      x5, m_handler
    csrw    mtvec, x5
    li      x18, 0x5A5A
    li      x19, 3

    .balign 64                      # the body starts at 0x40 (the assembler pads code with nops)
    .rept 300
    lr.d    x30, (x27)
    sd      x30, 40(x27)            # a store between the LR and the SC: the SC fails, also when a trigger exception cut the store short
    sc.d    x31, x18, (x27)
    lr.w    x30, (x27)
    sw      x30, 48(x27)
    sc.w    x31, x18, (x27)
    lr.d    x30, (x27)
    amoadd.d x28, x19, (x27)        # an AMO between the LR and the SC
    sc.d    x31, x18, (x27)
    lr.d    x30, (x27)
    sb      x30, 57(x27)
    sc.d    x31, x18, (x27)
    lr.d    x30, (x27)
    sc.d    x31, x18, (x27)         # nothing in between: the SC succeeds
    addi    x12, x12, 1
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
