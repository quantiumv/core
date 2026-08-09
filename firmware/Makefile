

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

# priv_test.s uses real CSR mnemonics (csrw/csrr) AND privileged-mode
#   mnemonics (mret/sret/ecall) -- confirmed empirically (a standalone
#   assemble-and-objdump check, not assumed) that riscv64-unknown-elf-as
#   accepts mret/sret/ecall/wfi/sfence.vma under the SAME -march=rv64i_zicsr
#   flag CSR_ASFLAGS above already uses for plain CSR instructions; no
#   separate "privileged" extension letter is needed by this toolchain.
#   Same value as CSR_ASFLAGS, kept as its own named variable anyway
#   (matching M_ASFLAGS's own precedent of a distinctly-named flag set per
#   program) so this target's requirements are self-documenting and don't
#   silently start diverging from CSR_ASFLAGS's if that ever changes for
#   Zicsr-only reasons.
PRIV_ASFLAGS = -march=rv64i_zicsr -mabi=lp64 -mno-relax

# a_test.s uses real A-extension mnemonics (lr.w/sc.w/amoadd.d/...), which
#   plain rv64i rejects ("unrecognized opcode") -- crt0.s itself has no
#   A-extension instructions, so it stays plain -march=rv64i (ASFLAGS
#   above) even when linked into this program.
A_ASFLAGS = -march=rv64ima -mabi=lp64 -mno-relax

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

# Pillar C of the U/S/M privilege-mode verification-strengthening plan: a
#   real-toolchain-encoded end-to-end privilege-mode test
#   (firmware/priv_test.s), linked against the SAME crt0.o/link.ld as the
#   "all"/csr_test/m_test targets above -- rebuilt here (plain
#   -march=rv64i, unchanged) rather than assumed to already exist, so this
#   target works standalone. Produces a DISTINCT priv_test.hex --
#   crt0.hex/csr_test.hex/m_test.hex and the "all" target's hello-world
#   pipeline are untouched either way.
priv_test:
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o
	riscv64-unknown-elf-as $(PRIV_ASFLAGS) priv_test.s -o priv_test.o
	riscv64-unknown-elf-ld -T link.ld -o priv_test.elf crt0.o priv_test.o
	riscv64-unknown-elf-objdump -d priv_test.elf
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 priv_test.elf priv_test.hex

# Pillar C of the A-extension verification plan: a real-toolchain-encoded
#   end-to-end A-extension (atomics) test (firmware/a_test.s), linked
#   against the SAME crt0.o/link.ld as the "all"/csr_test/m_test/priv_test
#   targets above -- rebuilt here (plain -march=rv64i, unchanged) rather
#   than assumed to already exist, so this target works standalone.
#   Produces a DISTINCT a_test.hex -- every other target's hex output is
#   untouched either way. Unlike m_test/priv_test, a_test.s genuinely
#   needs memory (LR/SC/AMO all operate on a real address) -- it uses
#   link.ld's existing .data section, so -j .data (already present below)
#   carries real, non-zero initialized content for the first time among
#   these targets, rather than just reserving space .bss-style.
a_test:
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o
	riscv64-unknown-elf-as $(A_ASFLAGS) a_test.s -o a_test.o
	riscv64-unknown-elf-ld -T link.ld -o a_test.elf crt0.o a_test.o
	riscv64-unknown-elf-objdump -d a_test.elf
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 a_test.elf a_test.hex
