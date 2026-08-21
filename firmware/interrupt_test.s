    .section .text
    .globl main

# Real-toolchain-assembled end-to-end machine-timer-interrupt test
# (Milestone 6) -- the interrupt/CLINT sibling of priv_test.s/csr_test.s/
# m_test.s, run through the REAL soc.sv topology (core+decoder+cache+
# sram+uart+clint), not a hand-packed core-only harness -- see
# testbench/soc_interrupt_tb.sv for the loading convention (crt0.hex then
# a #1-delayed readmemh override, exactly priv_toolchain_tb.sv's own
# idiom).
#
# Control flow:
#   1. Point mtvec at m_trap_handler.
#   2. mie.MTIE = 1 (bit 7).
#   3. Program the REAL CLINT's mtimecmp (CLINT_BASE+0x8 = 0x0001_0008)
#      to a real, small deadline (800 -- comfortably past this program's
#      own setup instructions, given every fetch/load in this milestone's
#      real soc.sv topology is a genuine Wishbone transaction, but small
#      enough to keep the whole test fast).
#   4. mstatus.MIE = 1 -- arms the interrupt for real.
#   5. A bounded busy-loop polling the real CLINT's mtime (CLINT_BASE+0x0)
#      against the deadline -- NOT `wfi` (a documented, deliberate no-op
#      in this core, see core.sv's Scope note; a real WFI-based wait
#      would simply never advance). The loop's own bound (10000
#      iterations) is a safety net only -- the real machine-timer
#      interrupt is expected to preempt it long before that, at whatever
#      instruction boundary mtime first reaches the deadline.
#   6. m_trap_handler: marks s1=1 (proves the real interrupt fired,
#      through the real CLINT/decoder/core path, not just a synthetic
#      i_mtip poke), disarms the timer (mtimecmp <- all-ones) so MRET's
#      own MIE restoration doesn't immediately re-trigger the same,
#      still-pending condition, then mret's back to exactly where the
#      busy-loop was preempted (no mepc adjustment -- unlike a
#      synchronous trap, an async interrupt handler must NOT skip past
#      the interrupted instruction).
#   7. Back in the busy-loop, mtip is now deasserted -- the loop runs to
#      its own natural exit (mtime already >= deadline) or its bound,
#      either way falls through to `ret`, and crt0.s's own trailing
#      ebreak halts the core, exactly like every other firmware image in
#      this repo.
#
# s1 (marker) and s2 (loop-iteration count, left alive for post-halt
# sanity) are the only results the testbench needs -- same "keep results
# alive in callee-saved registers, confirm from outside" idiom every
# other toolchain-assembled testbench in this project already uses (no
# trap-based pass/fail signal exists for a toolchain-built program).
main:
    la      t0, m_trap_handler
    csrw    mtvec, t0

    li      t0, 128                  # mie.MTIE (bit 7)
    csrw    mie, t0

    li      a0, 0x10008              # CLINT_BASE+0x8 (mtimecmp)
    li      a1, 800                  # deadline
    sd      a1, 0(a0)

    li      t0, 8                    # mstatus.MIE (bit 3)
    csrw    mstatus, t0

    li      a0, 0x10000              # CLINT_BASE (mtime)
    li      s2, 0
busy_loop:
    ld      t1, 0(a0)                # t1 = mtime (real, uncacheable CLINT read)
    bge     t1, a1, busy_done        # not expected to be how this loop exits --
                                      #   the real interrupt should preempt first
    addi    s2, s2, 1
    li      t2, 10000
    blt     s2, t2, busy_loop
busy_done:

    ret

m_trap_handler:
    li      s1, 1                    # marker: the real timer interrupt fired
    li      t0, 0x10008              # CLINT_BASE+0x8 (mtimecmp)
    li      t1, -1                   # all-ones -- disarms mtip.MTIP so MRET's
                                      #   own MIE restoration can't immediately
                                      #   re-trigger the same pending condition
    sd      t1, 0(t0)
    mret
