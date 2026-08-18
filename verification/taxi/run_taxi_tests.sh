#!/bin/bash
# Builds and runs every testbench under verification/taxi/tb/ via Verilator's
# --binary mode -- the toolchain fork this directory exists for. iverilog
# cannot compile ANY of taxi's AXI4/AXI4-Lite IP (its entire product line is
# built on SystemVerilog interface+modport ports, confirmed unparseable by
# this project's Icarus build via an isolated, taxi-independent repro) -- see
# this directory's own README.md for the full story. Never add a
# taxi-touching testbench to the iverilog-based design/testbench regression
# file lists; it will not compile there.
#
# Each testbench may have a companion <name>.f file listing the taxi AXI
# source files it needs, one per line, paths relative to
# third_party/taxi/src/axi/rtl/ (same flat-filename convention taxi's own
# upstream .f files already use). A testbench with no .f file is assumed to
# need no taxi sources of its own (e.g. a pure toolchain smoke test).
#
# Usage (from WSL): verification/taxi/run_taxi_tests.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAXI_AXI_RTL="$REPO_ROOT/third_party/taxi/src/axi/rtl"
TB_DIR="$REPO_ROOT/verification/taxi/tb"
OUT_DIR="/tmp/taxi_verilator_out"

if [ ! -d "$TAXI_AXI_RTL" ]; then
    echo "taxi submodule not initialized -- run:" >&2
    echo "  git submodule update --init third_party/taxi" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
PASS=0
FAIL=0
ERR=0

shopt -s nullglob
tbs=("$TB_DIR"/*_tb.sv)
shopt -u nullglob

if [ ${#tbs[@]} -eq 0 ]; then
    echo "No testbenches found under $TB_DIR" >&2
    exit 1
fi

for tb in "${tbs[@]}"; do
    name=$(basename "$tb" .sv)
    flist="$TB_DIR/${name}.f"
    log="$OUT_DIR/${name}.log"
    mdir="$OUT_DIR/${name}_obj"
    rm -rf "$mdir"

    sources=()
    if [ -f "$flist" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            sources+=("$TAXI_AXI_RTL/$f")
        done < "$flist"
    fi

    if verilator --binary -j 0 --timing -Wno-fatal -Mdir "$mdir" -I"$REPO_ROOT/testbench" \
        --top-module "$name" "${sources[@]}" "$tb" > "$log" 2>&1; then
        "$mdir/V$name" >> "$log" 2>&1
        summary=$(grep -E "^${name}: [0-9]+ passed, [0-9]+ failed" "$log" | tail -1)
        if [ -z "$summary" ]; then
            echo "NOSUMMARY $name"
            ERR=$((ERR+1))
        else
            failed=$(echo "$summary" | sed -E 's/.*, ([0-9]+) failed.*/\1/')
            if [ "$failed" -eq 0 ]; then
                echo "PASS   $name"
                PASS=$((PASS+1))
            else
                echo "FAIL   $name ($summary)"
                FAIL=$((FAIL+1))
            fi
        fi
    else
        echo "COMPERR $name"
        ERR=$((ERR+1))
        tail -20 "$log"
    fi
done

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed, $ERR errored (compile/run) ==="
[ "$FAIL" -eq 0 ] && [ "$ERR" -eq 0 ]
