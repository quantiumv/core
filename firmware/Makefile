

all:
	riscv64-unknown-elf-as -march=rv64i -mabi=lp64 crt0.s -o crt0.o
	riscv64-unknown-elf-ld -Ttext=0x0 -o crt0.elf crt0.o
	riscv64-unknown-elf-objdump -d crt0.elf
	# --verilog-data-width=8: one 64-bit $readmemh element per line, matching
	#   wb4_sram.sv's memory[] (widened to 64 bits -- see that file's own header).
	# --reverse-bytes=8: objcopy's verilog writer packs address-ascending bytes
	#   as the MOST-significant part of each hex token; $readmemh loading that
	#   into memory[i][63:0] would then put byte@lowest_address at [63:56], the
	#   opposite of the little-endian convention memory[i][7:0]==byte@lowest_address
	#   this design uses everywhere else (dmem.sv, wb4_sram.sv's own write path).
	#   This flag corrects the byte order at export time instead.
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=8 --reverse-bytes=8 crt0.elf crt0.hex
