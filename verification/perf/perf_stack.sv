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
    input logic             x_fault
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

    typedef enum int { SRC_NONE, SRC_ALIGN, SRC_MISPRED, SRC_SERIAL, SRC_OTHER } src_e;

    int win_q;                       // 0: not opened yet, 1: open, 2: closed
    longint unsigned c_window, c_retire, c_blk_lsu, c_blk_div, c_blk_alu, c_blk_sys, c_blk_fpu;
    longint unsigned c_ear_align, c_ear_mispred, c_ear_serial, c_ear_other, c_empty_front;
    longint unsigned c_iq_empty, c_fb_empty, c_is_oper, c_is_rob, c_is_lsu, c_is_div, c_no_uop;
    longint unsigned c_re_align, c_re_mispred, c_re_serial, c_re_other;
    longint unsigned c_mp_cond, c_mp_jal, c_mp_jalr, c_mp_wait, c_mp_n;
    longint unsigned c_bus_wait;
    longint unsigned c_instret;
    longint unsigned c_xl_req, c_xl_reuse, c_xl_cyc, c_dx_n, c_dx_hit, c_dx_save;
    longint unsigned c_re_ser [0:3];
    longint unsigned c_ear_ser [0:3];
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
            c_re_align <= 0; c_re_mispred <= 0; c_re_serial <= 0; c_re_other <= 0;
            c_mp_cond <= 0; c_mp_jal <= 0; c_mp_jalr <= 0; c_mp_wait <= 0; c_mp_n <= 0;
            c_bus_wait <= 0;
            c_instret <= 0;
            c_xl_req <= 0; c_xl_reuse <= 0; c_xl_cyc <= 0; c_dx_n <= 0; c_dx_hit <= 0; c_dx_save <= 0;
            for (int k = 0; k < 4; k++) begin c_re_ser[k] <= 0; c_ear_ser[k] <= 0; end
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
                if (commit && head_mispredict)      shadow_q <= SRC_MISPRED;
                else if (commit && head_serialize)  begin shadow_q <= SRC_SERIAL; shadow_kind_q <= ser_kind(head_cls, head_csr_wsup, head_csr_addr); end
                else                                shadow_q <= SRC_OTHER;
            end else if (fe_redirect) begin
                shadow_q <= SRC_ALIGN;
            end else if (issue_fire) begin
                shadow_q <= SRC_NONE;
            end

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
                        SRC_SERIAL:  begin
                                     c_ear_serial  <= c_ear_serial + 1;
                                     c_ear_ser[shadow_kind_q] <= c_ear_ser[shadow_kind_q] + 1;
                                     end
                        SRC_OTHER:   c_ear_other   <= c_ear_other + 1;
                        default:     c_empty_front <= c_empty_front + 1;
                    endcase
                end
                if (instr_retired) c_instret <= c_instret + 1;

                if (!iq_valid)  c_iq_empty <= c_iq_empty + 1;
                if (!fb_valid)  c_fb_empty <= c_fb_empty + 1;
                if (!uop_valid) c_no_uop <= c_no_uop + 1;
                if (uop_valid && !issue_fire) begin
                    if      (!alloc_ready)                        c_is_rob  <= c_is_rob + 1;
                    else if (!a_ready || !b_ready || !c_ready)    c_is_oper <= c_is_oper + 1;
                    else if (uop_fu == FU_LSU && !lsu_free)       c_is_lsu  <= c_is_lsu + 1;
                    else if (uop_fu == FU_DIV && !div_free)       c_is_div  <= c_is_div + 1;
                end
                if (flush) begin
                    if (commit && head_mispredict)                c_re_mispred <= c_re_mispred + 1;
                    else if (commit && head_serialize) begin
                        c_re_serial  <= c_re_serial + 1;
                        c_re_ser[ser_kind(head_cls, head_csr_wsup, head_csr_addr)] <=
                            c_re_ser[ser_kind(head_cls, head_csr_wsup, head_csr_addr)] + 1;
                    end
                    else                                          c_re_other   <= c_re_other + 1;
                end else if (fe_redirect) begin
                    c_re_align <= c_re_align + 1;
                end
                if (lsu_bus_wait) c_bus_wait <= c_bus_wait + 1;

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

                if (commit && head_mispredict && flush) begin
                    c_mp_n <= c_mp_n + 1;
                    case (mp_kind(head_raw))
                        0: c_mp_cond <= c_mp_cond + 1;
                        1: c_mp_jal  <= c_mp_jal + 1;
                        default: c_mp_jalr <= c_mp_jalr + 1;
                    endcase
                    if (mp_done_valid[head_tag])
                        c_mp_wait <= c_mp_wait + (cycle_q - mp_done_cycle[head_tag] - 1);   // 0 when it commits the cycle after it finished
                end
            end

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
        $display("PERF_SIDE: iq_empty=%0d fb_empty=%0d no_uop=%0d is_rob=%0d is_oper=%0d is_lsu=%0d is_div=%0d re_align=%0d re_mispred=%0d re_serial=%0d re_other=%0d mp_cond=%0d mp_jal=%0d mp_jalr=%0d mp_wait=%0d bus_wait=%0d xl_req=%0d xl_reuse=%0d xl_cyc=%0d dx_n=%0d dx_hit=%0d dx_save=%0d re_ser_ro=%0d re_ser_trapw=%0d re_ser_csr=%0d re_ser_sys=%0d ear_ser_ro=%0d ear_ser_trapw=%0d ear_ser_csr=%0d ear_ser_sys=%0d",
                 c_iq_empty, c_fb_empty, c_no_uop, c_is_rob, c_is_oper, c_is_lsu, c_is_div, c_re_align, c_re_mispred, c_re_serial,
                 c_re_other, c_mp_cond, c_mp_jal, c_mp_jalr, c_mp_wait, c_bus_wait,
                 c_xl_req, c_xl_reuse, c_xl_cyc, c_dx_n, c_dx_hit, c_dx_save,
                 c_re_ser[0], c_re_ser[1], c_re_ser[2], c_re_ser[3], c_ear_ser[0], c_ear_ser[1], c_ear_ser[2], c_ear_ser[3]);
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
