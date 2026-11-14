// SPDX-License-Identifier: MIT

/*
 * qv_align2 -- (O8b) qv_align over a window of two fetch-buffer entries: the head dword and the one behind it.
 *
 * qv_align sees one dword at a time, so its two instructions a cycle must both end in that dword, and a 32-bit
 * instruction that crosses into the next dword costs a cycle of its own (its first half is stashed, the dword popped,
 * and it goes out with the next dword). Here the entry behind the head (i_buf1_*) joins the window when it is the
 * head's sequential successor: the head carries no BTB hint (with one, the entry behind it is the hinted target's)
 * and neither entry is a fault marker. The window is then 16 bytes, halfwords 0-3 the head's and 4-7 the next one's,
 * and the two slots take any two instructions that start in it and end in it: a crossing instruction goes out with
 * the instruction before it, and an instruction that starts in the head can be followed by one that starts in the
 * next entry. Both entries are popped when the window is used up (o_buf_pop2), only the head when the last
 * instruction taken ended in the next entry or nothing more fits.
 *
 * Everything else is qv_align's, unchanged (its header):
 *   - without a usable next entry the window is the head alone, and a crossing instruction at halfword 3 is stashed
 *     (pend_q) and the head popped, as qv_align does: a head is never held for want of its successor (fetch reads a
 *     page-table entry outside RAM for its successor only once the fetch buffer is empty, qv_ptw's f_nonspec);
 *   - a fault marker in the head goes out alone; one behind it makes the entry unusable, so it is the head at the
 *     next cycle;
 *   - static prediction, the branch history table's direction, the RAS, and the BTB hint of the entry an instruction
 *     starts in (a crossing one: the hint of the entry it ends in, with hx); a confirmed hint drops the rest of its
 *     entry, an unconfirmed one sends fetch back to the entry's sequential successor once the entry is used up;
 *   - a predicted-taken instruction is the last of its cycle;
 *   - instructions go out when the IQ has room for two, or one with ONE_OK;
 *   - with ONE_COND (qv_gshare, O8a) at most one conditional branch goes out a cycle, so one global history serves
 *     every lookup of the cycle and shifts once.
 * The branch history table is looked up for the head's four halfwords (o_bht_base), the next entry's
 * (o_bht_base1) and a pending instruction (o_bht_ppc).
 */
module qv_align2 #(
    parameter bit ONE_OK   = 1'b0,
    parameter bit ONE_COND = 1'b0       // (O8a) at most one conditional branch a cycle (one global history)
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_flush,

    input  logic              i_buf_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       i_buf_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]       i_buf_data,
    input  logic              i_buf_err,
    input  logic [3:0]        i_buf_cause = 4'd1,
    input  logic              i_buf_xl    = 1'b0,
    input  logic [43:0]       i_buf_pg    = 44'b0,
    input  logic              i_buf_hint  = 1'b0,
    input  logic [1:0]        i_buf_hoff  = 2'b0,
    input  logic              i_buf_hx    = 1'b0,
    input  logic [63:0]       i_buf_htgt  = 64'b0,
    output logic              o_buf_pop,

    // the entry behind the head (valid only when there is one)
    input  logic              i_buf1_valid = 1'b0,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       i_buf1_pc    = 64'b0,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]       i_buf1_data  = 64'b0,
    input  logic              i_buf1_err   = 1'b0,
    input  logic              i_buf1_xl    = 1'b0,
    input  logic [43:0]       i_buf1_pg    = 44'b0,
    input  logic              i_buf1_hint  = 1'b0,
    input  logic [1:0]        i_buf1_hoff  = 2'b0,
    input  logic              i_buf1_hx    = 1'b0,
    input  logic [63:0]       i_buf1_htgt  = 64'b0,
    output logic              o_buf_pop2,

    input  logic [63:0]       i_ras_top   = 64'b0,
    input  logic              i_ras_has1  = 1'b0,
    output logic [63:0]       o_bht_base,
    output logic [63:0]       o_bht_base1,
    output logic [63:0]       o_bht_ppc,
    input  logic [3:0]        i_bht_known = 4'b0,
    input  logic [3:0]        i_bht_taken = 4'b0,
    input  logic [3:0]        i_bht_known1 = 4'b0,
    input  logic [3:0]        i_bht_taken1 = 4'b0,
    input  logic              i_bht_pknown = 1'b0,
    input  logic              i_bht_ptaken = 1'b0,
    output logic [1:0]        o_ras_op0,
    output logic [63:0]       o_ras_addr0,
    output logic [1:0]        o_ras_op1,
    output logic [63:0]       o_ras_addr1,

    output logic              o_push0_valid,
    output qv_pkg::fe_instr_t o_push0_data,
    output logic              o_push1_valid,
    output qv_pkg::fe_instr_t o_push1_data,
    input  logic              i_push_ready,
    input  logic              i_push_ready1 = 1'b0,

    output logic              o_redirect_valid,
    output logic [63:0]       o_redirect_pc
);
    import qv_pkg::*;

    logic        mid_q;
    logic [1:0]  off_q;
    logic        pend_q;
    logic [15:0] pend_hw_q;
    logic [63:0] pend_pc_q;
    logic        pend_xl_q;
    logic [43:0] pend_pg_q;

    wire [63:0] base  = {i_buf_pc[63:3], 3'b000};
    assign o_bht_base  = base;
    assign o_bht_base1 = base + 64'd8;
    assign o_bht_ppc   = pend_pc_q;
    wire [1:0]  start = mid_q ? off_q : i_buf_pc[2:1];
    wire        room1 = i_push_ready || (ONE_OK && i_push_ready1);
    wire        go    = i_buf_valid && room1 && !i_flush;
    // the entry behind the head is the head's successor: a 16-byte window
    wire        nseq  = i_buf1_valid && !i_buf_hint && !i_buf_err && !i_buf1_err;
    wire [3:0]  wend  = nseq ? 4'd8 : 4'd4;       // the window's end, in halfwords

    function automatic logic [15:0] hw8(input logic [63:0] d0, input logic [63:0] d1, input logic [2:0] i);
        case (i)
            3'd0:    hw8 = d0[15:0];
            3'd1:    hw8 = d0[31:16];
            3'd2:    hw8 = d0[47:32];
            3'd3:    hw8 = d0[63:48];
            3'd4:    hw8 = d1[15:0];
            3'd5:    hw8 = d1[31:16];
            3'd6:    hw8 = d1[47:32];
            default: hw8 = d1[63:48];
        endcase
    endfunction

    function automatic logic [64:0] predict(input logic [31:0] raw, input logic rvc, input logic [63:0] pc,
                                            input logic bk = 1'b0, input logic bt = 1'b0);
        logic        taken;
        logic [63:0] off;
        taken = 1'b0;
        off   = '0;
        if (rvc) begin
            if (raw[1:0] == 2'b01 && raw[15:13] == 3'b101) begin                    // C.J
                taken = 1'b1;
                off   = {{52{raw[12]}}, raw[12], raw[8], raw[10:9], raw[6], raw[7], raw[2],
                         raw[11], raw[5:3], 1'b0};
            end else if (raw[1:0] == 2'b01 && raw[15:14] == 2'b11) begin            // C.BEQZ/C.BNEZ
                taken = bk ? bt : raw[12];
                off   = {{55{raw[12]}}, raw[12], raw[6:5], raw[2], raw[11:10], raw[4:3], 1'b0};
            end
        end else if (raw[6:0] == 7'b1101111) begin                                  // JAL
            taken = 1'b1;
            off   = {{43{raw[31]}}, raw[31], raw[19:12], raw[20], raw[30:21], 1'b0};
        end else if (raw[6:0] == 7'b1100011 && raw[14:13] != 2'b01) begin           // branch
            taken = bk ? bt : raw[31];
            off   = {{51{raw[31]}}, raw[31], raw[7], raw[30:25], raw[11:8], 1'b0};
        end
        return {taken, pc + off};
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic hint_holds(input logic [31:0] raw, input logic rvc, input logic [63:0] pc,
                                        input logic hint_here, input logic [63:0] htgt,
                                        input logic bk = 1'b0, input logic bt = 1'b0);
        logic [64:0] p;
        logic [1:0]  k;
        p = predict(raw, rvc, pc, bk, bt);
        k = qv_ctl_kind(raw);
        return hint_here && ((k == 2'd1 && p[63:0] == htgt && !(qv_is_cond(raw) && bk && !bt)) || k == 2'd2);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic fe_instr_t mk(input logic [63:0] pc, input logic [31:0] raw, input logic rvc,
                                     input logic xl, input logic [43:0] pg_lo, input logic [43:0] pg_hi,
                                     input logic hint_here = 1'b0, input logic [63:0] htgt = 64'b0,
                                     input logic ras_ok = 1'b0, input logic [63:0] ras_tgt = 64'b0,
                                     input logic bk = 1'b0, input logic bt = 1'b0);
        logic [64:0] p;
        p             = predict(raw, rvc, pc, bk, bt);
        mk            = '0;
        mk.pc         = pc;
        mk.raw        = raw;
        mk.rvc        = rvc;
        mk.pred_taken = p[64];
        mk.pred_tgt   = p[63:0];
        if (hint_holds(raw, rvc, pc, hint_here, htgt, bk, bt)) begin
            mk.pred_taken = 1'b1;
            mk.pred_tgt   = (qv_ctl_kind(raw) == 2'd1) ? p[63:0] : htgt;
        end
        if (ras_ok && qv_ctl_kind(raw) == 2'd3) begin
            mk.pred_taken = 1'b1;
            mk.pred_tgt   = ras_tgt;
        end
        mk.xl         = xl;
        mk.pg_lo      = pg_lo;
        mk.pg_hi      = pg_hi;
    endfunction

    function automatic logic [1:0] ras_op_of(input logic [31:0] raw);
        return (qv_ctl_kind(raw) == 2'd3) ? 2'b10 : qv_is_call(raw) ? 2'b01 : 2'b00;
    endfunction

    // One slot at window position p (0-7): what starts there. Everything it needs is an argument (Icarus does not
    // re-evaluate a function on a module variable it reads).
    typedef struct packed {
        logic        emit;      // an instruction goes out
        logic        stash;     // a crossing first half with no successor in the window: pend_q takes it
        logic [3:0]  next;      // the position after it
        fe_instr_t   ins;
        logic        conf;      // its entry's BTB hint holds for it
        logic        in1;       // ... that entry is the next one
    } slot_t;

    function automatic slot_t slot_at(input logic [2:0] p, input logic [3:0] we,
                                      input logic [63:0] d0, input logic [63:0] d1, input logic [63:0] b,
                                      input logic xl0, input logic [43:0] pg0, input logic xl1, input logic [43:0] pg1,
                                      input logic h0, input logic [1:0] ho0, input logic hx0, input logic [63:0] ht0,
                                      input logic h1, input logic [1:0] ho1, input logic hx1, input logic [63:0] ht1,
                                      input logic [3:0] k0, input logic [3:0] t0, input logic [3:0] k1,
                                      input logic [3:0] t1, input logic rok, input logic [63:0] rtgt);
        logic [15:0] h;
        logic        in1, crosses, hh;
        logic [63:0] pc, ht;
        logic [31:0] raw;
        logic        bk, bt;
        slot_t       s;
        s       = '0;
        h       = hw8(d0, d1, p);
        in1     = p[2];
        pc      = b + {60'b0, p, 1'b0};
        bk      = in1 ? k1[p[1:0]] : k0[p[1:0]];
        bt      = in1 ? t1[p[1:0]] : t0[p[1:0]];
        crosses = (h[1:0] == 2'b11) && (p[1:0] == 2'b11);
        if (h[1:0] != 2'b11) begin
            raw = {16'b0, h};
        end else begin
            raw = {hw8(d0, d1, p + 3'd1), h};
        end
        // the hint an instruction answers to: its entry's at its halfword; a crossing one, the entry it ends in (hx)
        if (crosses && !in1) begin
            hh = h1 && hx1;
            ht = ht1;
        end else if (in1) begin
            hh = h1 && !hx1 && (p[1:0] == ho1);
            ht = ht1;
        end else begin
            hh = h0 && !hx0 && (p[1:0] == ho0);
            ht = ht0;
        end
        if (h[1:0] != 2'b11) begin
            s.emit = 1'b1;
            s.next = {1'b0, p} + 4'd1;
            s.ins  = mk(pc, raw, 1'b1, in1 ? xl1 : xl0, in1 ? pg1 : pg0, in1 ? pg1 : pg0, hh, ht, rok, rtgt, bk, bt);
        end else if ({1'b0, p} + 4'd1 < we) begin
            s.emit = 1'b1;
            s.next = {1'b0, p} + 4'd2;
            s.ins  = mk(pc, raw, 1'b0, in1 ? xl1 : xl0, in1 ? pg1 : pg0, (in1 || crosses) ? pg1 : pg0,
                        hh, ht, rok, rtgt, bk, bt);
        end else if (!in1) begin
            s.stash = 1'b1;                 // halfword 3 of the head with no successor: as qv_align
            s.next  = 4'd4;
        end else begin
            s.next  = {1'b0, p};            // halfword 7: its second half is beyond the window, it waits
        end
        s.conf = s.emit && hint_holds(raw, h[1:0] != 2'b11, pc, hh, ht, bk, bt);
        s.in1  = in1 || crosses;
        return s;
    endfunction

    logic [3:0]  cur;             // the next window position, wend = used up
    logic        stash;
    logic [15:0] stash_hw;
    logic        conf0, conf1, conf0_1, conf1_1;   // a slot's hint holds (and the hint is the next entry's)
    logic        hint_redir;
    logic        bk0, bt0;
    logic        ras_ok1;
    logic [63:0] ras_tgt1;
    logic        hint_here;
    slot_t       s0, s1;

    always_comb begin
        o_push0_valid = 1'b0;
        o_push1_valid = 1'b0;
        o_push0_data  = '0;
        o_push1_data  = '0;
        o_redirect_valid = 1'b0;
        o_redirect_pc    = '0;
        stash         = 1'b0;
        stash_hw      = '0;
        cur           = {2'b0, start};
        conf0         = 1'b0;
        conf1         = 1'b0;
        conf0_1       = 1'b0;
        conf1_1       = 1'b0;
        hint_redir    = 1'b0;
        hint_here     = 1'b0;
        bk0           = pend_q ? i_bht_pknown : i_bht_known[start];
        bt0           = pend_q ? i_bht_ptaken : i_bht_taken[start];
        o_ras_op0     = 2'b00;
        o_ras_op1     = 2'b00;
        o_ras_addr0   = '0;
        o_ras_addr1   = '0;
        ras_ok1       = i_ras_has1;
        ras_tgt1      = i_ras_top;
        s0            = '0;
        s1            = '0;

        if (go && i_buf_err) begin
            o_push0_valid = 1'b1;
            o_push0_data  = mk(pend_q ? pend_pc_q : base + {61'b0, start, 1'b0}, 32'b0, 1'b0,
                               pend_q && pend_xl_q, pend_q ? pend_pg_q : 44'b0, 44'b0);
            o_push0_data.xcpt       = 1'b1;
            o_push0_data.xcpt_cause = i_buf_cause;
            o_push0_data.xcpt_hi    = pend_q;
            cur = 4'd4;
        end else if (go) begin
            // slot 0: finish a crossing instruction, or start at cur
            if (pend_q) begin
                hint_here = i_buf_hint && i_buf_hx;
                o_push0_valid = 1'b1;
                o_push0_data  = mk(pend_pc_q, {hw8(i_buf_data, i_buf1_data, 3'd0), pend_hw_q}, 1'b0, pend_xl_q,
                                   pend_pg_q, i_buf_pg, hint_here, i_buf_htgt, i_ras_has1, i_ras_top, bk0, bt0);
                conf0 = hint_holds({hw8(i_buf_data, i_buf1_data, 3'd0), pend_hw_q}, 1'b0, pend_pc_q, hint_here,
                                   i_buf_htgt, bk0, bt0);
                cur = 4'd1;
            end else begin
                s0 = slot_at(cur[2:0], wend, i_buf_data, i_buf1_data, base, i_buf_xl, i_buf_pg, i_buf1_xl, i_buf1_pg,
                             i_buf_hint, i_buf_hoff, i_buf_hx, i_buf_htgt, i_buf1_hint, i_buf1_hoff, i_buf1_hx,
                             i_buf1_htgt, i_bht_known, i_bht_taken, i_bht_known1, i_bht_taken1, i_ras_has1, i_ras_top);
                o_push0_valid = s0.emit;
                o_push0_data  = s0.ins;
                conf0         = s0.conf && !s0.in1;
                conf0_1       = s0.conf && s0.in1;
                stash         = s0.stash;
                stash_hw      = hw8(i_buf_data, i_buf1_data, cur[2:0]);
                cur           = s0.next;
            end
            if (o_push0_valid) begin
                o_ras_op0   = ras_op_of(o_push0_data.raw);
                o_ras_addr0 = o_push0_data.pc + (o_push0_data.rvc ? 64'd2 : 64'd4);
                ras_ok1     = (o_ras_op0 == 2'b01) ? 1'b1 : i_ras_has1;
                ras_tgt1    = (o_ras_op0 == 2'b01) ? o_ras_addr0 : i_ras_top;
            end
            if (o_push0_valid && o_push0_data.pred_taken) begin
                if (conf0 || conf0_1) begin
                    cur = conf0_1 ? 4'd8 : 4'd4;     // fetch is already at the target: drop the rest of the entry
                end else begin
                    o_redirect_valid = 1'b1;
                    o_redirect_pc    = o_push0_data.pred_tgt;
                end
            end
            // slot 1: one more, if the window has any left
            if (o_push0_valid && !o_redirect_valid && cur < wend && i_push_ready) begin
                s1 = slot_at(cur[2:0], wend, i_buf_data, i_buf1_data, base, i_buf_xl, i_buf_pg, i_buf1_xl, i_buf1_pg,
                             i_buf_hint, i_buf_hoff, i_buf_hx, i_buf_htgt, i_buf1_hint, i_buf1_hoff, i_buf1_hx,
                             i_buf1_htgt, i_bht_known, i_bht_taken, i_bht_known1, i_bht_taken1, ras_ok1, ras_tgt1);
                if (ONE_COND && s1.emit && qv_is_cond(s1.ins.raw) && qv_is_cond(o_push0_data.raw)) begin
                    s1      = '0;          // (O8a) a second conditional waits for the next cycle's history
                    s1.next = cur;
                end
                o_push1_valid = s1.emit;
                o_push1_data  = s1.ins;
                conf1         = s1.conf && !s1.in1;
                conf1_1       = s1.conf && s1.in1;
                if (s1.stash) begin
                    stash    = 1'b1;
                    stash_hw = hw8(i_buf_data, i_buf1_data, cur[2:0]);
                end
                cur = s1.next;
                if (o_push1_valid && o_push1_data.pred_taken) begin
                    if (conf1 || conf1_1) begin
                        cur = conf1_1 ? 4'd8 : 4'd4;
                    end else begin
                        o_redirect_valid = 1'b1;
                        o_redirect_pc    = o_push1_data.pred_tgt;
                    end
                end
            end
            if (o_push1_valid) begin
                o_ras_op1   = ras_op_of(o_push1_data.raw);
                o_ras_addr1 = o_push1_data.pc + (o_push1_data.rvc ? 64'd2 : 64'd4);
            end
            // a hint no instruction confirmed, with its entry used up: fetch followed it for nothing, back to the
            // entry's successor (the window is the head alone when the head has a hint). The next entry's hint needs
            // nothing here: two instructions that start at halfword 3 or before end by halfword 7, so both entries
            // are used up in one cycle only by a confirmed hint in the second (align2_props proves it); an
            // unconfirmed one is dealt with once its entry is the head.
            if (!o_redirect_valid && !conf0 && !conf1 && i_buf_hint && cur == 4'd4) begin
                o_redirect_valid = 1'b1;
                o_redirect_pc    = base + 64'd8;
                hint_redir       = 1'b1;
            end
        end
    end

    // on a redirect, fetch drops the whole buffer itself
    assign o_buf_pop  = go && (cur >= 4'd4) && !o_redirect_valid;
    assign o_buf_pop2 = go && (cur == 4'd8) && !o_redirect_valid;

    always_ff @(posedge clk) begin
        if (rst || i_flush || (o_redirect_valid && !hint_redir)) begin
            mid_q  <= 1'b0;
            pend_q <= 1'b0;
        end else if (go) begin
            // the position in what is the head next cycle: this one, or (popped) the entry behind it
            mid_q  <= (cur < 4'd4) || (cur > 4'd4 && cur < 4'd8);
            off_q  <= cur[1:0];
            pend_q <= stash;
            if (stash) begin
                pend_hw_q <= stash_hw;
                pend_pc_q <= base + 64'd6;
                pend_xl_q <= i_buf_xl;
                pend_pg_q <= i_buf_pg;
            end
        end
    end

`ifndef SYNTHESIS
    // the entry behind a head with no hint is its sequential successor (fetch asks for dword + 8 unless a hint steers)
    always @(posedge clk) if (!rst && go && nseq && i_buf1_pc[63:3] != i_buf_pc[63:3] + 61'd1)
        $error("qv_align2: the entry behind the head is not its successor (%h after %h)", i_buf1_pc, i_buf_pc);
`endif
endmodule
