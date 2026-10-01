/*
 * repro_irq_stall.s -- minimal real-interrupt-taking program for the
 * lockstep harness. Unlike gen/qvgen.py's own corpus (which never
 * enables mstatus.MIE), this actually enables real interrupts and spins
 * briefly, giving lockstep_irq.sv's injected i_mtip a real chance to be
 * taken, not just asserted-and-ignored. Wired into the standard tooling
 * as verification/lockstep/irq.list's one entry -- `run_lockstep.sh
 * --corpus irq --irq-mode 2` builds and runs it the way described
 * below, automatically.
 *
 * Originally written to reproduce a real harness deadlock (lockstep_tb.
 * sv's own MAGIC_DWORD-bug stall, long since fixed -- see lockstep_mmio
 * .sv's header) and now repurposed as the proof that QV_MUTANT==5
 * (interrupt sampled one retirement late) is actually caught -- see
 * irq.list's own header for the full mechanism and why that proof needs
 * +MAX_RETIRE, never +TOHOST_ADDR.
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
 *       +TIMEOUT=50000 +IRQ_MODE=2 +MAX_RETIRE=1000
 *
 * Expected: LOCKSTEP_RESULT: PASS against QV_MUTANT_B=0, FAIL (a real
 * final-state register mismatch, after a clean 1000-retirement RVFI
 * stream) against QV_MUTANT_B=5 -- both confirmed directly. Do NOT use
 * +TOHOST_ADDR here: this program's tohost write is real and correct,
 * but requiring BOTH sides to simultaneously show tohost!=0 races
 * against this program's own post-completion `halt: j halt` (which
 * keeps retiring, so lockstep_irq.sv keeps injecting fresh interrupts,
 * for as long as either side is still waiting on the other) -- against
 * a structurally slower mutant that race never resolves, growing the
 * retirement count without bound instead of ever reaching PASS or FAIL.
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
