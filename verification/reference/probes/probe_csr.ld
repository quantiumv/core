/* probe_csr.ld -- csr_probe.py's layout: code from 0, data after it, inside the RAM of every config it runs under. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x0;
  .text : { *(.text*) }
  . = ALIGN(8);
  .data : { *(.data*) *(.sdata*) }
}
