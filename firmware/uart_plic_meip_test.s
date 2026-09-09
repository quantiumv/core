    .section .text
    .globl main

# Real-toolchain-assembled end-to-end UART-RX-through-PLIC test, the
# undelegated M-mode path (PMP+PLIC plan Milestone 6) -- the MEI/PLIC
# sibling of firmware/interrupt_test.s (which proves the same end-to-end
# shape for CLINT/MTI). Run through the REAL soc.sv topology (core+
# decoder+cache+sram+uart16550+clint+plic; CLINT/UART standards-
# compliance plan Milestone 4 replaced the old uart_tx+uart_rx pair with
# one real design/uart16550.sv instance) -- see testbench/soc_uart_plic_tb.sv
# for the loading convention.
#
# The triggering UART byte is injected by the TESTBENCH, not this
# firmware (real serial-line timing doesn't exist in this project, see
# design/uart16550.sv's own header) -- via dut.uart0.push_byte(), called
# once, early, before this program has any reason to touch RBR/PLIC at
# all, so there's no race with the pop this program's own handler does
# far later.
#
# UART IER (offset +1) is now ARMED (bit 0, RDA) before mstatus.MIE --
# see step 3 below and this file's own inline comment at that
# instruction. Not present before the CLINT/UART standards-compliance
# plan: uart_rx.sv's own o_rx_irq used to be unconditional
# (`rx_count>0`), but design/uart16550.sv's own real RDA interrupt is
# IER-gated, matching a genuine 16550's real semantics -- every firmware
# program relying on the UART RX interrupt must now arm IER for real.
#
# Control flow:
#   1. Point mtvec at m_trap_handler.
#   2. Configure PLIC for real, through the real decoder: priority1=1
#      (source 1, the only real source, reserved for UART RX),
#      enable_ctx0=1 (bit 1 of context 0's own enable word) --
#      threshold_ctx0 is left at its own reset default (0), already the
#      most permissive value.
#   3. Arm UART IER bit 0 (RDA) -- REQUIRED as of the CLINT/UART
#      standards-compliance plan (see this file's own header); the real
#      interrupt line stays low without this, regardless of PLIC/mie/
#      mstatus configuration.
#   4. mie.MEIE = 1 (bit 11).
#   5. mstatus.MIE = 1 -- arms the interrupt for real. By this point the
#      testbench's own byte push has already made pending_q real and
#      eip_ctx0 real (real spec-correct level, no polling needed) --
#      the interrupt is expected to preempt the very first eligible
#      instruction boundary, matching this core's own one-cycle-
#      deferred interrupt-taking design.
#   6. A bounded busy-loop (50 iterations, a safety net only -- the real
#      interrupt is expected to preempt it almost immediately. Unlike
#      firmware/interrupt_test.s's own busy-loop, this one has no
#      early-exit comparator condition -- its only exit is the bound
#      itself -- so even the SUCCESS case runs all 50 iterations after
#      resuming; kept deliberately small, not the same 10000-iteration
#      scale interrupt_test.s uses, so a real, cache-mediated soc.sv
#      pass through this loop stays fast).
#   7. m_trap_handler: claims (PLIC_BASE+0x200004, context 0's own
#      claim/complete register -- a real read there both returns
#      source 1's own ID AND atomically clears the gateway's pending
#      state), pops the real byte from UART RBR (0x0400_8000, a byte-
#      width load -- see this file's own inline comment at that
#      instruction), completes
#      (writes the claimed ID back to the same claim/complete address),
#      marks s1=1 (proves the real interrupt fired end to end, through
#      the real UART/PLIC/decoder/core path, not a synthetic i_meip
#      poke), then mret's back to exactly where the busy-loop was
#      preempted.
#   8. Back in the busy-loop, the gateway is quiescent (claimed+
#      completed, level already dropped) -- the loop runs to its own
#      natural exit or bound, either way falls through to `ret`, and
#      crt0.s's own trailing ebreak halts the core.
#
# s1 (handler marker), s3 (claimed ID), s4 (the popped byte), s2
# (loop-iteration count) are the only results the testbench needs --
# same "keep results alive in callee-saved registers, confirm from
# outside" idiom every other toolchain-assembled testbench in this
# project already uses.
main:
    la      t0, m_trap_handler
    csrw    mtvec, t0

    li      t0, 0x04400004          # PLIC priority, source 1 (PLIC_BASE+0x0, high32)
    li      t1, 1
    sw      t1, 0(t0)

    li      t0, 0x04402000          # PLIC enable, context 0 (PLIC_BASE+0x2000, low32)
    li      t1, 2                   # bit 1 = source 1
    sw      t1, 0(t0)

    # UART IER (offset +1 of the real 16550 register file, byte-addressed
    # -- design/uart16550.sv packs all 8 registers into one dword, so a
    # real access must be byte-width) bit 0 = RDA interrupt enable. RDA
    # is now IER-gated (CLINT/UART standards-compliance plan Milestone
    # 3), unlike the old uart_rx.sv's unconditional o_rx_irq -- this
    # arm is REQUIRED, not just an address tweak, for the real interrupt
    # to ever fire. Safe to arm after the testbench's own push_byte
    # already queued the byte: o_irq's own RDA term is level-based off
    # rx_count/ier_q live, so it rises the instant this write commits.
    li      t0, 0x04008001          # UART_BASE+1 (IER)
    li      t1, 1                   # bit 0 = RDA interrupt enable
    sb      t1, 0(t0)

    li      t0, 2048                # mie.MEIE (bit 11)
    csrw    mie, t0

    li      t0, 8                   # mstatus.MIE (bit 3)
    csrw    mstatus, t0

    li      s2, 0
busy_loop:
    addi    s2, s2, 1
    li      t2, 50
    blt     s2, t2, busy_loop
busy_done:

    ret

m_trap_handler:
    li      t0, 0x04600004          # PLIC claim/complete, context 0 (PLIC_BASE+0x200004, high32)
    lw      s3, 0(t0)               # claim -- returns source 1's real ID, clears pending

    li      t0, 0x04008000          # UART_BASE+0 (RBR)
    lbu     s4, 0(t0)               # pop the real byte the testbench pushed --
                                     #   MUST be a byte-width load: RBR shares a
                                     #   dword with IER/IIR/LCR (design/uart16550.sv's
                                     #   own packed register file), so a wider `lw`
                                     #   would fold IER's own bits (now 1) into s4's
                                     #   own value. lbu (not lb) zero-extends, matching
                                     #   the old TX_DATA/RX_DATA's own zero-extension.

    li      t0, 0x04600004
    sw      s3, 0(t0)               # complete (write back the claimed ID)

    li      s1, 1                   # marker: the real MEI fired end-to-end
    mret
