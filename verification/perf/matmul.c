#include "perf.h"

#define N 8

static int32_t a[N][N], b[N][N];
/* volatile: c[][] is otherwise never read anywhere, so -O2 proved the
 * whole triple-nested loop below has no observable effect and deleted
 * it outright (caught empirically: cycles=7 instret=2, i.e. nothing
 * ran between the two CSR-read pairs). */
static volatile int32_t c[N][N];

void main(void) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            a[i][j] = i + j;
            b[i][j] = i - j;
        }
    }

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int k = 0; k < N; k++) sum += a[i][k] * b[k][j];
            c[i][j] = sum;
        }
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
