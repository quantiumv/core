/*
 * Hello-world for the minimal SoC (design/soc.sv) -- the actual program
 * logic; firmware/crt0.s only sets up sp/.bss and calls main().
 *
 * Freestanding: no libc (-nostdlib in firmware/Makefile), so this can't
 * use printf or even strlen. The UART's TX_DATA register is written
 * directly through a volatile pointer -- volatile is load-bearing here,
 * not decoration: without it, the compiler is free to treat repeated
 * writes to the same address with no intervening read as dead stores
 * and drop all but the last one, since nothing about a plain write
 * tells it this address has an observable side effect.
 */

#define UART_TX_DATA ((volatile unsigned char *)0x8000)

static const char msg[] = "Hello, World!\n";

int main(void) {
    for (int i = 0; msg[i] != '\0'; i++) {
        *UART_TX_DATA = (unsigned char)msg[i];
    }
    return 0;
}
