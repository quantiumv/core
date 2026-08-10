    .section .text
    .globl main

# Real-toolchain-encoded C-extension (RV64 Zca, compressed instructions)
# verification program -- Pillar 4 of the C-extension plan, the
# compressed-instruction sibling of a_test.s/m_test.s.
#
# Unlike Pillar 3 (testbench/c_encode_check.s, which uses explicit c.xxx
# mnemonics for deterministic one-instruction-per-line coverage), this
# file is deliberately written as ORDINARY RISC-V assembly -- no c.xxx
# mnemonics at all. Under -march=rv64imac, the real assembler
# automatically selects the compressed encoding for any eligible plain
# mnemonic (confirmed empirically during Pillar 3's own investigation);
# letting that happen here, rather than forcing it, is the whole point --
# this is the first place in the C-extension milestone that exercises
# REALISTIC, non-cherry-picked compressed-code density end to end
# through the real fetch/expand/execute pipeline, a preview of what
# Pillar 5's hello-world-under-rv64imac regression does at full SoC
# scale.
#
# Specifically exercises the one thing Pillar 3's isolated mnemonic
# sweep structurally cannot: pc_plus_len's correctness against REAL
# LINKED addresses. `jal ra,sub1` (uncompressible -- RV64 has no
# compressed form for a jump-and-link with a real, non-x0 destination
# register) links `ra` to pc_plus_len of the jal itself; `ret` in sub1
# (compiles down to `jalr x0,0(ra)`, which -- rd=x0, rs1=ra=x1, a real
# jump discarding the link -- is exactly C.JR's shape, so the real
# assembler compresses it to `c.jr ra`) then jumps back to exactly that
# saved address. If pc_plus_len were computed even one byte wrong
# anywhere along this path, execution would resume at the wrong
# instruction and every check after the call would fail or the core
# would never reach `ebreak` at all -- a strong, naturally end-to-end
# proof, not a synthetic one.
#
# Also uses real .data memory (like a_test.s; m_test.s needed none) and
# a real backward-branching loop. main is NOT a leaf function (it calls
# sub1), so per standard RISC-V calling convention it explicitly saves
# its own incoming `ra` (crt0.s's own call-site return address) to the
# stack before `jal ra,sub1` overwrites it, and restores it before its
# own trailing `ret` -- gp/tp are otherwise untouched. Skipping this
# save/restore was the actual first draft's own bug (caught by this
# test's own timeout, then root-caused via a commit-by-commit fetch/pc
# trace showing main's own `ret` incorrectly landing back inside its own
# body instead of crt0.s -- a real lesson in this file's own test
# program correctness, not in core.sv/c_expand.sv, both of which traced
# out exactly right throughout). With the save/restore in place, `ret`
# falls back correctly into crt0.s's trailing ebreak, halting the core
# the same way every other firmware image in this repo does.

    .section .data
    .align 3
c_data:
    .dword 0   # 0: store/load round-trip scratch

    .section .text
sub1:
    # Leaf function: doubles a0. Exercises a real, non-x0-destination
    # jal (main->sub1) paired with a real compressed return (sub1->main).
    add     a0, a0, a0
    ret

main:
    # main is NOT a leaf function (it calls sub1) -- ra is caller-saved
    # per standard RISC-V calling convention, so main must save its own
    # incoming ra (crt0.s's call-site return address) before clobbering
    # it with `jal ra,sub1` below, and restore it before its own trailing
    # ret. sp was already set up by crt0.s before main was ever called.
    addi    sp, sp, -16
    sd      ra, 8(sp)

    la      t0, c_data
    li      t1, 123
    sd      t1, 0(t0)
    ld      s1, 0(t0)        # s1 = 123, confirms the store+load round trip

    li      a0, 21
    jal     ra, sub1         # sub1(21) -> 42; return address correctness
                              # is exactly what this whole file exists to
                              # prove (see header)
    mv      s2, a0            # s2 = 42

    li      s3, 5
    li      s4, 0
loop:
    addi    s4, s4, 1
    addi    s3, s3, -1
    bnez    s3, loop          # backward branch, real loop -- s4 ends at 5

    li      s5, -7
    li      s6, 100
    add     s5, s5, s6        # s5 = 93

    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret
