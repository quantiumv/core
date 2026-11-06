    .section .text
    .globl main

# Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration)
# acceptance-test program. Structured around ONE genuine "core is really
# running, catch it with haltreq" event (the spin loop below), after
# which every other test region is reached purely via debugger-controlled
# dpc redirects + resume -- the same trick testbench/jtag_dmi_e2e_tb.sv's
# own program already uses, extended with real software/hardware
# breakpoint sites and a single-step area. Real addresses are read back
# from `riscv64-unknown-elf-objdump -d m10_debug_test.elf` after building
# (firmware/Makefile's m10_debug_test target) and hardcoded into
# verification/openocd/m10_smoke.tcl as named constants -- not hand-
# predicted, since crt0.s's own la-expansion length isn't assumed.
main:
    addi x1, x0, 10
    addi x2, x0, 20
    addi x3, x0, 30
spin:
    j spin                      # initial haltreq always eventually catches this

single_step_area:
    addi x5, x0, 111             # single-step target #1 -- redirect dpc here, step once: expect x5==111
    addi x5, x5, 1               # single-step target #2 -- step again: expect x5==112
    addi x5, x5, 1               # available for a further step if ever needed
    j swbp_site

swbp_site:
    addi x6, x0, 0                # SOFTWARE BREAKPOINT site -- OpenOCD's own `bp` patches this word with ebreak
    addi x6, x0, 222               # reached only if resume-past-the-swbp worked: expect x6==222
    j hwbp_site

hwbp_site:
    addi x7, x0, 0                 # HARDWARE BREAKPOINT site -- M9's Trigger Module watches this address
    addi x7, x0, 333                # reached only if resume-past-the-hwbp worked: expect x7==333

    ebreak                          # final halt -- explicit, doesn't rely on main() returning to crt0.s
