#include "perf.h"

/* F/D: divide, square root and conversions, in both precisions: what the FPU's side unit and its rounder do */
#define N 32

static double v[N];
static volatile double out_d;
static volatile float out_s;
static volatile int64_t out_i;

void main(void) {
    perf_fp_on();
    for (int i = 0; i < N; i++) v[i] = (double)(3 * i + 1) * 0.125;

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    double acc = 0.0;
    float facc = 0.0f;
    int64_t iacc = 0;
    for (int i = 0; i < N; i++) {
        double x = __builtin_sqrt(v[i]) / (v[i] + 1.0);   /* FSQRT.D, FADD.D, FDIV.D */
        acc += x;
        facc += (float)x * 1.5f;                          /* FCVT.S.D, FMUL.S/FMADD.S */
        iacc += (int64_t)(x * 1000.0);                    /* FCVT.L.D */
    }
    out_d = acc;
    out_s = facc;
    out_i = iacc;
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
