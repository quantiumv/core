#!/bin/bash
# Runs every self-checking ACT4 ELF generated for quantiumv-rv64im through
# testbench/act_runner_tb.sv and reports PASS/FAIL/TIMEOUT/UNKNOWN counts.
#
# Prerequisites: ELFs already generated via
#   CONFIG_FILES=verification/riscv-arch-test/quantiumv-rv64im/test_config.yaml \
#   WORKDIR=verification/riscv-arch-test/work make --jobs $(nproc)
# run from a riscv-arch-test checkout (see quantiumv-rv64im/test_config.yaml's
# header comment for the exact EXCLUDE_EXTENSIONS override needed to include
# Sm/S -- the framework's own Makefile default excludes both).
#
# Usage (from WSL): verification/riscv-arch-test/run_act_tests.sh [elf_dir]
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ELF_DIR="${1:-$REPO_ROOT/verification/riscv-arch-test/work/quantiumv-rv64im/elfs}"
HEX_DIR="/tmp/act_hex_$$"
VVP_BIN="/tmp/act_runner_tb_$$.vvp"
RESULTS_LOG="$REPO_ROOT/verification/riscv-arch-test/act_results.log"

if [ ! -d "$ELF_DIR" ]; then
    echo "ELF directory not found: $ELF_DIR" >&2
    exit 1
fi

mkdir -p "$HEX_DIR"
trap 'rm -rf "$HEX_DIR" "$VVP_BIN"' EXIT

echo "Compiling act_runner_tb.sv against the current core..."
iverilog -g2012 -I "$REPO_ROOT/design" -I "$REPO_ROOT/testbench" -o "$VVP_BIN" \
    "$REPO_ROOT/design/alu.sv" "$REPO_ROOT/design/decoder.sv" "$REPO_ROOT/design/register_file.sv" \
    "$REPO_ROOT/design/csr_file.sv" "$REPO_ROOT/design/divider.sv" "$REPO_ROOT/design/core.sv" \
    "$REPO_ROOT/design/wb4_sram.sv" "$REPO_ROOT/testbench/act_runner_tb.sv"
if [ $? -ne 0 ]; then
    echo "COMPILE FAILED"
    exit 1
fi

PASS=0; FAIL=0; TIMEOUT=0; UNKNOWN=0; ERR=0
: > "$RESULTS_LOG"

elfs=()
while IFS= read -r -d '' f; do elfs+=("$f"); done < <(find "$ELF_DIR" -iname "*.elf" -print0 | sort -z)
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

    out=$(vvp "$VVP_BIN" "+HEXFILE=$hexfile" "+TOHOST_ADDR=$tohost_addr" "+TIMEOUT=1000000" 2>&1)
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
echo "quantiumv-rv64im ACT4 results: $PASS passed, $FAIL failed, $TIMEOUT timeout, $UNKNOWN unknown, $ERR error (of $total total)"
echo "Per-test results: $RESULTS_LOG"

rm -f /tmp/act_objcopy_err_$$.log
