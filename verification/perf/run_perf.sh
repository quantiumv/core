#!/bin/bash
# verification/perf/run_perf.sh -- P3.5 CPI baseline driver (pipelining
# track plan). Run under WSL bash:
#   wsl bash -lc "verification/perf/run_perf.sh"
#
# Builds all the kernels (verification/perf/Makefile), builds the two
# perf_tb.sv configurations ONCE (CACHE_CFG=0/1 -- the testbench itself
# doesn't change per kernel, only +HEXFILE/+PERF_RESULT_ADDR do), runs
# every kernel against both, and writes baseline_<core>.csv (config
# "sram": the plain SRAM harness; "cache": the real SoC with caches).
# --core pipe (default) is the pipelined core (design/pipe/core.sv),
# --core ref the frozen multi-cycle reference (verification/reference/).
# --mode s is the S-mode build (P10.0): the same kernels entered by crt0_s.s,
# in S under a 4 KiB Sv39 identity map; their numbers are perf_stack's window
# (perf_tb.sv SMODE), written to baseline_<core>_s.csv. Pipelined core only.
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
MODE=m
ILPDIR=""
MEMLAT=""

usage() {
    cat <<EOF
Usage: run_perf.sh [options]

  --core pipe|ref     which core (default pipe)
  --mode m|s          the kernels in M (default), or in S under Sv39 (baseline_<core>_s.csv; pipe only)
  --outdir DIR        results directory (default verification/perf/.results)
  --force             rebuild kernels/testbenches even if cached
  --oracle store      the cache configuration only, with the ideal-store D$ (oracle_dcache.sv): an upper bound for a store buffer;
                      writes oracle_store_<core>.csv, never the baselines
  --oracle dc         the cache configuration only, with an ideal D$ inside the core (mk_oracle_dc.py makes it from
                      qv_lsu.sv: a plain RAM load completes in the cycle it could start, read from the RAM array): an
                      upper bound for O5a (O5.0); writes oracle_dc_<core>[_s].csv, never the baselines
  --defines "A=1 B"    extra Verilog defines for the testbench builds (e.g. "QV_PIPE_SB_DEPTH=0" for the old timing)
  --label NAME        results go to baseline_<core>_<NAME>.csv (and its _stack.csv) and the builds are tagged, so the committed baselines stay
  --timeout N          per-run cycle budget passed as +TIMEOUT (default 2000000)
  --ilptrace DIR       also write each run's +ILPTRACE lines (perf_stack.sv) to DIR/<kernel>[_s]_<config>.ilp
  --memlat L[,B[,W]]   the cache configuration only, with a memory that answers a read in L cycles (B for the next
                       dword of a line right behind the last read, W for a write; wb4_sram_lat.sv); results labelled
                       lat<L> (plus --label), never the baselines
  --wall-timeout N      real seconds per run before it's killed (default 120)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --oracle) ORACLE="$2"; shift 2 ;;
        --defines) DEFINES="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --timeout) MAX_CYCLES="$2"; shift 2 ;;
        --wall-timeout) WALL_TIMEOUT="$2"; shift 2 ;;
        --ilptrace) ILPDIR="$2"; shift 2 ;;
        --memlat) MEMLAT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

mkdir -p "$OUTDIR"

KERNELS="memcpy crc32 qsort matmul sieve listchase mixedint trap fmatmul fpmix"

case "$MODE" in
    m) SFX=""; MAKE_TARGET=all; SMODE=0 ;;
    s) SFX="_s"; MAKE_TARGET=all_s; SMODE=1
       if [ "$CORE" != "pipe" ] || { [ -n "$ORACLE" ] && [ "$ORACLE" != "dc" ]; }; then
           echo "--mode s needs --core pipe and no --oracle but dc (its result is the pipelined core's CPI monitor)" >&2; exit 1
       fi ;;
    *) echo "Unknown --mode: $MODE (expected m or s)" >&2; exit 1 ;;
esac

# ---------------- build kernels ----------------
echo "=== building kernels ==="
if [ "$FORCE" == "1" ]; then
    (cd verification/perf && make clean > /dev/null 2>&1)
fi
(cd verification/perf && make $MAKE_TARGET > "$OUTDIR/kernel_build.log" 2>&1)
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
TAG="${CORE}${SFX}"
if [ "$ORACLE" == "store" ]; then
    ORACLE_DCACHE=verification/perf/oracle_dcache.sv
    DESIGN_FILES="${DESIGN_FILES/design\/dcache.sv/$ORACLE_DCACHE}"
    TAG="${CORE}_oracle_store"
elif [ "$ORACLE" == "dc" ]; then
    if [ "$CORE" != "pipe" ]; then echo "--oracle dc needs --core pipe" >&2; exit 1; fi
    mkdir -p "$OUTDIR"
    ORACLE_DC="$OUTDIR/oracle_dc_qv_lsu.sv"
    python3 verification/perf/mk_oracle_dc.py design/pipe/qv_lsu.sv "$ORACLE_DC" || exit 1
    DESIGN_FILES="${DESIGN_FILES/design\/pipe\/qv_lsu.sv/$ORACLE_DC}"
    DEFINES="$DEFINES QV_ORACLE_DC_MEM=perf_tb.g_cache.dut.sram0.memory"
    TAG="${CORE}${SFX}_oracle_dc"
elif [ -n "$ORACLE" ]; then
    echo "Unknown --oracle: $ORACLE (expected store or dc)" >&2; exit 1
fi
MEMLAT_PLUS=""
if [ -n "$MEMLAT" ]; then
    IFS=, read -r ML_L ML_B ML_W <<< "$MEMLAT"
    ML_B=${ML_B:-$ML_L}; ML_W=${ML_W:-$ML_L}
    DESIGN_FILES="${DESIGN_FILES/design\/wb4_sram.sv/verification/perf/wb4_sram_lat.sv}"
    MEMLAT_PLUS="+MEMLAT_L=$ML_L +MEMLAT_B=$ML_B +MEMLAT_W=$ML_W"
    LABEL="lat${ML_L}_${ML_B}_${ML_W}${LABEL:+_$LABEL}"
fi
[ -n "$LABEL" ] && TAG="${TAG}_${LABEL}"
# the defines are part of the build: a run that changes only --defines must not reuse another point's build
[ -n "$DEFINES" ] && TAG="${TAG}_d$(echo "$DEFINES" | sha1sum | cut -c1-6)"
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
        -Pperf_tb.CACHE_CFG=$cfg -Pperf_tb.SMODE=$SMODE \
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

if [ "$ORACLE" != "store" ] && [ "$ORACLE" != "dc" ] && [ -z "$MEMLAT" ]; then build_tb 0 "$OUTDIR/perf_tb_${TAG}_sram.vvp" "$OUTDIR/build_${TAG}_sram.log"; fi
build_tb 1 "$OUTDIR/perf_tb_${TAG}_cache.vvp" "$OUTDIR/build_${TAG}_cache.log"

# ---------------- run every kernel against both configs ----------------
CSV="$SCRIPT_DIR/baseline_${CORE}${SFX}${LABEL:+_$LABEL}.csv"
if [ -n "$ORACLE" ]; then CSV="$SCRIPT_DIR/oracle_${ORACLE}_${CORE}${SFX}${LABEL:+_$LABEL}.csv"; fi
echo "kernel,config,cycles,instret,cpi" > "$CSV"

# The CPI stack of the pipelined core (perf_stack.sv): where the window's cycles go, and the side counters. The
# columns are the keys of the PERF_STACK and PERF_SIDE lines, in this order.
STACK_CSV="$SCRIPT_DIR/baseline_${CORE}${SFX}${LABEL:+_$LABEL}_stack.csv"
if [ -n "$ORACLE" ]; then STACK_CSV="$SCRIPT_DIR/oracle_${ORACLE}_${CORE}${SFX}${LABEL:+_$LABEL}_stack.csv"; fi
STACK_KEYS="window retire blk_lsu blk_div blk_alu blk_sys ear_align ear_mispred ear_serial ear_other empty_front blk_fpu"
SIDE_KEYS="iq_empty fb_empty no_uop is_rob is_oper is_lsu is_div re_align re_mispred re_serial re_other mp_cond mp_jal mp_jalr mp_wait bus_wait"
SIDE_KEYS="$SIDE_KEYS xl_req xl_reuse xl_cyc dx_n dx_hit dx_save re_ser_ro re_ser_trapw re_ser_csr re_ser_sys"
SIDE_KEYS="$SIDE_KEYS ear_ser_ro ear_ser_trapw ear_ser_csr ear_ser_sys is_rs"
# the load/store queue's counters (O2), a file of their own so the stack's stays as it was
LSQ_CSV="${STACK_CSV%_stack.csv}_lsq.csv"
LSQ_KEYS="early_ld early_st bar_wait match_wait qmatch_wait handoff drain"
# the two-wide core's counters (OX.0): the second commit slot's classes (they add up to the window) and the caches'
# refills, again a file of their own
OX_CSV="${STACK_CSV%_stack.csv}_ox.csv"
OX_KEYS="s1_retire s1_idle s1_none s1_wait_lsu s1_wait_div s1_wait_fpu s1_wait_alu s1_rule_head s1_rule_pair"
OX_KEYS="$OX_KEYS dc_miss dc_cyc ic_miss ic_cyc xr_n xr_killed xr_head xr_save mp_commit ear_mp_x"
OX_KEYS="$OX_KEYS rob_occ rob_max rs_occ rs_max rob_one is_lsq"
# the three-wide track's counters (W3), a file of their own again: the store buffer's beats, and those presented in
# the previous beat's response cycle (W3a); fetch's answers into the buffer, and those that filled two entries (W3b)
W3_CSV="${STACK_CSV%_stack.csv}_w3.csv"
W3_KEYS="sb_beats sb_b2b fb_resp fb_pairs"
if [ "$CORE" == "pipe" ] && [ "$ORACLE" != "store" ]; then
    echo "kernel,config,$(echo $STACK_KEYS $SIDE_KEYS | tr ' ' ',')" > "$STACK_CSV"
    echo "kernel,config,$(echo $LSQ_KEYS | tr ' ' ',')" > "$LSQ_CSV"
    echo "kernel,config,$(echo $OX_KEYS | tr ' ' ',')" > "$OX_CSV"
    echo "kernel,config,$(echo $W3_KEYS | tr ' ' ',')" > "$W3_CSV"
fi

# kv "<line>" key: the number after key= in a PERF_ line
kv() { echo "$1" | grep -oE "(^| )$2=[0-9]+" | grep -oE '[0-9]+$'; }

run_one() {
    local kernel="$1" cfg_name="$2" vvp="$3"
    local hex="verification/perf/${kernel}${SFX}.hex"
    local elf="verification/perf/${kernel}${SFX}.elf"
    local addr
    addr=$(riscv64-unknown-elf-nm "$elf" 2>/dev/null | awk '$3 == "_perf_result" { print $1 }')
    if [ -z "$addr" ]; then
        echo "WARN: $kernel: _perf_result not found in $elf, skipping $cfg_name" >&2
        return
    fi
    local out
    local plus=""
    [ -n "$ILPDIR" ] && plus="+ILPTRACE"
    out=$(timeout "$WALL_TIMEOUT" vvp "$vvp" +HEXFILE="$hex" +PERF_RESULT_ADDR="$addr" +TIMEOUT="$MAX_CYCLES" $plus $MEMLAT_PLUS 2>&1 | grep -v "Unable to open")
    if [ -n "$ILPDIR" ]; then
        mkdir -p "$ILPDIR"
        echo "$out" | grep "^ILP " > "$ILPDIR/${kernel}${SFX}_${cfg_name}.ilp"
        out=$(echo "$out" | grep -v "^ILP ")
    fi
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

    if [ "$CORE" == "pipe" ] && [ "$ORACLE" != "store" ]; then
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
        local qline
        qline=$(echo "$out" | grep "^PERF_LSQ:" | head -1)
        row="${kernel},${cfg_name}"
        for k in $LSQ_KEYS; do row="$row,$(kv "$qline" $k)"; done
        echo "$row" >> "$LSQ_CSV"
        local xline
        xline=$(echo "$out" | grep "^PERF_OX:" | head -1)
        row="${kernel},${cfg_name}"
        for k in $OX_KEYS; do row="$row,$(kv "$xline" $k)"; done
        echo "$row" >> "$OX_CSV"
        local wline
        wline=$(echo "$out" | grep "^PERF_W3:" | head -1)
        row="${kernel},${cfg_name}"
        for k in $W3_KEYS; do row="$row,$(kv "$wline" $k)"; done
        echo "$row" >> "$W3_CSV"
    fi
}

echo "=== running kernels ==="
for kernel in $KERNELS; do
    if [ "$ORACLE" != "store" ] && [ "$ORACLE" != "dc" ] && [ -z "$MEMLAT" ]; then run_one "$kernel" "sram" "$OUTDIR/perf_tb_${TAG}_sram.vvp"; fi
    run_one "$kernel" "cache" "$OUTDIR/perf_tb_${TAG}_cache.vvp"
done

echo "=== wrote $CSV ==="
cat "$CSV"
