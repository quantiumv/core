/*
 * repro_fencei_smc.s -- self-modifying-code proof for the lockstep
 * harness's mutant kill matrix (QV_MUTANT==9: FENCE.I doesn't flush,
 * cache configuration -- see verification/reference/ref_core.sv). Ports
 * testbench/core_fence_i_tb.sv's own proven sequence (see that file's
 * header for the full rationale) into real-toolchain assembly instead
 * of hand-packed SystemVerilog encode_*() calls, since this needs to
 * run through gen/link.ld + the real objcopy/$readmemh pipeline, not a
 * standalone unit-test harness.
 *
 * Unlike QV_MUTANT==5 (see irq.list's own header), this mutant changes
 * WHICH instruction retires, not just timing -- side A is always flat
 * SRAM (no cache to go stale), so its second call to `target` always
 * sees the freshly-written bytes regardless of FENCE.I; side B, on the
 * cache memory configuration with mutant 9 active, would instead keep
 * serving the STALE cached first instruction if the mutation's broken
 * icache_flush_o is actually exercised. That's a genuine, immediate
 * per-retirement RVFI divergence (different insn, different rd_wdata),
 * so a plain tohost/MAX_RETIRE run catches it directly -- no need for
 * mutant 5's final-register-snapshot trick.
 *
 * Sequence, in order:
 *   1. `jal target` (call #1) -- target's first instruction (addi
 *      x5,x0,111) fetches into I$ for the first time.
 *   2. Copy new_instr's own assembled bytes (addi x5,x0,222 -- written
 *      below as a plain instruction inside .data.misc purely so the
 *      assembler computes its encoding; never executed from there) over
 *      target's first word -- a D$ store the I$ doesn't know about.
 *   3. `fence.i` -- must invalidate the I$ line covering target.
 *   4. `jal target` (call #2) -- must now see the NEW bytes (x5=222),
 *      not a stale hit re-serving the OLD ones (x5=111).
 * x5's final value (222, not 111) is the direct proof, exactly like
 * core_fence_i_tb.sv's own x5 check.
 *
 * Build (matches gen/link.ld's memory map, identical to repro_irq_stall.s):
 *   riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax \
 *       repro_fencei_smc.s -o repro_fencei_smc.o
 *   riscv64-unknown-elf-ld -T gen/link.ld -o repro_fencei_smc.elf repro_fencei_smc.o
 *   riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers \
 *       -j .data.misc --verilog-data-width=8 repro_fencei_smc.elf repro_fencei_smc.hex
 *
 * Run (MAX_RETIRE, not TOHOST_ADDR -- see irq.list's header for why a
 * mutant that structurally skews timing races against a tohost-based
 * mutual-completion check; this one doesn't skew timing, but staying
 * consistent with the corpus's own established, proven-safe convention
 * costs nothing). MAX_RETIRE=40, not something tighter -- confirmed
 * empirically that 20 is too tight: it can land mid-way through the
 * tohost-write sequence, where each side's own AHEAD_MAX slack hasn't
 * settled yet, producing a final-state mismatch on the CONTROL
 * (QV_MUTANT_B=0) run that has nothing to do with the mutant at all:
 *   vvp <lockstep_tb.vvp> +HEXFILE=repro_fencei_smc.hex +TIMEOUT=5000 \
 *       +MAX_RETIRE=40 -Plockstep_tb.MEMCFG_B_CACHE=1 -Plockstep_tb.QV_MUTANT_B=9
 *
 * Wired into the standard tooling as verification/lockstep/smc.list's
 * one entry -- `run_lockstep.sh --corpus smc --memcfg-b cache` builds
 * and runs it automatically.
 */
.section .text.entry
.global _start

_start:
    # ---- Test 1: FENCE.I is a clean no-op/retire ----
    li      x3, 999            # sentinel -- FENCE.I must not touch it
    fence.i
    li      x4, 111            # resume marker -- proves clean retirement

    # ---- Test 2: self-modifying code ----
    jal     x1, target         # call #1 -- populates I$ with OLD bytes
    li      x6, 1              # "call #1 returned"

    la      x9, new_instr      # x9 <- address of the NEW instruction's
    lw      x9, 0(x9)          #   own assembled encoding (see .data.misc below)
    la      x10, target        # x10 <- target's address
    sw      x9, 0(x10)         # D$ store overwrites target's first instruction
    fence.i
    jal     x1, target         # call #2 -- target's own jalr always returns via
                                #   x1, so BOTH calls must link into x1, not a
                                #   distinct register per call (core_fence_i_tb.
                                #   sv's own header flags exactly this as a past
                                #   authoring bug)
    li      x11, 1             # "call #2 returned"

    li      x12, 1
    la      x13, tohost
    sd      x12, 0(x13)
halt:
    j       halt

    .align 5                   # line-aligned (cache_complex's default line
                                # size is 4 dwords = 32 bytes), matching
                                # core_fence_i_tb.sv's own TARGET_ADDR choice
target:
    li      x5, 111            # OLD instruction -- will be overwritten
    jalr    x0, x1, 0          # return via the caller's own link register

.section .data.misc
.align 3
tohost:
    .zero 8
.align 2
new_instr:
    addi    x5, x0, 222        # NOT executed from here -- a plain instruction
                                # placed in .data.misc purely so the assembler
                                # computes its own encoding; copied over
                                # target's first word by the sw above
