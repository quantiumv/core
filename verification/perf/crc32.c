#include "perf.h"

#define N 128

static uint8_t buf[N];

/* Bitwise, no 256-entry table -- keeps .rodata (and the fetch footprint) small. */
static uint32_t crc32_bitwise(const uint8_t *data, int len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (int i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            if (crc & 1u) crc = (crc >> 1) ^ 0xEDB88320u;
            else          crc = crc >> 1;
        }
    }
    return ~crc;
}

static volatile uint32_t result;

void main(void) {
    for (int i = 0; i < N; i++) buf[i] = (uint8_t)(i * 31 + 17);

    uint64_t c0 = rdcycle(), i0 = rdinstret();
    result = crc32_bitwise(buf, N);
    uint64_t c1 = rdcycle(), i1 = rdinstret();

    perf_report(c1 - c0, i1 - i0);
}
