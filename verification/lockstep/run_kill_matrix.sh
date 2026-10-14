#!/bin/bash
# verification/lockstep/run_kill_matrix.sh -- the lockstep harness against its mutants (P3.4's kill matrix).
# Run under WSL bash:  wsl bash -lc "verification/lockstep/run_kill_matrix.sh [--random-count N] [-j N] [--outdir DIR] [--only 1,5,9]"
#
# Each ref_core mutant (QV_MUTANT_B = 1..10, see ref_core.sv) runs against the reference through run_lockstep.sh
# --mode mutant, and at least one corpus entry must FAIL: that is the proof the comparator can see that kind of
# bug. Most mutants are caught by the ordinary corpus (act + fw + random); two need a corpus and an option of
# their own:
#   5  interrupt sampled one cycle late    the irq corpus with injected interrupts, each level shown a cycle late
#   9  FENCE.I does not flush              the self-modifying-code corpus on the cache memory configuration
# --entries REGEX narrows the ordinary corpus (run_lockstep.sh --only); the default is the firmware programs,
# the random ones and a few ACT ELFs, enough for every mutant but not the whole 111-ELF ACT set.
# Exit status 0 only if every selected mutant was caught.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.." || exit 1

COUNT=10
JOBS=3
OUT=/tmp/qv_kill_matrix
ONLY="1,2,3,4,5,6,7,8,9,10"
ENTRIES='fw_|random_|act_(I-add-00|I-sb-00|I-bltu-00|I-fence-00|ExceptionsZc-00|U-00|S-00)' 
while [ $# -gt 0 ]; do
    case "$1" in
        --random-count) COUNT="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --outdir) OUT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --entries) ENTRIES="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

caught=0; missed=0
for m in ${ONLY//,/ }; do
    case "$m" in
        5) args=(--corpus irq --irq-mode 2 --irq-late) ;;
        9) args=(--corpus smc --memcfg-b cache) ;;
        *) args=(--corpus all --only "$ENTRIES" --random-count "$COUNT") ;;
    esac
    log="$OUT/mutant_$m.log"
    mkdir -p "$OUT"
    bash verification/lockstep/run_lockstep.sh --mode mutant --mutant "$m" "${args[@]}" -j "$JOBS" \
        --outdir "$OUT/m$m" > "$log" 2>&1
    rc=$?
    first=$(grep 'LOCKSTEP_RESULT: FAIL' "$log" | head -1)
    if [ $rc -eq 0 ] && [ -n "$first" ]; then
        printf 'mutant %-2s caught   %s\n' "$m" "$first"
        caught=$((caught + 1))
    else
        printf 'mutant %-2s NOT CAUGHT (rc=%s, see %s)\n' "$m" "$rc" "$log"
        missed=$((missed + 1))
    fi
done
echo "=== kill matrix: $caught caught, $missed not caught ==="
[ $missed -eq 0 ]
