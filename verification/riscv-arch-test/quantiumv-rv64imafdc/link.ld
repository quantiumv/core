OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/*
 * QuantiumV's wb4_sram is a single flat memory starting at address 0
 * (every existing testbench in design/ and testbench/ assumes this),
 * unlike the classic riscv-tests/Spike DRAM-at-0x80000000 convention.
 * Reset PC is 0 (design/core.sv's pc register resets to '0).
 */
SECTIONS
{
  . = 0x0;
  .text.init    : { *(.text.init) }
  .text.rvtest  : { *(.text.rvtest) *(.text.rvtest.*) }
  . = ALIGN(0x1000);
  .data         : { *(.data) }
  . = ALIGN(0x100);
  .text.rvmodel : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }
  . = ALIGN(0x100);
  _end = .;
}
