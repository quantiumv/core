#!/bin/bash
# run_rvfi_diff.sh -- P4a bring-up gate: run testbench/rvfi_tracer.sv
# against design/core.sv and against design/pipe/core_pipe.sv (built as
# `core` via -DQV_PIPE_AS_CORE) on gen_alu.py programs, and compare the
# two retirement streams with cmp_rvfi.py.
#
# Stands in for the lockstep harness until core_pipe can run its corpus
# (that needs memory and CSRs). Run from WSL, any cwd.
#
#   run_rvfi_diff.sh [--seeds N] [--first S] [--len L]
#                    [--serialize 0|1] [--bypass 0|1]
#
# Prints one PASS/FAIL line per seed, then RVFI_DIFF_SUMMARY. Logs for
# failing seeds stay in verification/pipe/.results/.
set -u
cd "$(dirname "$0")/../.."
REPO=$(pwd)

SEEDS=20; FIRST=1; LEN=400; SER=0; BYP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --seeds)     SEEDS=$2; shift 2 ;;
        --first)     FIRST=$2; shift 2 ;;
        --len)       LEN=$2; shift 2 ;;
        --serialize) SER=$2; shift 2 ;;
        --bypass)    BYP=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$SER$BYP" in
    00|01|10|11) ;;
    *) echo "--serialize and --bypass take 0 or 1" >&2; exit 2 ;;
esac

OUT="$REPO/verification/pipe/.results"
mkdir -p "$OUT"
TAG="s${SER}b${BYP}"
REF_VVP="$OUT/ref.vvp"
DUT_VVP="$OUT/pipe_$TAG.vvp"

REF_FILES="decoder.sv alu.sv c_expand.sv core.sv csr_file.sv divider.sv register_file.sv wb4_sram.sv wb_arbiter2.sv"
PIPE_FILES="decoder.sv c_expand.sv pipe/qv_pkg.sv pipe/qv_fetch.sv pipe/qv_align.sv pipe/qv_fifo.sv pipe/qv_decode.sv
            pipe/qv_issue.sv pipe/qv_rob.sv pipe/qv_exu_alu.sv pipe/qv_exu_bru.sv pipe/qv_lsu.sv pipe/qv_commit.sv pipe/core_pipe.sv
            alu.sv register_file.sv csr_file.sv wb4_sram.sv wb_arbiter2.sv"

build() {
    local out=$1; shift
    if ! (cd design && iverilog -g2012 -DRISCV_FORMAL -I . -I defaults "$@" -o "$out" ../testbench/rvfi_tracer.sv) \
            > "$out.log" 2>&1; then
        echo "BUILD FAILED: $out"; grep -v "sorry: constant selects" "$out.log" | head -20; exit 1
    fi
}
# shellcheck disable=SC2086
build "$REF_VVP" $REF_FILES
# shellcheck disable=SC2086
build "$DUT_VVP" -DQV_PIPE_AS_CORE -DQV_PIPE_SERIALIZE=$SER -DQV_PIPE_BYPASS_EN=$BYP $PIPE_FILES

pass=0; fail=0
for ((s = FIRST; s < FIRST + SEEDS; s++)); do
    base="$OUT/alu_$s"
    read -r n dyn < <(python3 verification/pipe/gen_alu.py --seed "$s" --len "$LEN" -o "$base.s") || exit 1
    riscv64-unknown-elf-as -march=rv64imc_zicsr_zifencei -mabi=lp64 -mno-relax "$base.s" -o "$base.o" &&
    riscv64-unknown-elf-ld -T verification/lockstep/gen/link.ld -o "$base.elf" "$base.o" &&
    riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.sandbox \
        --verilog-data-width=8 "$base.elf" "$base.hex" || exit 1

    # 0x80000 is never written, so the tracer runs to its cycle limit.
    # Both cores average a few cycles per instruction (core_pipe more on
    # taken branches); a limit that turns out too tight shows up as an
    # "unfinished" FAIL, never a silent pass.
    timeout=$((dyn * 12 + 1000))
    vvp -n "$REF_VVP" +HEXFILE="$base.hex" +TOHOST_ADDR=80000 +TIMEOUT=$timeout > "$base.ref.log" 2>&1
    vvp -n "$DUT_VVP" +HEXFILE="$base.hex" +TOHOST_ADDR=80000 +TIMEOUT=$timeout > "$base.$TAG.log" 2>&1
    end=$(riscv64-unknown-elf-nm "$base.elf" | awk '$3 == "end_of_test" {print $1}')
    res=$(python3 verification/pipe/cmp_rvfi.py "$base.ref.log" "$base.$TAG.log" "$end")
    if echo "$res" | tail -1 | grep -q "PASS"; then
        pass=$((pass + 1)); echo "seed $s: PASS ($(echo "$res" | tail -1 | sed 's/.*n=//') retirements)"
        rm -f "$base".*
    else
        fail=$((fail + 1)); echo "seed $s: FAIL"; echo "$res" | sed 's/^/    /'
    fi
done
echo "RVFI_DIFF_SUMMARY ($TAG len=$LEN): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
