/*
 * Linker script of the S-mode build of the CPI kernels (P10.0; crt0_s.s).
 * link.ld's layout over 64 KB instead of 32 KB, plus the three page-table
 * pages crt0_s.s fills (root, L1, L0), 4 KiB aligned. The flat-SRAM harness
 * of this build has NUM_WORDS 8192 (64 KB); the SoC's RAM is a superset.
 */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x10000
}

SECTIONS
{
    .text : {
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
        *(.srodata*)    /* the F/D kernels' double constants (.srodata.cst8): the hex takes .rodata, not orphans */
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    .perf_result (NOLOAD) : ALIGN(8) {
        _perf_result = .;
        . += 16;
    } > RAM

    .pt (NOLOAD) : ALIGN(4096) {
        _pt_base = .;
        . += 3 * 4096;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
