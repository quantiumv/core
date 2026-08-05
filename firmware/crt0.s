    .section .text
    .globl _start

# Startup stub for the minimal SoC (design/soc.sv) -- sets up the two
# things any nontrivial C function needs before it's safe to call into
# C at all, then hands off to main() (firmware/hello.c). Previously this
# file WAS the whole program, hand-written to avoid depending on
# unverified section-placement behavior; now that firmware/link.ld
# exists and has been verified against a real build, the actual program
# logic lives in C instead. See git history for the assembly-only version.
#
#  - sp (x2): without this, the first push (e.g. a saved return address,
#    or any register a called function spills) writes to address 0 --
#    which happens to be this program's own first instruction. Set to
#    _stack_top (firmware/link.ld), the top of RAM, growing down.
#  - .bss zeroed: C assumes zero-initialized globals/statics.
#
# gp (x3, RISC-V's "global pointer") is deliberately NOT set up --
# firmware/Makefile passes -mno-relax to both the assembler and gcc,
# which disables the linker relaxation that would otherwise rewrite
# small-data accesses into gp-relative instructions. Without that
# relaxation, gp-relative addressing never gets emitted, so gp can stay
# uninitialized without breaking anything.
_start:
    la sp, _stack_top

    la t0, _bss_start
    la t1, _bss_end
zero_bss:
    bge t0, t1, zero_bss_done
    sb x0, 0(t0)
    addi t0, t0, 1
    j zero_bss
zero_bss_done:

    call main

    # main() has no OS to return to -- halt the same way every other
    # firmware image in this repo signals "done" (see core.sv's halt
    # latch). main()'s return value (a0) is deliberately not inspected;
    # there's nothing to report it to yet.
    ebreak
