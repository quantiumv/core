/*
 * qv_io.h -- console output for `make run` programs, through soc.sv's
 * NS16550A UART (design/uart16550.sv). No libc: no printf, no malloc.
 *
 * In simulation every byte written to THR appears on the console as it
 * is written. qv_putdec divides by repeated subtraction, so it also runs
 * on core_pipe, which has no divider yet.
 */
#ifndef QV_IO_H
#define QV_IO_H

#define QV_UART_BASE 0x04008000UL
#define QV_UART_THR  ((volatile unsigned char *)(QV_UART_BASE + 0))
#define QV_UART_LSR  ((volatile unsigned char *)(QV_UART_BASE + 5))
#define QV_LSR_THRE  0x20

static inline void qv_putc(char c)
{
    while (!(*QV_UART_LSR & QV_LSR_THRE))
        ;
    *QV_UART_THR = (unsigned char)c;
}

static inline void qv_puts(const char *s)
{
    while (*s)
        qv_putc(*s++);
}

static inline void qv_puthex(unsigned long v)
{
    qv_puts("0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        unsigned d = (v >> shift) & 0xF;
        qv_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

static inline void qv_putdec(long v)
{
    static const unsigned long pow10[] = {
        10000000000000000000UL, 1000000000000000000UL, 100000000000000000UL,
        10000000000000000UL, 1000000000000000UL, 100000000000000UL,
        10000000000000UL, 1000000000000UL, 100000000000UL, 10000000000UL,
        1000000000UL, 100000000UL, 10000000UL, 1000000UL, 100000UL, 10000UL,
        1000UL, 100UL, 10UL, 1UL,
    };
    unsigned long u = (unsigned long)v;
    if (v < 0) {
        qv_putc('-');
        u = -u;
    }
    int started = 0;
    for (unsigned i = 0; i < sizeof pow10 / sizeof pow10[0]; i++) {
        char d = '0';
        while (u >= pow10[i]) {
            u -= pow10[i];
            d++;
        }
        if (d != '0' || started || pow10[i] == 1) {
            qv_putc(d);
            started = 1;
        }
    }
}

#endif
