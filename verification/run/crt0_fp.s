    .section .text
    .globl _start

# Startup stub for hard-float programs (run_prog.sh --float hard): the same as
# firmware/crt0.s (sp, .bss, main, then EBREAK ends the run), but it first
# turns the FPU on. mstatus.FS resets to Off, and every FP instruction is
# illegal until it is set; Initial is enough, the core marks it Dirty on the
# first FP write. fcsr starts at 0: round to nearest, no flags.
_start:
    li t0, 0x2000
    csrs mstatus, t0
    csrw fcsr, x0

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
    ebreak
