#!/bin/bash
# verification/perf/run_perf.sh -- P3.5 CPI baseline driver (pipelining
# track plan). Run under WSL bash:
#   wsl bash -lc "verification/perf/run_perf.sh"
#
# Builds all seven kernels (verification/perf/Makefile), builds the two
# perf_tb.sv configurations ONCE (CACHE_CFG=0/1 -- the testbench itself
# doesn't change per kernel, only +HEXFILE/+PERF_RESULT_ADDR do), runs
# every kernel against both, and writes baseline_<core>.csv (config
# "sram": the plain SRAM harness; "cache": the real SoC with caches).
# --core pipe (default) is the pipelined core (design/pipe/core.sv),
# --core ref the frozen multi-cycle reference (verification/reference/).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

OUTDIR="$SCRIPT_DIR/.results"
CORE=pipe
WALL_TIMEOUT=120
MAX_CYCLES=2000000
FORCE=0
ORACLE=""
DEFINES=""
LABEL=""

usage() {
    cat <<EOF
Usage: run_perf.sh [options]

  --core pipe|ref     which core (default pipe)
  --outdir DIR        results directory (default verification/perf/.results)
  --force             rebuild kernels/testbenches even if cached
  --oracle store      the cache configuration only, with the ideal-store D$ (oracle_dcache.sv): an upper bound for a store buffer;
                      writes oracle_store_<core>.csv, never the baselines
  --defines "A=1 B"    extra Verilog defines for the testbench builds (e.g. "QV_PIPE_SB_DEPTH=0" for the old timing)
  --label NAME        results go to baseline_<core>_<NAME>.csv (and its _stack.csv) and the builds are tagged, so the committed baselines stay
  --timeout N          per-run cycle budget passed as +TIMEOUT (default 2000000)
  --wall-timeout N      real seconds per run before it's killed (default 120)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --oracle) ORACLE="$2"; shift 2 ;;
        --defines) DEFINES="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
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
CORE_INC=""
case "$CORE" in
    pipe) DESIGN_LIST=design_files.list;     CORE_DEFINE="" ;;
    ref)  DESIGN_LIST=ref_design_files.list; CORE_DEFINE="-DQV_REF_AS_CORE"; CORE_INC="-I verification/reference" ;;
    *) echo "Unknown --core: $CORE (expected pipe or ref; the FSM core is ref)" >&2; exit 1 ;;
esac
DESIGN_FILES=$(grep -vE '^\s*(#|$)' "verification/regress/$DESIGN_LIST" | tr '\n' ' ')
TAG="$CORE"
if [ "$ORACLE" == "store" ]; then
    ORACLE_DCACHE=verification/perf/oracle_dcache.sv
    DESIGN_FILES="${DESIGN_FILES/design\/dcache.sv/$ORACLE_DCACHE}"
    TAG="${CORE}_oracle_store"
elif [ -n "$ORACLE" ]; then
    echo "Unknown --oracle: $ORACLE (expected store)" >&2; exit 1
fi
[ -n "$LABEL" ] && TAG="${TAG}_${LABEL}"
DEF_FLAGS=""
for d in $DEFINES; do DEF_FLAGS="$DEF_FLAGS -D$d"; done
HARNESS_FILES="testbench/core_wb4_sram_harness.sv"
PERF_FILES="verification/perf/perf_tb.sv verification/perf/perf_stack.sv"

build_tb() {
    local cfg="$1" vvp="$2" log="$3"
    if [ -e "$vvp" ] && [ "$FORCE" != "1" ]; then
        return
    fi
    echo "=== building $vvp ==="
    iverilog -g2012 $CORE_DEFINE $DEF_FLAGS -I design -I design/defaults -I testbench -I verification/perf $CORE_INC \
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

if [ -z "$ORACLE" ]; then build_tb 0 "$OUTDIR/perf_tb_${TAG}_sram.vvp" "$OUTDIR/build_${TAG}_sram.log"; fi
build_tb 1 "$OUTDIR/perf_tb_${TAG}_cache.vvp" "$OUTDIR/build_${TAG}_cache.log"

# ---------------- run every kernel against both configs ----------------
CSV="$SCRIPT_DIR/baseline_${CORE}${LABEL:+_$LABEL}.csv"
if [ -n "$ORACLE" ]; then CSV="$SCRIPT_DIR/oracle_${ORACLE}_${CORE}${LABEL:+_$LABEL}.csv"; fi
echo "kernel,config,cycles,instret,cpi" > "$CSV"

# The CPI stack of the pipelined core (perf_stack.sv): where the window's cycles go, and the side counters. The
# columns are the keys of the PERF_STACK and PERF_SIDE lines, in this order.
STACK_CSV="$SCRIPT_DIR/baseline_${CORE}${LABEL:+_$LABEL}_stack.csv"
STACK_KEYS="window retire blk_lsu blk_div blk_alu blk_sys ear_align ear_mispred ear_serial ear_other empty_front"
SIDE_KEYS="iq_empty fb_empty no_uop is_rob is_oper is_lsu is_div re_align re_mispred re_serial re_other mp_cond mp_jal mp_jalr mp_wait bus_wait"
if [ "$CORE" == "pipe" ] && [ -z "$ORACLE" ]; then
    echo "kernel,config,$(echo $STACK_KEYS $SIDE_KEYS | tr ' ' ',')" > "$STACK_CSV"
fi

# kv "<line>" key: the number after key= in a PERF_ line
kv() { echo "$1" | grep -oE "(^| )$2=[0-9]+" | grep -oE '[0-9]+$'; }

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

    if [ "$CORE" == "pipe" ] && [ -z "$ORACLE" ]; then
        local sline pline row
        sline=$(echo "$out" | grep "^PERF_STACK:" | head -1)
        pline=$(echo "$out" | grep "^PERF_SIDE:" | head -1)
        if [ -z "$sline" ] || [ -z "$pline" ]; then
            echo "WARN: $kernel ($cfg_name): no PERF_STACK/PERF_SIDE line" >&2
            return
        fi
        echo "$out" | grep "^PERF_STACK_WARN" | sed "s/^/WARN: $kernel ($cfg_name): /" >&2
        row="${kernel},${cfg_name}"
        for k in $STACK_KEYS; do row="$row,$(kv "$sline" $k)"; done
        for k in $SIDE_KEYS; do row="$row,$(kv "$pline" $k)"; done
        echo "$row" >> "$STACK_CSV"
    fi
}

echo "=== running kernels ==="
for kernel in $KERNELS; do
    if [ -z "$ORACLE" ]; then run_one "$kernel" "sram" "$OUTDIR/perf_tb_${TAG}_sram.vvp"; fi
    run_one "$kernel" "cache" "$OUTDIR/perf_tb_${TAG}_cache.vvp"
done

echo "=== wrote $CSV ==="
cat "$CSV"
