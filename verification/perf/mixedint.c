#include "perf.h"

/*
 * mixedint -- stands in for the plan's "Dhrystone" slot. NOT the genuine
 * EEMBC-licensed Dhrystone source (this repo doesn't carry a copy, and
 * that benchmark comes with its own specific result-reporting
 * methodology that wouldn't mean much for a quick CPI baseline anyway).
 * This is an original workload inspired by its STRUCTURE instead: a mix
 * of integer arithmetic, function calls, and small string copy/compare
 * over local and global state. CoreMark (the plan's other, explicitly
 * optional slot) is skipped entirely for the same reason.
 */

#define STRLEN 12

static char str_a[STRLEN] = "QuantiumV!!";
static char str_b[STRLEN];
static int32_t int_glob;

static int32_t proc1(int32_t a, int32_t b) {
    return (a * 3 + b) ^ (a >> 2);
}

static void proc2(char *dst, const char *src, int n) {
    for (int i = 0; i < n; i++) dst[i] = src[i];
}

static int proc3(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i++) {
        if (a[i] != b[i]) return 0;
    }
    return 1;
}

void main(void) {
    int32_t local = 1;
    int match_count = 0;

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    for (int i = 0; i < 60; i++) {
        local = proc1(local, int_glob);
        int_glob += local & 0xFF;
        proc2(str_b, str_a, STRLEN);
        match_count += proc3(str_a, str_b, STRLEN);
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    (void)match_count;
    perf_report(c1 - c0, i1 - i0);
}
