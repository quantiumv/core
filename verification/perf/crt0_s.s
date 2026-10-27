    .section .text
    .globl _start
    .weak _perf_mtrap
    .weak _perf_scratch

# Startup stub of the S-mode build (P10.0): runs in M, maps the 64 KB image
# 1:1 under Sv39 with 4 KiB leaves, and drops to main() in S.
#
#   - zeroes .bss and the three table pages of link_s.ld's .pt section (SRAM
#     outside the hex image is X, and a walk on a wrong path may read any
#     entry of them);
#   - root[0] -> L1, L1[0] -> L0, L0[i] = page i (V R W X A D, U = 0) for the
#     16 pages of RAM, so code, data, .perf_result and the stack are all mapped;
#   - satp = Sv39, root; mtvec = _perf_mtrap (the trap kernel's M handler, weak:
#     _perf_done when a kernel has none, so an unexpected trap ends the run);
#     mscratch = _perf_scratch (the handler's save area, weak);
#   - mstatus.MPP = S, mepc = main, ra = _perf_done: main's return lands on
#     the ebreak, which traps to M (medeleg is 0) and ends the run as in crt0.s.
# PMP needs nothing: pmpaddr0 resets to an all-RWX NAPOT region.
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

    la t0, _pt_base
    li t1, 3 * 4096
    add t1, t0, t1
zero_pt:
    bge t0, t1, zero_pt_done
    sd x0, 0(t0)
    addi t0, t0, 8
    j zero_pt
zero_pt_done:

    la t0, _pt_base                 # root
    li t3, 4096
    add t1, t0, t3                  # L1
    add t2, t1, t3                  # L0
    srli t4, t1, 12
    slli t4, t4, 10
    ori  t4, t4, 1                  # pointer: V
    sd   t4, 0(t0)                  # root[0] -> L1
    srli t4, t2, 12
    slli t4, t4, 10
    ori  t4, t4, 1
    sd   t4, 0(t1)                  # L1[0] -> L0
    li   t5, 0                      # page number
    li   t6, 16
map_page:
    bge  t5, t6, map_done
    slli t4, t5, 10
    ori  t4, t4, 0xCF               # V R W X A D
    slli a0, t5, 3
    add  a0, t2, a0
    sd   t4, 0(a0)
    addi t5, t5, 1
    j    map_page
map_done:

    srli t4, t0, 12
    li   t5, 8
    slli t5, t5, 60
    or   t4, t4, t5
    csrw satp, t4

    la   t0, _perf_mtrap
    bnez t0, 1f
    la   t0, _perf_done
1:  csrw mtvec, t0
    la   t0, _perf_scratch
    csrw mscratch, t0

    li   t0, 0x1800
    csrc mstatus, t0
    li   t0, 0x0800
    csrs mstatus, t0
    la   t0, main
    csrw mepc, t0
    la   ra, _perf_done
    mret

    .balign 4
    .globl _perf_done
_perf_done:
    ebreak
