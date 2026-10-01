# P3.5 CPI-baseline kernels. All seven share one crt0.o/link.ld and one
# flag set, unlike firmware/Makefile's per-target flags -- a pattern
# rule covers all of them instead of repeating the same four commands
# seven times.
#
# -march=rv64imac_zicsr: Zicsr for the mcycle/minstret reads in perf.h,
#   layered onto the project's usual rv64imac -- no existing firmware/
#   target combines the two, confirmed assembling and compiling cleanly
#   at -O2 before relying on it here.
# -O2: the plan's own explicit choice for these kernels (every firmware/
#   target instead builds -O0) -- this is a performance baseline, so it
#   wants realistic optimized code.
# -fno-builtin: without it, GCC's loop-idiom recognition can silently
#   rewrite a kernel's own copy/compare loop into a call to libc memcpy/
#   memcmp/etc. that doesn't exist under -nostdlib.
CFLAGS  = -march=rv64imac_zicsr -mabi=lp64 -mno-relax -ffreestanding -nostdlib -fno-builtin -O2 -Wall
ASFLAGS = -march=rv64imac_zicsr -mabi=lp64 -mno-relax

KERNELS = memcpy crc32 qsort matmul sieve listchase mixedint

all: $(addsuffix .hex,$(KERNELS))

crt0.o: crt0.s
	riscv64-unknown-elf-as $(ASFLAGS) crt0.s -o crt0.o

%.o: %.c perf.h
	riscv64-unknown-elf-gcc $(CFLAGS) -c $< -o $@

%.elf: crt0.o %.o
	riscv64-unknown-elf-ld -T link.ld -o $@ crt0.o $*.o
	riscv64-unknown-elf-objdump -d $@ > $*.lst

%.hex: %.elf
	riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 $< $@

clean:
	rm -f *.o *.elf *.hex *.lst

# Without this, make treats %.elf/%.o as purely-intermediate (nothing on
# the command line ever names them directly) and deletes them right
# after building %.hex -- but run_perf.sh needs each kernel's .elf
# around afterward, to resolve _perf_result's real address via `nm`.
.PRECIOUS: %.elf %.o

.PHONY: all clean
