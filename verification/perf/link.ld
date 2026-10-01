/*
 * Linker script for the P3.5 CPI-baseline kernels (verification/perf/).
 *
 * Deliberately mirrors firmware/link.ld's own RAM window (0x0000-0x7FFF,
 * 32KB) rather than soc.sv's real 64MB -- every kernel here needs to
 * build to a SINGLE .hex image that runs unmodified on both perf_tb.sv
 * configurations (the SRAM-only harness, whose own NUM_WORDS defaults to
 * the same 32KB, and soc.sv, whose real RAM is a superset starting at
 * the same address 0x0), and 32KB is already far more than any of these
 * small kernels need. See firmware/link.ld's own header for why .text is
 * placed first (core.sv's reset vector is address 0) and why crt0.o must
 * be the first object passed to `ld`.
 *
 * The one addition over firmware/link.ld: a `.perf_result` section,
 * right after .bss, sized for two 64-bit words (cycle delta, instret
 * delta -- see perf.h). Letting the LINKER place it (rather than
 * hardcoding an address and hoping no kernel's .bss/stack ever grows
 * into it) is deliberate: run_perf.sh resolves its real address per
 * kernel via `nm`, the exact same way run_lockstep.sh already resolves
 * each ACT4 ELF's own `tohost` symbol.
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

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
