#include "perf.h"

#define N 1000

static uint8_t is_composite[N];

void main(void) {
    for (int i = 0; i < N; i++) is_composite[i] = 0;

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int p = 2; p * p < N; p++) {
        if (!is_composite[p]) {
            for (int m = p * p; m < N; m += p) is_composite[m] = 1;
        }
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
