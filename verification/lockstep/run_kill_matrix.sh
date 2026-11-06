#!/bin/bash
# verification/lockstep/run_kill_matrix.sh -- the lockstep harness against its mutants (P3.4's kill matrix).
# Run under WSL bash:  wsl bash -lc "verification/lockstep/run_kill_matrix.sh [--random-count N] [-j N] [--outdir DIR] [--only 1,5,9] [--sim verilator]"
#
# Each ref_core mutant (QV_MUTANT_B = 1..18, see ref_core.sv) runs against the reference through run_lockstep.sh
# --mode mutant, and at least one corpus entry must FAIL: that is the proof the comparator can see that kind of
# bug. Most mutants are caught by the ordinary corpus (act + fw + random); three need a corpus and an option of
# their own:
#   5  interrupt sampled one cycle late    the irq corpus with injected interrupts, each level shown a cycle late
#   9  FENCE.I does not flush              the self-modifying-code corpus on the cache memory configuration
#   13 PTE-read PMP denial as page fault   the random corpus with --pmp, whose pocket can forbid a walk's PTE read
#   14-17 the F/D mutants                  the random corpus with FP instructions (--isa imafdc), both cores built
#                                          with QV_FPU_EN=1
# (11, a TLB hit skipping the permission re-check, and 12, SFENCE.VMA not flushing, are Sv39 mutants the default
# random profile catches: it translates. 18, U ignoring scounteren, it catches too: its bodies run in U with random
# counter enables and read the counters.)
# --entries REGEX narrows the ordinary corpus (run_lockstep.sh --only); the default is the firmware programs,
# the random ones and a few ACT ELFs, enough for every mutant but not the whole 200-ELF ACT set.
# Exit status 0 only if every selected mutant was caught.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.." || exit 1

COUNT=10
JOBS=3
OUT=/tmp/qv_kill_matrix
SIM=iverilog
ONLY="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18"
ENTRIES='fw_|random_|act_(I-add-00|I-sb-00|I-bltu-00|I-fence-00|ExceptionsZc-00|U-00|S-00|Zca-c.addi16sp-00)'
while [ $# -gt 0 ]; do
    case "$1" in
        --random-count) COUNT="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --outdir) OUT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --entries) ENTRIES="$2"; shift 2 ;;
        --sim) SIM="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

caught=0; missed=0
for m in ${ONLY//,/ }; do
    envp=()
    case "$m" in
        5) args=(--corpus irq --irq-mode 2 --irq-late) ;;
        9) args=(--corpus smc --memcfg-b cache) ;;
        # 13 needs PMP in front of the page tables: a PTE read the PMP pocket forbids (a hole the random body probes)
        13) args=(--corpus random --random-count "$COUNT")
            envp=(QV_RANDOM_PROFILE='--isa imac --priv msu --pmp --smc --sv39') ;;
        14|15|16|17) args=(--corpus random --random-count "$COUNT" --defines "QV_FPU_EN=1")
            envp=(QV_RANDOM_PROFILE='--isa imafdc --priv msu --pmp --smc --sv39') ;;
        *) args=(--corpus all --only "$ENTRIES" --random-count "$COUNT") ;;
    esac
    log="$OUT/mutant_$m.log"
    mkdir -p "$OUT"
    env "${envp[@]}" bash verification/lockstep/run_lockstep.sh --mode mutant --mutant "$m" "${args[@]}" --sim "$SIM" -j "$JOBS" \
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
