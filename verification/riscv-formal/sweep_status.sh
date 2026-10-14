#!/bin/bash
# sweep_status.sh fsm|pipe|pipe-full [--only REGEX] [--summary] [--detail]
#
# The status table run_sweep.sh prints at its end, without running anything: one line per generated check
# (PASS, FAIL, TIMEOUT, ERROR, incomplete = still running or never finished, not run) and the PASS count.
# --summary prints only the counts and the checks that are not PASS. Safe to run while a sweep is going.
# --detail adds, from each check's own log and work directory: the solver it ran on, whether the model was
# built with QV_FORMAL_NO_MUL ("nomul") or not ("full"), and the CPU time the solver processes used (wall
# time is not shown: it includes any time the machine slept).
set -u
RVFORMAL=${RVFORMAL:-$HOME/riscv-formal}
ONLY="."; SUMMARY=0; DETAIL=0
case "${1:-}" in
    fsm)  NAME=quantiumv ;;
    pipe) NAME=quantiumv_pipe ;;
    pipe-full) NAME=quantiumv_pipe_full ;;
    *) echo "usage: sweep_status.sh fsm|pipe|pipe-full [--only REGEX] [--summary] [--detail]" >&2; exit 2 ;;
esac
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY=$2; shift 2 ;;
        --summary) SUMMARY=1; shift ;;
        --detail) DETAIL=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
CHECKS="$RVFORMAL/cores/$NAME/checks"
[ -d "$CHECKS" ] || { echo "no $CHECKS -- run sync_core.sh first" >&2; exit 1; }
cd "$CHECKS" || exit 1

status() {
    local log="$1/logfile.txt"
    if   [ ! -e "$log" ];                     then echo "not run"
    elif grep -q "DONE (PASS" "$log";         then echo "PASS"
    elif grep -q "DONE (FAIL" "$log";         then echo "FAIL"
    elif grep -q "DONE (TIMEOUT\|DONE (UNKNOWN" "$log"; then echo "TIMEOUT"
    elif grep -q "DONE (ERROR" "$log";        then echo "ERROR"
    else echo "incomplete"
    fi
}

# solver, model and CPU time of one check, from its log and work directory
detail() {
    local d="$1" log="$1/logfile.txt" solver model cpu
    solver=$(grep -o 'yosys-smtbmc -s [a-z0-9]*' "$log" 2>/dev/null | head -1 | awk '{print $3}')
    model=-
    if [ -e "$d/model/design.ys" ]; then
        if grep -q 'QV_FORMAL_NO_MUL' "$d/model/design.ys"; then model=nomul; else model=full; fi
    fi
    cpu=$(grep -o 'Elapsed process time \[H:MM:SS (secs)\]: [0-9:]*' "$log" 2>/dev/null | head -1 | awk '{print $NF}')
    printf '%-9s %-5s %s' "${solver:--}" "$model" "${cpu:--}"
}

pass=0; total=0
for sby in $(ls *.sby | grep -v '_p31\.sby$' | grep -E "$ONLY" | sort); do
    check=${sby%.sby}
    s=$(status "$check")
    total=$((total + 1))
    [ "$s" == "PASS" ] && pass=$((pass + 1))
    if [ "$SUMMARY" == "0" ] || [ "$s" != "PASS" ]; then
        if [ "$DETAIL" == "1" ]; then
            printf '%-28s %-10s %s\n' "$check" "$s" "$(detail "$check")"
        else
            printf '%-28s %s\n' "$check" "$s"
        fi
    fi
done
echo "SWEEP $NAME: $pass/$total PASS"
