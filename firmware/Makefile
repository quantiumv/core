

all:
	riscv64-unknown-elf-as -march=rv64i -mabi=lp64 crt0.s -o crt0.o
	riscv64-unknown-elf-ld -Ttext=0x0 -o crt0.elf crt0.o
	riscv64-unknown-elf-objdump -d crt0.elf
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 crt0.elf crt0.hex
