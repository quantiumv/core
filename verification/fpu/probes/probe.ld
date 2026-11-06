/* probe.ld -- the probes' layout: code at 0, data at 0x10000, both inside the Sail override's single RAM region. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x0;
  .text : { *(.text*) }
  . = 0x10000;
  .data : { *(.data*) *(.sdata*) }
}
