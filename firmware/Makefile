

all:
	riscv64-unknown-elf-as -march=rv64i -mabi=lp64 crt0.s -o crt0.o
	riscv64-unknown-elf-ld -Ttext=0x0 -o crt0.elf crt0.o
	riscv64-unknown-elf-objdump -d crt0.elf
	# -j .text: only convert .text -- .riscv.attributes (toolchain metadata
	#   the linker adds, not something we want loaded into memory at all)
	#   isn't a multiple of 8 bytes long, which --reverse-bytes=8 would
	#   choke on if it were applied to the whole file instead.
	# --verilog-data-width=8: one 64-bit $$readmemh element per line, matching
	#   wb4_sram.sv's memory[] (widened to 64 bits -- see that file's own header).
	# NO --reverse-bytes: verified by hand against a real build (objdump -d
	#   plus the raw hex output) that objcopy's verilog writer already emits
	#   bytes in the order $$readmemh needs for this design's convention --
	#   memory[i][7:0] == byte@lowest_address -- with no extra flag. Adding
	#   --reverse-bytes=8, which an earlier untested assumption here called
	#   for, actually produces the WRONG order; don't re-add it without
	#   re-deriving this by hand against real objdump output first.
	riscv64-unknown-elf-objcopy -O verilog -j .text --verilog-data-width=8 crt0.elf crt0.hex
