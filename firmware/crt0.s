    .section .text
    .globl _start

# Hello-world for the minimal SoC (design/soc.sv): print "Hello, World!\n"
# one byte at a time through the UART's memory-mapped TX_DATA register
# (design/uart_tx.sv, address 0x8000). x1 holds that address for the
# whole program; x2 is reused as the one-byte payload for each write.
#
# Deliberately a flat, repeated li+sb sequence rather than a string
# constant walked in a loop -- this milestone links with a bare
# `-Ttext=0x0` and no linker script, so there's no established, verified
# convention yet for where a .data/.rodata section would actually land.
# A loop over a real string is the natural next step once that exists;
# until then, this avoids depending on section-placement behavior that
# hasn't been proven on this toolchain/link setup.
_start:
    li x1, 0x8000

    li x2, 'H'
    sb x2, 0(x1)
    li x2, 'e'
    sb x2, 0(x1)
    li x2, 'l'
    sb x2, 0(x1)
    li x2, 'l'
    sb x2, 0(x1)
    li x2, 'o'
    sb x2, 0(x1)
    li x2, ','
    sb x2, 0(x1)
    li x2, ' '
    sb x2, 0(x1)
    li x2, 'W'
    sb x2, 0(x1)
    li x2, 'o'
    sb x2, 0(x1)
    li x2, 'r'
    sb x2, 0(x1)
    li x2, 'l'
    sb x2, 0(x1)
    li x2, 'd'
    sb x2, 0(x1)
    li x2, '!'
    sb x2, 0(x1)
    li x2, '\n'
    sb x2, 0(x1)

    ebreak
