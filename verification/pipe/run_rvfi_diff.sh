#!/bin/bash
# run_rvfi_diff.sh -- P4a bring-up gate: run testbench/rvfi_tracer.sv
# against the frozen reference core (verification/reference/ref_core.sv,
# built as `core` via -DQV_REF_AS_CORE) and against the pipelined core
# (design/pipe/core.sv) on gen_alu.py programs, and compare the two
# retirement streams with cmp_rvfi.py.
#
# A quick smoke gate next to the lockstep harness (no bus delay, no
# interrupts, one program at a time). Run from WSL, any cwd.
#
#   run_rvfi_diff.sh [--seeds N] [--first S] [--len L]
#                    [--serialize 0|1] [--bypass 0|1] [--no-div] [--no-amo] [--pipe-dir DIR] [--defines "A=1 B=0"]
#
# --pipe-dir builds the pipelined core from a copy of design/pipe/ (for mutants);
# --defines passes preprocessor defines to both builds (the QV_PIPE_* feature knobs, which the reference ignores,
# and QV_FPU_EN, which both cores read), and puts a hash of them in the build name;
# --outdir keeps concurrent runs apart.
#
# Prints one PASS/FAIL line per seed, then RVFI_DIFF_SUMMARY. Logs for
# failing seeds stay in verification/pipe/.results/.
set -u
cd "$(dirname "$0")/../.."
REPO=$(pwd)

SEEDS=20; FIRST=1; LEN=400; SER=0; BYP=1; GEN_ARGS=""; PIPE_DIR="$REPO/design/pipe"; DEFS=""
OUT="$REPO/verification/pipe/.results"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-div)    GEN_ARGS="$GEN_ARGS --no-div"; shift ;;
        --no-amo)    GEN_ARGS="$GEN_ARGS --no-amo"; shift ;;
        --pipe-dir)  PIPE_DIR=$(cd "$2" && pwd); shift 2 ;;
        --outdir)    OUT=$2; shift 2 ;;
        --seeds)     SEEDS=$2; shift 2 ;;
        --first)     FIRST=$2; shift 2 ;;
        --len)       LEN=$2; shift 2 ;;
        --serialize) SER=$2; shift 2 ;;
        --bypass)    BYP=$2; shift 2 ;;
        --defines)   DEFS=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$SER$BYP" in
    00|01|10|11) ;;
    *) echo "--serialize and --bypass take 0 or 1" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
TAG="s${SER}b${BYP}"
DEF_FLAGS=""
DTAG=""
if [ -n "$DEFS" ]; then
    for d in $DEFS; do DEF_FLAGS="$DEF_FLAGS -D$d"; done
    DTAG="_$(echo "$DEFS" | sha1sum | cut -c1-6)"
    TAG="${TAG}${DTAG}"
fi
REF_VVP="$OUT/ref${DTAG}.vvp"
DUT_VVP="$OUT/pipe_$TAG.vvp"

# the reference: its seven files (ref_macros.svh is found through the include path), absolute paths, since the build runs from design/
REF_DIR=$REPO/verification/reference
REF_FILES="$REF_DIR/ref_alu.sv $REF_DIR/ref_decoder.sv $REF_DIR/ref_register_file.sv $REF_DIR/ref_csr_file.sv \
$REF_DIR/ref_divider.sv $REF_DIR/ref_c_expand.sv $REF_DIR/ref_core.sv $REPO/design/wb4_sram.sv $REPO/design/wb_arbiter2.sv"
# the pipelined core's own files come from the shared list (so a new module is added
# in one place); absolute paths, since the build runs from design/
PIPE_FILES="$(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
                  verification/regress/design_files.list \
                  | sed -e "s#^design/pipe/#$PIPE_DIR/#" -e "s#^design/#$REPO/design/#" | tr '\n' ' ') \
            $REPO/design/wb4_sram.sv $REPO/design/wb_arbiter2.sv"

build() {
    local out=$1; shift
    if ! (cd design && iverilog -g2012 -DRISCV_FORMAL -I . -I defaults "$@" -o "$out" ../testbench/rvfi_tracer.sv) \
            > "$out.log" 2>&1; then
        echo "BUILD FAILED: $out"; grep -v "sorry: constant selects" "$out.log" | head -20; exit 1
    fi
}
# shellcheck disable=SC2086
build "$REF_VVP" -DQV_REF_AS_CORE -I "$REF_DIR" $DEF_FLAGS $REF_FILES
# shellcheck disable=SC2086
build "$DUT_VVP" -DQV_PIPE_SERIALIZE=$SER -DQV_PIPE_BYPASS_EN=$BYP $DEF_FLAGS $PIPE_FILES

pass=0; fail=0
for ((s = FIRST; s < FIRST + SEEDS; s++)); do
    base="$OUT/alu_$s"
    read -r n dyn divs < <(python3 verification/pipe/gen_alu.py --seed "$s" --len "$LEN" $GEN_ARGS -o "$base.s") || exit 1
    riscv64-unknown-elf-as -march=rv64imac_zicsr_zifencei -mabi=lp64 -mno-relax "$base.s" -o "$base.o" &&
    riscv64-unknown-elf-ld -T verification/lockstep/gen/link.ld -o "$base.elf" "$base.o" &&
    riscv64-unknown-elf-objcopy -O verilog -j .text.entry -j .text.handlers -j .data.sandbox \
        --verilog-data-width=8 "$base.elf" "$base.hex" || exit 1

    # 0x80000 is never written, so the tracer runs to its cycle limit.
    # Both cores average a few cycles per instruction (the pipelined core more on
    # taken branches) plus ~70 per divide; a limit that turns out too tight
    # shows up as an "unfinished" FAIL, never a silent pass.
    timeout=$((dyn * 12 + divs * 90 + 1000))
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
