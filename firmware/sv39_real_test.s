    .section .text
    .globl main

# Real-toolchain-assembled end-to-end Sv39 virtual-memory test -- the
# first Sv39 test in this project actually compiled/linked by the real
# riscv64-unknown-elf-as/-ld/-objcopy toolchain, as opposed to every
# prior Sv39 testbench (testbench/core_sv39_{fetch,mem,tlb,cache}_tb.sv),
# which hand-packs page tables and instruction encodings directly into
# simulation memory. Confirmed empirically (a standalone assemble-and-
# objdump check, same discipline as PRIV_ASFLAGS/firmware/Makefile's own
# comment) that mret/csrw/csrr/sfence.vma, and the CSR name "satp"
# itself, all assemble cleanly under plain -march=rv64i_zicsr -- no
# separate "privileged" or "Sv39" march string is needed by this
# toolchain, same conclusion PRIV_ASFLAGS already reached for mret/sret/
# ecall.
#
# Unlike every prior Sv39 testbench, this program does NOT hand-pick any
# physical address for its page table or leaf pages. Instead, the three
# page-table levels (l2_table/l1_table/l0_table) and the mem-side leaf's
# own backing word (s_mode_data) are reserved as ordinary, page-aligned
# .data symbols near the end of this file (see that section's own header
# comment for why .data, not the more obvious .bss), and every PPN this
# program writes into a PTE is read back at RUNTIME via a plain `la` off
# that symbol -- never a hand-computed immediate. This sidesteps the
# exact "hand-computed physical addresses drift once the real
# assembler's own encoding choices shift layout" failure mode called out
# for this class of test: there is nothing hand-computed to drift. The
# linker (via link.ld) guarantees .data is placed strictly after .text/
# .rodata with no overlap, and this program's own footprint (a few
# hundred bytes of .text plus 4 reserved 4KB-aligned .data pages = ~16KB)
# sits comfortably under the 32KB RAM image with a huge margin below
# _stack_top (0x8000) -- and this program never uses the stack beyond
# `call main`'s implicit `ra` write (no explicit sp-relative pushes
# anywhere), so there is no stack-growth collision risk to reason about
# either.
#
# Control flow:
#   1. (M-mode) Point mtvec at a defensive fallback handler (below) --
#      medeleg is deliberately left at its reset value (0, nothing
#      delegated), so ANY unexpected trap, from either M-mode or the
#      later S-mode phase, lands there instead of silently corrupting
#      state or hanging.
#   2. (M-mode) Build a real 3-level Sv39 page table at runtime, using
#      ordinary la + srli/slli/ori + sd instructions:
#        L2[vpn2=1] -> pointer to l1_table
#        L1[vpn1=2] -> pointer to l0_table
#        L0[vpn0=4] -> leaf, s_mode_target's own real PA (R+X, no W --
#                      a code page)
#        L0[vpn0=5] -> leaf, s_mode_data's own real PA (R+W, no X -- a
#                      data page)
#      Both leaves share the same vpn2/vpn1 (one L1/L0 pair covers
#      both), so five reserved .data pages (l2/l1/l0/... ) cover the
#      whole table plus the data leaf's own backing page; the code
#      leaf's own physical page is wherever the linker placed
#      s_mode_target inside .text (no reservation needed there -- it's
#      real, executable content, not a placeholder).
#   3. (M-mode) satp <- MODE=Sv39(8), PPN=l2_table's own real PPN, then
#      a real `sfence.vma` (defensive -- flushes any stale TLB state
#      before the very first translated access, the textbook-correct
#      sequence, even though this core's TLB is architecturally empty
#      at reset).
#   4. (M-mode) mstatus.MPP <- S, mepc <- the TRANSLATED VA of
#      s_mode_target (vpn2=1,vpn1=2,vpn0=4, page offset = s_mode_target's
#      own real PA's low 12 bits, passed through untranslated exactly
#      like every other Sv39 milestone's own leaf-address reconstruction
#      -- computed here via slli-by-52-then-srli-by-52, since `andi`'s
#      12-bit signed immediate can't directly express a 0xFFF mask).
#      mret -- current_priv becomes S, and the very next fetch is a
#      REAL, walker-mediated translation of a VA that shares nothing
#      with its own real PA except the low-12-bit page offset.
#   5. (S-mode, s_mode_target) A few genuine instructions, reached only
#      through that real fetch-side walk: mark s1 (proves translated
#      fetch happened), independently recompute s_mode_data's own
#      translated VA (vpn0=5, same technique as step 4, entirely
#      self-contained -- no register handoff from the M-mode phase
#      needed), then a real store-doubleword THROUGH that VA (mem-side
#      walk #1) followed by a real load-doubleword from the SAME VA
#      (mem-side walk #2 or a TLB hit, depending on core's own caching
#      -- either way, mem-side translation is exercised in both
#      directions), landing the round-tripped value in s2. A final
#      marker (s3) confirms the whole S-mode sequence ran to
#      completion, then EBREAK halts the core -- while STILL in S-mode
#      (checked by the testbench via the same "sample current_priv on
#      the SAME edge the terminal ebreak's own trap_taken first fires"
#      technique testbench/core_priv_toolchain_tb.sv already uses,
#      since current_priv itself flips to M the instant this EBREAK's
#      own trap entry commits).
#
# s1 (x9, 0xAA) / s2 (x18, the round-tripped 0x12345678) / s3 (x19,
# 0xC0FFEE) are the success markers; s4 (x20) / s5 (x21, mcause) are set
# ONLY if the defensive fallback handler is ever reached (s4 must read 0
# post-halt for a genuine pass) -- same "keep results alive in
# callee-saved registers, confirm from outside" idiom every real-
# toolchain testbench in this project already uses.
main:
    la      t0, m_fallback_handler
    csrw    mtvec, t0

    # ---- L2[vpn2=1] -> pointer to l1_table ----
    la      t0, l1_table
    srli    t1, t0, 12
    slli    t1, t1, 10
    ori     t1, t1, 1                # V=1, R=W=X=0 (non-leaf pointer)
    la      t2, l2_table
    addi    t2, t2, 8                # index 1 * 8 bytes (vpn2=1's own entry)
    sd      t1, 0(t2)

    # ---- L1[vpn1=2] -> pointer to l0_table ----
    la      t0, l0_table
    srli    t1, t0, 12
    slli    t1, t1, 10
    ori     t1, t1, 1
    la      t2, l1_table
    addi    t2, t2, 16               # index 2 * 8 bytes
    sd      t1, 0(t2)

    # ---- L0[vpn0=4] -> leaf, s_mode_target's own real PA (code page) ----
    la      t0, s_mode_target
    srli    t1, t0, 12
    slli    t1, t1, 10
    ori     t1, t1, 0x4B             # V=1,R=1,W=0,X=1,U=0,G=0,A=1,D=0
    la      t2, l0_table
    addi    t2, t2, 32               # index 4 * 8 bytes
    sd      t1, 0(t2)

    # ---- L0[vpn0=5] -> leaf, s_mode_data's own real PA (data page) ----
    la      t0, s_mode_data
    srli    t1, t0, 12
    slli    t1, t1, 10
    ori     t1, t1, 0xC7             # V=1,R=1,W=1,X=0,U=0,G=0,A=1,D=1
    la      t2, l0_table
    addi    t2, t2, 40               # index 5 * 8 bytes
    sd      t1, 0(t2)

    # ---- activate Sv39 ----
    la      t0, l2_table
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1               # t0 = satp: MODE=8, PPN=l2_table's own real PPN
    csrw    satp, t0
    sfence.vma

    # ---- bootstrap M -> S ----
    li      t0, 1
    slli    t0, t0, 11
    csrw    mstatus, t0              # mstatus.MPP = S

    la      t0, s_mode_target
    slli    t1, t0, 52
    srli    t1, t1, 52               # t1 = s_mode_target's own real page offset

    li      t2, 1
    slli    t2, t2, 30               # vpn2=1
    li      t3, 2
    slli    t3, t3, 21               # vpn1=2
    li      t4, 4
    slli    t4, t4, 12               # vpn0=4
    or      t2, t2, t3
    or      t2, t2, t4
    or      t2, t2, t1               # t2 = translated VA of s_mode_target
    csrw    mepc, t2

    mret

    # ---- Defensive fallback: ANY unexpected trap (medeleg==0, so every
    # cause from either privilege level lands here) marks s4/s5 and
    # halts immediately -- a real bug shows up as a distinct marker
    # instead of a silent hang or a retry that masks the real failure.
m_fallback_handler:
    li      s4, 1
    csrr    s5, mcause
    ebreak

    # ---- The translated S-mode target -- real, toolchain-assembled
    # code, reached ONLY through a genuine 3-level Sv39 fetch-side walk.
s_mode_target:
    li      s1, 0xAA                 # marker: real S-mode fetch-translated code is running

    la      t0, s_mode_data
    slli    t1, t0, 52
    srli    t1, t1, 52               # t1 = s_mode_data's own real page offset

    li      t2, 1
    slli    t2, t2, 30               # vpn2=1 (same L1/L0 pair main built)
    li      t3, 2
    slli    t3, t3, 21               # vpn1=2
    li      t4, 5
    slli    t4, t4, 12               # vpn0=5
    or      t2, t2, t3
    or      t2, t2, t4
    or      t2, t2, t1               # t2 = translated VA of s_mode_data

    li      t5, 0x12345678
    sd      t5, 0(t2)                # STORE through the mem-side walker
    ld      s2, 0(t2)                # LOAD through the mem-side walker (round trip)

    li      s3, 0xC0FFEE             # final marker: the whole S-mode sequence completed
    ebreak

    # ---- Reserved page-table/data regions -- deliberately placed in
    # .data, NOT .bss, even though their whole point is to start out
    # zero. crt0.s's own zero_bss loop zeroes .bss ONE BYTE PER
    # ITERATION (see that file's own header -- it has no memset-style
    # bulk clear); a naive `.section .bss` reservation here (three
    # 4KB-aligned page-table pages + a data page, ~12KB total) would
    # make that loop alone cost on the order of 100,000+ simulated
    # cycles, blowing past every timeout tier this project uses, PURELY
    # as a self-inflicted artifact of section choice -- not anything
    # about Sv39 itself. `.data` sidesteps this entirely: `.zero N`
    # here emits real, explicit zero BYTES into the linked image (loaded
    # by $readmemh like any other program content, and redundant with--
    # but harmless alongside--wb4_sram.sv's own time-0 zero-fill of
    # every word before that load), so crt0's zero loop never touches
    # this region at all; the loop's own (tiny) real .bss span is
    # whatever main()'s own local scratch needs, none here.
    .section .data
    .align 12
l2_table:
    .zero 4096
    .align 12
l1_table:
    .zero 4096
    .align 12
l0_table:
    .zero 4096
    .align 12
s_mode_data:
    .zero 8
