#!/bin/bash
# run.sh [--mutants] -- module-level SymbiYosys proofs for units of the pipelined core.
# Run under WSL (sby, yosys-slang, boolector; see the riscv-formal README).
#
#   fetch.sby, lsu.sby, dbg.sby, ptw.sby, sb.sby: prove (k-induction), bmc and cover tasks must all
#   PASS (cover: every non-vacuity cover point reached).
#   --mutants: each property set must also catch known-bad versions, each
#   FAILing a BMC: the pre-fix qv_fetch whose 1-bit epoch let a stale
#   response through (ade0d1c^), and hand-made mutants of both units
#   (for the LSU also the A extension's: an SC that ignores its
#   reservation, a gap or a stray lock, a write after a faulting or
#   flushed read, an AMO that never writes, and a PMP-denied access that
#   still goes to the bus; for the debug flags a start outside Debug Mode,
#   a resume during a Program Buffer run, an injector that ignores the word
#   in flight or the queue, an index that moves at the run's last word, the
#   Debug Module owning the ports during a run, a step that is never armed;
#   for the walker a cancelled walk that reports, a beat that starts while the
#   LSU is busy or for a denied address, a beat abandoned on a cancel or held
#   into its response cycle, an F read outside the RAM window off the real path, a waiting F that does not give way
#   to D; for the store buffer a drain out of order, a lost byte select, a beat that starts while
#   the LSU is on the bus or the walker's beat is in flight, one that ignores the full-buffer rule, a cyc held into
#   the response cycle, an answer taken that is not the buffer's own, an o_match that sees a dead entry, a beat
#   with nothing to write, a push into a full buffer, an idle start that follows the response; for fetch a stream through a redirect, a yield or
#   a full buffer, a request presented with the old address).
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
REPO=$(cd ../../.. && pwd)
fail=0

status() { grep -o 'DONE ([A-Z]*' | head -1 | sed 's/DONE (//'; }

for unit in fetch lsu dbg ptw sb fpu; do
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
        cp "$REPO/design/pipe/qv_pkg.sv" "$REPO/design/pipe/qv_pmp.sv" "$REPO/design/pipe/qv_pte.sv" "$HERE/${unit}_props.sv" "$d/"
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
read_slang --single-unit $defs qv_pkg.sv qv_pmp.sv qv_pte.sv qv_$unit.sv ${unit}_props.sv --top ${unit}_props
prep -top ${unit}_props
[files]
qv_pkg.sv
qv_pmp.sv
qv_pte.sv
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
    mutant fetch_ignores_hold  fetch 's/ \&\& !i_hold$//'
    mutant fetch_abandons      fetch 's/assign wb_fetch_cyc_o  = bus \&\& (!(wb_fetch_ack_i || wb_fetch_err_i) || stream_go);/assign wb_fetch_cyc_o  = bus \&\& (!(wb_fetch_ack_i || wb_fetch_err_i) || stream_go) \&\& !i_redirect_valid;/'
    mutant fetch_stream_redirect fetch 's/ \&\& !i_redirect_valid \&\& (!i_xl_on || stream_reuse)/ \&\& (!i_xl_on || stream_reuse)/'
    mutant fetch_stream_yield  fetch 's/ \&\& (!i_xl_on || stream_reuse) \&\& !i_yield;/ \&\& (!i_xl_on || stream_reuse);/'
    mutant fetch_stream_room   fetch 's/wire stream_go = STREAM \&\& can_issue \&\& bus_resp/wire stream_go = STREAM \&\& bus_resp/'
    mutant fetch_credit        fetch 's/(fb_count_next < CNT_W.(FB_DEPTH))/(fb_count_next <= CNT_W'"'"'(FB_DEPTH))/'
    mutant fetch_stream_addr   fetch 's/: {fpc_q\[31:3\], 3.b000})/: {req_pc_q[31:3], 3'"'"'b000})/'
    mutant fetch_hint_ignored  fetch 's/fpc_q       <= hint ? i_btb_tgt : {issue_pc\[63:3\], 3.b000} + 64.d8;/fpc_q       <= {issue_pc[63:3], 3'"'"'b000} + 64'"'"'d8;/'
    mutant fetch_hint_lost     fetch 's/fb_hint\[fb_wr_q\]  <= req_hint_q;/fb_hint[fb_wr_q]  <= 1'"'"'b0;/'
    mutant fetch_hint_tgt      fetch 's/fb_htgt\[fb_wr_q\]  <= req_htgt_q;/fb_htgt[fb_wr_q]  <= req_htgt_q + 64'"'"'d2;/'
    mutant lsu_ignores_head    lsu 's/wire at_head  = (state_q == S_WAIT_HEAD) \&\& i_head_valid \&\& (i_head_tag == tag_q) \&\& !i_flush;/wire at_head  = (state_q == S_WAIT_HEAD) \&\& !i_flush;/'
    mutant lsu_misaligned_bus  lsu 's/wire start_raw = at_head \&\& !misaligned_q \&\& !pmp_deny/wire start_raw = at_head \&\& !pmp_deny/'
    mutant lsu_pmp_bus         lsu 's/wire start_raw = at_head \&\& !misaligned_q \&\& !pmp_deny \&\& !sc_fail/wire start_raw = at_head \&\& !misaligned_q \&\& !sc_fail/'
    mutant lsu_reissues        lsu 's/^                        state_q <= S_IDLE;/                        state_q <= S_WAIT_HEAD;/'
    mutant lsu_abandons        lsu 's/assign wb_mem_cyc_o  = (start || in_bus) \&\& !resp;/assign wb_mem_cyc_o  = (start || in_bus) \&\& !resp \&\& !i_flush;/'
    mutant lsu_sc_no_reservation lsu 's/wire sc_fail  = sc_q \&\& !(i_res_valid \&\& i_res_addr == addr_q);/wire sc_fail  = 1'"'"'b0;/'
    mutant lsu_lock_gap        lsu 's/assign wb_mem_lock_o = amo_q \&\& (start || in_bus);/assign wb_mem_lock_o = amo_q \&\& (start || in_bus) \&\& !(state_q == S_BUS \&\& wb_mem_ack_i);/'
    mutant lsu_lock_for_all    lsu 's/assign wb_mem_lock_o = amo_q \&\& (start || in_bus);/assign wb_mem_lock_o = (start || in_bus);/'
    mutant lsu_write_after_err lsu 's/wb_mem_ack_i \&\& !wb_mem_err_i \&\& !i_flush;/wb_mem_ack_i \&\& !i_flush;/'
    mutant lsu_write_after_flush lsu 's/wb_mem_ack_i \&\& !wb_mem_err_i \&\& !i_flush;/wb_mem_ack_i \&\& !wb_mem_err_i;/'
    mutant lsu_amo_never_writes lsu 's/wire amo_read_ack = (state_q == S_BUS) \&\& amo_q \&\& !phase_wr_q \&\& wb_mem_ack_i \&\& !wb_mem_err_i \&\& !i_flush;/wire amo_read_ack = 1'"'"'b0;/'
    mutant dbg_start_not_halted dbg 's/i_progbuf_start \&\& in_debug_q \&\& !active_q \&\& !i_resume_req)   active_q/i_progbuf_start \&\& !active_q \&\& !i_resume_req)   active_q/'
    mutant dbg_start_beats_resume dbg 's/ \&\& !i_resume_req)   active_q/)   active_q/'
    mutant dbg_resume_in_run   dbg 's/assign o_resume = i_resume_req \&\& in_debug_q \&\& !active_q;/assign o_resume = i_resume_req \&\& in_debug_q;/'
    mutant dbg_multi_inject    dbg 's/assign o_inject_valid = active_q \&\& !outstanding_q \&\& i_inject_ready;/assign o_inject_valid = active_q \&\& i_inject_ready;/'
    mutant dbg_inject_no_room  dbg 's/ \&\& i_inject_ready;/;/'
    mutant dbg_idx_on_last     dbg 's/else if (i_pb_commit \&\& !i_pb_end)/else if (i_pb_commit)/'
    mutant dbg_access_in_run   dbg 's/assign o_dm_access_active = in_debug_q \&\& !active_q;/assign o_dm_access_active = in_debug_q;/'
    mutant dbg_step_unarmed    dbg 's/else if (o_resume)       stepping_q <= i_dcsr_step;/else if (o_resume)       stepping_q <= 1'"'"'b0;/'
    mutant ptw_cancelled_reports ptw 's/wire stale_eff  = stale_q || cancel_srv;/wire stale_eff  = 1'"'"'b0;/'
    mutant ptw_ignores_lsu     ptw 's/wire go_beat = (st_q == W_GO) \&\& !i_lsu_busy \&\& !f_wait;/wire go_beat = (st_q == W_GO) \&\& !f_wait;/'
    mutant ptw_f_ignores_window ptw 's/wire go_beat = (st_q == W_GO) \&\& !i_lsu_busy \&\& !f_wait;/wire go_beat = (st_q == W_GO) \&\& !i_lsu_busy;/'
    mutant ptw_f_never_gives_up ptw 's/end else if (f_wait \&\& d_can) begin/end else if (1'"'"'b0) begin/'
    mutant ptw_denied_reaches_bus ptw 's/end else if (pmp_deny) begin/end else if (1'"'"'b0) begin/'
    mutant ptw_cyc_in_response ptw 's/assign o_bus_cyc  = beat_q \&\& !(i_bus_ack || i_bus_err);/assign o_bus_cyc  = beat_q;/'
    mutant ptw_abandons_on_cancel ptw 's/assign o_bus_cyc  = beat_q \&\& !(i_bus_ack || i_bus_err);/assign o_bus_cyc  = beat_q \&\& !(i_bus_ack || i_bus_err) \&\& !cancel_srv;/'
    mutant ptw_stale_decoded   ptw 's/if (st_q == W_DEC \&\& !stale_eff) begin/if (st_q == W_DEC) begin/'
    mutant sb_out_of_order     sb 's/assign o_addr      = {addr_q\[rd_q\], 3'"'"'b000};/assign o_addr      = {addr_q[wr_q], 3'"'"'b000};/'
    mutant sb_loses_select     sb 's/assign o_sel       = sel_q\[rd_q\];/assign o_sel       = 8'"'"'hFF;/'
    mutant sb_ignores_lsu_bus  sb 's/ \&\& !i_lsu_inflight \&\& !i_ptw_beat$/ \&\& !i_ptw_beat/'
    mutant sb_ignores_walker   sb 's/ \&\& !i_lsu_inflight \&\& !i_ptw_beat$/ \&\& !i_lsu_inflight/'
    mutant sb_always_urgent    sb 's/wire urgent   = full || (held_q >= 8'"'"'(YIELD_MAX));/wire urgent   = 1'"'"'b1;/'
    mutant sb_cyc_in_response  sb 's/assign o_cyc       = beat_q \&\& !(i_ack || i_err);/assign o_cyc       = beat_q;/'
    mutant sb_takes_foreign_ack sb 's/wire resp     = beat_q \&\& (i_ack || i_err);/wire resp     = (i_ack || i_err);/'
    mutant sb_match_dead_entry sb 's/if (v_q\[i\] \&\& addr_q\[i\] == i_match_addr) o_match = 1'"'"'b1;/if (addr_q[i] == i_match_addr) o_match = 1'"'"'b1;/'
    mutant sb_beat_with_nothing sb 's/wire has_next = (cnt_q > (resp ? CNT_W'"'"'(1) : CNT_W'"'"'(0)));/wire has_next = 1'"'"'b1;/'
    mutant sb_push_when_full   sb 's/wire push = i_push \&\& o_ready;/wire push = i_push;/'
    mutant sb_idle_in_response sb 's/assign o_start_idle = !beat_q \&\& (cnt_q != .0)/assign o_start_idle = (!beat_q || resp) \&\& (cnt_q != 0)/'
    # fpu_mutant NAME FILE SED-EXPR: the FP unit is five files (the datapath abstracted); one of them is mutated
    fpu_mutant() {
        local name=$1 file=$2 expr=$3
        local d=$T/$name
        mkdir -p "$d"
        for f in qv_pkg qv_fpu_round qv_fpu_pipe qv_fpu_divsqrt qv_exu_fpu; do cp "$REPO/design/pipe/$f.sv" "$d/"; done
        cp "$HERE/fpu_props.sv" "$d/"
        sed "$expr" "$REPO/design/pipe/$file.sv" > "$d/$file.sv"
        if cmp -s "$d/$file.sv" "$REPO/design/pipe/$file.sv"; then
            printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
        fi
        sed -e 's#^\.\./\.\./\.\./design/pipe/##' "$HERE/fpu.sby" > "$d/fpu.sby"
        local r
        r=$(cd "$d" && sby -f fpu.sby bmc 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    fpu_mutant fpu_wb_in_flush     qv_exu_fpu 's/o_wb.valid = (pwb.valid || ds_done) \&\& !i_flush;/o_wb.valid = (pwb.valid || ds_done);/'
    fpu_mutant fpu_ack_over_pipe   qv_exu_fpu 's/assign ds_ack    = ds_done \&\& !pwb.valid \&\& !i_flush;/assign ds_ack    = ds_done \&\& !i_flush;/'
    fpu_mutant fpu_ds_always_free  qv_exu_fpu 's/assign o_ds_free = !ds_busy;/assign o_ds_free = 1'"'"'b1;/'
    fpu_mutant fpu_flush_keeps_r1  qv_fpu_pipe 's/if (rst || i_flush) r1_valid <= 1'"'"'b0;/if (rst) r1_valid <= 1'"'"'b0;/'
    fpu_mutant fpu_ds_not_killed   qv_fpu_divsqrt 's/if (rst || i_flush) begin/if (rst) begin/'
    fpu_mutant fpu_ds_no_hold      qv_fpu_divsqrt 's/S_DONE: if (i_ack) st_q <= S_IDLE;/S_DONE: st_q <= S_IDLE;/'
    fpu_mutant fpu_ds_busy_short   qv_fpu_divsqrt 's/assign o_busy = st_q != S_IDLE;/assign o_busy = st_q == S_ITER;/'
    fpu_mutant fpu_tag_skips_stage qv_fpu_pipe 's/r2_tag <= r1_tag;/r2_tag <= r0.tag;/'
    fpu_mutant fpu_stage_skipped   qv_fpu_pipe 's/r3_valid <= r2_valid;/r3_valid <= r1_valid;/'
    rm -rf "$T"
fi

[ "$fail" == "0" ] && echo "MODULE PROOFS: PASS" || echo "MODULE PROOFS: FAIL"
exit $fail
