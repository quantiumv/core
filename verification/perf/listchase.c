#include "perf.h"

#define N 64

typedef struct node {
    struct node *next;
    int32_t value;
} node_t;

static node_t nodes[N];
static volatile int64_t sum_sink;

/* Fixed (non-sequential) permutation, not true random -- just enough to
 * defeat "next node is always the next array slot" rather than needing
 * a real RNG. Linked as a single N-length cycle. */
void main(void) {
    int order[N];
    for (int i = 0; i < N; i++) order[i] = i;
    for (int i = N - 1; i > 0; i--) {
        int j = (i * 37 + 11) % (i + 1);
        int t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (int i = 0; i < N; i++) {
        nodes[order[i]].value = order[i];
        nodes[order[i]].next  = &nodes[order[(i + 1) % N]];
    }

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    node_t *p = &nodes[0];
    int64_t sum = 0;
    for (int i = 0; i < N * 8; i++) {
        sum += p->value;
        p = p->next;
    }
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    /* volatile sink, not (void)sum -- a discarded local proved the
     * whole walk had no observable effect and -O2 deleted it outright
     * (caught empirically: cycles=7 instret=2). */
    sum_sink = sum;
    perf_report(c1 - c0, i1 - i0);
}
