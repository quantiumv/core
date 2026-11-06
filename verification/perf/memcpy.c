#include "perf.h"

#define N 256

static uint8_t src[N];
static uint8_t dst[N];

static void my_memcpy(uint8_t *d, const uint8_t *s, int n) {
    for (int i = 0; i < n; i++) d[i] = s[i];
}

void main(void) {
    for (int i = 0; i < N; i++) src[i] = (uint8_t)(i * 7 + 3);

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int rep = 0; rep < 4; rep++) {
        my_memcpy(dst, src, N);
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
