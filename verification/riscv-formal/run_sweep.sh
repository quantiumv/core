#!/bin/bash
# run_sweep.sh fsm|pipe [-j N] [--only REGEX] [--timeout SECONDS] [--rerun]
#
# Runs a core's generated riscv-formal checks (see sync_core.sh), N at a
# time with a 4 s stagger between launches (simultaneous launches killed
# runs in the FSM sweep) and an 8 GB memory cap each, then prints one
# status line per check. Resumable: a check whose log already says PASS
# is skipped unless --rerun, so an interrupted sweep just continues.
set -u
RVFORMAL=${RVFORMAL:-$HOME/riscv-formal}
JOBS=4; ONLY="."; TIMEOUT=7000; RERUN=0
case "${1:-}" in
    fsm)  NAME=quantiumv ;;
    pipe) NAME=quantiumv_pipe ;;
    *) echo "usage: run_sweep.sh fsm|pipe [-j N] [--only REGEX] [--timeout S] [--rerun]" >&2; exit 2 ;;
esac
shift
while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        --rerun) RERUN=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

CHECKS="$RVFORMAL/cores/$NAME/checks"
[ -d "$CHECKS" ] || { echo "no $CHECKS -- run sync_core.sh first" >&2; exit 1; }
cd "$CHECKS" || exit 1
export PYTHONPATH="$HOME/yosys-py-patch${PYTHONPATH:+:$PYTHONPATH}"   # smtio.py fix for bitwuzla
export PATH="$HOME/.local/bin:$PATH"     # sby, solvers; not on a systemd unit's PATH
command -v sby > /dev/null || { echo "sby not found" >&2; exit 1; }

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

running=0
for sby in $(ls *.sby | grep -v '_p31\.sby$' | grep -E "$ONLY" | sort); do
    check=${sby%.sby}
    [ "$RERUN" == "0" ] && [ "$(status "$check")" == "PASS" ] && continue
    ( ulimit -v 8000000; timeout "$TIMEOUT" sby -f "$sby" > /dev/null 2>&1 ) &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n
        running=$((running - 1))
    fi
    sleep 4
done
wait

pass=0; total=0
for sby in $(ls *.sby | grep -v '_p31\.sby$' | grep -E "$ONLY" | sort); do
    check=${sby%.sby}
    s=$(status "$check")
    total=$((total + 1))
    [ "$s" == "PASS" ] && pass=$((pass + 1))
    printf '%-28s %s\n' "$check" "$s"
done
echo "SWEEP $NAME: $pass/$total PASS"
