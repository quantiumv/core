# Running your own program

`make run` builds a bare-metal C/assembly program and runs it on the full
SoC (`design/soc.sv`) in simulation, with UART output on the console.

Run it from WSL bash at the repo root. It needs `riscv64-unknown-elf-gcc`
and Icarus Verilog.

```
make run PROG=verification/run/examples/hello.c
make run PROG="main.c util.c start.S" CORE=pipe TRACE=1 CYCLES=50000000
```

| Option | Meaning |
|---|---|
| `PROG` | One or more `.c`/`.s`/`.S` files. They are linked after `firmware/crt0.s`, which sets `sp`, zeroes `.bss`, calls `main`, then executes `ebreak`. |
| `CORE` | `fsm` (default) is `design/core.sv`. `ref` is the frozen reference core. `pipe` is `design/pipe/core_pipe.sv`. |
| `TRACE=1` | Also writes `trace.log`, with one line per retired instruction (pc, instruction, rd, memory access). Traces from two cores can be diffed with `verification/pipe/cmp_rvfi.py`. |
| `CYCLES` | Simulation budget. The default is 10,000,000. |

Build outputs go to `/tmp/qv_run_<core>/`:
- `prog.elf`
- `prog.lst` (the disassembly)
- `prog.hex`
- `trace.log`

The run ends in one of three ways:
- **ebreak:** `main` returned. The run prints the cycle count, the number of instructions retired, and the exit code, which is `main`'s return value.
- **unhandled trap:** cause, pc and tval are printed. This happens when the program traps without having installed its own `mtvec`; otherwise the trap would silently restart the program.
- **TIMEOUT**

## The machine

The core starts at pc 0 in M-mode, with no trap handler installed.

| Region | Address |
|---|---|
| RAM | `0x0000_0000`–`0x03FF_FFFF` (64 MB; stack at the top) |
| UART (NS16550A) | `0x0400_8000`. THR is at +0 and LSR at +5. |
| CLINT | `0x0401_0000` |
| PLIC | `0x0440_0000` |

Supported ISA, per core:
- `fsm` and `ref`: RV64IMAC + Zicsr + Zifencei, M/S/U modes, Sv39 and PMP.
- `pipe`: RV64I, multiply, RVC, Zicsr and Zifencei, in M-mode only. It has no divider yet, so programs are built for rv64ic and libgcc does `*`, `/` and `%` in software. The build refuses any `div`/`rem` instruction.

## Limits

There is no libc: no `printf`, no `malloc`, no file I/O. Use
`verification/run/qv_io.h` instead:
- `qv_putc`
- `qv_puts`
- `qv_puthex`
- `qv_putdec`

The build links libgcc, so 64-bit integer arithmetic works everywhere.
Floating point also builds (in software, through libgcc), but it is slow.

## How it works

`verification/run/run_prog.sh` does the work:
1. It compiles with `-O2 -ffreestanding -nostdlib`.
2. It links with `verification/run/link.ld`, which places gcc's small-data sections inside the image.
3. It runs `testbench/run_soc_tb.sv`, which loads the image into `soc.sv`'s RAM through `+HEXFILE`.
