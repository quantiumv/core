/*
 * Linker script for `make run` programs (verification/run/run_prog.sh).
 *
 * Same layout as firmware/link.ld, which firmware/crt0.s is written
 * against (_start at 0, _bss_start/_bss_end zeroed by crt0, sp =
 * _stack_top), with two differences:
 *   - all 64MB of soc.sv's RAM, not firmware/'s 32KB;
 *   - gcc's small-data sections (.srodata/.sdata/.sbss) are gathered
 *     into .rodata/.data/.bss, so the objcopy of .text/.rodata/.data
 *     can't silently leave small globals out of the image.
 */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x04000000
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > RAM

    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    _end = .;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
