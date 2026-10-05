#!/bin/bash
# run.sh [--mutants] -- module-level SymbiYosys proofs for core_pipe units.
# Run under WSL (sby, yosys-slang, boolector; see the riscv-formal README).
#
#   fetch.sby, lsu.sby: prove (k-induction), bmc and cover tasks must all
#   PASS (cover: every non-vacuity cover point reached).
#   --mutants: each property set must also catch known-bad versions, each
#   FAILing a BMC: the pre-fix qv_fetch whose 1-bit epoch let a stale
#   response through (ade0d1c^), and hand-made mutants of both units.
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
REPO=$(cd ../../.. && pwd)
fail=0

status() { grep -o 'DONE ([A-Z]*' | head -1 | sed 's/DONE (//'; }

for unit in fetch lsu; do
    for task in prove bmc cover; do
        r=$(sby -f $unit.sby $task 2>&1 | status)
        printf '%-12s %s\n' "$unit $task" "$r"
        [ "$r" == "PASS" ] || fail=1
    done
done

if [ "${1:-}" == "--mutants" ]; then
    T=$(mktemp -d)
    # mutant NAME UNIT (SED-EXPR | FILE) [PROPS-DEFINES]
    mutant() {
        local name=$1 unit=$2 src=$3 defs=${4:-}
        local d=$T/$name
        mkdir -p "$d"
        cp "$REPO/design/pipe/qv_pkg.sv" "$HERE/${unit}_props.sv" "$d/"
        if [ -f "$src" ]; then
            cp "$src" "$d/qv_$unit.sv"
        else
            sed "$src" "$REPO/design/pipe/qv_$unit.sv" > "$d/qv_$unit.sv"
            if cmp -s "$d/qv_$unit.sv" "$REPO/design/pipe/qv_$unit.sv"; then
                printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
            fi
        fi
        cat > "$d/m.sby" <<EOF
[options]
mode bmc
depth 24
[engines]
smtbmc boolector
[script]
plugin -i /home/potato/yosys-slang-src/build/slang.so
read_slang --single-unit $defs qv_pkg.sv qv_$unit.sv ${unit}_props.sv --top ${unit}_props
prep -top ${unit}_props
[files]
qv_pkg.sv
qv_$unit.sv
${unit}_props.sv
EOF
        local r
        r=$(cd "$d" && sby -f m.sby 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    git -C "$REPO" show 'ade0d1c^:design/pipe/qv_fetch.sv' > "$T/qv_fetch_epoch.sv"
    mutant fetch_epoch_aba     fetch "$T/qv_fetch_epoch.sv" "-D FETCH_OLD"
    mutant fetch_no_stale      fetch 's/wire resp_ok  = resp \&\& !req_stale_q \&\& !i_redirect_valid;/wire resp_ok  = resp \&\& !i_redirect_valid;/'
    mutant fetch_ignores_hold  fetch 's/ \&\& !i_hold;/;/'
    mutant fetch_abandons      fetch 's/assign wb_fetch_cyc_o  = req_valid_q \&\& !(wb_fetch_ack_i || wb_fetch_err_i);/assign wb_fetch_cyc_o  = req_valid_q \&\& !(wb_fetch_ack_i || wb_fetch_err_i) \&\& !i_redirect_valid;/'
    mutant lsu_ignores_head    lsu 's/wire at_head = (state_q == S_WAIT_HEAD) \&\& i_head_valid \&\& (i_head_tag == tag_q) \&\& !i_flush;/wire at_head = (state_q == S_WAIT_HEAD) \&\& !i_flush;/'
    mutant lsu_misaligned_bus  lsu 's/wire start   = at_head \&\& !misaligned_q;/wire start   = at_head;/'
    mutant lsu_reissues        lsu 's/S_BUS:   if (resp) state_q <= S_IDLE;/S_BUS:   if (resp) state_q <= S_WAIT_HEAD;/'
    mutant lsu_abandons        lsu 's/assign wb_mem_cyc_o  = (start || in_bus) \&\& !resp;/assign wb_mem_cyc_o  = (start || in_bus) \&\& !resp \&\& !i_flush;/'
    rm -rf "$T"
fi

[ "$fail" == "0" ] && echo "MODULE PROOFS: PASS" || echo "MODULE PROOFS: FAIL"
exit $fail
