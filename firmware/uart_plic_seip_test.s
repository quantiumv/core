    .section .text
    .globl main

# Real-toolchain-assembled end-to-end UART-RX-through-PLIC test, the
# DELEGATED S-mode path (PMP+PLIC plan Milestone 6) -- the real,
# Linux-realistic shape: PLIC's context 1 (S-mode), a genuinely-set
# mideleg[9] (not left at 0 the way MTI's own delegation stayed in
# firmware/interrupt_test.s), and MRET-bootstrapped M->S entry, same
# real pattern firmware/priv_test.s already established for that
# transition. See firmware/uart_plic_meip_test.s's own header for the
# shared design notes (testbench-injected byte, why PLIC is configured
# via real SW/LW through the real decoder) -- not re-derived here.
#
# Control flow:
#   1. Point mtvec at m_trap_handler (the undelegated fallback -- never
#      expected to actually run, but armed anyway so a real routing bug
#      fails LOUDLY as a wrong-handler execution, not a silent hang).
#   2. Configure PLIC: priority1=1, enable_ctx1=1 (context 1 = S-mode).
#   3. Arm UART IER bit 0 (RDA) -- REQUIRED as of the CLINT/UART
#      standards-compliance plan, same reasoning as
#      firmware/uart_plic_meip_test.s's own header/inline comment (not
#      re-derived here); privilege-mode-independent, so it makes no
#      difference that this arm happens from M-mode before the S-mode
#      bootstrap below.
#   4. mideleg bit 9 (SEI delegation) = 1 -- genuinely delegates, unlike
#      interrupt_test.s's own MTI case.
#   5. Point stvec at s_trap_handler.
#   6. sie.SEIE (bit 9) = 1 -- S-mode CSRs are always accessible from
#      S-mode regardless of delegation; this is armed before the MRET
#      below only because mstatus's own S-side fields (sstatus.SIE)
#      survive MRET untouched (same reasoning firmware/priv_test.s's
#      own S-mode bootstrap already established for SIE/SPIE/SPP), so
#      sie itself is safe to arm from M-mode beforehand too.
#   7. Bootstrap into S-mode via MRET: mstatus.MPP=S, mepc=s_entry.
#   8. s_entry: sstatus.SIE = 1 -- arms the interrupt for real, now
#      running genuinely in S-mode. The testbench's own byte push
#      already happened before this program started, so the interrupt
#      is expected to preempt almost immediately.
#   9. A bounded busy-loop (50 iterations, safety net only -- same
#      "no early-exit condition, kept deliberately small" reasoning
#      firmware/uart_plic_meip_test.s's own header explains in full).
#  10. s_trap_handler: claims via context 1's own claim/complete
#      register (PLIC_BASE+0x201004), pops the real byte (a byte-width
#      load -- see this file's own inline comment at that instruction),
#      completes, marks s1=1, sret's back to the busy-loop.
#  11. Falls through to `ret`, crt0.s's own trailing ebreak halts.
main:
    la      t0, m_trap_handler
    csrw    mtvec, t0

    li      t0, 0x04400004          # PLIC priority, source 1
    li      t1, 1
    sw      t1, 0(t0)

    li      t0, 0x04402080          # PLIC enable, context 1 (PLIC_BASE+0x2080, low32)
    li      t1, 2                   # bit 1 = source 1
    sw      t1, 0(t0)

    # UART IER bit 0 (RDA) -- see this file's own header and
    # firmware/uart_plic_meip_test.s's own inline comment for the full
    # reasoning (byte-addressed offset +1, real 16550 register packing).
    li      t0, 0x04008001          # UART_BASE+1 (IER)
    li      t1, 1                   # bit 0 = RDA interrupt enable
    sb      t1, 0(t0)

    li      t0, 512                 # mideleg.bit9 (SEI delegation)
    csrw    mideleg, t0

    la      t0, s_trap_handler
    csrw    stvec, t0

    li      t0, 512                 # sie.SEIE (bit 9)
    csrw    sie, t0

    li      t0, 2048                # mstatus.MPP = S (bits[12:11])
    csrw    mstatus, t0
    la      t0, s_entry
    csrw    mepc, t0
    mret

s_entry:
    li      t0, 2                   # sstatus.SIE (bit 1)
    csrw    sstatus, t0

    li      s2, 0
busy_loop:
    addi    s2, s2, 1
    li      t2, 50
    blt     s2, t2, busy_loop
busy_done:

    ret

# Never expected to actually execute -- see the header. A stray marker
# (s5) distinguishes "the undelegated handler wrongly ran" from "nothing
# ran at all" if this test ever fails.
m_trap_handler:
    li      s5, 1
    mret

s_trap_handler:
    li      t0, 0x04601004          # PLIC claim/complete, context 1 (PLIC_BASE+0x201004, high32)
    lw      s3, 0(t0)               # claim -- returns source 1's real ID, clears pending

    li      t0, 0x04008000          # UART_BASE+0 (RBR)
    lbu     s4, 0(t0)               # pop the real byte the testbench pushed --
                                     #   MUST be a byte-width load: RBR shares a
                                     #   dword with IER/IIR/LCR, and lbu (not lb)
                                     #   zero-extends (see firmware/uart_plic_meip_test.s's
                                     #   own inline comment for the full reasoning).

    li      t0, 0x04601004
    sw      s3, 0(t0)               # complete (write back the claimed ID)

    li      s1, 1                   # marker: the real SEI fired, routed to S
    sret
