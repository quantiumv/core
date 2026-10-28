#include "perf.h"

/* F/D: an 8x8 double matrix multiply; -O2 contracts a[i][k] * b[k][j] + sum into one FMADD.D (fp-contract=fast) */
#define N 8

static double a[N][N], b[N][N];
static volatile double c[N][N];     /* volatile: otherwise nothing reads c and the loops go */

void main(void) {
    perf_fp_on();
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            a[i][j] = (double)(i + j) * 0.5;
            b[i][j] = (double)(i - j) * 0.25;
        }
    }

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            double sum = 0.0;
            for (int k = 0; k < N; k++) sum += a[i][k] * b[k][j];
            c[i][j] = sum;
        }
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
