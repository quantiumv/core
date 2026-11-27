#!/bin/bash
# run.sh [--mutants] -- module-level SymbiYosys proofs for units of the pipelined core.
# Run under WSL (sby, yosys-slang, boolector, bitwuzla; see the riscv-formal README).
#
#   lsq.sby (the queue with the engine): bmc and cover only.
#   fetch.sby, lsu.sby, dbg.sby, ptw.sby, sb.sby, rs.sby: prove (k-induction), bmc and cover tasks must all
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
#   with nothing to write, a push into a full buffer, an idle start that follows the response, a drain that yields to
#   a ready LSU access far from the head (P9d's rule, off since O4f); for fetch a stream through a redirect, a yield or
#   a full buffer, a request presented with the old address; for the reservation station a late operand woken by a
#   unit's writeback, no dispatch-cycle capture, the youngest entry first, a divide past an older one or to a busy
#   divider, a select in a flush cycle, an entry that stays after it goes, a lost divider wakeup, an FMA that ignores
#   its third operand, room in a full station, a flush that keeps the entries; and in a two-wide core (rs2: two
#   pushes, two ALU ports) a multiply or port 0's entry on port 1, port 1 in a flush cycle or keeping its entry, a
#   second push without the dispatch-cycle capture or ahead of the first, port 1's bus lost).
#   (O3) kill.sby (issue's producer tables and the ROB's kill, together) and ras.sby (the circular return-address
#   stack against the shift stack it replaced, no restores): prove, bmc and cover; --mutants: a kill that rebuilds
#   nothing, the oldest writer winning, late not rebuilt, no tail rollback, killed entries or this cycle's retirements
#   among the survivors, a kill vector that takes the tail; a flush copy in the wrong order, the second op's push
#   lost, a pop that wraps an empty count; and the kills the other proofs now take (rs, rs2, fpu, lsu, lsq): a killed
#   entry selected or kept, a pipeline stage or a divide that ignores its kill, a killed op written back, a killed op
#   offered to the engine, a queue that does not roll back.
#   (O8b) fetch.sby's *_w tasks (the window aligner's fetch: the entry behind the head, popping two, a request from an
#   idle bus in its issue cycle) and align2.sby (qv_align2 against a model fetch buffer, on bitwuzla); (O8a) gh.sby
#   (qv_gshare's global history against a ghost of the instructions in flight);
#   --mutants: an idle-bus request that ignores the buffer's room, a redirect or the reset, two
#   pops counted or moved as one, two pops with one entry, the entry behind the head read at the head; and for the
#   aligner a window that joins a faulted entry, a crossing instruction's second half taken from its first, both
#   entries popped early, the position in the second entry lost; for the global history a restore with the predicted
#   direction, a jump's restore that shifts, a flush without this cycle's retirement, a lost shift, a committed history
#   that never moves.
#   (W3b) fetch.sby's *_16 tasks (FETCH16: 16-byte blocks, two entries an answer, the second BTB lookup); --mutants:
#   room for one entry, the upper dword pushed after a taken branch in the lower one or for a start in the upper one,
#   the upper dword's hint not followed or lost or its target changed, the upper entry's pc or data wrong, a start in
#   the upper dword with the lower dword's data, the second push not counted or overwritten, the dword asked for.
#   (O5a) dc.sby (qv_dc, the D$ inside the core, against a shadow of one symbolic dword): prove, bmc and cover at
#   2 x 2, bmc4 at 4 x 4; --mutants: a hit on an invalid line, an install after a snoop or an error, an update that
#   writes a line not holding its address or ignores its byte select, a snoop or an invalidation ignored, cyc held into
#   the response cycle, the beats out of order, the answer from the wrong beat, an error that does not end the refill.
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
REPO=$(cd ../../.. && pwd)
export PYTHONPATH="$HOME/yosys-py-patch${PYTHONPATH:+:$PYTHONPATH}"   # smtio.py fix for bitwuzla (the lsq opw tasks)
fail=0

status() { grep -o 'DONE ([A-Z]*' | head -1 | sed 's/DONE (//'; }

for unit in fetch lsu dbg ptw sb fpu rs rs2 kill ras align2 gh dc; do
    for task in prove bmc cover; do
        r=$(sby -f $unit.sby $task 2>&1 | status)
        printf '%-12s %s\n' "$unit $task" "$r"
        [ "$r" == "PASS" ] || fail=1
    done
done
# (O8b) the window aligner's fetch
for task in prove_w bmc_w cover_w prove_w2; do
    r=$(sby -f fetch.sby $task 2>&1 | status)
    printf '%-12s %s\n' "fetch $task" "$r"
    [ "$r" == "PASS" ] || fail=1
done
# (W3a) the store buffer draining a beat a cycle (PIPE)
for task in prove_p bmc_p cover_p; do
    r=$(sby -f sb.sby $task 2>&1 | status)
    printf '%-12s %s\n' "sb $task" "$r"
    [ "$r" == "PASS" ] || fail=1
done
# (W3b) 16-byte fetch: the core's FB_DEPTH 5, and the formal small 3
for task in prove_16 bmc_16 cover_16 prove_16s; do
    r=$(sby -f fetch.sby $task 2>&1 | status)
    printf '%-12s %s
' "fetch $task" "$r"
    [ "$r" == "PASS" ] || fail=1
done
# (O5a) the D$ at 4 lines x 4 dwords: bounded
r=$(sby -f dc.sby bmc4 2>&1 | status)
printf '%-12s %s\n' "dc bmc4" "$r"
[ "$r" == "PASS" ] || fail=1
# the load/store queue with the engine (lsq.sby): bounded only, no k-induction (see lsq_props.sv)
for task in bmc cover opw opw_cover; do
    r=$(sby -f lsq.sby $task 2>&1 | status)
    printf '%-12s %s\n' "lsq $task" "$r"
    [ "$r" == "PASS" ] || fail=1
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
read_slang --single-unit -D QV_ROB_MAX=8 $defs qv_pkg.sv qv_pmp.sv qv_pte.sv qv_$unit.sv ${unit}_props.sv --top ${unit}_props
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
    # (O5a) the D$
    mutant dc_hit_invalid      dc 's/assign o_hit = valid_q\[l_idx\] \&\& (tag_q\[l_idx\] == l_tag);/assign o_hit = (tag_q[l_idx] == l_tag);/'
    mutant dc_snoop_no_kill    dc 's/wire snoop_f = i_snoop \&\& busy_q \&\& (i_snoop_addr\[31:OB\] == f_line_q);/wire snoop_f = 1'"'"'b0;/'
    mutant dc_install_on_err   dc 's/valid_q\[f_idx\] <= !i_err \&\& !kill_q/valid_q[f_idx] <= !kill_q/'
    mutant dc_update_allocates dc 's/if (i_wr \&\& holds(i_wr_addr\[31:OB\]))/if (i_wr)/'
    mutant dc_update_no_sel    dc 's/<= merge(data_q\[w_idx\]\[w_word\], i_wr_sel, i_wr_dat);/<= i_wr_dat;/'
    mutant dc_snoop_ignored    dc 's/if (i_snoop \&\& holds(i_snoop_addr\[31:OB\])) valid_q/if (1'"'"'b0) valid_q/'
    mutant dc_inv_ignored      dc 's/if (i_inv \&\& holds(i_inv_addr\[31:OB\]))     valid_q/if (1'"'"'b0)     valid_q/'
    mutant dc_cyc_held         dc 's/assign o_beat     = beat_q \&\& !(i_ack || i_err);/assign o_beat     = beat_q;/'
    mutant dc_beat_order       dc 's/f_beat_q <= f_beat_q + 1.b1;/f_beat_q <= f_beat_q;/'
    mutant dc_fill_from_last   dc 's/assign o_fill_dat = (f_beat_q == f_word_q) ? i_dat : f_dat_q;/assign o_fill_dat = i_dat;/'
    mutant dc_err_no_end       dc 's/wire               f_end  = resp \&\& (last || i_err);/wire               f_end  = resp \&\& last;/'
    git -C "$REPO" show 'ade0d1c^:design/pipe/qv_fetch.sv' > "$T/qv_fetch_epoch.sv"
    mutant fetch_epoch_aba     fetch "$T/qv_fetch_epoch.sv" "-D FETCH_OLD"
    mutant fetch_no_stale      fetch 's/wire resp_ok  = resp \&\& !req_stale_q \&\& !i_redirect_valid;/wire resp_ok  = resp \&\& !i_redirect_valid;/'
    mutant fetch_ignores_hold  fetch 's/ \&\& !i_hold$//'
    mutant fetch_abandons      fetch 's/assign wb_fetch_cyc_o  = (bus \&\& (!(wb_fetch_ack_i || wb_fetch_err_i) || stream_go)) || idle_go;/assign wb_fetch_cyc_o  = (bus \&\& (!(wb_fetch_ack_i || wb_fetch_err_i) || stream_go) \&\& !i_redirect_valid) || idle_go;/'
    mutant fetch_stream_redirect fetch 's/ \&\& !i_redirect_valid \&\& (!i_xl_on || stream_reuse)/ \&\& (!i_xl_on || stream_reuse)/'
    mutant fetch_stream_yield  fetch 's/ \&\& (!i_xl_on || stream_reuse) \&\& !i_yield;/ \&\& (!i_xl_on || stream_reuse);/'
    mutant fetch_stream_room   fetch 's/wire stream_go = STREAM \&\& can_issue \&\& bus_resp/wire stream_go = STREAM \&\& bus_resp/'
    mutant fetch_credit        fetch 's/(fb_count_next < CNT_W.(FB_DEPTH - (FETCH16 ? 1 : 0)))/(fb_count_next <= CNT_W'"'"'(FB_DEPTH - (FETCH16 ? 1 : 0)))/'
    mutant fetch_stream_addr   fetch 's/: {fpc_q\[31:3\], 3.b000})/: {req_pc_q[31:3], 3'"'"'b000})/'
    mutant fetch_hint_ignored  fetch 's/fpc_q       <= hint ? i_btb_tgt : {issue_pc\[63:3\], 3.b000} + 64.d8;/fpc_q       <= {issue_pc[63:3], 3'"'"'b000} + 64'"'"'d8;/'
    mutant fetch_hint_lost     fetch 's/fb_hint\[fb_wr_q\]  <= req_hint_q;/fb_hint[fb_wr_q]  <= 1'"'"'b0;/'
    mutant fetch_hint_tgt      fetch 's/fb_htgt\[fb_wr_q\]  <= req_htgt_q;/fb_htgt[fb_wr_q]  <= req_htgt_q + 64'"'"'d2;/'
    mutant fetch_idle_room     fetch 's/wire idle_go   = IDLE_GO \&\& !rst \&\& STREAM \&\& can_issue \&\& !req_valid_q/wire idle_go   = IDLE_GO \&\& !rst \&\& STREAM \&\& !i_hold \&\& !req_valid_q/' "-D IDLEGO"
    mutant fetch_idle_redirect fetch 's/ \&\& can_issue \&\& !req_valid_q \&\& !i_redirect_valid$/ \&\& can_issue \&\& !req_valid_q/' "-D IDLEGO"
    mutant fetch_idle_reset    fetch 's/wire idle_go   = IDLE_GO \&\& !rst \&\& STREAM/wire idle_go   = IDLE_GO \&\& STREAM/' "-D IDLEGO"
    mutant fetch_pop2_count    fetch 's/ - CNT_W.(fb_pop) - CNT_W.(fb_pop2)$/ - CNT_W'"'"'(fb_pop)/' "-D IDLEGO"
    mutant fetch_pop2_ptr      fetch 's/if (fb_pop) fb_rd_q <= fb_pop2 ? ptr_inc(ptr_inc(fb_rd_q)) : ptr_inc(fb_rd_q);/if (fb_pop) fb_rd_q <= ptr_inc(fb_rd_q);/' "-D IDLEGO"
    mutant fetch_pop2_one      fetch 's/wire fb_pop2 = i_buf_pop2 \&\& fb_pop \&\& (fb_count_q >= CNT_W.(2));/wire fb_pop2 = i_buf_pop2 \&\& fb_pop;/' "-D IDLEGO"
    mutant fetch_buf1_head     fetch 's/assign o_buf1_pc    = fb_pc\[fb_rd1\];/assign o_buf1_pc    = fb_pc[fb_rd_q];/' "-D IDLEGO"
    # (W3b) 16-byte fetch, at the core's FB_DEPTH 5
    mutant fetch16_room        fetch 's/(fb_count_next < CNT_W.(FB_DEPTH - (FETCH16 ? 1 : 0)))/(fb_count_next < CNT_W'"'"'(FB_DEPTH))/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_two_hint    fetch 's/wire        two      = FETCH16 \&\& !issue_pc\[3\] \&\& !hint;/wire        two      = FETCH16 \&\& !issue_pc[3];/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_two_upper   fetch 's/wire        two      = FETCH16 \&\& !issue_pc\[3\] \&\& !hint;/wire        two      = FETCH16 \&\& !hint;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_hint2_lost  fetch 's/if (two) fpc_q <= hint2 ? i_btb2_tgt : /if (two) fpc_q <= /' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_h2_entry    fetch 's/fb_hint\[fb_wr1\]  <= req_h2_q;/fb_hint[fb_wr1]  <= 1'"'"'b0;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_h2_tgt      fetch 's/fb_htgt\[fb_wr1\]  <= req_h2tgt_q;/fb_htgt[fb_wr1]  <= req_h2tgt_q + 64'"'"'d2;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_upper_pc    fetch 's/fb_pc\[fb_wr1\]    <= {req_pc_q\[63:4\], 4.b1000};/fb_pc[fb_wr1]    <= req_pc_q;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_upper_data  fetch 's/fb_data\[fb_wr1\]  <= flt_resp ? 64.b0 : wb_fetch_dat_hi_i;/fb_data[fb_wr1]  <= wb_fetch_dat_i;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_start_data  fetch 's/if (FETCH16 \&\& req_pc_q\[3\] \&\& !flt_resp) fb_data/if (1'"'"'b0) fb_data/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_push2_count fetch 's/^ *+ CNT_W.(fb_push2);/;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_push2_ptr   fetch 's/fb_wr_q          <= ptr_inc(fb_wr1);/fb_wr_q          <= fb_wr1;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant fetch16_dword_addr  fetch 's/assign wb_fetch_addr_o = FETCH16 ? {addr_dw\[31:4\], 4.b0000} : addr_dw;/assign wb_fetch_addr_o = addr_dw;/' "-D FBD=5 -D IDLEGO -D F16"
    mutant lsu_ignores_head    lsu 's/wire at_head  = (state_q == S_WAIT_HEAD) \&\& i_head_valid \&\& (i_head_tag == tag_q) \&\& !i_flush;/wire at_head  = (state_q == S_WAIT_HEAD) \&\& !i_flush;/'
    mutant lsu_misaligned_bus  lsu 's/wire start_raw = go \&\& !misaligned_q \&\& !pmp_deny/wire start_raw = go \&\& !pmp_deny/'
    mutant lsu_pmp_bus         lsu 's/wire start_raw = go \&\& !misaligned_q \&\& !pmp_deny \&\& !sc_fail/wire start_raw = go \&\& !misaligned_q \&\& !sc_fail/'
    mutant lsu_reissues        lsu 's/^                        state_q <= S_IDLE;/                        state_q <= S_WAIT_HEAD;/'
    mutant lsu_abandons        lsu 's/assign wb_mem_cyc_o  = (start || (in_bus \&\& !fill_q)) \&\& !bus_resp;/assign wb_mem_cyc_o  = (start || (in_bus \&\& !fill_q)) \&\& !bus_resp \&\& !i_flush;/'
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
    mutant sb_out_of_order     sb 's/assign o_addr      = {addr_q\[cur\], 3'"'"'b000};/assign o_addr      = {addr_q[wr_q], 3'"'"'b000};/'
    mutant sb_loses_select     sb 's/assign o_sel       = sel_q\[cur\];/assign o_sel       = 8'"'"'hFF;/'
    mutant sb_ignores_lsu_bus  sb 's/ \&\& !i_lsu_inflight \&\& !i_ptw_beat$/ \&\& !i_ptw_beat/'
    mutant sb_ignores_walker   sb 's/ \&\& !i_lsu_inflight \&\& !i_ptw_beat$/ \&\& !i_lsu_inflight/'
    mutant sb_always_urgent    sb 's/wire urgent   = full || (held_q >= 8'"'"'(YIELD_MAX));/wire urgent   = 1'"'"'b1;/'
    mutant sb_cyc_in_response  sb 's/assign o_cyc       = beat_q \&\& (!(i_ack || i_err) || nxt);/assign o_cyc       = beat_q;/'
    mutant sb_takes_foreign_ack sb 's/wire resp     = beat_q \&\& (i_ack || i_err);/wire resp     = (i_ack || i_err);/'
    mutant sb_match_dead_entry sb 's/if (v_q\[i\] \&\& addr_q\[i\] == i_match_addr) o_match = 1'"'"'b1;/if (addr_q[i] == i_match_addr) o_match = 1'"'"'b1;/'
    mutant sb_beat_with_nothing sb 's/wire has_next = (cnt_q > (resp ? CNT_W'"'"'(1) : CNT_W'"'"'(0)));/wire has_next = 1'"'"'b1;/'
    # (W3a) a beat a cycle: the response cycle's request is the next entry, and only then held. (A next beat that ignores
    # the drain's holds is equivalent at DEPTH 2 -- a response with a next entry means a full buffer, which never
    # yields -- and is left to qv_sb_tb at DEPTH 4: verification/pipe/mutants/w3a_unit_sb.json.)
    mutant sb_pipe_same_entry  sb 's/wire \[PTR_W-1:0\] cur = nxt ? ptr_inc(rd_q) : rd_q;/wire [PTR_W-1:0] cur = rd_q;/' "-D QV_SB_PIPE"
    mutant sb_pipe_cyc_held    sb 's/assign o_cyc       = beat_q \&\& (!(i_ack || i_err) || nxt);/assign o_cyc       = beat_q \&\& (!(i_ack || i_err) || PIPE);/' "-D QV_SB_PIPE"
    mutant sb_push_when_full   sb 's/wire push = i_push \&\& o_ready;/wire push = i_push;/'
    mutant sb_idle_in_response sb 's/assign o_start_idle = !beat_q \&\& (cnt_q != .0)/assign o_start_idle = (!beat_q || resp) \&\& (cnt_q != 0)/'
    mutant sb_yields_to_ready  sb 's/!(YIELD_READY \&\& i_lsu_busy)/!i_lsu_busy/g'
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
    fpu_mutant fpu_wb_in_flush     qv_exu_fpu 's/o_wb.valid = (pwb.valid || ds_live) \&\& !i_flush;/o_wb.valid = (pwb.valid || ds_live);/'
    fpu_mutant fpu_ack_over_pipe   qv_exu_fpu 's/assign ds_ack    = ds_live \&\& !pwb.valid \&\& !i_flush;/assign ds_ack    = ds_live \&\& !i_flush;/'
    fpu_mutant fpu_ds_always_free  qv_exu_fpu 's/assign o_ds_free = !ds_busy;/assign o_ds_free = 1'"'"'b1;/'
    fpu_mutant fpu_flush_keeps_r1  qv_fpu_pipe 's/if (rst || i_flush) r1_valid <= 1'"'"'b0;/if (rst) r1_valid <= 1'"'"'b0;/'
    fpu_mutant fpu_ds_not_killed   qv_fpu_divsqrt 's/if (rst || i_flush) begin/if (rst) begin/'
    fpu_mutant fpu_ds_no_hold      qv_fpu_divsqrt 's/S_DONE: if (i_ack) st_q <= S_IDLE;/S_DONE: st_q <= S_IDLE;/'
    fpu_mutant fpu_ds_busy_short   qv_fpu_divsqrt 's/assign o_busy = st_q != S_IDLE;/assign o_busy = st_q == S_ITER;/'
    fpu_mutant fpu_tag_skips_stage qv_fpu_pipe 's/r2_tag <= r1_tag;/r2_tag <= r0.tag;/'
    fpu_mutant fpu_stage_skipped   qv_fpu_pipe 's/r3_valid <= r2_valid;/r3_valid <= r1_valid;/'
    # lsq_mutant NAME FILE SED-EXPR: the queue proof is two units (qv_lsq, qv_lsu); one of them is mutated
    lsq_mutant() {
        local name=$1 file=$2 expr=$3
        local d=$T/$name
        mkdir -p "$d"
        for f in qv_pkg qv_pmp qv_lsq qv_lsu; do cp "$REPO/design/pipe/$f.sv" "$d/"; done
        cp "$HERE/lsq_props.sv" "$d/"
        sed "$expr" "$REPO/design/pipe/$file.sv" > "$d/$file.sv"
        if cmp -s "$d/$file.sv" "$REPO/design/pipe/$file.sv"; then
            printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
        fi
        sed -e 's#^\.\./\.\./\.\./design/pipe/##' "$HERE/lsq.sby" > "$d/lsq.sby"
        local r
        r=$(cd "$d" && sby -f lsq.sby bmc 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    lsq_mutant lsq_early_ignores_bar  qv_lsu 's/wire early     = EARLY \&\& i_early \&\& /wire early     = EARLY \&\& /'
    lsq_mutant lsq_early_outside_ram  qv_lsu 's/wire ram_ld    = pa_in_window \&\& /wire ram_ld    = /'
    lsq_mutant lsq_early_atomic       qv_lsu 's/wire ram_ld    = pa_in_window \&\& !store_q \&\& !atomic_q/wire ram_ld    = pa_in_window \&\& !store_q/'
    lsq_mutant lsq_no_match           qv_lsq 's/assign o_match = |posted_hit;/assign o_match = 1'"'"'b0;/'
    lsq_mutant lsq_match_no_copy      qv_lsq 's/r    = (copy_q \&\& copy_idx_q == IW.(i)) ? i_eng_res : res_q\[i\];/r    = res_q[i];/'
    lsq_mutant lsq_head_no_bypass     qv_lsq 's/assign o_head_res = (copy_q \&\& copy_idx_q == head_i) ? i_eng_res : res_q\[head_i\];/assign o_head_res = res_q[head_i];/'
    lsq_mutant lsq_pop_any_tag        qv_lsq 's/ \&\& (i_pop_tag == tag_q\[head_i\])//'
    lsq_mutant lsq_bar_ignored        qv_lsq 's/assign o_early  = (cmpl_q != send_q) \&\& !bar_q\[cmpl_i\] \&\& /assign o_early  = (cmpl_q != send_q) \&\& /'
    lsq_mutant lsq_newest_first       qv_lsq 's/o_eng_req       = has_q ? send_e : i_req;/o_eng_req       = i_req.valid ? i_req : send_e;/'
    # rs_mutant NAME SED-EXPR [FILE]: the reservation station, at rs.sby's own BMC depth (the generic 24 is far too deep
    # for it); FILE (default qv_rs) is the one mutated: qv_pkg for the waiting-operand rules (qv_opnd_*, O4d)
    rs_mutant() {
        local name=$1 expr=$2 f=${3:-qv_rs}
        local d=$T/$name
        mkdir -p "$d"
        cp "$REPO/design/pipe/qv_pkg.sv" "$REPO/design/pipe/qv_rs.sv" "$HERE/rs_props.sv" "$d/"
        sed "$expr" "$REPO/design/pipe/$f.sv" > "$d/$f.sv"
        if cmp -s "$d/$f.sv" "$REPO/design/pipe/$f.sv"; then
            printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
        fi
        sed -e 's#^\.\./\.\./\.\./design/pipe/##' "$HERE/rs.sby" > "$d/rs.sby"
        local r
        r=$(cd "$d" && sby -f rs.sby bmc 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    rs_mutant rs_late_wakes_on_unit  's/end else if (!o.late) begin/end else begin/' qv_pkg
    rs_mutant rs_no_capture          's/^            x.a    = qv_opnd_wake(x.a, i_wb, i_wbp, i_wbl, i_wbd, i_wbf, i_wbc);$/            x.a    = x.a;/'
    rs_mutant rs_youngest_first      's/for (int i = DEPTH - 1; i >= 0; i--) begin             \/\/ the last hit is the oldest/for (int i = 0; i < DEPTH; i++) begin/'
    rs_mutant rs_div_passes_older    's/if (v_q\[i\] \&\& kind\[i\] == QV_RS_DIV)/if (ready[i] \&\& kind[i] == QV_RS_DIV)/'
    rs_mutant rs_div_when_busy       's/o_sel_div = !i_flush \&\& div_f \&\& ready\[div_i\] \&\& i_div_free;/o_sel_div = !i_flush \&\& div_f \&\& ready[div_i];/'
    rs_mutant rs_sel_in_flush        's/o_sel_ab  = !i_flush \&\& ab_f;/o_sel_ab  = ab_f;/'
    rs_mutant rs_issued_stays        's/issued\[i\] = (o_sel_ab \&\& i == ab_i) || /issued[i] = /'
    rs_mutant rs_div_bus_lost        's/else if (wbd.valid \&\& wbd.tag == o.tag) begin n.rdy = 1.b1; n.value = wbd.value; end//' qv_pkg
    rs_mutant rs_c_ignored           's/ \&\& (x.c.rdy || qv_opnd_byp(x.c, i_wb, i_wbp, i_wbl, i_wbf, BYPASS_EN, LSU_BYPASS));/;/'
    rs_mutant rs_room_when_full      's/assign o_room = !v_q\[DEPTH-1\];/assign o_room = 1;/'
    rs_mutant rs_flush_keeps         's/v_q\[i\] <= (rst || i_flush) ? 1.b0 : n_v\[i\];/v_q[i] <= rst ? 0 : n_v[i];/'
    # rs2_mutant NAME SED-EXPR [FILE]: the station in a two-wide core (rs2_props.sv: two pushes, two ALU ports)
    rs2_mutant() {
        local name=$1 expr=$2 f=${3:-qv_rs}
        local d=$T/$name
        mkdir -p "$d"
        cp "$REPO/design/pipe/qv_pkg.sv" "$REPO/design/pipe/qv_rs.sv" "$HERE/rs2_props.sv" "$d/"
        sed "$expr" "$REPO/design/pipe/$f.sv" > "$d/$f.sv"
        if cmp -s "$d/$f.sv" "$REPO/design/pipe/$f.sv"; then
            printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
        fi
        sed -e 's#^\.\./\.\./\.\./design/pipe/##' "$HERE/rs2.sby" > "$d/rs2.sby"
        local r
        r=$(cd "$d" && sby -f rs2.sby bmc 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    rs2_mutant rs2_p1_multiply        's/ \&\& !qv_is_mul(eop\[i\])//'
    rs2_mutant rs2_p1_port0s_entry    's/ \&\& !(ab_f \&\& i == ab_i)//'
    rs2_mutant rs2_p1_in_flush        's/o_sel_p1  = !i_flush \&\& p1_f;/o_sel_p1  = p1_f;/'
    rs2_mutant rs2_p1_stays           's/|| (o_sel_p1 \&\& i == p1_i);/;/'
    rs2_mutant rs2_push2_no_capture   's/y.a = qv_opnd_wake(y.a, i_wb, i_wbp, i_wbl, i_wbd, i_wbf, i_wbc);/y.a = y.a;/'
    rs2_mutant rs2_push2_ahead        's/k   = j + (i_push ? 1 : 0);/k   = j;/'
    rs2_mutant rs2_p1_bus_lost        's/else if (wbp.valid \&\& wbp.tag == o.tag) begin n.rdy = 1.b1; n.value = wbp.value; end//' qv_pkg
    # (O3) a proof over several design files: copy what its .sby lists, mutate one of them, run its bmc task
    multi_mutant() {
        local name=$1 sbyf=$2 f=$3 expr=$4
        local d=$T/$name
        mkdir -p "$d"
        for src in $(sed -n '/^\[files\]/,$p' "$HERE/$sbyf" | grep -v '^\['); do cp "$HERE/$src" "$d/"; done
        sed "$expr" "$REPO/design/pipe/$f.sv" > "$d/$f.sv"
        if cmp -s "$d/$f.sv" "$REPO/design/pipe/$f.sv"; then
            printf '%-30s %s\n' "mutant $name" "sed changed nothing"; fail=1; return
        fi
        sed -e 's#^\.\./\.\./\.\./design/pipe/##' "$HERE/$sbyf" > "$d/$sbyf"
        local r
        r=$(cd "$d" && sby -f $sbyf bmc 2>&1 | status)
        if [ "$r" == "FAIL" ]; then
            printf '%-30s %s\n' "mutant $name" "caught"
        else
            printf '%-30s %s\n' "mutant $name" "NOT CAUGHT ($r)"; fail=1
        fi
    }
    multi_mutant kill_no_rebuild        kill.sby qv_issue 's/        end else if (i_kill) begin/        end else if (1'"'"'b0) begin/'
    multi_mutant kill_oldest_wins       kill.sby qv_issue 's/            for (int j = 0; j < QV_ROB_DEPTH; j++) begin/            for (int j = QV_ROB_DEPTH - 1; j >= 0; j--) begin/'
    multi_mutant kill_late_lost         kill.sby qv_issue 's/prod_late_q\[i_surv_rd\[j\]\] <= CSR_LATE \&\& i_surv_csr\[j\];/prod_late_q[i_surv_rd[j]] <= 1'"'"'b0;/'
    multi_mutant kill_no_rollback       kill.sby qv_rob   's/                tail_q <= kill_from;/                tail_q <= tail_q;/'
    multi_mutant kill_killed_survive    kill.sby qv_rob   "s/QV_ROB_TAG_W'(kill_from), QV_ROB_TAG_W'(head_next), PTR_W);/QV_ROB_TAG_W'(tail_q), QV_ROB_TAG_W'(head_next), PTR_W);/"
    multi_mutant kill_retired_survive   kill.sby qv_rob   "s/            p = head_next + PTR_W'(j);/            p = head_q + PTR_W'(j);/"
    multi_mutant kill_vec_takes_tail    kill.sby qv_rob   "s/                                < qv_rob_dist(QV_ROB_TAG_W'(tail_q)/                                <= qv_rob_dist(QV_ROB_TAG_W'(tail_q)/"
    multi_mutant ras_flush_order        ras.sby  qv_ras   's/a_q\[j\] <= c_next\[64\*((DEPTH - j) % DEPTH) +: 64\];/a_q[j] <= c_next[64*j +: 64];/'
    multi_mutant ras_push1_lost         ras.sby  qv_ras   's/if (i_sp_op1 == 2.b01) a_q\[p1\] <= i_sp_addr1;//'
    multi_mutant ras_pop_wraps          ras.sby  qv_ras   "s/if (op == 2'b10 \&\& n != '0) return/if (op == 2'b10) return/"
    # (O3) the kills the other proofs now take
    multi_mutant rs_killed_selected     rs.sby   qv_rs    's/ready\[i\] = v_q\[i\] \&\& !killed\[i\] \&\&/ready[i] = v_q[i] \&\&/'
    multi_mutant rs2_killed_kept        rs2.sby  qv_rs    's/if (v_q\[i\] \&\& !issued\[i\] \&\& !killed\[i\]) begin/if (v_q[i] \&\& !issued[i]) begin/'
    multi_mutant fpu_stage_kill_lost    fpu.sby  qv_fpu_pipe    "s/        if (i_kill_vec\[r1_tag\]) r2_valid <= 1'b0;//"
    multi_mutant fpu_ds_kill_lost       fpu.sby  qv_fpu_divsqrt "s/            if (st_q != S_IDLE \&\& i_kill_vec\[tag_q\]) st_q <= S_IDLE;//"
    multi_mutant lsu_killed_writes_back lsq.sby  qv_lsu   "s/        if (killed) o_wb.valid = 1'b0;//"
    multi_mutant lsq_killed_offered     lsq.sby  qv_lsq   "s/        if (i_kill_vec\[o_eng_req.tag\]) o_eng_req.valid = 1'b0;.*//"
    multi_mutant lsq_no_rollback        lsq.sby  qv_lsq   "s/                tail_q <= keep_tail;//"
    # (O8b) the window aligner against its model fetch buffer
    multi_mutant align2_joins_faulted   align2.sby qv_align2 's/wire        nseq  = i_buf1_valid \&\& !i_buf_hint \&\& !i_buf_err \&\& !i_buf1_err;/wire        nseq  = i_buf1_valid \&\& !i_buf_hint \&\& !i_buf_err;/'
    multi_mutant align2_cross_half      align2.sby qv_align2 "s/raw = {hw8(d0, d1, p + 3'd1), h};/raw = {hw8(d0, d1, p), h};/"
    multi_mutant align2_pop2_early      align2.sby qv_align2 "s/assign o_buf_pop2 = go \&\& (cur == 4'd8) \&\& !o_redirect_valid;/assign o_buf_pop2 = go \&\& (cur >= 4'd4) \&\& !o_redirect_valid;/"
    multi_mutant align2_mid_lost        align2.sby qv_align2 "s/mid_q  <= (cur < 4'd4) || (cur > 4'd4 \&\& cur < 4'd8);/mid_q  <= (cur < 4'd4);/"
    # (O8a) the global history
    multi_mutant gh_restore_pred        gh.sby     qv_gshare "s/h_q <= i_restore_cond ? shift(i_restore_h, !i_restore_pred) : i_restore_h;/h_q <= i_restore_cond ? shift(i_restore_h, i_restore_pred) : i_restore_h;/"
    multi_mutant gh_restore_jump        gh.sby     qv_gshare "s/h_q <= i_restore_cond ? shift(i_restore_h, !i_restore_pred) : i_restore_h;/h_q <= shift(i_restore_h, !i_restore_pred);/"
    multi_mutant gh_flush_stale         gh.sby     qv_gshare "s/if (i_flush)        h_q <= hc_next;/if (i_flush)        h_q <= hc_q;/"
    multi_mutant gh_shift_lost          gh.sby     qv_gshare "s/else if (i_cond)    h_q <= shift(h_q, i_pred);/else if (1'b0)      h_q <= shift(h_q, i_pred);/"
    multi_mutant gh_commit_stuck        gh.sby     qv_gshare "s/wire \[H-1:0\]    hc_next = i_upd_valid ? shift(hc_q, i_upd_taken) : hc_q;/wire [H-1:0]    hc_next = hc_q;/"
    rm -rf "$T"
fi

[ "$fail" == "0" ] && echo "MODULE PROOFS: PASS" || echo "MODULE PROOFS: FAIL"
exit $fail
