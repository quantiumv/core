// SPDX-License-Identifier: MIT

/*
 * perf_stack -- the CPI stack of the pipelined core (P9.0): where the cycles of a
 * kernel's measured window go. Testbench only; perf_tb.sv instantiates it with
 * hierarchical connections to the core's own nets and prints it next to the
 * PERF_RESULT line. It is compiled out of the reference build (the reference has
 * none of these nets).
 *
 * The window is the kernel's own. perf.h reads mcycle (CSR 0xB00) right before and
 * right after the timed region, so the window is the cycles after the commit of the
 * first such read up to and including the commit of the second: exactly the delta
 * the kernel reports. The retirements inside it are the kernel's instret delta
 * (its minstret reads sit right behind the mcycle reads), which the report checks.
 *
 * Every window cycle falls in exactly one class, in this priority:
 *   retire        an instruction commits
 *   blocked_*     the ROB is not empty and nothing commits: the head is still being
 *                 executed (lsu, div, alu: everything else, ALU/BRU/CSR/SYS), or it is
 *                 complete and commit holds it (sys: FENCE.I waiting for fetch, an
 *                 interrupt or halt taking the slot)
 *   ear_*         the ROB is empty inside the refill shadow of a redirect (from the
 *                 redirect until the first issue after it), by the redirect's source:
 *                 an align redirect (static prediction), a commit redirect for a
 *                 mispredict, for a serializing instruction, or for anything else
 *   empty_front   the ROB is empty and no redirect explains it: fetch, align, the IQ
 *                 or decode starved it
 * Side counters, not exclusive: why issue did not fire, empty queues, redirects and
 * mispredicts by kind, how long the mispredicted branches that commit redirected on
 * sat complete in the ROB before reaching the head (all P9b can save), and, on the
 * shared-SRAM harness, the cycles the LSU's request waited for the arbiter.
 *
 * P10.0 adds the bounds of the P10 steps: the translated fetch requests and how many
 * of them are in the page the last successful translation found, under the same
 * context (what reusing that page saves: P10a); the translated LSU ops whose head
 * lookup was a TLB hit after waiting before the head (one cycle each: P10b); and the
 * serializing redirects by kind, with their refill cycles (P10c). instret counts as
 * minstret does (a trapping instruction is a commit, not a retirement).
 *
 * WIN_CSR is the CSR whose reads open and close the window: mcycle (0xB00), or in the
 * S-mode build sscratch (0x140), where perf.h's rdcycle reads it as a marker and the
 * window's cycles and retirements are the result (report_result).
 */
module perf_stack #(
    parameter int          TAG_W   = 4,
    parameter logic [11:0] WIN_CSR = 12'hB00
) (
    input logic             clk,
    input logic             rst,

    input logic             commit,
    input logic             instr_retired,      // minstret counts it
    input logic             instr_retired2 = 1'b0, // (O4) a second retirement in the same cycle
    input logic             mispredict2 = 1'b0,    // (O4) ... which is a mispredicted branch: its redirect
    input logic             head_valid,
    input logic             head_complete,
    input logic [2:0]       head_cls,           // qv_fu_e: 0 ALU, 1 BRU, 2 DIV, 3 LSU, 4 CSR, 5 SYS
    input logic [31:0]      head_raw,
    input logic [63:0]      head_pc,
    input logic [63:0]      head_next_pc,
    input logic             head_mispredict,
    input logic             head_serialize,
    input logic             head_csr_wsup,      // a CSR op that writes nothing (csrr, csrrs/c x0, the immediate forms with 0)
    input logic [11:0]      head_csr_addr,
    input logic [TAG_W-1:0] head_tag,

    input logic             flush,              // a commit redirect (trap, xRET, serialize, mispredict, interrupt, debug)
    input logic             fe_flush = 1'b0,    // (O3) the frontend's flush: a commit redirect or a recovery at execute
    input logic             fe_redirect,        // an align redirect (static prediction)
    input logic             rob_empty,

    input logic             fb_valid,
    input logic             iq_valid,
    input logic             uop_valid,
    input logic [2:0]       uop_fu,
    input logic             issue_fire,
    input logic             a_ready,
    input logic             b_ready,
    input logic             c_ready = 1'b1,     // F/D: the FMA's third operand
    input logic             alloc_ready,
    input logic             lsu_free,
    input logic             div_free,
    input logic             rs_full = 1'b0,    // O1: the uop is for the reservation station, cannot go straight to its unit, and the station is full
    input logic [7:0]       rob_used = 8'd0,    // (O7) ROB entries held
    input logic [7:0]       rs_used = 8'd0,     // (O7) station entries held
    input logic             alloc_ready2 = 1'b1, // (O7) the ROB has room for two

    input logic             wb_valid,           // the fast writeback bus
    input logic             wb_mispredict,
    input logic [TAG_W-1:0] wb_tag,

    input logic             lsu_bus_wait,       // the LSU's request waits for the arbiter (SRAM harness; else 0)

    // fetch translation
    input logic             f_issue,            // fetch issues a request this cycle
    input logic [63:0]      f_issue_pc,
    input logic             f_xl_on,            // ... translated
    input logic             f_xl_req,           // a request is in its translation phase
    input logic             f_xl_done,
    input logic             f_xl_fault,
    input logic [63:0]      f_xl_va,
    input logic             f_hold,
    input logic             f_redirect,         // a redirect reaches fetch
    input logic             f_redirect_ctx,     // ... one that changes the translation context
    input logic             sfence,
    input logic             in_debug,

    // data translation
    input logic             lsu_wait_head,      // the LSU holds an op that is not started (WAIT_HEAD)
    input logic             lsu_at_head,        // ... and it is the head
    input logic             x_req,              // its translation is asked (at the head)
    input logic             x_done,
    input logic             x_fault,

    // the load/store queue (O2); 0 when the core has none
    input logic             lsq_early_ld = 1'b0,    // a load starts before it is the head
    input logic             lsq_early_st = 1'b0,    // a store is posted before it is the head
    input logic             lsq_bar_wait = 1'b0,    // the LSU's op could go early but a barrier is older
    input logic             lsq_match_wait = 1'b0,  // a load waits for an older store to its dword (queue or buffer)
    input logic             lsq_qmatch = 1'b0,      // ... one in the queue (posted, not retired)
    input logic             lsq_handoff = 1'b0,     // the LSU takes its next op as the last completes
    input logic             lsq_drain = 1'b0,       // a flush finds an early load on the bus (it is drained)

    // +ILPTRACE (O1.0): when each instruction entered the instruction queue, left it, was dispatched, reached the
    // LSU, started its access and completed (any writeback port), for the trace model verification/perf/ilp.py
    input logic             iq_push0 = 1'b0,
    input logic             iq_push1 = 1'b0,
    input logic             iq_pop = 1'b0,
    input logic             alloc_valid = 1'b0,
    input logic [TAG_W-1:0] alloc_tag = '0,
    input logic             lsu_acc = 1'b0,         // the LSU takes an op ...
    input logic [TAG_W-1:0] lsu_acc_tag = '0,       // ... with this tag
    input logic             lsu_go = 1'b0,          // its access starts (on the bus, posted, or done without the bus) ...
    input logic             lsu_go_early = 1'b0,    // ... before it is the head
    input logic [TAG_W-1:0] lsu_go_tag = '0,
    input logic             wb2_valid = 1'b0,       // the LSU's, the divider's and the FPU's writebacks
    input logic [TAG_W-1:0] wb2_tag = '0,
    input logic             wb3_valid = 1'b0,
    input logic [TAG_W-1:0] wb3_tag = '0,
    input logic             wb4_valid = 1'b0,
    input logic [TAG_W-1:0] wb4_tag = '0,
    input logic             trap = 1'b0,            // the retiring instruction takes a synchronous exception
    input logic [63:0]      mem_addr = '0,          // the head memory op's physical dword

    // (OX.0) the two-wide core. The second retirement (commit channel 1) and why it did not happen, the second
    // dispatch, the IQ's second pop, the second ALU port's writeback, the units' requests (when an op issued), the
    // fetch buffer (when an instruction's dword arrived), and the caches' refills (the SoC configuration).
    input logic             commit2 = 1'b0,
    input logic [63:0]      head1_pc = '0,
    input logic [31:0]      head1_raw = '0,
    input logic [TAG_W-1:0] head1_tag = '0,
    input logic             head1_mispredict = 1'b0,
    // (O3) a recovery at execute: its kill cycle, the branch's tag and the tags killed; the heads' mispredicts that
    // were recovered (commit retires them without a redirect)
    input logic             xr_fire = 1'b0,
    input logic [TAG_W-1:0] xr_tag = '0,
    input logic [(1<<TAG_W)-1:0] kill_vec = '0,
    input logic             head_recovered = 1'b0,
    input logic             head1_recovered = 1'b0,
    input logic [63:0]      mem_addr1 = '0,
    input logic             head1_valid = 1'b0,
    input logic             head1_complete = 1'b0,
    input logic [2:0]       head1_cls = '0,
    input logic             plain1 = 1'b0,          // qv_commit's plain1: the head commits and may be the first of a pair
    input logic             alloc2_valid = 1'b0,
    input logic [TAG_W-1:0] alloc_tag1 = '0,
    input logic             iq_pop2 = 1'b0,
    input logic             wb5_valid = 1'b0,
    input logic [TAG_W-1:0] wb5_tag = '0,
    input logic             req_alu = 1'b0,
    input logic [TAG_W-1:0] req_alu_tag = '0,
    input logic             req_alu1 = 1'b0,
    input logic [TAG_W-1:0] req_alu1_tag = '0,
    input logic             req_bru = 1'b0,
    input logic [TAG_W-1:0] req_bru_tag = '0,
    input logic             req_div = 1'b0,
    input logic [TAG_W-1:0] req_div_tag = '0,
    input logic             req_fpu = 1'b0,
    input logic [TAG_W-1:0] req_fpu_tag = '0,
    input logic             fb_push = 1'b0,         // a fetched dword enters the fetch buffer
    input logic             fb_pop = 1'b0,          // the aligner is done with the buffer's head
    input logic             fb_pop2 = 1'b0,         // (O8b) ... and with the entry behind it
    input logic             fb_flush = 1'b0,        // a redirect empties it
    input logic             lsu_in_bus = 1'b0,      // the LSU's op is on the bus
    input logic             dc_refill = 1'b0,       // the D$ refills a line
    input logic             ic_refill = 1'b0        // the I$ refills a line
);
    localparam logic [2:0] FU_DIV = 3'd2;
    localparam logic [2:0] FU_LSU = 3'd3;
    localparam logic [2:0] FU_CSR = 3'd4;
    localparam logic [2:0] FU_FPU = 3'd6;

    // the CSRs whose writes P10c lets through without a flush: m/s scratch, epc, cause, tval
    function automatic logic trap_csr(input logic [11:0] a);
        return (a >= 12'h340 && a <= 12'h343) || (a >= 12'h140 && a <= 12'h143);
    endfunction
    // the kind of a serializing head: 0 a CSR op that writes nothing, 1 a trap-CSR write, 2 another CSR op, 3 FENCE.I / SFENCE.VMA
    function automatic int ser_kind(input logic [2:0] cls, input logic wsup, input logic [11:0] a);
        if (cls != FU_CSR) return 3;
        if (wsup)          return 0;
        if (trap_csr(a))   return 1;
        return 2;
    endfunction

    typedef enum int { SRC_NONE, SRC_ALIGN, SRC_MISPRED, SRC_SERIAL, SRC_OTHER, SRC_XR } src_e;

    int win_q;                       // 0: not opened yet, 1: open, 2: closed
    longint unsigned c_window, c_retire, c_blk_lsu, c_blk_div, c_blk_alu, c_blk_sys, c_blk_fpu;
    longint unsigned c_ear_align, c_ear_mispred, c_ear_serial, c_ear_other, c_empty_front;
    longint unsigned c_iq_empty, c_fb_empty, c_is_oper, c_is_rob, c_is_lsu, c_is_div, c_no_uop, c_is_rs;
    longint unsigned c_lq_ld, c_lq_st, c_lq_bar, c_lq_match, c_lq_qmatch, c_lq_hand, c_lq_drain;
    longint unsigned c_re_align, c_re_mispred, c_re_serial, c_re_other;
    longint unsigned c_mp_cond, c_mp_jal, c_mp_jalr, c_mp_wait, c_mp_n;
    longint unsigned c_bus_wait;
    longint unsigned c_instret;
    longint unsigned c_xl_req, c_xl_reuse, c_xl_cyc, c_dx_n, c_dx_hit, c_dx_save;
    longint unsigned c_re_ser [0:3];
    longint unsigned c_ear_ser [0:3];
    // (OX.0) the second commit slot: every window cycle once more, in exactly one of these (they add up to window)
    longint unsigned c_s1_retire, c_s1_idle, c_s1_none, c_s1_wait_lsu, c_s1_wait_div, c_s1_wait_fpu, c_s1_wait_alu;
    longint unsigned c_s1_rule_head, c_s1_rule_pair;
    longint unsigned c_dc_miss, c_dc_cyc, c_ic_miss, c_ic_cyc;
    // (O3) recoveries at execute: how many, the entries they killed, the ones whose branch retired in its kill cycle
    // (no gain), the cycles they redirected ahead of the branch's commit, the mispredicts commit still redirected on,
    // and the refill-shadow cycles after them (also in ear_mispred)
    longint unsigned c_xr_n, c_xr_killed, c_xr_head, c_xr_save, c_mp_commit, c_ear_mp_x;
    // (O7) the window's fill: ROB and station occupancy (summed over the window, and the largest), cycles with room
    // for one entry but not two, and a memory op held by a full queue whatever its operands (is_lsu counts it only
    // when its operands are ready); side counters, in no class
    longint unsigned c_rob_occ, c_rob_max, c_rs_occ, c_rs_max, c_rob_one, c_is_lsq;
    longint unsigned xr_cycle [0:(1<<TAG_W)-1];
    logic            dc_refill_q, ic_refill_q;
    src_e   shadow_q;                // the source of the redirect whose refill shadow is running
    int     shadow_kind_q;           // ... and, for a serializing one, its ser_kind
    longint unsigned cycle_q;

    // the page the last successful fetch translation found, while the context it was found in holds (P10a's rule)
    logic        lp_valid_q;
    logic [51:0] lp_vpn_q;
    // the op the LSU holds: it waited before the head; its translation was asked already
    logic        dx_pre_q, dx_asked_q;

    // when each mispredicted branch finished (tag-indexed; at most one per tag in flight)
    longint unsigned mp_done_cycle [0:(1<<TAG_W)-1];
    logic            mp_done_valid [0:(1<<TAG_W)-1];

    wire is_win_csr = commit && head_raw[6:0] == 7'h73 && head_raw[31:20] == WIN_CSR;

    // +BRTRACE: one line per control-flow instruction retired inside the window (pc, encoding, next pc), for
    // evaluating branch predictors offline (verification/perf/brpred.py)
    bit brtrace;
    initial brtrace = $test$plusargs("BRTRACE");
    always @(posedge clk)
        if (brtrace && win_q == 1 && commit && head_cls == 3'd1)
            $display("BR %h %h %h", head_pc, head_raw, head_next_pc);

    // +ILPTRACE: one line per instruction retired inside the window, with the cycles of its way through the core:
    //   ILP pc raw push pop disp acc go cmpl commit early ared trap redir addr iss ds cs fr dcm
    // push/pop: entered/left the instruction queue; disp: issued (ROB allocation); acc/go: the LSU took it / started
    // its access (0 for other ops); cmpl: its writeback; ared: the aligner redirected fetch after it (a taken branch
    // or a hint it did not confirm); redir: the commit redirect it caused (0 none, 1 mispredict, 2 serializing,
    // 3 other: a trap or xRET; 4 is kept for a mispredict recovered at execute); addr: its physical dword (memory
    // ops). (OX.0) iss: the cycle its unit took it (acc for a memory op); ds/cs: its dispatch slot and its commit
    // channel; fr: the cycle the fetch buffer got the dword it was aligned from; dcm: the D$ refilled a line while its
    // access was on the bus. A pair retires as two lines, the older first. Cycles count from reset.
    bit ilptrace;
    initial ilptrace = $test$plusargs("ILPTRACE");
    localparam int IQ_MIRROR = 16;
    localparam int FB_MIRROR = 16;
    longint unsigned iqm_push [0:IQ_MIRROR-1];       // the instruction queue's entries, mirrored
    bit              iqm_ared [0:IQ_MIRROR-1];
    longint unsigned iqm_fr   [0:IQ_MIRROR-1];
    int              iqm_rd, iqm_n;
    longint unsigned fbm_push [0:FB_MIRROR-1];       // the fetch buffer's entries: when each arrived
    int              fbm_rd, fbm_n;
    longint unsigned dq_push [0:1], dq_pop [0:1], dq_fr [0:1];   // the uops decode holds (one, or two at two-wide)
    bit              dq_ared [0:1];
    int              dq_n;
    longint unsigned t_push [0:(1<<TAG_W)-1], t_pop [0:(1<<TAG_W)-1], t_disp [0:(1<<TAG_W)-1];
    longint unsigned t_acc [0:(1<<TAG_W)-1], t_go [0:(1<<TAG_W)-1], t_cmpl [0:(1<<TAG_W)-1];
    longint unsigned t_iss [0:(1<<TAG_W)-1], t_fr [0:(1<<TAG_W)-1];
    bit              t_early [0:(1<<TAG_W)-1], t_ared [0:(1<<TAG_W)-1], t_ds [0:(1<<TAG_W)-1], t_dcm [0:(1<<TAG_W)-1];
    initial begin iqm_rd = 0; iqm_n = 0; fbm_rd = 0; fbm_n = 0; dq_n = 0; end

    task automatic ilp_line(input logic [63:0] pc, input logic [31:0] raw, input logic [TAG_W-1:0] t, input bit trp,
                            input int rdr, input logic [63:0] ma, input int cs);
        $display("ILP %h %h %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %h %0d %0d %0d %0d %0d", pc, raw,
                 t_push[t], t_pop[t], t_disp[t], t_acc[t], t_go[t], t_cmpl[t], cycle_q, t_early[t], t_ared[t], trp,
                 rdr, ma, t_iss[t], t_ds[t], cs, t_fr[t], t_dcm[t]);
    endtask
    task automatic ilp_disp(input logic [TAG_W-1:0] t, input int k, input int slot);
        t_push[t] = dq_push[k]; t_pop[t] = dq_pop[k]; t_disp[t] = cycle_q; t_ared[t] = dq_ared[k]; t_fr[t] = dq_fr[k];
        t_acc[t] = 0; t_go[t] = 0; t_cmpl[t] = 0; t_iss[t] = 0; t_early[t] = 0; t_ds[t] = slot; t_dcm[t] = 0;
    endtask
    task automatic ilp_pop();
        dq_push[dq_n] = iqm_push[iqm_rd]; dq_ared[dq_n] = iqm_ared[iqm_rd]; dq_fr[dq_n] = iqm_fr[iqm_rd];
        dq_pop[dq_n] = cycle_q;
        dq_n = dq_n + 1;
        iqm_rd = (iqm_rd + 1) % IQ_MIRROR; iqm_n = iqm_n - 1;
    endtask
    task automatic ilp_push();
        iqm_push[(iqm_rd + iqm_n) % IQ_MIRROR] = cycle_q; iqm_ared[(iqm_rd + iqm_n) % IQ_MIRROR] = 0;
        iqm_fr[(iqm_rd + iqm_n) % IQ_MIRROR] = (fbm_n > 0) ? fbm_push[fbm_rd] : cycle_q;
        iqm_n = iqm_n + 1;
    endtask

    always @(posedge clk) if (ilptrace && !rst) begin
        // retire first: the head's entry is read before this cycle's events touch it. A pair's redirect is its
        // second's (a mispredicted branch: the head of a pair can cause none)
        if (win_q == 1 && commit)
            ilp_line(head_pc, head_raw, head_tag, trap,
                     (head_mispredict && head_recovered) ? 4
                     : (!flush || commit2) ? 0 : head_mispredict ? 1 : head_serialize ? 2 : 3, mem_addr, 0);
        if (win_q == 1 && commit2)
            ilp_line(head1_pc, head1_raw, head1_tag, 1'b0,
                     (head1_mispredict && head1_recovered) ? 4 : (flush && head1_mispredict) ? 1 : 0, mem_addr1, 1);
        // dispatch takes the uops decode holds, the older first (before this cycle's pops refill them)
        if (alloc_valid)  ilp_disp(alloc_tag, 0, 0);
        if (alloc2_valid) ilp_disp(alloc_tag1, 1, 1);
        if (alloc2_valid) begin
            dq_n = 0;
        end else if (alloc_valid) begin
            dq_push[0] = dq_push[1]; dq_pop[0] = dq_pop[1]; dq_fr[0] = dq_fr[1]; dq_ared[0] = dq_ared[1];
            dq_n = (dq_n > 0) ? dq_n - 1 : 0;
        end
        if (lsu_acc) begin t_acc[lsu_acc_tag] = cycle_q; t_iss[lsu_acc_tag] = cycle_q; end
        if (lsu_go)  begin t_go[lsu_go_tag] = cycle_q; t_early[lsu_go_tag] = lsu_go_early; end
        if (lsu_in_bus && dc_refill) t_dcm[lsu_go_tag] = 1;
        if (req_alu)  t_iss[req_alu_tag]  = cycle_q;
        if (req_alu1) t_iss[req_alu1_tag] = cycle_q;
        if (req_bru)  t_iss[req_bru_tag]  = cycle_q;
        if (req_div)  t_iss[req_div_tag]  = cycle_q;
        if (req_fpu)  t_iss[req_fpu_tag]  = cycle_q;
        // a writeback for a tag dispatched in this same cycle is a flushed op's (only the LSU's is not masked)
        if (wb_valid  && cycle_q > t_disp[wb_tag])  t_cmpl[wb_tag]  = cycle_q;
        if (wb2_valid && cycle_q > t_disp[wb2_tag]) t_cmpl[wb2_tag] = cycle_q;
        if (wb3_valid && cycle_q > t_disp[wb3_tag]) t_cmpl[wb3_tag] = cycle_q;
        if (wb4_valid && cycle_q > t_disp[wb4_tag]) t_cmpl[wb4_tag] = cycle_q;
        if (wb5_valid && cycle_q > t_disp[wb5_tag]) t_cmpl[wb5_tag] = cycle_q;
        // the instruction queue: decode pops its head (and at two-wide the entry behind it); pushes go to the tail,
        // each remembering when the fetch buffer got the dword it came from. Both are emptied by whatever flushes the
        // frontend: a recovery at execute too (left out, the entries a recovery dropped stayed in the mirror and every
        // later instruction took an older one's push and pop)
        if (flush || fe_flush) begin
            iqm_n = 0;
            dq_n = 0;
        end else begin
            if (iq_pop && iqm_n > 0 && dq_n < 2) ilp_pop();
            if (iq_pop2 && iqm_n > 0 && dq_n < 2) ilp_pop();
            if (iq_push0) ilp_push();
            if (iq_push1) ilp_push();
            // an align redirect follows the last instruction pushed (in this cycle or before)
            if (fe_redirect && iqm_n > 0) iqm_ared[(iqm_rd + iqm_n - 1) % IQ_MIRROR] = 1;
            else if (fe_redirect && (iq_pop || alloc_valid) && dq_n > 0) dq_ared[dq_n - 1] = 1;
        end
        // the fetch buffer: the aligner is done with its head after this cycle's pushes read it
        if (fb_flush) begin
            fbm_n = 0;
        end else begin
            if (fb_pop && fbm_n > 0) begin fbm_rd = (fbm_rd + 1) % FB_MIRROR; fbm_n = fbm_n - 1; end
            if (fb_pop2 && fbm_n > 0) begin fbm_rd = (fbm_rd + 1) % FB_MIRROR; fbm_n = fbm_n - 1; end
            if (fb_push) begin fbm_push[(fbm_rd + fbm_n) % FB_MIRROR] = cycle_q; fbm_n = fbm_n + 1; end
        end
    end

    // the kind of a mispredicted branch from its encoding (32-bit and RVC)
    function automatic int mp_kind(input logic [31:0] raw);
        if (raw[1:0] == 2'b11) begin
            if (raw[6:0] == 7'b1100011) return 0;                       // conditional
            if (raw[6:0] == 7'b1101111) return 1;                       // JAL
            return 2;                                                   // JALR
        end else begin
            if (raw[1:0] == 2'b01 && raw[15:14] == 2'b11) return 0;     // C.BEQZ / C.BNEZ
            if (raw[1:0] == 2'b01 && raw[15:13] == 3'b101) return 1;    // C.J
            return 2;                                                   // C.JR / C.JALR
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            win_q <= 0;
            c_window <= 0; c_retire <= 0; c_blk_lsu <= 0; c_blk_div <= 0; c_blk_alu <= 0; c_blk_sys <= 0; c_blk_fpu <= 0;
            c_ear_align <= 0; c_ear_mispred <= 0; c_ear_serial <= 0; c_ear_other <= 0; c_empty_front <= 0;
            c_iq_empty <= 0; c_fb_empty <= 0; c_is_oper <= 0; c_is_rob <= 0; c_is_lsu <= 0; c_is_div <= 0; c_no_uop <= 0;
            c_is_rs <= 0;
            c_re_align <= 0; c_re_mispred <= 0; c_re_serial <= 0; c_re_other <= 0;
            c_mp_cond <= 0; c_mp_jal <= 0; c_mp_jalr <= 0; c_mp_wait <= 0; c_mp_n <= 0;
            c_bus_wait <= 0;
            c_instret <= 0;
            c_xl_req <= 0; c_xl_reuse <= 0; c_xl_cyc <= 0; c_dx_n <= 0; c_dx_hit <= 0; c_dx_save <= 0;
            c_lq_ld <= 0; c_lq_st <= 0; c_lq_bar <= 0; c_lq_match <= 0; c_lq_qmatch <= 0; c_lq_hand <= 0; c_lq_drain <= 0;
            for (int k = 0; k < 4; k++) begin c_re_ser[k] <= 0; c_ear_ser[k] <= 0; end
            c_s1_retire <= 0; c_s1_idle <= 0; c_s1_none <= 0; c_s1_wait_lsu <= 0; c_s1_wait_div <= 0;
            c_s1_wait_fpu <= 0; c_s1_wait_alu <= 0; c_s1_rule_head <= 0; c_s1_rule_pair <= 0;
            c_dc_miss <= 0; c_dc_cyc <= 0; c_ic_miss <= 0; c_ic_cyc <= 0;
            c_xr_n <= 0; c_xr_killed <= 0; c_xr_head <= 0; c_xr_save <= 0; c_mp_commit <= 0; c_ear_mp_x <= 0;
            c_rob_occ <= 0; c_rob_max <= 0; c_rs_occ <= 0; c_rs_max <= 0; c_rob_one <= 0; c_is_lsq <= 0;
            dc_refill_q <= 1'b0; ic_refill_q <= 1'b0;
            shadow_q <= SRC_NONE;
            shadow_kind_q <= 0;
            lp_valid_q <= 1'b0;
            lp_vpn_q <= '0;
            dx_pre_q <= 1'b0;
            dx_asked_q <= 1'b0;
            cycle_q <= 0;
            for (int i = 0; i < (1<<TAG_W); i++) begin mp_done_valid[i] = 1'b0; mp_done_cycle[i] = 0; end
        end else begin
            cycle_q <= cycle_q + 1;

            // ---- the refill shadow: from a redirect to the first issue after it ----
            if (flush) begin
                if ((commit && head_mispredict) || mispredict2) shadow_q <= SRC_MISPRED;
                else if (commit && head_serialize)  begin shadow_q <= SRC_SERIAL; shadow_kind_q <= ser_kind(head_cls, head_csr_wsup, head_csr_addr); end
                else                                shadow_q <= SRC_OTHER;
            end else if (xr_fire) begin
                shadow_q <= SRC_XR;
            end else if (fe_redirect) begin
                shadow_q <= SRC_ALIGN;
            end else if (issue_fire) begin
                shadow_q <= SRC_NONE;
            end

            if (xr_fire && !flush) xr_cycle[xr_tag] = cycle_q;
            // ---- mispredicted branches: when they finish, and how long they wait for the head ----
            if (wb_valid && wb_mispredict) begin
                mp_done_valid[wb_tag] = 1'b1;
                mp_done_cycle[wb_tag] = cycle_q;
            end

            // ---- the last translated fetch page (qv_fetch latches a translation where this does) ----
            if (f_redirect_ctx || sfence || in_debug)
                lp_valid_q <= 1'b0;
            else if (f_xl_req && f_xl_done && !f_xl_fault && !f_hold && !f_redirect) begin
                lp_valid_q <= 1'b1;
                lp_vpn_q   <= f_xl_va[63:12];
            end

            // ---- the op the LSU holds ----
            if (!lsu_wait_head) begin
                dx_pre_q   <= 1'b0;
                dx_asked_q <= 1'b0;
            end else begin
                if (!lsu_at_head) dx_pre_q   <= 1'b1;
                if (x_req)        dx_asked_q <= 1'b1;
            end
            // ---- the window ----
            if (win_q == 1) begin
                c_window <= c_window + 1;

                if (commit)                                    c_retire <= c_retire + 1;
                else if (head_valid && !head_complete) begin
                    if      (head_cls == FU_LSU)               c_blk_lsu <= c_blk_lsu + 1;
                    else if (head_cls == FU_DIV)               c_blk_div <= c_blk_div + 1;
                    else if (head_cls == FU_FPU)               c_blk_fpu <= c_blk_fpu + 1;
                    else                                       c_blk_alu <= c_blk_alu + 1;
                end
                else if (head_valid)                           c_blk_sys <= c_blk_sys + 1;
                else if (rob_empty) begin
                    case (shadow_q)
                        SRC_ALIGN:   c_ear_align   <= c_ear_align + 1;
                        SRC_MISPRED: c_ear_mispred <= c_ear_mispred + 1;
                        SRC_XR:      begin c_ear_mispred <= c_ear_mispred + 1; c_ear_mp_x <= c_ear_mp_x + 1; end
                        SRC_SERIAL:  begin
                                     c_ear_serial  <= c_ear_serial + 1;
                                     c_ear_ser[shadow_kind_q] <= c_ear_ser[shadow_kind_q] + 1;
                                     end
                        SRC_OTHER:   c_ear_other   <= c_ear_other + 1;
                        default:     c_empty_front <= c_empty_front + 1;
                    endcase
                end
                if (instr_retired) c_instret <= c_instret + 1 + (instr_retired2 ? 1 : 0);

                if (!iq_valid)  c_iq_empty <= c_iq_empty + 1;
                if (!fb_valid)  c_fb_empty <= c_fb_empty + 1;
                if (!uop_valid) c_no_uop <= c_no_uop + 1;
                if (uop_valid && !issue_fire) begin
                    if      (!alloc_ready)                        c_is_rob  <= c_is_rob + 1;
                    else if (rs_full)                             c_is_rs   <= c_is_rs + 1;
                    else if (!a_ready || !b_ready || !c_ready)    c_is_oper <= c_is_oper + 1;
                    else if (uop_fu == FU_LSU && !lsu_free)       c_is_lsu  <= c_is_lsu + 1;
                    else if (uop_fu == FU_DIV && !div_free)       c_is_div  <= c_is_div + 1;
                end
                c_rob_occ <= c_rob_occ + rob_used;
                c_rs_occ  <= c_rs_occ + rs_used;
                if (rob_used > c_rob_max) c_rob_max <= rob_used;
                if (rs_used > c_rs_max)   c_rs_max  <= rs_used;
                if (alloc_ready && !alloc_ready2) c_rob_one <= c_rob_one + 1;
                if (uop_valid && !issue_fire && uop_fu == FU_LSU && !lsu_free) c_is_lsq <= c_is_lsq + 1;
                // (OX.0) the second commit slot: it retired, the first did not either (slot 0's class says why), or
                // the first did and the second could not: no entry behind it, it is not done, the head may not be
                // the first of a pair (qv_commit's plain1), or the pair rule refused the second
                if (commit2)                                       c_s1_retire    <= c_s1_retire + 1;
                else if (!commit)                                  c_s1_idle      <= c_s1_idle + 1;
                else if (!head1_valid)                             c_s1_none      <= c_s1_none + 1;
                else if (!head1_complete) begin
                    if      (head1_cls == FU_LSU)                  c_s1_wait_lsu  <= c_s1_wait_lsu + 1;
                    else if (head1_cls == FU_DIV)                  c_s1_wait_div  <= c_s1_wait_div + 1;
                    else if (head1_cls == FU_FPU)                  c_s1_wait_fpu  <= c_s1_wait_fpu + 1;
                    else                                           c_s1_wait_alu  <= c_s1_wait_alu + 1;
                end
                else if (!plain1)                                  c_s1_rule_head <= c_s1_rule_head + 1;
                else                                               c_s1_rule_pair <= c_s1_rule_pair + 1;
                if (dc_refill) begin c_dc_cyc <= c_dc_cyc + 1; if (!dc_refill_q) c_dc_miss <= c_dc_miss + 1; end
                if (ic_refill) begin c_ic_cyc <= c_ic_cyc + 1; if (!ic_refill_q) c_ic_miss <= c_ic_miss + 1; end

                if (flush) begin
                    if ((commit && head_mispredict) || (commit2 && head1_mispredict))
                                                                  c_re_mispred <= c_re_mispred + 1;
                    else if (commit && head_serialize) begin
                        c_re_serial  <= c_re_serial + 1;
                        c_re_ser[ser_kind(head_cls, head_csr_wsup, head_csr_addr)] <=
                            c_re_ser[ser_kind(head_cls, head_csr_wsup, head_csr_addr)] + 1;
                    end
                    else                                          c_re_other   <= c_re_other + 1;
                end else if (xr_fire) begin
                    c_re_mispred <= c_re_mispred + 1;
                end else if (fe_redirect) begin
                    c_re_align <= c_re_align + 1;
                end
                if (xr_fire && !flush) begin
                    int nk;
                    nk = 0;
                    for (int i = 0; i < (1<<TAG_W); i++) if (kill_vec[i]) nk = nk + 1;
                    c_xr_n      <= c_xr_n + 1;
                    c_xr_killed <= c_xr_killed + nk;
                    if (commit && head_tag == xr_tag) c_xr_head <= c_xr_head + 1;
                end
                if (flush && ((commit && head_mispredict && !head_recovered) || (commit2 && head1_mispredict && !head1_recovered)))
                    c_mp_commit <= c_mp_commit + 1;
                begin
                    longint unsigned sv;
                    sv = 0;
                    if (commit && head_mispredict && head_recovered)    sv = sv + (cycle_q - xr_cycle[head_tag]);
                    if (commit2 && head1_mispredict && head1_recovered) sv = sv + (cycle_q - xr_cycle[head1_tag]);
                    c_xr_save <= c_xr_save + sv;
                end
                if (lsu_bus_wait) c_bus_wait <= c_bus_wait + 1;
                // O2: what the load/store queue's engine does before the head, and what holds it back
                if (lsq_early_ld)   c_lq_ld     <= c_lq_ld + 1;
                if (lsq_early_st)   c_lq_st     <= c_lq_st + 1;
                if (lsq_bar_wait)   c_lq_bar    <= c_lq_bar + 1;
                if (lsq_match_wait) c_lq_match  <= c_lq_match + 1;
                if (lsq_qmatch)     c_lq_qmatch <= c_lq_qmatch + 1;
                if (lsq_handoff)    c_lq_hand   <= c_lq_hand + 1;
                if (lsq_drain)      c_lq_drain  <= c_lq_drain + 1;

                // P10a: a translated request in the page of the last translation; P10b: a head lookup that hit
                // after the op had waited before the head
                if (f_issue && f_xl_on) begin
                    c_xl_req <= c_xl_req + 1;
                    if (lp_valid_q && f_issue_pc[63:12] == lp_vpn_q) c_xl_reuse <= c_xl_reuse + 1;
                end
                if (f_xl_req) c_xl_cyc <= c_xl_cyc + 1;
                if (x_req && !dx_asked_q) begin
                    c_dx_n <= c_dx_n + 1;
                    if (x_done && !x_fault) begin
                        c_dx_hit <= c_dx_hit + 1;
                        if (dx_pre_q) c_dx_save <= c_dx_save + 1;
                    end
                end

                // every mispredicted branch that retires, on either commit channel (O4: the second can be one)
                begin
                    int n_c, n_j, n_r;
                    longint unsigned w;
                    n_c = 0; n_j = 0; n_r = 0; w = 0;
                    if (commit && head_mispredict) begin
                        case (mp_kind(head_raw)) 0: n_c = n_c + 1; 1: n_j = n_j + 1; default: n_r = n_r + 1; endcase
                        if (mp_done_valid[head_tag])
                            w = w + (cycle_q - mp_done_cycle[head_tag] - 1);   // 0 when it commits the cycle after it finished
                    end
                    if (commit2 && head1_mispredict) begin
                        case (mp_kind(head1_raw)) 0: n_c = n_c + 1; 1: n_j = n_j + 1; default: n_r = n_r + 1; endcase
                        if (mp_done_valid[head1_tag]) w = w + (cycle_q - mp_done_cycle[head1_tag] - 1);
                    end
                    c_mp_n    <= c_mp_n + n_c + n_j + n_r;
                    c_mp_cond <= c_mp_cond + n_c;
                    c_mp_jal  <= c_mp_jal + n_j;
                    c_mp_jalr <= c_mp_jalr + n_r;
                    c_mp_wait <= c_mp_wait + w;
                end
            end
            dc_refill_q <= dc_refill;
            ic_refill_q <= ic_refill;

            if (is_win_csr) begin
                if (win_q == 0)      win_q <= 1;
                else if (win_q == 1) win_q <= 2;
            end

            // a redirect flushes every branch in flight (after the window block above used its entry)
            if (flush) for (int i = 0; i < (1<<TAG_W); i++) mp_done_valid[i] = 1'b0;
        end
    end

    // one line, parsed by run_perf.sh: the exclusive classes first (they add up to window), then the side counters
    task automatic report(input longint unsigned instret);
        longint unsigned sum;
        sum = c_retire + c_blk_lsu + c_blk_div + c_blk_alu + c_blk_sys + c_ear_align + c_ear_mispred + c_ear_serial
            + c_ear_other + c_empty_front + c_blk_fpu;
        // (blk_fpu, the head waiting for the FPU, came with F/D: the last of the exclusive classes)
        $display("PERF_STACK: window=%0d retire=%0d blk_lsu=%0d blk_div=%0d blk_alu=%0d blk_sys=%0d ear_align=%0d ear_mispred=%0d ear_serial=%0d ear_other=%0d empty_front=%0d blk_fpu=%0d",
                 c_window, c_retire, c_blk_lsu, c_blk_div, c_blk_alu, c_blk_sys, c_ear_align, c_ear_mispred, c_ear_serial,
                 c_ear_other, c_empty_front, c_blk_fpu);
        $display("PERF_SIDE: iq_empty=%0d fb_empty=%0d no_uop=%0d is_rob=%0d is_oper=%0d is_lsu=%0d is_div=%0d re_align=%0d re_mispred=%0d re_serial=%0d re_other=%0d mp_cond=%0d mp_jal=%0d mp_jalr=%0d mp_wait=%0d bus_wait=%0d xl_req=%0d xl_reuse=%0d xl_cyc=%0d dx_n=%0d dx_hit=%0d dx_save=%0d re_ser_ro=%0d re_ser_trapw=%0d re_ser_csr=%0d re_ser_sys=%0d ear_ser_ro=%0d ear_ser_trapw=%0d ear_ser_csr=%0d ear_ser_sys=%0d is_rs=%0d",
                 c_iq_empty, c_fb_empty, c_no_uop, c_is_rob, c_is_oper, c_is_lsu, c_is_div, c_re_align, c_re_mispred, c_re_serial,
                 c_re_other, c_mp_cond, c_mp_jal, c_mp_jalr, c_mp_wait, c_bus_wait,
                 c_xl_req, c_xl_reuse, c_xl_cyc, c_dx_n, c_dx_hit, c_dx_save,
                 c_re_ser[0], c_re_ser[1], c_re_ser[2], c_re_ser[3], c_ear_ser[0], c_ear_ser[1], c_ear_ser[2], c_ear_ser[3],
                 c_is_rs);
        $display("PERF_LSQ: early_ld=%0d early_st=%0d bar_wait=%0d match_wait=%0d qmatch_wait=%0d handoff=%0d drain=%0d",
                 c_lq_ld, c_lq_st, c_lq_bar, c_lq_match, c_lq_qmatch, c_lq_hand, c_lq_drain);
        $display("PERF_OX: s1_retire=%0d s1_idle=%0d s1_none=%0d s1_wait_lsu=%0d s1_wait_div=%0d s1_wait_fpu=%0d s1_wait_alu=%0d s1_rule_head=%0d s1_rule_pair=%0d dc_miss=%0d dc_cyc=%0d ic_miss=%0d ic_cyc=%0d xr_n=%0d xr_killed=%0d xr_head=%0d xr_save=%0d mp_commit=%0d ear_mp_x=%0d rob_occ=%0d rob_max=%0d rs_occ=%0d rs_max=%0d rob_one=%0d is_lsq=%0d",
                 c_s1_retire, c_s1_idle, c_s1_none, c_s1_wait_lsu, c_s1_wait_div, c_s1_wait_fpu, c_s1_wait_alu,
                 c_s1_rule_head, c_s1_rule_pair, c_dc_miss, c_dc_cyc, c_ic_miss, c_ic_cyc,
                 c_xr_n, c_xr_killed, c_xr_head, c_xr_save, c_mp_commit, c_ear_mp_x,
                 c_rob_occ, c_rob_max, c_rs_occ, c_rs_max, c_rob_one, c_is_lsq);
        if (c_s1_retire + c_s1_idle + c_s1_none + c_s1_wait_lsu + c_s1_wait_div + c_s1_wait_fpu + c_s1_wait_alu
                + c_s1_rule_head + c_s1_rule_pair != c_window)
            $display("PERF_STACK_WARN: the second slot's classes do not add up to the window");
        if (win_q != 2)
            $display("PERF_STACK_WARN: the window never closed (state %0d)", win_q);
        if (sum != c_window)
            $display("PERF_STACK_WARN: the classes add up to %0d, the window is %0d", sum, c_window);
        if (c_instret != instret)
            $display("PERF_STACK_WARN: %0d retirements in the window, the kernel's instret is %0d", c_instret, instret);
    endtask

    // the S-mode build: the window is the result (the kernel cannot read mcycle or minstret)
    task automatic report_result();
        $display("PERF_RESULT: cycles=%0d instret=%0d", c_window, c_instret);
    endtask
endmodule
