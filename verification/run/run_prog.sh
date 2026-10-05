#!/bin/bash
# run_prog.sh -- build a bare-metal program and run it on the full SoC
# (design/soc.sv) in simulation. Behind `make run`; run under WSL bash,
# any cwd.
#
#   run_prog.sh [--core fsm|ref|pipe] [--trace] [--cycles N] [--out DIR] SRC...
#
# SRC: one or more .c/.s/.S files, linked after firmware/crt0.s (sets sp,
# zeroes .bss, calls main, then EBREAK ends the run) with
# verification/run/link.ld. No libc; verification/run/qv_io.h prints
# through the UART. libgcc is linked, so * / % work on every core: for
# core_pipe (no divider yet) the program is built for rv64ic and libgcc
# does the arithmetic.
#
# --core   fsm: design/core.sv (default); ref: the frozen reference;
#          pipe: design/pipe/core_pipe.sv
# --trace  also write OUT/trace.log, one line per retired instruction
# --cycles simulation budget (default 10000000)
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$(pwd)

CORE=fsm; TRACE=0; CYCLES=10000000; OUT=""; SRCS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --core)   CORE=$2; shift 2 ;;
        --trace)  TRACE=1; shift ;;
        --cycles) CYCLES=$2; shift 2 ;;
        --out)    OUT=$2; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  SRCS+=("$(realpath "$1")"); shift ;;
    esac
done
[ ${#SRCS[@]} -gt 0 ] || { echo "usage: run_prog.sh [--core fsm|ref|pipe] [--trace] [--cycles N] SRC..." >&2; exit 2; }

case "$CORE" in
    fsm)  LIST=design_files.list;      DEF="";                 MARCH=rv64imac_zicsr_zifencei ;;
    ref)  LIST=ref_design_files.list;  DEF="-DQV_REF_AS_CORE";  MARCH=rv64imac_zicsr_zifencei ;;
    pipe) LIST=pipe_design_files.list; DEF="-DQV_PIPE_AS_CORE"; MARCH=rv64ic_zicsr_zifencei ;;
    *) echo "unknown core: $CORE (expected fsm, ref or pipe)" >&2; exit 2 ;;
esac
[ -n "$OUT" ] || OUT="/tmp/qv_run_${CORE}"
mkdir -p "$OUT"

# ---------------- build ----------------
CC=riscv64-unknown-elf-gcc
CFLAGS=(-march=$MARCH -mabi=lp64 -mno-relax -ffreestanding -nostdlib -O2 -Wall -I "$REPO/verification/run")
OBJS=("$OUT/crt0.o")
$CC "${CFLAGS[@]}" -c "$REPO/firmware/crt0.s" -o "$OUT/crt0.o" || exit 1
for src in "${SRCS[@]}"; do
    obj="$OUT/$(basename "${src%.*}").o"
    $CC "${CFLAGS[@]}" -c "$src" -o "$obj" || exit 1
    OBJS+=("$obj")
done
$CC "${CFLAGS[@]}" -T "$REPO/verification/run/link.ld" -Wl,--no-warn-rwx-segments -o "$OUT/prog.elf" "${OBJS[@]}" -lgcc || exit 1
riscv64-unknown-elf-objdump -d "$OUT/prog.elf" > "$OUT/prog.lst"
riscv64-unknown-elf-objcopy -O verilog -j .text -j .rodata -j .data --verilog-data-width=8 \
    "$OUT/prog.elf" "$OUT/prog.hex" || exit 1
if [ "$CORE" == "pipe" ] && grep -qE $'\t(div|rem)[uw]*\t' "$OUT/prog.lst"; then
    echo "error: the build contains div/rem, which core_pipe can't execute yet (see $OUT/prog.lst)" >&2
    exit 1
fi
echo "built $OUT/prog.elf ($(riscv64-unknown-elf-size "$OUT/prog.elf" | awk 'NR==2 {print $4}') bytes; listing in prog.lst)"

# ---------------- simulate ----------------
FILES=$(grep -vE '^\s*(#|$)' "verification/regress/$LIST" | sed "s#^#$REPO/#")
TRACEDEF=""; TRACEARG=()
[ "$TRACE" == "1" ] && { TRACEDEF="-DRISCV_FORMAL"; TRACEARG=(+TRACE="$OUT/trace.log"); }
# shellcheck disable=SC2086
if ! iverilog -g2012 $DEF $TRACEDEF -I design -I design/defaults -I testbench -I verification/reference \
        -o "$OUT/sim.vvp" $FILES testbench/run_soc_tb.sv > "$OUT/build.log" 2>&1; then
    grep -v "sorry: constant selects" "$OUT/build.log" | head -20
    exit 1
fi
echo "running on core=$CORE ..."
# from design/: wb4_sram's own startup load is "../firmware/crt0.hex"
(cd design && vvp -n "$OUT/sim.vvp" +HEXFILE="$OUT/prog.hex" +MAX_CYCLES="$CYCLES" "${TRACEARG[@]}")
[ "$TRACE" == "1" ] && echo "trace: $OUT/trace.log"
exit 0
