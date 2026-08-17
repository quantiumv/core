    .section .text
    .globl main

# Real-toolchain-encoded U/S/M privilege-mode verification program (Pillar C
# of the privilege-mode verification-strengthening plan) -- the privilege/
# trap sibling of csr_test.s and m_test.s. Exercises genuine csrw/csrr/
# mret/sret/ecall mnemonics through the real riscv64-unknown-elf-as
# assembler, as opposed to testbench/core_priv_tb.sv's hand-packed
# instruction encodings (that file already covers the exhaustive
# combinatorial privilege/delegation cases -- U-mode bootstrap, illegal
# MRET/SRET, CSR-privilege violations, WFI/SFENCE.VMA no-ops, etc. -- so
# this program is deliberately representative, not exhaustive: one M-mode
# trap, one cross-privilege bootstrap, one delegated S-mode trap, chained
# through real firmware control flow).
#
# Confirmed empirically (see firmware/Makefile's PRIV_ASFLAGS comment):
# mret/sret/ecall/wfi/sfence.vma all assemble under plain
# -march=rv64i_zicsr, the same extension flag CSR instructions already
# need -- no separate "privileged" march string is required by this
# toolchain.
#
# This core has no trap-based pass/fail signal for a toolchain-built
# program (ECALL/illegal-instruction just trap to a handler that resumes
# the next instruction), so exactly like csr_test.s/m_test.s, every
# result worth checking is kept alive in a distinct callee-saved register
# and confirmed from outside, by the testbench, once the program halts.
#
# Control flow:
#   Setup (M-mode): point mtvec/stvec at the two trap handlers below, and
#     delegate ONLY ECALL-from-S (medeleg bit 9) -- illegal-instruction
#     (bit 2) stays undelegated, though this program never triggers one;
#     the point is to prove medeleg is a real per-cause mask, not an
#     all-or-nothing switch, matching core_priv_tb.sv's own setup
#     reasoning.
#   Phase 1 (M-mode): ECALL. M-mode traps never delegate regardless of
#     medeleg (core.sv's trap_to_s is forced low whenever current_priv==M)
#     -- confirmed by reading mcause into s1 (expect 11, ECALL-from-M)
#     immediately after m_trap_handler's mret resumes here. s2 is a plain
#     marker proving control genuinely resumed at the right place, not
#     just that mcause happened to read correctly by chance.
#   Phase 2: bootstrap M -> S by writing mstatus.MPP=S and mepc=in_s_mode,
#     then mret -- current_priv becomes S and execution resumes at
#     in_s_mode. s3 is a marker proving this landed in real S-mode
#     firmware code (confirmed independently by the testbench checking
#     dut.current_priv == S post-halt, not just by trusting the marker
#     ran at all).
#   Phase 3 (S-mode): ECALL. medeleg[9]=1 delegates this one to S --
#     s_trap_handler's sret (not m_trap_handler's mret) handles it,
#     confirmed by reading scause into s4 (expect 9, ECALL-from-S,
#     delegated). scause (CSR 0x142) is S-accessible; mcause (CSR 0x342)
#     is NOT (bits[9:8]=11=M-only) -- so unlike core_priv_tb.sv's phase 1
#     (which needed a white-box PC-triggered sample because ITS own later
#     phases include more M-target traps that go on to overwrite mcause_q
#     again), this program never traps to M again after phase 1, so the
#     "mcause from the earlier M-mode ECALL is untouched by this later
#     S-target trap" disambiguating check the task calls for is done by
#     the testbench directly reading dut.csr_file0.mcause_q
#     post-halt and confirming it still reads 11 -- cheaper than a
#     white-box sampler here, and just as conclusive, precisely because
#     nothing after phase 1 ever re-enters M-mode to disturb it. s5 is
#     the final marker, proving control genuinely returned to real
#     firmware code (not just that the core happened to still be running)
#     after the delegated S-mode trap.
#
# ra/sp/gp/tp are never touched (only t0/t1 and the s1-s5 result chain
# are used), so `ret` correctly falls back into crt0.s's trailing ebreak
# regardless of which privilege mode is current at that point (EBREAK's
# halt latch, per core.sv, has no privilege gate) -- halting the core the
# same way every other firmware image in this repo does.
main:
    # ---- Setup (M-mode): trap vectors + per-cause delegation ----
    la      t0, m_trap_handler
    csrw    mtvec, t0
    la      t0, s_trap_handler
    csrw    stvec, t0
    li      t0, 512                 # bit 9 (ECALL-from-S) only; bit 2 (illegal-instr) left undelegated
    csrw    medeleg, t0

    # ---- Phase 1: ECALL from M-mode -- never delegates, regardless of medeleg ----
    ecall                           # traps to m_trap_handler; mepc+=4, mret resumes at the next line
    csrr    s1, mcause              # s1 = 11 (ECALL from M-mode)
    li      s2, 111                 # marker: control genuinely resumed after the M-mode ECALL trap

    # ---- Phase 2: bootstrap M -> S via mstatus.MPP=S + mepc + mret ----
    li      t0, 1
    slli    t0, t0, 11              # t0 = mstatus.MPP field (bits[12:11]) = S (2'b01)
    csrw    mstatus, t0
    la      t0, in_s_mode
    csrw    mepc, t0
    mret                            # current_priv <- S (from MPP), jump to in_s_mode
in_s_mode:
    li      s3, 222                 # marker: now running in real S-mode firmware code

    # ---- Phase 3: ECALL from S-mode -- delegated to S via medeleg[9] ----
    ecall                           # traps to s_trap_handler (S-target); sepc+=4, sret resumes at the next line
    csrr    s4, scause              # s4 = 9 (ECALL from S-mode, delegated) -- scause is S-accessible, unlike mcause
    li      s5, 333                 # final marker: control genuinely returned after the delegated S-mode ECALL trap

    ret

# ---- M-mode trap handler: skip the trapping instruction, return ----
# Same "read xEPC, advance by 4, write back, xRET" pattern used throughout
# this project's privilege-mode testing (see testbench/core_priv_tb.sv's
# M_TRAP_HANDLER) -- a test program deliberately trapping doesn't need to
# re-examine the fault, just prove it can resume past it correctly. t1 is
# scratch: dead across every trap boundary in this program (main() always
# re-initializes t0 before its next use, and never reads t1 at all), so
# clobbering it here is safe.
m_trap_handler:
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    mret

# ---- S-mode trap handler: same shape, S-mode's own xEPC/xRET pair ----
s_trap_handler:
    csrr    t1, sepc
    addi    t1, t1, 4
    csrw    sepc, t1
    sret
