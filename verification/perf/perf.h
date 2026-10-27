#ifndef PERF_H
#define PERF_H

#include <stdint.h>

/*
 * mcycle/minstret via Zicsr, not a port -- csr_file.sv exports both as
 * plain 64-bit CSRs (CSR_ADDR_MCYCLE/CSR_ADDR_MINSTRET), so a kernel
 * reads its own cost exactly the way real RISC-V software would.
 *
 * PERF_SMODE (the S-mode build, crt0_s.s): S cannot read either, so the two
 * reads become window markers for perf_stack.sv, which counts the window
 * itself: rdcycle reads sscratch (the marker the monitor keys on), rdinstret
 * reads instret (0xC02: legal from S, unmapped, reads 0), so the kernel retires
 * the same instructions as in the M build. The values they return mean nothing.
 */
#ifdef PERF_SMODE
static inline uint64_t rdcycle(void) {
    uint64_t x;
    asm volatile("csrr %0, sscratch" : "=r"(x));
    return x;
}

static inline uint64_t rdinstret(void) {
    uint64_t x;
    asm volatile("csrr %0, instret" : "=r"(x));
    return x;
}
#else
static inline uint64_t rdcycle(void) {
    uint64_t x;
    asm volatile("csrr %0, mcycle" : "=r"(x));
    return x;
}

static inline uint64_t rdinstret(void) {
    uint64_t x;
    asm volatile("csrr %0, minstret" : "=r"(x));
    return x;
}
#endif

/*
 * link.ld places this (letting the linker pick the real address rather
 * than a hardcoded guess that some kernel's .bss/stack could grow into)
 * -- run_perf.sh resolves it per kernel via `nm`, then passes it to
 * perf_tb.sv as +PERF_RESULT_ADDR, the same way run_lockstep.sh already
 * resolves each ACT4 ELF's own `tohost` symbol.
 */
extern volatile uint64_t _perf_result[2];

static inline void perf_report(uint64_t cycles, uint64_t instret) {
    _perf_result[0] = cycles;
    _perf_result[1] = instret;
}

#endif
