/*
 * Linker script for the minimal SoC (design/soc.sv).
 *
 * RAM spans 0x0000-0x7FFF -- a conservative 32KB program-size ceiling
 * this script itself chooses, not a hard hardware boundary: since the
 * Linux-boot-readiness RAM-growth change, soc.sv's own real sram0
 * instance is 64MB (addresses 0x0000_0000-0x03FF_FFFF all land on real
 * RAM; every peripheral -- UART/CLINT/DRAM/PLIC -- now lives well above
 * that, starting at 0x0400_8000, see design/wb_addr_decoder.sv's own
 * header) -- this project's own tiny test firmware simply has never
 * needed more than 32KB, so this script never grew LENGTH to match RAM's
 * real capacity. .text is placed first so it starts at 0x0, matching
 * core.sv's reset vector (pc resets to 0) -- crt0.o must be the first
 * object passed to `ld` for its _start to actually land there; this
 * script alone doesn't guarantee input-file order.
 *
 * The stack starts at the very top of RAM and grows down. For this
 * milestone's tiny C programs it will never collide with
 * .text/.rodata/.data/.bss, but nothing here enforces that -- a much
 * bigger program could grow .bss up into the stack with no warning.
 */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x8000
}

SECTIONS
{
    .text : {
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    /*
     * _bss_start/_bss_end are consumed by crt0.s's zero-fill loop. Real
     * hardware gives .bss no zero-initialization guarantee at all;
     * design/wb4_sram.sv happens to zero-fill everything in simulation
     * (see that file's own header), which would silently paper over a
     * missing zero-loop here -- crt0.s zeros it explicitly anyway,
     * since that simulator behavior isn't something to rely on.
     */
    .bss : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
