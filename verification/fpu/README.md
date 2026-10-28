# F/D verification support

This directory holds what the F/D (single- and double-precision floating point) work is checked against, outside
the cores themselves:

- the Sail probes that pin the rules the RTL copies (`probes/`);
- the Sail override that turns F, D and Zcd on (`sail_fd_override.json`, applied after
  `verification/lockstep/sail_config_override.json`);
- the TestFloat setup used for the FPU's unit vectors.

## Sail probes

`probes/probe_fd.S` is one bare-metal program, run on Sail by `probes/run_probes.py` (WSL, from the repo root). Each
probe writes its id to x31 and its observations to x28-x30, through explicit CSR reads and `fmv.x.d`. A trap writes
mcause to x27 and skips the instruction.

```
python3 verification/fpu/probes/run_probes.py         # the table
python3 verification/fpu/probes/run_probes.py --raw   # Sail's full trace
```

Results on Sail 0.10 (`a33475a`), 2026-10-28. These are the rules the RTL copies.

| Probe | What | Sail |
|---|---|---|
| 10 | mstatus and misa at reset | mstatus `0xA00000000` (**FS = 0, Off**); misa `0x800000000014112D` (A C D F I M S U) |
| 11 | an FP op at reset | illegal instruction (cause 2): FS resets Off |
| 12 | fcsr, f0 and f1 after FS on | all 0 |
| 20 | FPR write (fadd.d) | Dirty |
| 21 | FP to int, no flag raised (fmv.x.d) | stays Clean |
| 22 | FP store (fsd) | stays Clean |
| 23 | FP load (fld) | Dirty |
| 24 | feq.d of an sNaN with NV already set (fflags unchanged) | **stays Clean** |
| 25 | feq.d of an sNaN with fflags clear (NV raised) | Dirty |
| 26 | csrr fflags | stays Clean |
| 27 | csrw fflags with the value it already holds | **Dirty**: any CSR write counts, whatever the value |
| 28 | csrs fflags, x0 (no write) | stays Clean |
| 29 | fclass.d | stays Clean |
| 30 | fcvt.w.d raising NX | Dirty |
| 31 | flt.d of numbers, no flag | stays Clean |
| 32, 33 | fsrm, and csrw frm with the same value | Dirty |
| 40, 41 | fadd.d with static rm 5; rm = dyn with frm = 5 | illegal |
| 42, 43 | fcvt.d.w and fcvt.d.s (exact, never round) with static rm 5 | **illegal**: rm is checked even where it cannot matter |
| 44 | fcvt.d.w, rm = dyn with frm = 7 | illegal |
| 45-55 | reserved funct3 (fsgnj, fmv.x.d, fmin, feq), reserved rs2 (fsqrt, fmv.d.x, fcvt.s.d, fclass), fmt H or Q, fcvt.w.d with rm 6 | illegal |
| 60 | fmv.w.x | result boxed (`0xFFFFFFFF3F800000`) |
| 61 | fadd.s on an unboxed operand | canonical NaN, boxed (`0xFFFFFFFF7FC00000`) |
| 62 | fsgnj.s with an unboxed rs1 | canonical NaN, boxed: the box check applies to sign injection too |
| 63 | fmv.x.w of an unboxed value | low 32 bits, sign-extended (no box check) |
| 64 | fsw of an unboxed value | low 32 bits stored (no box check) |
| 65 | fclass.s of an unboxed value | `0x200` (quiet NaN) |
| 66 | flw | result boxed |
| 67 | fcvt.d.s of an unboxed value | canonical double NaN `0x7FF8000000000000` |
| 68 | fmin.s(unboxed, 1.0f) | 1.0f, no flag (the canonical NaN is quiet) |
| 69 | fmax.d(sNaN, 1.0) | 1.0, NV |
| 70 | fmin.d(+0, -0) both ways | -0 |
| 71 | fcvt.wu.d of 2^31 + 0.5, rtz | `0xFFFFFFFF80000000` (the 32-bit result sign-extended), NX |
| 72 | fcvt.w.d of NaN; of -inf | `0x7FFFFFFF`; `0xFFFFFFFF80000000` |
| 80-86 | FS Off: fadd.d, csrr fcsr, csrr frm, flw, fsd, fmv.x.d, c.fld | all illegal |
| 87 | mstatus with FS Off | readable |
| 90 | FS = Dirty | mstatus bit 63 (SD) set; sstatus `0x8000000200006000` (SD and FS in the view) |
| 91 | FS = Initial | SD clear |
| 92 | FS written through sstatus | takes effect |
| 93 | csrw fcsr, -1 | fcsr `0xFF`, frm 7, fflags `0x1F` (frm keeps the reserved value 7) |
| 94 | csrw frm, -1; csrw fflags, -1 | frm 7, fflags `0x1F`, fcsr `0xFF` |

Dirty, therefore, is set:
- by any write to an FPR;
- by an fflags accrual that changes fflags;
- by any CSR-instruction write to fflags, frm or fcsr.

It is not set by FP stores, by FP-to-int ops that raise no new flag, or by CSR reads.

Sail's trace prints implicit state changes as lines of their own: `f<N> <- …` for an FPR write, `CSR fflags (0x001)
<- …` for every accrual (even an unchanged one), and `CSR mstatus (0x300) <- …` when FS becomes Dirty.

## TestFloat

TestFloat 3e (`github.com/ucb-bar/berkeley-testfloat-3`, commit `a9c849f`) is built in WSL at `~/fp-tools/testfloat`,
against a SoftFloat 3e built with `SPECIALIZE_TYPE=RISCV` at `~/fp-tools/softfloat`. That SoftFloat is a copy of
Whisper's `third_party/softfloat`; `build/Linux-x86_64-GCC` was rebuilt for the host. The RISC-V specialization
gives the RISC-V answers: canonical NaN `7FC00000` / `7FF8000000000000`, a NaN converted to int is `7FFFFFFF`, and a
negative value to an unsigned int is 0 with NV. The flags column uses SoftFloat's order (NX 1, UF 2, OF 4, DZ 8,
NV 16), which is the fflags order.

Case counts per function and rounding mode (`testfloat_gen -level N <function> | wc -l`):

| Function | Level 1 | Level 2 |
|---|---|---|
| f32 add, sub, mul, div, eq, lt, le | 46,464 | 7,496,192 |
| f64 add, sub, mul, div, eq, lt, le | 46,464 | 40,284,288 |
| f32_mulAdd | 6,133,248 | more than 124M (stopped at 60 s) |
| f64_mulAdd | 6,133,248 | more than 79M (stopped at 60 s) |
| f32 sqrt, f32 to int/f64 | 600 | 8,800 |
| f64 sqrt, f64 to int/f32 | 768 | 26,112 |
| int to f32/f64 | 756 | 63,756 |

What TestFloat doesn't generate gets its own golden model (`gen_vectors.py`), checked against Sail: sign injection,
min/max (with -0 < +0 and the NaN rules), classify, the moves, NaN-boxing of single-precision inputs, and the RV64
sign extension of 32-bit integer results.

## Vectors

`gen_vectors.py` writes architectural vectors, one case per line, all fields hex:

```
insn frm a b c result flags
```

- `insn` is the instruction itself: rd = 4, rs1 = 1, rs2 = 2, rs3 = 3, and its rm field (7 means dynamic).
- `frm` is the dynamic rounding mode.
- `a`, `b`, `c` are the 64-bit register values of the sources: singles NaN-boxed, an integer source in x1 with junk in
  the upper half for the 32-bit conversions.
- `result` is the 64-bit value written to rd; `flags` is what the instruction raises.

A testbench decodes `insn` with the same decoder the core uses, so the vectors don't depend on how the FPU encodes
its ops internally.

Sources:
- TestFloat cases for every function TestFloat has: add, sub, mul, div, sqrt; the four FMA forms, with inputs
  negated as Sail and Spike do (FNMADD is `mulAdd(-a, b, -c)`); eq, lt, le; every conversion. They come in all five
  rounding modes, and a quarter of them through rm = dyn.
- `--unboxed`: each such case again with every single-precision quiet-NaN operand replaced by an unboxed pattern.
- The golden-model cases for the rest.

`check_vectors_sail.py` replays a vector file on Sail: a table of operands and one stub per vector. A sampled set of
260,511 vectors (`--level 1 --sample 2000 --unboxed --golden 20000`, every function and rounding mode) matches Sail
exactly. As a negative control, a copy with three corrupted vectors (a result bit, a flag, a golden result) reports
exactly those three.

```
python3 verification/fpu/gen_vectors.py --level 1 --sample 2000 --unboxed -o /tmp/smoke.vec
python3 verification/fpu/check_vectors_sail.py /tmp/smoke.vec
```
