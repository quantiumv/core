#!/bin/bash
# Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration):
# builds the firmware image + the Verilator remote_bitbang harness, runs
# the real OpenOCD acceptance test (m10_smoke.tcl) against it, and
# propagates a single pass/fail exit code -- matching
# verification/taxi/run_taxi_tests.sh's own convention (computed
# REPO_ROOT, one summary line, exit code from the final boolean check).
#
# Usage (from WSL): verification/openocd/run_m10_smoke_test.sh
#   CORE=fsm|ref|pipe verification/openocd/run_m10_smoke_test.sh
# CORE (default fsm) picks the core under test: the file list and the rename
# define come from the same verification/regress/*design_files.list as
# run_regress.sh, so soc.sv's `core core0` is the FSM core, ref_core
# (-DQV_REF_AS_CORE) or core_pipe (-DQV_PIPE_AS_CORE). Each core builds in
# its own directory and listens on its own port, so they can run side by side.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OOD_DIR="$REPO_ROOT/verification/openocd"
FW_DIR="$REPO_ROOT/firmware"
CORE="${CORE:-fsm}"
case "$CORE" in
    fsm)  DESIGN_LIST="$REPO_ROOT/verification/regress/design_files.list";      CORE_DEFINE="";                  PORT=9824; OUT_DIR="/tmp/m10_smoke_out" ;;
    ref)  DESIGN_LIST="$REPO_ROOT/verification/regress/ref_design_files.list";   CORE_DEFINE="-DQV_REF_AS_CORE";   PORT=9825; OUT_DIR="/tmp/m10_smoke_out_ref" ;;
    pipe) DESIGN_LIST="$REPO_ROOT/verification/regress/pipe_design_files.list";  CORE_DEFINE="-DQV_PIPE_AS_CORE";  PORT=9826; OUT_DIR="/tmp/m10_smoke_out_pipe" ;;
    *) echo "Unknown CORE: $CORE (expected fsm, ref or pipe)" >&2; exit 1 ;;
esac

DESIGN_FILES=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] || continue
    DESIGN_FILES+=("$REPO_ROOT/$line")
done < "$DESIGN_LIST"

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

echo "=== Building the Verilator remote_bitbang harness (core: $CORE) ==="
SIM_MDIR="$OUT_DIR/sim_obj"
rm -rf "$SIM_MDIR"
mkdir -p "$SIM_MDIR"
# -Wno-fatal: the pipe and ref builds raise lint-style warnings the FSM build does not (this is not the lint gate)
if ! verilator --cc --exe --build --timing -j 0 -Wno-fatal $CORE_DEFINE \
        -I"$REPO_ROOT/design" -I"$REPO_ROOT/design/defaults" -I"$REPO_ROOT/verification/reference" \
        --top-module sim_soc_top -Mdir "$SIM_MDIR" -o sim_m10 \
        "${DESIGN_FILES[@]}" \
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
