    .section .text
    .globl main

# Real-toolchain-assembled end-to-end UART-RX-through-PLIC test, the
# undelegated M-mode path (PMP+PLIC plan Milestone 6, the final
# milestone of that plan) -- the MEI/PLIC sibling of
# firmware/interrupt_test.s (which proves the same end-to-end shape for
# CLINT/MTI). Run through the REAL soc.sv topology (core+decoder+cache+
# sram+uart_tx+uart_rx+clint+plic) -- see
# testbench/soc_uart_plic_tb.sv for the loading convention.
#
# The triggering UART byte is injected by the TESTBENCH, not this
# firmware (real serial-line timing doesn't exist in this project, see
# uart_rx.sv's own header) -- via dut.uart_rx0.push_byte(), called once,
# early, before this program has any reason to touch RX_DATA/PLIC at
# all, so there's no race with the pop this program's own handler does
# far later.
#
# Control flow:
#   1. Point mtvec at m_trap_handler.
#   2. Configure PLIC for real, through the real decoder: priority1=1
#      (source 1, the only real source, reserved for UART RX),
#      enable_ctx0=1 (bit 1 of context 0's own enable word) --
#      threshold_ctx0 is left at its own reset default (0), already the
#      most permissive value.
#   3. mie.MEIE = 1 (bit 11).
#   4. mstatus.MIE = 1 -- arms the interrupt for real. By this point the
#      testbench's own byte push has already made pending_q real and
#      eip_ctx0 real (real spec-correct level, no polling needed) --
#      the interrupt is expected to preempt the very first eligible
#      instruction boundary, matching this core's own one-cycle-
#      deferred interrupt-taking design.
#   5. A bounded busy-loop (50 iterations, a safety net only -- the real
#      interrupt is expected to preempt it almost immediately. Unlike
#      firmware/interrupt_test.s's own busy-loop, this one has no
#      early-exit comparator condition -- its only exit is the bound
#      itself -- so even the SUCCESS case runs all 50 iterations after
#      resuming; kept deliberately small, not the same 10000-iteration
#      scale interrupt_test.s uses, so a real, cache-mediated soc.sv
#      pass through this loop stays fast).
#   6. m_trap_handler: claims (PLIC_BASE+0x200004, context 0's own
#      claim/complete register -- a real read there both returns
#      source 1's own ID AND atomically clears the gateway's pending
#      state), pops the real byte from UART RX_DATA (0x8010), completes
#      (writes the claimed ID back to the same claim/complete address),
#      marks s1=1 (proves the real interrupt fired end to end, through
#      the real UART/PLIC/decoder/core path, not a synthetic i_meip
#      poke), then mret's back to exactly where the busy-loop was
#      preempted.
#   7. Back in the busy-loop, the gateway is quiescent (claimed+
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

    li      t0, 0x400004            # PLIC priority, source 1 (PLIC_BASE+0x0, high32)
    li      t1, 1
    sw      t1, 0(t0)

    li      t0, 0x402000            # PLIC enable, context 0 (PLIC_BASE+0x2000, low32)
    li      t1, 2                   # bit 1 = source 1
    sw      t1, 0(t0)

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
    li      t0, 0x600004            # PLIC claim/complete, context 0 (PLIC_BASE+0x200004, high32)
    lw      s3, 0(t0)               # claim -- returns source 1's real ID, clears pending

    li      t0, 0x8010              # UART RX_DATA
    lw      s4, 0(t0)               # pop the real byte the testbench pushed

    li      t0, 0x600004
    sw      s3, 0(t0)               # complete (write back the claimed ID)

    li      s1, 1                   # marker: the real MEI fired end-to-end
    mret
