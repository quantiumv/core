#!/bin/bash
# Runs every self-checking ACT4 ELF generated for one DUT config (CONFIG, default
# quantiumv-rv64im; quantiumv-rv64imafdc adds A, F, D, Zcd and Zifencei) through
# testbench/act_runner_tb.sv and reports PASS/FAIL/TIMEOUT/UNKNOWN counts.
#
# Prerequisites: ELFs already generated via
#   CONFIG_FILES=verification/riscv-arch-test/$CONFIG/test_config.yaml \
#   WORKDIR=verification/riscv-arch-test/work make --jobs $(nproc)
# run from a riscv-arch-test checkout (see quantiumv-rv64im/test_config.yaml's
# header comment for the exact EXCLUDE_EXTENSIONS override needed to include
# Sm/S -- the framework's own Makefile default excludes both).
#
# Usage (from WSL): verification/riscv-arch-test/run_act_tests.sh [elf_dir]
# CORE=pipe|ref (default pipe) selects the core under test: the pipelined
# core (design/pipe/core.sv and the design/ leaves it uses, in
# design_files.list order) or the frozen multi-cycle reference
# (verification/reference/ref_core.sv + its ref_* leaves, P3.3) -- same
# env-var convention as CONFIG_FILES/WORKDIR above. ACT_ONLY=<regex> runs
# only the ELFs whose path matches. ACT_DEFINES="A=1 B" adds preprocessor
# defines to the build (QV_FPU_EN=1 for the F/D config). Results go to
# act_results.log for pipe, act_results_<core>.log otherwise, with the
# config's suffix (e.g. act_results_rv64imafdc_ref.log) for any config other
# than quantiumv-rv64im (ACT_RESULTS=<path> overrides, to keep the tracked
# log untouched). Both cores pass the same ELFs. (None of the generated tests
# turns Sv39 on, so ACT is only a Bare-mode regression check.)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${CONFIG:-quantiumv-rv64im}"
ELF_DIR="${1:-$REPO_ROOT/verification/riscv-arch-test/work/$CONFIG/elfs}"
HEX_DIR="/tmp/act_hex_$$"
VVP_BIN="/tmp/act_runner_tb_$$.vvp"
CORE="${CORE:-pipe}"
SUFFIX=""
[ "$CONFIG" == "quantiumv-rv64im" ] || SUFFIX="_${CONFIG#quantiumv-}"
[ "$CORE" == "pipe" ] || SUFFIX="${SUFFIX}_${CORE}"
RESULTS_LOG="$REPO_ROOT/verification/riscv-arch-test/act_results${SUFFIX}.log"
RESULTS_LOG="${ACT_RESULTS:-$RESULTS_LOG}"   # experiments: keep the tracked log untouched
ACT_ONLY="${ACT_ONLY:-}"
EXTRA_DEFINES=()
for d in ${ACT_DEFINES:-}; do EXTRA_DEFINES+=("-D$d"); done

if [ ! -d "$ELF_DIR" ]; then
    echo "ELF directory not found: $ELF_DIR" >&2
    exit 1
fi

mkdir -p "$HEX_DIR"
trap 'rm -rf "$HEX_DIR" "$VVP_BIN"' EXIT

case "$CORE" in
    ref)
        # the reference's private copies, from ref_design_files.list
        mapfile -t CORE_FILES < <(grep -E '^verification/reference/' \
            "$REPO_ROOT/verification/regress/ref_design_files.list" | sed "s#^#$REPO_ROOT/#")
        CORE_DEFINE=(-DQV_REF_AS_CORE)
        ;;
    pipe)
        # the pipelined core and the design/ leaves it uses, in design_files.list order
        mapfile -t CORE_FILES < <(grep -E '^design/(pipe/|decoder\.sv|alu\.sv|c_expand\.sv|csr_file\.sv|register_file\.sv|divider\.sv)' \
            "$REPO_ROOT/verification/regress/design_files.list" | sed "s#^#$REPO_ROOT/#")
        CORE_DEFINE=()
        ;;
    *)
        echo "Unknown CORE: $CORE (expected pipe or ref; the FSM core is ref)" >&2
        exit 1
        ;;
esac

echo "Compiling act_runner_tb.sv against the current core (CORE=$CORE, CONFIG=$CONFIG)..."
iverilog -g2012 "${CORE_DEFINE[@]}" "${EXTRA_DEFINES[@]}" -I "$REPO_ROOT/design" -I "$REPO_ROOT/testbench" \
    -I "$REPO_ROOT/design/defaults" -I "$REPO_ROOT/verification/reference" -o "$VVP_BIN" \
    "${CORE_FILES[@]}" "$REPO_ROOT/design/wb4_sram.sv" "$REPO_ROOT/design/wb_arbiter2.sv" \
    "$REPO_ROOT/testbench/act_runner_tb.sv"
if [ $? -ne 0 ]; then
    echo "COMPILE FAILED"
    exit 1
fi

PASS=0; FAIL=0; TIMEOUT=0; UNKNOWN=0; ERR=0
: > "$RESULTS_LOG"

elfs=()
while IFS= read -r -d '' f; do
    [ -z "$ACT_ONLY" ] || [[ "$f" =~ $ACT_ONLY ]] || continue
    elfs+=("$f")
done < <(find "$ELF_DIR" -iname "*.elf" -print0 | sort -z)
total=${#elfs[@]}
if [ "$total" -eq 0 ]; then
    echo "No .elf files found under $ELF_DIR" >&2
    exit 1
fi

i=0
for elf in "${elfs[@]}"; do
    i=$((i + 1))
    name=$(basename "$elf" .elf)
    hexfile="$HEX_DIR/${name}.hex"

    riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=8 \
        -j .text.init -j .text.rvtest -j .data -j .text.rvmodel \
        "$elf" "$hexfile" 2>/tmp/act_objcopy_err_$$.log
    if [ $? -ne 0 ]; then
        echo "$name: ERROR (objcopy failed: $(cat /tmp/act_objcopy_err_$$.log))" >> "$RESULTS_LOG"
        ERR=$((ERR + 1))
        continue
    fi

    tohost_addr=$(riscv64-unknown-elf-nm "$elf" | awk '$3 == "tohost" { print $1 }')
    if [ -z "$tohost_addr" ]; then
        echo "$name: ERROR (no tohost symbol in ELF)" >> "$RESULTS_LOG"
        ERR=$((ERR + 1))
        continue
    fi

    # 5000000 (up from 1000000): sized for the old EBREAK-freezes-forever
    # behavior, when every test hit its own first ebreak (if any) near-
    # instantly. Now that EBREAK is a real, resumable trap, tests that
    # deliberately exercise it mid-test (e.g. priv/U/U-00's own
    # uprivinst_ebreak subcase) run to their genuine, much later
    # completion instead -- confirmed U-00 itself needs ~1.28M cycles for
    # real completion (thousands of subcases, not just the first one) --
    # 5x that gives real headroom, not just margin, matching this
    # project's own "generous, not tightest-fit" timeout convention.
    out=$(vvp "$VVP_BIN" "+HEXFILE=$hexfile" "+TOHOST_ADDR=$tohost_addr" "+TIMEOUT=5000000" 2>&1)
    result_line=$(printf '%s\n' "$out" | grep -E "^ACT_RESULT:|^TIMEOUT:" | head -1)

    if [ -z "$result_line" ]; then
        echo "$name: ERROR (no ACT_RESULT/TIMEOUT line -- raw output: $out)" >> "$RESULTS_LOG"
        ERR=$((ERR + 1))
        continue
    fi

    echo "$name: $result_line" >> "$RESULTS_LOG"
    case "$result_line" in
        "ACT_RESULT: PASS"*) PASS=$((PASS + 1)) ;;
        "ACT_RESULT: FAIL"*) FAIL=$((FAIL + 1)) ;;
        "ACT_RESULT: UNKNOWN"*) UNKNOWN=$((UNKNOWN + 1)) ;;
        "TIMEOUT:"*) TIMEOUT=$((TIMEOUT + 1)) ;;
        *) ERR=$((ERR + 1)) ;;
    esac

    if [ $((i % 25)) -eq 0 ] || [ "$i" -eq "$total" ]; then
        echo "  [$i/$total] pass=$PASS fail=$FAIL timeout=$TIMEOUT unknown=$UNKNOWN error=$ERR"
    fi
done

echo ""
echo "$CONFIG ACT4 results: $PASS passed, $FAIL failed, $TIMEOUT timeout, $UNKNOWN unknown, $ERR error (of $total total)"
echo "Per-test results: $RESULTS_LOG"

rm -f /tmp/act_objcopy_err_$$.log
