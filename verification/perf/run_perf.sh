#!/bin/bash
# verification/perf/run_perf.sh -- P3.5 CPI baseline driver (pipelining
# track plan). Run under WSL bash:
#   wsl bash -lc "verification/perf/run_perf.sh"
#
# Builds all seven kernels (verification/perf/Makefile), builds the two
# perf_tb.sv configurations ONCE (CACHE_CFG=0/1 -- the testbench itself
# doesn't change per kernel, only +HEXFILE/+PERF_RESULT_ADDR do), runs
# every kernel against both, and writes baseline_fsm.csv: the FSM core's
# own baseline (both the plain SRAM harness and the real SoC with
# caches), named for later comparison against a future core_pipe
# baseline once one exists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

OUTDIR="$SCRIPT_DIR/.results"
WALL_TIMEOUT=120
MAX_CYCLES=2000000
FORCE=0

usage() {
    cat <<EOF
Usage: run_perf.sh [options]

  --outdir DIR        results directory (default verification/perf/.results)
  --force             rebuild kernels/testbenches even if cached
  --timeout N          per-run cycle budget passed as +TIMEOUT (default 2000000)
  --wall-timeout N      real seconds per run before it's killed (default 120)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --outdir) OUTDIR="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --timeout) MAX_CYCLES="$2"; shift 2 ;;
        --wall-timeout) WALL_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

mkdir -p "$OUTDIR"

KERNELS="memcpy crc32 qsort matmul sieve listchase mixedint"

# ---------------- build kernels ----------------
echo "=== building kernels ==="
if [ "$FORCE" == "1" ]; then
    (cd verification/perf && make clean > /dev/null 2>&1)
fi
(cd verification/perf && make all > "$OUTDIR/kernel_build.log" 2>&1)
if [ $? -ne 0 ]; then
    echo "KERNEL BUILD FAILED -- see $OUTDIR/kernel_build.log" >&2
    tail -40 "$OUTDIR/kernel_build.log" >&2
    exit 1
fi

# ---------------- build the two testbench configurations ----------------
DESIGN_FILES="design/decoder.sv design/alu.sv design/c_expand.sv design/cache_complex.sv \
design/clint.sv design/core.sv design/csr_file.sv design/dcache.sv design/divider.sv \
design/dm.sv design/dm_dmi.sv design/icache.sv design/jtag_tap.sv design/plic.sv \
design/register_file.sv design/soc.sv design/uart16550.sv design/wb4_sram.sv \
design/wb_addr_decoder.sv design/wb_arbiter2.sv"
HARNESS_FILES="testbench/core_wb4_sram_harness.sv"
PERF_FILES="verification/perf/perf_tb.sv"

build_tb() {
    local cfg="$1" vvp="$2" log="$3"
    if [ -e "$vvp" ] && [ "$FORCE" != "1" ]; then
        return
    fi
    echo "=== building $vvp ==="
    iverilog -g2012 -I design -I design/defaults -I testbench -I verification/perf \
        -Pperf_tb.CACHE_CFG=$cfg \
        -o "$vvp" \
        $DESIGN_FILES $HARNESS_FILES $PERF_FILES > "$log" 2>&1
    # iverilog's own well-known "sorry: constant selects..." notes (see
    # design/c_expand.sv/core.sv) are informational -- iverilog itself
    # still exits 0 and produces the binary when that's all there is, so
    # the exit code (not grepping the log for "error") is what actually
    # distinguishes those from a real failure.
    if [ $? -ne 0 ] || ! [ -e "$vvp" ]; then
        echo "BUILD FAILED -- see $log" >&2
        grep -viE 'sorry:' "$log" | tail -40 >&2
        exit 1
    fi
}

build_tb 0 "$OUTDIR/perf_tb_fsm.vvp"   "$OUTDIR/build_fsm.log"
build_tb 1 "$OUTDIR/perf_tb_cache.vvp" "$OUTDIR/build_cache.log"

# ---------------- run every kernel against both configs ----------------
CSV="$SCRIPT_DIR/baseline_fsm.csv"
echo "kernel,config,cycles,instret,cpi" > "$CSV"

run_one() {
    local kernel="$1" cfg_name="$2" vvp="$3"
    local hex="verification/perf/${kernel}.hex"
    local elf="verification/perf/${kernel}.elf"
    local addr
    addr=$(riscv64-unknown-elf-nm "$elf" 2>/dev/null | awk '$3 == "_perf_result" { print $1 }')
    if [ -z "$addr" ]; then
        echo "WARN: $kernel: _perf_result not found in $elf, skipping $cfg_name" >&2
        return
    fi
    local out
    out=$(timeout "$WALL_TIMEOUT" vvp "$vvp" +HEXFILE="$hex" +PERF_RESULT_ADDR="$addr" +TIMEOUT="$MAX_CYCLES" 2>&1 | grep -v "Unable to open")
    local line
    line=$(echo "$out" | grep "^PERF_RESULT:" | head -1)
    if [ -z "$line" ]; then
        echo "WARN: $kernel ($cfg_name): no PERF_RESULT line -- $(echo "$out" | grep -i timeout | head -1)" >&2
        return
    fi
    local cycles instret
    cycles=$(echo "$line" | grep -oE 'cycles=[0-9]+' | grep -oE '[0-9]+')
    instret=$(echo "$line" | grep -oE 'instret=[0-9]+' | grep -oE '[0-9]+')
    local cpi
    cpi=$(awk -v c="$cycles" -v i="$instret" 'BEGIN { if (i > 0) printf "%.3f", c / i; else print "nan" }')
    echo "${kernel},${cfg_name},${cycles},${instret},${cpi}" >> "$CSV"
    printf "%-10s %-6s cycles=%-8s instret=%-8s cpi=%s\n" "$kernel" "$cfg_name" "$cycles" "$instret" "$cpi"
}

echo "=== running kernels ==="
for kernel in $KERNELS; do
    run_one "$kernel" "fsm"   "$OUTDIR/perf_tb_fsm.vvp"
    run_one "$kernel" "cache" "$OUTDIR/perf_tb_cache.vvp"
done

echo "=== wrote $CSV ==="
cat "$CSV"
