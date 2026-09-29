/*
 * Linker script for qvgen.py's generated programs -- see that file's own
 * header for the full memory-map rationale. Unlike firmware/link.ld
 * (32KB, .text/.rodata/.data all unordered-but-contiguous) this script
 * enforces qvgen's own fixed region boundaries explicitly, matching the
 * plan's memory map: code [0x0,0x10000), data [0x10000,0x20000), page
 * tables [0x20000,0x30000), general/stack headroom above that, all
 * within a 1 MiB image. qvgen.py tags its own output with matching
 * section names (.text.entry/.text.handlers/.data.sandbox/
 * .data.pagetables) so each lands in its own region regardless of how
 * much of that region it actually uses -- an oversized region is just
 * unused padding, not a real constraint on program size.
 *
 * Entry point is qvgen's own `_start` (a minimal one, NOT firmware's
 * crt0.s -- qvgen's generated programs set up their own M-mode state
 * from a cold reset directly, they don't need crt0's C-runtime bss-zero/
 * stack-init dance since qvgen never emits a C program).
 */
ENTRY(_start)

SECTIONS
{
    .text.entry 0x0 : { *(.text.entry) }

    .text.handlers 0x8000 : { *(.text.handlers) }

    .data.sandbox 0x10000 : { *(.data.sandbox) }

    .data.pagetables 0x20000 : { *(.data.pagetables) }

    .data.misc 0x30000 : { *(.data.misc) *(.data) *(.data.*) *(.rodata) *(.rodata.*) *(.bss) *(.bss.*) *(COMMON) }

    _stack_top = 0x100000;
}
