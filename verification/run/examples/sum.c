/*
 * make run PROG=verification/run/examples/sum.c [CORE=pipe]
 *
 * Uses *, / and % (libgcc does them on core_pipe), a global array in
 * .bss and an initialized one in .data, and returns a checksum: the run
 * ends with "exit code 99" when everything matches.
 */
#include "qv_io.h"

#define N 20

static long squares[N];                        /* .bss, zeroed by crt0 */
static long primes[] = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29};   /* .data */

static int is_prime(long n)
{
    if (n < 2)
        return 0;
    for (long d = 2; d * d <= n; d++)
        if (n % d == 0)
            return 0;
    return 1;
}

int main(void)
{
    long sum = 0;
    for (int i = 0; i < N; i++) {
        squares[i] = (long)i * i;
        sum += squares[i];
    }
    qv_puts("sum of squares 0..19 = ");
    qv_putdec(sum);                            /* 2470 */
    qv_puts("\naverage = ");
    qv_putdec(sum / N);                        /* 123 */

    int found = 0, ok = 1;
    for (long n = 0; n < 30; n++) {
        if (is_prime(n)) {
            ok &= (primes[found] == n);
            found++;
        }
    }
    qv_puts("\nprimes below 30: ");
    qv_putdec(found);
    qv_puts(ok ? " (all match)\n" : " (MISMATCH)\n");

    return (sum == 2470 && sum / N == 123 && found == 10 && ok) ? 99 : 1;
}
