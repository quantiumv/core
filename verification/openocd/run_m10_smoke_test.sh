#!/bin/bash
# Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration):
# builds the firmware image + the Verilator remote_bitbang harness, runs
# the real OpenOCD acceptance test (m10_smoke.tcl) against it, and
# propagates a single pass/fail exit code -- matching
# verification/taxi/run_taxi_tests.sh's own convention (computed
# REPO_ROOT, one summary line, exit code from the final boolean check).
#
# Usage (from WSL): verification/openocd/run_m10_smoke_test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OOD_DIR="$REPO_ROOT/verification/openocd"
FW_DIR="$REPO_ROOT/firmware"
OUT_DIR="/tmp/m10_smoke_out"
PORT=9824

mkdir -p "$OUT_DIR"

SIM_PID=""
cleanup() {
    if [ -n "$SIM_PID" ] && kill -0 "$SIM_PID" 2>/dev/null; then
        kill "$SIM_PID" 2>/dev/null
        wait "$SIM_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

echo "=== Building firmware/m10_debug_test.hex ==="
if ! make -C "$FW_DIR" m10_debug_test > "$OUT_DIR/firmware_build.log" 2>&1; then
    echo "FAIL: firmware build failed -- see $OUT_DIR/firmware_build.log" >&2
    tail -30 "$OUT_DIR/firmware_build.log"
    exit 1
fi

echo "=== Building the Verilator remote_bitbang harness ==="
SIM_MDIR="$OUT_DIR/sim_obj"
rm -rf "$SIM_MDIR"
mkdir -p "$SIM_MDIR"
if ! verilator --cc --exe --build --timing -j 0 \
        -I"$REPO_ROOT/design" -I"$REPO_ROOT/design/defaults" \
        --top-module sim_soc_top -Mdir "$SIM_MDIR" -o sim_m10 \
        "$REPO_ROOT"/design/decoder.sv "$REPO_ROOT"/design/alu.sv "$REPO_ROOT"/design/c_expand.sv \
        "$REPO_ROOT"/design/cache_complex.sv "$REPO_ROOT"/design/clint.sv "$REPO_ROOT"/design/core.sv \
        "$REPO_ROOT"/design/csr_file.sv "$REPO_ROOT"/design/dcache.sv "$REPO_ROOT"/design/divider.sv \
        "$REPO_ROOT"/design/dm.sv "$REPO_ROOT"/design/dm_dmi.sv "$REPO_ROOT"/design/icache.sv \
        "$REPO_ROOT"/design/jtag_tap.sv "$REPO_ROOT"/design/register_file.sv "$REPO_ROOT"/design/soc.sv \
        "$REPO_ROOT"/design/uart_rx.sv "$REPO_ROOT"/design/uart_tx.sv "$REPO_ROOT"/design/wb4_sram.sv \
        "$REPO_ROOT"/design/wb_addr_decoder.sv "$REPO_ROOT"/design/wb_arbiter2.sv \
        "$OOD_DIR/sim_soc_top.sv" "$OOD_DIR/sim_main.cpp" > "$OUT_DIR/verilator_build.log" 2>&1; then
    echo "FAIL: Verilator build failed -- see $OUT_DIR/verilator_build.log" >&2
    tail -40 "$OUT_DIR/verilator_build.log"
    exit 1
fi

echo "=== Launching the sim harness (remote_bitbang server on port $PORT) ==="
SIM_LOG="$OUT_DIR/sim.log"
: > "$SIM_LOG"
( cd "$FW_DIR" && "$SIM_MDIR/sim_m10" "$PORT" >> "$SIM_LOG" 2>&1 ) &
SIM_PID=$!

# Poll for the harness's own startup sentinel rather than a fixed sleep
# -- see sim_main.cpp's own comment on why this line is printed exactly
# once, right before its blocking accept().
tries=0
while ! grep -q "REMOTE_BITBANG_LISTENING" "$SIM_LOG" 2>/dev/null; do
    if ! kill -0 "$SIM_PID" 2>/dev/null; then
        echo "FAIL: sim harness exited before it started listening -- see $SIM_LOG" >&2
        cat "$SIM_LOG"
        exit 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
        echo "FAIL: sim harness never printed its listening sentinel -- see $SIM_LOG" >&2
        cat "$SIM_LOG"
        exit 1
    fi
    sleep 0.1
done

echo "=== Running the OpenOCD acceptance test ==="
OPENOCD_LOG="$OUT_DIR/openocd.log"
( cd "$OOD_DIR" && openocd -f quantiumv.cfg -f m10_smoke.tcl ) > "$OPENOCD_LOG" 2>&1
cat "$OPENOCD_LOG"

summary=$(grep -E "^m10_smoke: [0-9]+ passed, [0-9]+ failed" "$OPENOCD_LOG" | tail -1)
if [ -z "$summary" ]; then
    echo ""
    echo "=== SUMMARY: NO RESULT LINE FOUND (openocd crashed or the script errored out early) ==="
    exit 1
fi

failed=$(echo "$summary" | sed -E 's/.*, ([0-9]+) failed.*/\1/')
echo ""
echo "=== SUMMARY: $summary ==="
[ "$failed" -eq 0 ]
