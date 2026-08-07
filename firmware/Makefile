

# -mno-relax on both the assembler and gcc: disables linker relaxation
#   of small-data accesses into gp-relative instructions, so crt0.s
#   doesn't need to set up gp at all -- see that file's own header.
ASFLAGS = -march=rv64i -mabi=lp64 -mno-relax
CFLAGS  = -march=rv64i -mabi=lp64 -mno-relax -ffreestanding -nostdlib -O0 -Wall

# csr_test.s uses real CSR mnemonics (csrwi/csrrw/csrrc/csrrs/...), which
#   plain rv64i rejects ("extension zicsr required") -- crt0.s itself has
#   no CSR instructions, so it stays plain -march=rv64i (ASFLAGS above)
#   even when linked into this program.
CSR_ASFLAGS = -march=rv64i_zicsr -mabi=lp64 -mno-relax

# m_test.s uses real M-extension mnemonics (mul/mulh/.../div/rem/...),
#   which plain rv64i rejects ("unrecognized opcode") -- crt0.s itself has
#   no M-extension instructions, so it stays plain -march=rv64i (ASFLAGS
#   above) even when linked into this program.
M_ASFLAGS = -march=rv64im -mabi=lp64 -mno-relax

all:
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o
	riscv64-unknown-elf-gcc $(CFLAGS) -c hello.c -o hello.o
	riscv64-unknown-elf-ld -T link.ld -o crt0.elf crt0.o hello.o
	riscv64-unknown-elf-objdump -d crt0.elf
	# -j .text -j .rodata -j .data: only convert sections holding real
	#   runtime content -- excludes .riscv.attributes (toolchain metadata,
	#   not something we want loaded into memory) and .bss (zero-
	#   initialized, holds no file content to begin with; crt0.s zeros it
	#   at runtime instead -- see link.ld's comment on that section).
	# --verilog-data-width=8: one 64-bit $$readmemh element per line, matching
	#   wb4_sram.sv's memory[] (widened to 64 bits -- see that file's own header).
	# NO --reverse-bytes: verified by hand against a real build (objdump -d
	#   plus the raw hex output) that objcopy's verilog writer already emits
	#   bytes in the order $$readmemh needs for this design's convention --
	#   memory[i][7:0] == byte@lowest_address -- with no extra flag. Adding
	#   --reverse-bytes=8, which an earlier untested assumption here called
	#   for, actually produces the WRONG order; don't re-add it without
	#   re-deriving this by hand against real objdump output first.
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 crt0.elf crt0.hex

# Pillar 1 of the Zicsr verification-strengthening plan: a real-toolchain-
#   encoded end-to-end CSR test (firmware/csr_test.s), linked against the
#   SAME crt0.o/link.ld as the "all" target above -- rebuilt here (plain
#   -march=rv64i, unchanged) rather than assumed to already exist, so this
#   target works standalone. Produces a DISTINCT csr_test.hex -- crt0.hex
#   and the "all" target's hello-world pipeline are untouched either way.
csr_test:
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o
	riscv64-unknown-elf-as $(CSR_ASFLAGS) csr_test.s -o csr_test.o
	riscv64-unknown-elf-ld -T link.ld -o csr_test.elf crt0.o csr_test.o
	riscv64-unknown-elf-objdump -d csr_test.elf
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 csr_test.elf csr_test.hex

# Pillar C of the M-extension verification-strengthening plan: a real-
#   toolchain-encoded end-to-end M-extension test (firmware/m_test.s),
#   linked against the SAME crt0.o/link.ld as the "all"/csr_test targets
#   above -- rebuilt here (plain -march=rv64i, unchanged) rather than
#   assumed to already exist, so this target works standalone. Produces a
#   DISTINCT m_test.hex -- crt0.hex/csr_test.hex and the "all" target's
#   hello-world pipeline are untouched either way.
m_test:
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o
	riscv64-unknown-elf-as $(M_ASFLAGS) m_test.s -o m_test.o
	riscv64-unknown-elf-ld -T link.ld -o m_test.elf crt0.o m_test.o
	riscv64-unknown-elf-objdump -d m_test.elf
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 m_test.elf m_test.hex
