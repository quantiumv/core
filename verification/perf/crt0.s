    .section .text
    .globl _start

# Startup stub for the P3.5 CPI-baseline kernels -- identical pattern to
# firmware/crt0.s (see that file's own header for the sp/.bss rationale
# and why gp is deliberately left uninitialized under -mno-relax). The
# one difference: main()'s return doesn't matter any more than it does
# there, but by the time we reach ebreak here, main() has already
# written its own measured cycle/instret deltas to _perf_result (see
# perf.h) -- ebreak just signals "done" to perf_tb.sv the same way every
# other core-instantiating testbench in this repo already detects it
# (testbench/halt_wait.sv's trap_taken && is_ebreak convention).
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
    ebreak
