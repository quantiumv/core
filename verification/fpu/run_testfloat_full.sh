#!/bin/bash
# verification/fpu/run_testfloat_full.sh [-j N] [--outdir DIR] [--only REGEX] -- the FPU datapath against the full
# TestFloat set, under Verilator: level 2 for every function except the FMA forms, level 1 for the eight FMA forms
# (their level 2 does not end in practice: more than 124M cases per form and rounding mode), every precision and
# rounding mode. One job per function and rounding mode, each streaming gen_vectors.py into qv_fpu_vec_tb
# (+VEC=/dev/stdin), so no vector file is written. Resumable: a job whose log already ends in "0 failed" is skipped.
# Run from the repo root under WSL; needs TestFloat (see README.md) and Verilator.
set -u
JOBS=4; OUT=/tmp/qv_testfloat_full; ONLY="."
while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS=$2; shift 2 ;;
        --outdir) OUT=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        *) echo "usage: run_testfloat_full.sh [-j N] [--outdir DIR] [--only REGEX]" >&2; exit 2 ;;
    esac
done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$OUT/src"
cd "$ROOT/design"
cp -r defaults "$OUT/src/"
for f in qv_pkg qv_fp_dec qv_fpu_round qv_fpu_pipe qv_fpu_divsqrt qv_fpu_vec_tb; do cp pipe/$f.sv "$OUT/src/"; done
( cd "$OUT/src" && verilator --binary --timing -j 4 -O3 -Wno-fatal -Wno-lint -Wno-style -I. -Idefaults \
    --top-module qv_fpu_vec_tb --Mdir "$OUT/obj" qv_pkg.sv qv_fp_dec.sv qv_fpu_round.sv qv_fpu_pipe.sv \
    qv_fpu_divsqrt.sv qv_fpu_vec_tb.sv > "$OUT/build.log" 2>&1 ) || { echo "build failed: $OUT/build.log" >&2; exit 1; }

# the jobs: name|level|rm, the double-precision two-operand functions first (the longest)
python3 - "$ROOT/verification/fpu" "$ONLY" > "$OUT/jobs.txt" <<'EOF'
import re, sys
sys.path.insert(0, sys.argv[1])
import gen_vectors as g
only = re.compile(sys.argv[2])
jobs = []
for name, fn, kinds, rkind, enc, rounds, neg in g.TF_TABLE:
    if not only.search(name):
        continue
    level = 1 if neg is not None else 2
    for rm in (range(5) if rounds else [0]):
        weight = (3 if level == 1 else 0) + (2 if kinds[0] == "d" and len(kinds) == 2 else 0) + len(kinds)
        jobs.append((-weight, name, level, rm))
for _, name, level, rm in sorted(jobs):
    print(f"{name}|{level}|{rm}")
EOF
echo "$(wc -l < "$OUT/jobs.txt") jobs, $JOBS at a time, logs in $OUT"

one() {   # name|level|rm
    IFS='|' read -r name level rm <<< "$1"
    local log="$OUT/${name}_l${level}_rm${rm}.log"
    grep -q "passed, 0 failed" "$log" 2>/dev/null && return 0
    python3 ../verification/fpu/gen_vectors.py --level "$level" --only "^${name//./\\.}\$" --rm "$rm" --golden 0 \
        2> "$log.gen" | "$OUT/obj/Vqv_fpu_vec_tb" +VEC=/dev/stdin 2>&1 | \
        awk 'NR <= 100 || /vectors from|passed,|FAILURES/' > "$log"
    echo "$name level $level rm $rm: $(grep 'passed,' "$log" || echo 'no summary')"
}
export -f one; export OUT
xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} < "$OUT/jobs.txt"

pass=0; fail=0; vec=0; bad=""
while IFS='|' read -r name level rm; do
    log="$OUT/${name}_l${level}_rm${rm}.log"
    n=$(sed -n 's/.*: \([0-9]*\) passed, \([0-9]*\) failed/\1 \2/p' "$log" 2>/dev/null)
    if [ -n "$n" ] && [ "${n#* }" == "0" ]; then pass=$((pass + 1)); vec=$((vec + ${n% *})); else fail=$((fail + 1)); bad="$bad $name/rm$rm"; fi
done < "$OUT/jobs.txt"
echo "TESTFLOAT_FULL: $pass jobs clean, $fail not, $vec vectors passed${bad:+ (not clean:$bad)}"
