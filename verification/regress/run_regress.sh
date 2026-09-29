#!/bin/bash
# QuantiumV checked-in regression runner (P3.0 of the pipelining track --
# see the plan at C:\Users\Potato\.claude\plans\
# research-the-c-extension-reflective-candle.md). Run under WSL bash
# (needs iverilog/vvp + the riscv64-unknown-elf toolchain for firmware/
# testbench prerequisites): `wsl bash -lc "verification/regress/run_regress.sh"`
# from the repo root, or from anywhere -- the script locates the repo
# root itself.
#
# Compiles and runs each testbench in tests.list in its own iverilog/vvp
# invocation. Resumable: a per-tag result file under OUTDIR is skipped on
# a later run unless --force or --only re-selects it. Parallel across a
# bounded job pool (default: nproc).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CORE=fsm
ONLY=""
JOBS="$(nproc 2>/dev/null || echo 4)"
FORCE=0
LIST_ONLY=0
OUTDIR=""
DEFAULT_TIMEOUT=180

usage() {
    cat <<'EOF'
Usage: run_regress.sh [--core fsm|ref|pipe] [--only REGEX] [-j N]
                       [--force] [--list] [--outdir DIR]

  --core fsm|ref|pipe  Which core build to test (default: fsm). "ref"
                        is verification/reference/ref_core.sv (frozen
                        P3.3); "pipe" is wired in once P4a (design/pipe/)
                        lands.
  --only REGEX         Only run tags matching this extended regex.
  -j N                  Parallel job count (default: nproc).
  --force               Re-run every selected test, ignoring cached
                        per-tag results from a previous run.
  --list                Print the tags that would run, then exit.
  --outdir DIR          Where per-tag results/logs go (default:
                        /tmp/qv_regress_<core>).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

CORE_DEFINE=""
case "$CORE" in
    fsm)
        DESIGN_LIST="$REPO_ROOT/verification/regress/design_files.list"
        ;;
    ref)
        DESIGN_LIST="$REPO_ROOT/verification/regress/ref_design_files.list"
        CORE_DEFINE="-DQV_REF_AS_CORE"
        ;;
    pipe)
        echo "ERROR: --core pipe is not wired up yet -- design/pipe/ doesn't" \
             "exist until pipelining-track-plan.md's P4a." >&2
        exit 1
        ;;
    *)
        echo "Unknown --core: $CORE (expected fsm, ref or pipe)" >&2
        exit 1
        ;;
esac

[ -n "$OUTDIR" ] || OUTDIR="/tmp/qv_regress_${CORE}"
mkdir -p "$OUTDIR"

# Read design_files.list into a space-joined string (skip blank/# lines).
DESIGN_FILES=""
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"  # trim whitespace
    [ -n "$line" ] || continue
    DESIGN_FILES="$DESIGN_FILES $REPO_ROOT/$line"
done < "$DESIGN_LIST"

INCFLAGS="-I $REPO_ROOT/design -I $REPO_ROOT/design/defaults -I $REPO_ROOT/testbench -I $REPO_ROOT/verification/reference"

echo "=== Building firmware/testbench prerequisites ==="
make -C "$REPO_ROOT/firmware" >/tmp/qv_regress_firmware_build.log 2>&1
if [ $? -ne 0 ]; then
    echo "firmware build FAILED -- see /tmp/qv_regress_firmware_build.log" >&2
    exit 1
fi
make -C "$REPO_ROOT/testbench" >/tmp/qv_regress_testbench_build.log 2>&1
if [ $? -ne 0 ]; then
    echo "testbench fixture build FAILED -- see /tmp/qv_regress_testbench_build.log" >&2
    exit 1
fi

parse_verdict() {
    # $1 = log file. Order matters: a testbench always prints
    # "N passed, M failed" and THEN, only when M>0, a second line
    # containing "FAILURES PRESENT" (verified across the whole
    # testbench/ corpus) -- so checking FAILURES PRESENT first is safe
    # even though both strings can appear in the same log.
    local logf="$1"
    if grep -q "FAILURES PRESENT" "$logf"; then
        echo "FAIL"; return
    fi
    if grep -qE ": [0-9]+ passed, [0-9]+ failed" "$logf"; then
        echo "PASS"; return
    fi
    if grep -qE "[0-9]+ iterations, [0-9]+ checks passed, [0-9]+ checks failed" "$logf"; then
        echo "PASS"; return
    fi
    echo "UNKNOWN"
}

run_one() {
    # Fields per tests.list's own header comment.
    local tag="$1" tbfile="$2" extra_csv="$3" runcwd="$4" cores_csv="$5" expect="$6" timeout_s="$7"
    local resultf="$OUTDIR/${tag}.result"

    if [ "$FORCE" -ne 1 ] && [ -f "$resultf" ]; then
        return
    fi

    local extra=""
    if [ -n "$extra_csv" ]; then
        extra="$(echo "$extra_csv" | tr ',' ' ' | sed "s#[^ ]*#$REPO_ROOT/&#g")"
    fi
    [ -n "$timeout_s" ] || timeout_s="$DEFAULT_TIMEOUT"

    local vvpout="$OUTDIR/${tag}.vvp"
    local logout="$OUTDIR/${tag}.log"
    local t0 t1

    t0=$(date +%s)
    iverilog -g2012 $CORE_DEFINE $INCFLAGS -o "$vvpout" $DESIGN_FILES $extra "$REPO_ROOT/$tbfile" \
        > "${logout}.compile" 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${tag}\tCOMPILE_FAIL\t0" > "$resultf"
        return
    fi

    (cd "$REPO_ROOT/$runcwd" && timeout "$timeout_s" vvp "$vvpout" > "$logout" 2>&1)
    local rc=$?
    t1=$(date +%s)

    local verdict
    if [ $rc -eq 124 ]; then
        verdict="TIMEOUT"
    else
        verdict="$(parse_verdict "$logout")"
    fi

    # Reconcile against the expectation column.
    if [[ "$expect" == xfail:* ]]; then
        if [ "$verdict" == "PASS" ]; then
            verdict="UNEXPECTED_PASS"
        elif [ "$verdict" == "FAIL" ]; then
            verdict="XFAIL"
        fi
    fi

    echo -e "${tag}\t${verdict}\t$((t1 - t0))" > "$resultf"
}

# Build the selected tag list.
TAGS_FILE="$OUTDIR/.selected_tags"
> "$TAGS_FILE"
while IFS='|' read -r tag tbfile extra runcwd cores expect timeout_s; do
    tag="$(echo "$tag" | xargs)"
    [ -n "$tag" ] || continue
    [[ "$tag" == \#* ]] && continue
    if [ -n "$ONLY" ] && ! [[ "$tag" =~ $ONLY ]]; then
        continue
    fi
    # cores column: comma-separated subset of fsm,ref,pipe this test is
    # meaningful for (tests.list's own header comment). A test not
    # listing $CORE is skipped entirely for this run -- e.g. the 6
    # leaf-module unit tests (design_alu_tb and siblings) instantiate
    # their module by its fixed FSM name (`alu`, `csr_file`, ...), which
    # has no ref-side equivalent (ref_alu.sv's module is unconditionally
    # named `ref_alu`, never aliased to `alu` the way ref_core.sv aliases
    # to `core`) -- a real gap found by direct comparison: this column
    # existed before P3.3 but was never actually enforced, so `--core
    # ref` silently tried to compile every fsm-only test too and failed
    # 8 of them.
    if ! echo ",$cores," | grep -q ",$CORE,"; then
        continue
    fi
    echo -e "${tag}|${tbfile}|${extra}|${runcwd}|${cores}|${expect}|${timeout_s}" >> "$TAGS_FILE"
done < "$REPO_ROOT/verification/regress/tests.list"

TOTAL=$(wc -l < "$TAGS_FILE")
echo "=== $TOTAL test(s) selected (core=$CORE, only=${ONLY:-<all>}) ==="

if [ "$LIST_ONLY" -eq 1 ]; then
    cut -d'|' -f1 "$TAGS_FILE"
    exit 0
fi

# Bounded-concurrency launch.
running=0
while IFS='|' read -r tag tbfile extra runcwd cores expect timeout_s; do
    run_one "$tag" "$tbfile" "$extra" "$runcwd" "$cores" "$expect" "$timeout_s" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
done < "$TAGS_FILE"
wait

echo "=== Results ==="
FAIL_COUNT=0
while IFS='|' read -r tag _rest; do
    resultf="$OUTDIR/${tag}.result"
    if [ -f "$resultf" ]; then
        cat "$resultf"
        verdict="$(cut -f2 "$resultf")"
        [ "$verdict" == "PASS" ] || [ "$verdict" == "XFAIL" ] || FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo -e "${tag}\tMISSING\t0"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done < "$TAGS_FILE"

echo "=== $((TOTAL - FAIL_COUNT))/$TOTAL clean (core=$CORE) ==="
echo "Per-tag logs/results: $OUTDIR"
[ "$FAIL_COUNT" -eq 0 ]
