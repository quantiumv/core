/*
 * repro_irq_stall.s -- minimal reproduction case for the interrupt-take
 * stall documented in lockstep_tb.sv's own header comment ("KNOWN GAP").
 * Unlike gen/qvgen.py's own corpus (which never enables mstatus.MIE, so
 * it never reaches this path), this actually enables real interrupts and
 * spins briefly, giving lockstep_irq.sv's injected i_mtip a real chance
 * to be taken, not just asserted-and-ignored.
 *
 * Build (matches gen/link.ld's memory map):
 *   riscv64-unknown-elf-as -march=rv64imac_zicsr -mabi=lp64 -mno-relax \
 *       repro_irq_stall.s -o repro_irq_stall.o
 *   riscv64-unknown-elf-ld -T gen/link.ld -o repro_irq_stall.elf repro_irq_stall.o
 *   riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers \
 *       -j .data.misc --verilog-data-width=8 repro_irq_stall.elf repro_irq_stall.hex
 *
 * Run (from the repo root, matching every other lockstep_tb.sv invocation):
 *   vvp <lockstep_tb.vvp> +HEXFILE=repro_irq_stall.hex \
 *       +TOHOST_ADDR=0000000000030000 +TIMEOUT=2000 +IRQ_MODE=2
 *
 * Expected (working) behavior: LOCKSTEP_RESULT: PASS, a handful of
 * retirements (well under a thousand). Actual (as of this comment):
 * silent exit(0), no LOCKSTEP_RESULT line at all -- both sides' rings
 * drain to empty a few retirements after the mstatus.MIE-enabling
 * csrw and nothing further is ever pushed.
 */
.section .text.entry
.global _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      t0, 128          # mie.MTIE (bit 7)
    csrw    mie, t0

    li      s1, 0            # trap count

    li      t0, 8            # mstatus.MIE (bit 3)
    csrw    mstatus, t0

    # spin long enough for lockstep_irq.sv to assert i_mtip at least once
    li      t1, 400
spin:
    addi    t1, t1, -1
    bnez    t1, spin

    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
halt:
    j       halt

.section .text.handlers
trap_handler:
    addi    s1, s1, 1
    li      t0, 0x0400F004
    li      t1, 1
    sw      t1, 0(t0)        # MAGIC_CLR
    csrr    t0, mepc
    addi    t0, t0, 0
    csrw    mepc, t0
    mret

.section .data.misc
.align 3
tohost:
    .zero 8
