#include "perf.h"

/*
 * The trap path of an OS (P10.0): a loop of ecalls, each taken by an M-mode
 * handler shaped like Linux's entry and exit -- swap sp with the scratch CSR,
 * save registers, read the cause, epc, tval and status CSRs, step the epc past
 * the ecall, restore, swap back, xRET. In the S-mode build the ecall comes from
 * S and the same handler runs in M (crt0_s.s points mtvec and mscratch at it).
 */
#define N 200

uint64_t _perf_scratch[8];
static volatile uint64_t sink;

void _perf_mtrap(void);
asm(
    "    .text\n"
    "    .balign 4\n"
    "    .globl _perf_mtrap\n"
    "_perf_mtrap:\n"
    "    csrrw sp, mscratch, sp\n"
    "    sd t0, 0(sp)\n"
    "    sd t1, 8(sp)\n"
    "    sd t2, 16(sp)\n"
    "    sd t3, 24(sp)\n"
    "    sd a0, 32(sp)\n"
    "    sd a1, 40(sp)\n"
    "    csrr t0, mcause\n"
    "    csrr t1, mepc\n"
    "    csrr t2, mtval\n"
    "    csrr t3, mstatus\n"
    "    add a0, t0, t2\n"
    "    xor a1, t3, a0\n"
    "    addi t1, t1, 4\n"
    "    csrw mepc, t1\n"
    "    ld t0, 0(sp)\n"
    "    ld t1, 8(sp)\n"
    "    ld t2, 16(sp)\n"
    "    ld t3, 24(sp)\n"
    "    ld a0, 32(sp)\n"
    "    ld a1, 40(sp)\n"
    "    csrrw sp, mscratch, sp\n"
    "    mret\n"
);

void main(void) {
#ifndef PERF_SMODE
    asm volatile("csrw mtvec, %0" :: "r"(_perf_mtrap));
    asm volatile("csrw mscratch, %0" :: "r"(_perf_scratch));
#endif
    uint64_t acc = 1;

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int i = 0; i < N; i++) {
        acc = acc * 5 + (uint64_t)i;
        asm volatile("ecall" ::: "memory");
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
    sink = acc;
}
