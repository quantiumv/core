#include "perf.h"

#define N 64

static int32_t arr[N];

static void swap(int32_t *a, int32_t *b) {
    int32_t t = *a; *a = *b; *b = t;
}

static void quicksort(int32_t *a, int lo, int hi) {
    if (lo >= hi) return;
    int32_t pivot = a[(lo + hi) / 2];
    int i = lo, j = hi;
    while (i <= j) {
        while (a[i] < pivot) i++;
        while (a[j] > pivot) j--;
        if (i <= j) { swap(&a[i], &a[j]); i++; j--; }
    }
    quicksort(a, lo, j);
    quicksort(a, i, hi);
}

void main(void) {
    uint32_t seed = 12345u;
    for (int i = 0; i < N; i++) {
        seed = seed * 1103515245u + 12345u;
        arr[i] = (int32_t)((seed >> 16) % 1000u);
    }

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    quicksort(arr, 0, N - 1);
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
