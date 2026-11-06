# probe_fd.S -- pins Sail's F/D rules that the RTL must copy (run_probes.py runs it and prints a table).
#
# Every probe starts with `li x31, <id>`; its observations are written to x28-x30 (explicit CSR reads and fmv.x.d, so
# nothing depends on what Sail's trace prints for implicit state). A trap writes its mcause to x27 and skips the
# instruction. The trap handler uses no FP.
#
# Probes 1x: reset values and misa. 2x: when mstatus.FS becomes Dirty (FS set to Clean before each).
# 3x: rounding-mode and field legality. 4x: NaN boxing. 5x: FS=Off. 6x: SD, sstatus view, fcsr field widths.

    .option norvc
    .section .text
    .globl _start
_start:
    la      t0, trap
    csrw    mtvec, t0
    la      sp, scratch

# --- 1x: reset values -----------------------------------------------------------------------------------------------
    li      x31, 10
    csrr    x30, mstatus
    csrr    x29, misa
    li      x31, 11                 # an FP op at reset: traps if FS resets Off
    fmv.x.d x30, f0
    li      x31, 12                 # FS -> Initial, then the reset fcsr and f0/f1
    li      t0, 0x2000
    csrs    mstatus, t0
    csrr    x30, fcsr
    fmv.x.d x29, f0
    fmv.x.d x28, f1
    li      t0, 0x6000              # FS fully on for the setup below
    csrs    mstatus, t0
    fld     f10, 0(sp)              # f10 = 1.0
    fld     f11, 8(sp)              # f11 = 1.5
    fld     f12, 16(sp)             # f12 = sNaN (double)
    fld     f13, 24(sp)             # f13 = 0x3F800000 unboxed (1.0f without the box)

    .macro CLEAN
    li      t0, 0x6000
    csrc    mstatus, t0
    li      t0, 0x4000
    csrs    mstatus, t0
    .endm
    .macro FSREAD
    csrr    x30, mstatus
    srli    x30, x30, 13
    andi    x30, x30, 3
    .endm

# --- 2x: Dirty (x30 = FS after the op; 3 = Dirty, 2 = still Clean) ---------------------------------------------------
    li      x31, 20                 # FPR write
    CLEAN
    fadd.d  f1, f10, f10
    FSREAD
    li      x31, 21                 # FP -> int, no flag
    CLEAN
    fmv.x.d x5, f10
    FSREAD
    li      x31, 22                 # FP store
    CLEAN
    fsd     f10, 32(sp)
    FSREAD
    li      x31, 23                 # FP load
    CLEAN
    fld     f1, 0(sp)
    FSREAD
    li      x31, 24                 # feq of an sNaN with NV already set: fflags does not change
    csrwi   fflags, 0x10
    CLEAN
    feq.d   x5, f12, f12
    FSREAD
    csrr    x29, fflags
    li      x31, 25                 # feq of an sNaN with fflags clear: NV raised
    csrwi   fflags, 0
    CLEAN
    feq.d   x5, f12, f12
    FSREAD
    csrr    x29, fflags
    li      x31, 26                 # csrr fflags
    CLEAN
    csrr    x5, fflags
    FSREAD
    li      x31, 27                 # csrw fflags with the value it already has
    csrwi   fflags, 0
    CLEAN
    csrwi   fflags, 0
    FSREAD
    li      x31, 28                 # csrs fflags, x0 (no write)
    CLEAN
    csrs    fflags, x0
    FSREAD
    li      x31, 29                 # fclass, no flags
    CLEAN
    fclass.d x5, f10
    FSREAD
    li      x31, 30                 # fcvt.w.d 1.5 with NX clear: NX raised, int rd
    csrwi   fflags, 0
    CLEAN
    fcvt.w.d x5, f11, rtz
    FSREAD
    csrr    x29, fflags
    li      x31, 31                 # flt of numbers, no flags, int rd
    CLEAN
    flt.d   x5, f10, f11
    FSREAD
    li      x31, 32                 # fsrm (writes frm)
    CLEAN
    fsrm    x0
    FSREAD
    li      x31, 33                 # csrw frm with the same value
    csrwi   frm, 0
    CLEAN
    csrwi   frm, 0
    FSREAD

# --- 3x: legality (x27 = cause 2 if illegal; x30 = result when legal) -------------------------------------------------
    li      t0, 0x6000
    csrs    mstatus, t0
    li      x31, 40                 # fadd.d with static rm = 5
    .insn r 0x53, 5, 0x01, x1, x10, x10      # rd/rs as f-regs by number: f1 = f10 + f10
    li      x31, 41                 # fadd.d rm = dyn with frm = 5
    csrwi   frm, 5
    .insn r 0x53, 7, 0x01, x1, x10, x10
    csrwi   frm, 0
    li      x31, 42                 # fcvt.d.w (exact) with static rm = 5
    .insn r 0x53, 5, 0x69, x1, x5, x0
    li      x31, 43                 # fcvt.d.s (exact) with static rm = 5
    .insn r 0x53, 5, 0x21, x1, x10, x0
    li      x31, 44                 # fcvt.d.w rm = dyn with frm = 7
    csrwi   frm, 7
    .insn r 0x53, 7, 0x69, x1, x5, x0
    csrwi   frm, 0
    li      x31, 45                 # fsgnj.d funct3 = 3 (reserved)
    .insn r 0x53, 3, 0x11, x1, x10, x10
    li      x31, 46                 # fmv.x.d funct3 = 2 (reserved)
    .insn r 0x53, 2, 0x71, x5, x10, x0
    li      x31, 47                 # fmin.d funct3 = 2 (reserved)
    .insn r 0x53, 2, 0x15, x1, x10, x10
    li      x31, 48                 # fsqrt.d with rs2 = 1 (reserved)
    .insn r 0x53, 0, 0x2D, x1, x10, x1
    li      x31, 49                 # fadd with fmt = 2 (H, Zfh off)
    .insn r 0x53, 0, 0x02, x1, x10, x10
    li      x31, 50                 # fmadd with fmt = 3 (Q)
    .insn r4 0x43, 0, 3, x1, x10, x10, x10
    li      x31, 51                 # fmv.d.x with rs2 = 1 (reserved)
    .insn r 0x53, 0, 0x79, x1, x5, x1
    li      x31, 52                 # fcvt.w.d with rm = 6 (rounds: reserved)
    .insn r 0x53, 6, 0x61, x5, x10, x0
    li      x31, 53                 # feq.d funct3 = 3 (reserved)
    .insn r 0x53, 3, 0x51, x5, x10, x10
    li      x31, 54                 # fcvt.s.d with rs2 = 2 (reserved)
    .insn r 0x53, 0, 0x20, x1, x10, x2
    li      x31, 55                 # fclass.d with rs2 = 1 (reserved)
    .insn r 0x53, 1, 0x71, x5, x10, x1

# --- 4x: NaN boxing (x30 = fmv.x.d of the result, or the int result) --------------------------------------------------
    li      x31, 60                 # fmv.w.x boxes
    li      t0, 0x3F800000
    fmv.w.x f1, t0
    fmv.x.d x30, f1
    li      x31, 61                 # fadd.s on an unboxed operand
    fadd.s  f1, f13, f13
    fmv.x.d x30, f1
    li      x31, 62                 # fsgnj.s with an unboxed rs1
    fsgnj.s f1, f13, f10
    fmv.x.d x30, f1
    li      x31, 63                 # fmv.x.w of an unboxed value
    fmv.x.w x30, f13
    li      x31, 64                 # fsw of an unboxed value, read back
    fsw     f13, 40(sp)
    lwu     x30, 40(sp)
    li      x31, 65                 # fclass.s of an unboxed value
    fclass.s x30, f13
    li      x31, 66                 # flw boxes
    flw     f1, 40(sp)
    fmv.x.d x30, f1
    li      x31, 67                 # fcvt.d.s of an unboxed value
    fcvt.d.s f1, f13
    fmv.x.d x30, f1
    li      x31, 68                 # fmin.s(unboxed, 1.0f): the unboxed operand reads as the canonical NaN; flags
    csrwi   fflags, 0
    flw     f2, 44(sp)              # 1.0f boxed
    fmin.s  f1, f13, f2
    fmv.x.d x30, f1
    csrr    x29, fflags
    li      x31, 69                 # fmax.d(sNaN, 1.0): NV and the number
    csrwi   fflags, 0
    fmax.d  f1, f12, f10
    fmv.x.d x30, f1
    csrr    x29, fflags
    li      x31, 70                 # fmin.d(+0, -0) and fmin.d(-0, +0)
    fmv.d.x f1, x0
    fneg.d  f2, f1
    fmin.d  f3, f1, f2
    fmv.x.d x30, f3
    fmin.d  f3, f2, f1
    fmv.x.d x29, f3
    li      x31, 71                 # fcvt.wu.d of 2^31 + 0.5 (fits unsigned 32): sign-extended result
    fld     f1, 48(sp)
    csrwi   fflags, 0
    fcvt.wu.d x30, f1, rtz
    csrr    x29, fflags
    li      x31, 72                 # fcvt.w.d of NaN and of -inf
    fcvt.w.d x30, f12, rtz
    fld     f1, 56(sp)
    fcvt.w.d x29, f1, rtz

# --- 5x: FS = Off --------------------------------------------------------------------------------------------------
    li      t0, 0x6000
    csrc    mstatus, t0
    li      x31, 80                 # fadd.d
    fadd.d  f1, f10, f10
    li      x31, 81                 # csrr fcsr
    csrr    x30, fcsr
    li      x31, 82                 # csrr frm
    csrr    x30, frm
    li      x31, 83                 # flw
    flw     f1, 40(sp)
    li      x31, 84                 # fsd
    fsd     f1, 40(sp)
    li      x31, 85                 # fmv.x.d
    fmv.x.d x30, f1
    li      x31, 86                 # c.fld
    .option rvc
    c.fld   f8, 0(x8)
    c.nop                           # keeps what follows 4-byte aligned (norvc cannot pad 2 bytes)
    .option norvc
    li      x31, 87                 # mstatus readable, FS = 0
    csrr    x30, mstatus

# --- 6x: SD, sstatus, fcsr widths -------------------------------------------------------------------------------------
    li      x31, 90                 # FS = Dirty: mstatus and sstatus (SD is bit 63)
    li      t0, 0x6000
    csrs    mstatus, t0
    csrr    x30, mstatus
    csrr    x29, sstatus
    li      x31, 91                 # FS = Initial: SD clear
    li      t0, 0x4000
    csrc    mstatus, t0
    csrr    x30, mstatus
    csrr    x29, sstatus
    li      x31, 92                 # sstatus.FS is writable
    li      t0, 0x6000
    csrs    sstatus, t0
    csrr    x30, mstatus
    li      x31, 93                 # csrw fcsr, -1
    li      t0, -1
    csrw    fcsr, t0
    csrr    x30, fcsr
    csrr    x29, frm
    csrr    x28, fflags
    li      x31, 94                 # csrw frm, -1 and fflags, -1
    csrw    frm, t0
    csrr    x30, frm
    csrw    fflags, t0
    csrr    x29, fflags
    csrr    x28, fcsr
    li      x31, 95                 # misa again with FS on (no change expected)
    csrr    x30, misa

    li      x31, 99
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
1:  j       1b

# The handler: x27 = mcause, skip the instruction by its length.
    .balign 4
trap:                               # uses s1-s3 only (x29-x31 are the probe registers)
    csrr    x27, mcause
    csrr    s1, mepc
    lhu     s2, 0(s1)
    andi    s2, s2, 3
    li      s3, 3
    addi    s1, s1, 2
    bne     s2, s3, 2f
    addi    s1, s1, 2
2:  csrw    mepc, s1
    mret

    .section .data
    .balign 8
scratch:
    .dword 0x3FF0000000000000       #  0: 1.0
    .dword 0x3FF8000000000000       #  8: 1.5
    .dword 0x7FF4000000000000       # 16: sNaN
    .dword 0x000000003F800000       # 24: 1.0f, not boxed
    .dword 0                        # 32: store target
    .word  0                        # 40: fsw target
    .word  0x3F800000               # 44: 1.0f
    .dword 0x41E0000000100000       # 48: 2^31 + 0.5
    .dword 0xFFF0000000000000       # 56: -inf
    .balign 8
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
