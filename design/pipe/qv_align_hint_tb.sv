// SPDX-License-Identifier: MIT

/*
 * qv_align_hint_tb -- the aligner (design/pipe/qv_align.sv) and the instruction queue under branch target buffer
 * hints, with the fetch buffer played by a model of what qv_fetch does with a BTB.
 *
 * The source plays dwords of a random program (16- and 32-bit instructions, JAL/C.J, conditional branches both
 * ways, indirect jumps, returns). For each dword it may attach a hint, as the BTB would: right (a control-flow
 * instruction that starts in the dword at or after the first halfword used, with its own target; a 32-bit one
 * that crosses into the next dword is hinted on that next dword, at halfword 0, with the crossing flag), a right
 * place with a wrong target, a phantom (any halfword, any target), or none. After a hinted dword the source plays the
 * hinted target, as fetch would; a redirect of the aligner's restarts it and empties its buffer.
 *
 * What comes out of the queue must be a valid path through the program whatever the hints said, and the aligner
 * must make progress:
 *   - the first instruction after a restart is the restart pc; each next one is at the previous one's predicted
 *     target if it was predicted taken, else right behind it; the bits and the length are the image's;
 *   - a taken prediction is on a control-flow instruction only: a direct one goes to its own target, an indirect
 *     one (not a return) anywhere; a JAL/C.J is always predicted taken; a return is predicted taken to the address
 *     the return-address stack holds when it is emitted -- a model of the stack, fed by the calls and returns in
 *     the order they come out of the queue, says what that is -- and not at all when the stack is empty;
 *   - a conditional branch the branch history table has seen is predicted as its counter says, whatever a hint says
 *     (looked up at the cycle it is emitted: the testbench trains the table with random outcomes as branches come out
 *     of the queue); one it has not is predicted by the static rule or a hint;
 *   - the number of instructions that come out grows.
 * Without hints the same checks are the static prediction's. Runs with ONE_OK off and on, and with random
 * consumer backpressure.
 */
`include "riscv_encode.sv"

module qv_align_hint_tb #(
    parameter bit ONE_OK = 1'b0
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    localparam int W = $bits(fe_instr_t);
    localparam int MEM_HW = 2048;                   // 4 KiB of code
    localparam int FBD = 4;
    localparam int RAS_DEPTH = 4;
    localparam int BHT_ENTRIES = 64;               // small, so branches alias

    // ---------------- DUT ----------------
    logic        buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic        buf_hint, buf_hx;
    logic [1:0]  buf_hoff;
    logic [63:0] buf_htgt;
    logic        buf_pop;
    logic        p0_valid, p1_valid, push_ready, push_ready1;
    fe_instr_t   p0_data, p1_data;
    logic        fe_redir;
    logic [63:0] fe_redir_pc;
    logic        flush = 1'b0;
    logic        head_valid;
    logic [W-1:0] head_bits;
    fe_instr_t   head;
    int          pop_pct = 100;
    logic        pop_roll;
    always @(negedge clk) pop_roll = ($urandom % 100) < pop_pct;
    wire         pop = head_valid && pop_roll;
    assign head = fe_instr_t'(head_bits);

    logic        ras_has1;
    logic [1:0]  ras_op0, ras_op1;
    logic [63:0] ras_a0, ras_a1, ras_top;
    qv_ras #(.DEPTH(RAS_DEPTH)) ras0 (
        .clk(clk), .rst(rst),
        .i_sp_op0(ras_op0), .i_sp_addr0(ras_a0), .i_sp_op1(ras_op1), .i_sp_addr1(ras_a1),
        .i_cm_push(1'b0), .i_cm_addr(64'b0), .i_cm_pop(1'b0), .i_flush(flush),
        .o_top(ras_top), .o_has1(ras_has1)
    );

    logic [63:0] bht_base, bht_ppc, bht_upd_pc;
    logic [3:0]  bht_known, bht_taken;
    logic        bht_pknown, bht_ptaken, bht_upd_valid = 1'b0, bht_upd_taken = 1'b0;
    qv_bht #(.ENTRIES(BHT_ENTRIES)) bht0 (
        .clk(clk), .rst(rst),
        .i_base_pc(bht_base), .i_pend_pc(bht_ppc),
        .o_known(bht_known), .o_taken(bht_taken), .o_pend_known(bht_pknown), .o_pend_taken(bht_ptaken),
        .i_upd_valid(bht_upd_valid), .i_upd_pc(bht_upd_pc), .i_upd_taken(bht_upd_taken)
    );

    qv_align #(.ONE_OK(ONE_OK)) align0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_buf_valid(buf_valid), .i_buf_pc(buf_pc), .i_buf_data(buf_data), .i_buf_err(buf_err),
        .i_buf_hint(buf_hint), .i_buf_hoff(buf_hoff), .i_buf_hx(buf_hx), .i_buf_htgt(buf_htgt),
        .o_buf_pop(buf_pop),
        .o_bht_base(bht_base), .o_bht_ppc(bht_ppc),
        .i_bht_known(bht_known), .i_bht_taken(bht_taken), .i_bht_pknown(bht_pknown), .i_bht_ptaken(bht_ptaken),
        .i_ras_top(ras_top), .i_ras_has1(ras_has1),
        .o_ras_op0(ras_op0), .o_ras_addr0(ras_a0), .o_ras_op1(ras_op1), .o_ras_addr1(ras_a1),
        .o_push0_valid(p0_valid), .o_push0_data(p0_data),
        .o_push1_valid(p1_valid), .o_push1_data(p1_data),
        .i_push_ready(push_ready), .i_push_ready1(push_ready1),
        .o_redirect_valid(fe_redir), .o_redirect_pc(fe_redir_pc)
    );

    qv_fifo #(.WIDTH(W), .DEPTH(8)) iq0 (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_push0_valid(p0_valid), .i_push0_data(p0_data),
        .i_push1_valid(p1_valid), .i_push1_data(p1_data),
        .o_push_ready(push_ready), .o_push_ready1(push_ready1),
        .o_head_valid(head_valid), .o_head_data(head_bits),
        .i_pop(pop)
    );

    // ---------------- the program ----------------
    logic [15:0] mem     [0:MEM_HW-1];
    logic [2:0]  kind_at [0:MEM_HW-1];              // 0: not an instruction start, 1 plain, 2 direct, 3 indirect, 4 return
    logic        jal_at  [0:MEM_HW-1];              // JAL / C.J: always taken
    logic        call_at [0:MEM_HW-1];              // a call: its link register is ra
    logic        cond_at [0:MEM_HW-1];              // a conditional branch
    logic [63:0] tgt_at  [0:MEM_HW-1];              // a direct one's target
    int          starts  [0:MEM_HW-1];
    int          n_starts;

    function automatic logic [15:0] rand_c();       // a compressed halfword that is not control flow
        logic [15:0] h;
        do begin
            h = 16'($urandom);
            if (h[1:0] == 2'b11) h[1:0] = 2'($urandom % 3);
        end while ((h[1:0] == 2'b01 && (h[15:13] == 3'b101 || h[15:14] == 2'b11))
                   || (h[1:0] == 2'b10 && h[15:13] == 3'b100 && h[6:2] == 5'd0 && h[11:7] != 5'd0));
        return h;
    endfunction
    function automatic logic [31:0] rand_32();      // a 32-bit encoding that is not JAL/branch/JALR
        logic [31:0] w;
        do w = {$urandom} | 32'h3; while (w[6:0] == 7'b1101111 || w[6:0] == 7'b1100011 || w[6:0] == 7'b1100111);
        return w;
    endfunction

    task automatic put16(input int hw, input logic [15:0] h);
        mem[hw] = h;
    endtask
    task automatic put32(input int hw, input logic [31:0] w);
        mem[hw]     = w[15:0];
        mem[hw + 1] = w[31:16];
    endtask

    task automatic make_program();
        int  hw, k, t, off;
        int  len [0:MEM_HW-1];
        int  typ [0:MEM_HW-1];
        for (int i = 0; i < MEM_HW; i++) begin
            mem[i] = 16'($urandom); kind_at[i] = 3'd0; jal_at[i] = 1'b0; call_at[i] = 1'b0; cond_at[i] = 1'b0; tgt_at[i] = '0;
        end
        // pass 1: lengths and types
        hw = 0; n_starts = 0;
        while (hw < MEM_HW - 2) begin
            starts[n_starts] = hw;
            typ[n_starts]    = ($urandom % 100) < 35 ? 1 + int'($urandom % 9) : 0;   // 0 plain, 1.. control flow
            case (typ[n_starts])
                0: len[n_starts] = (($urandom % 100) < 45) ? 1 : 2;                   // halfwords
                1, 2, 3: len[n_starts] = 2;                                           // 32-bit JAL, B backward, B forward
                4, 5, 6: len[n_starts] = 1;                                           // C.J, C.BEQZ, C.BNEZ
                7: len[n_starts] = 2;                                                 // JALR (indirect)
                8: len[n_starts] = 2;                                                 // JALR ra (a return)
                default: len[n_starts] = 1;                                           // C.JR (indirect) / C.JR ra
            endcase
            hw += len[n_starts];
            n_starts++;
        end
        // pass 2: encodings, with targets among the instruction starts
        for (k = 0; k < n_starts; k++) begin
            int  here, pick;
            here = starts[k];
            kind_at[here] = 3'd1;
            case (typ[k])
                0: begin
                    if (len[k] == 1) put16(here, rand_c()); else put32(here, rand_32());
                end
                1: begin    // JAL
                    pick = starts[$urandom % n_starts];
                    off = (pick - here) * 2;
                    call_at[here] = ($urandom % 2) == 1;
                    put32(here, encode_j(off, call_at[here] ? 5'd1 : 5'd0, `OPC_JAL));
                    kind_at[here] = 3'd2; jal_at[here] = 1'b1; tgt_at[here] = 64'(pick * 2);
                end
                2: begin    // conditional, backward
                    pick = starts[$urandom % (k + 1)];
                    off = (pick - here) * 2;
                    if (off >= -4096 && off < 0) begin
                        put32(here, encode_b(off, 5'($urandom), 5'($urandom), 3'b001, `OPC_BRANCH));
                        kind_at[here] = 3'd2; cond_at[here] = 1'b1; tgt_at[here] = 64'(pick * 2);
                    end else put32(here, rand_32());
                end
                3: begin    // conditional, forward
                    pick = starts[(k + 1 + $urandom % 40) % n_starts];
                    off = (pick - here) * 2;
                    if (off > 0 && off < 4096) begin
                        put32(here, encode_b(off, 5'($urandom), 5'($urandom), 3'b100, `OPC_BRANCH));
                        kind_at[here] = 3'd2; cond_at[here] = 1'b1; tgt_at[here] = 64'(pick * 2);
                    end else put32(here, rand_32());
                end
                4: begin    // C.J
                    pick = starts[$urandom % n_starts];
                    off = (pick - here) * 2;
                    if (off >= -2048 && off < 2048 && off != 0) begin
                        put16(here, encode_c_j(off));
                        kind_at[here] = 3'd2; jal_at[here] = 1'b1; tgt_at[here] = 64'(pick * 2);
                    end else put16(here, rand_c());
                end
                5, 6: begin // C.BEQZ / C.BNEZ
                    pick = starts[(k + $urandom % 60) % n_starts];
                    off = (pick - here) * 2;
                    if (off >= -256 && off < 256 && off != 0) begin
                        put16(here, typ[k] == 5 ? encode_c_beqz(off, 3'($urandom)) : encode_c_bnez(off, 3'($urandom)));
                        kind_at[here] = 3'd2; cond_at[here] = 1'b1; tgt_at[here] = 64'(pick * 2);
                    end else put16(here, rand_c());
                end
                7: begin    // JALR, not a return: rd ra, rs1 a5
                    put32(here, encode_i(0, 5'd15, 3'b000, 5'd1, `OPC_JALR));
                    kind_at[here] = 3'd3; call_at[here] = 1'b1;
                end
                8: begin    // JALR x0, 0(ra): a return
                    put32(here, encode_i(0, 5'd1, 3'b000, 5'd0, `OPC_JALR));
                    kind_at[here] = 3'd4;
                end
                default: begin
                    case ($urandom % 3)
                        0: begin put16(here, encode_c_jr(5'd7)); kind_at[here] = 3'd3; end                              // C.JR t2
                        1: begin put16(here, encode_c_jalr(5'd7)); kind_at[here] = 3'd3; call_at[here] = 1'b1; end      // C.JALR t2
                        default: begin put16(here, encode_c_jr(5'd1)); kind_at[here] = 3'd4; end                         // C.JR ra: a return
                    endcase
                end
            endcase
        end
    endtask

    // ---------------- fetch model with a BTB ----------------
    logic [63:0] fpc;                               // the dword (start pc) the source plays next
    logic [63:0] fb_pc   [0:FBD-1];
    logic [63:0] fb_dat  [0:FBD-1];
    logic        fb_h    [0:FBD-1];
    logic [1:0]  fb_ho   [0:FBD-1];
    logic        fb_hxx  [0:FBD-1];
    logic [63:0] fb_ht   [0:FBD-1];
    int          fb_n, fb_rd;
    logic        src_en = 1'b0;
    int          p_true = 45, p_wrong = 10, p_phantom = 10;
    int          hints_true = 0, hints_wrong = 0, hints_phantom = 0;
    int          true_fwd = 0;                      // right hints on a forward conditional branch (static prediction never takes those)
    int          true_jalr = 0;                     // right hints on an indirect jump (nothing else predicts those taken)

    function automatic logic [63:0] dword_at(input logic [63:0] a);
        int b;
        b = int'(a[11:3]) * 4;
        return {mem[b + 3], mem[b + 2], mem[b + 1], mem[b]};
    endfunction

    assign buf_valid = (fb_n != 0);
    assign buf_err   = 1'b0;
    assign buf_pc    = fb_pc[fb_rd];
    assign buf_data  = fb_dat[fb_rd];
    assign buf_hint  = fb_h[fb_rd];
    assign buf_hoff  = fb_ho[fb_rd];
    assign buf_hx    = fb_hxx[fb_rd];
    assign buf_htgt  = fb_ht[fb_rd];

    // restart / reset of the source
    logic [63:0] restart_pc = '0;
    logic        restart = 1'b0;

    task automatic pick_hint(input logic [63:0] dpc, output logic h, output logic [1:0] ho, output logic hx,
                             output logic [63:0] ht);
        // candidates: control-flow instructions starting in this dword at or after the first halfword used, plus a
        // crossing one that ends in the first halfword
        int  nc;
        int  cand_hw [0:4];
        logic cand_x [0:4];
        int  base, start, r, c;
        logic [63:0] tg;
        h = 1'b0; ho = 2'b0; hx = 1'b0; ht = '0;
        base  = int'({dpc[11:3], 3'b000}) / 2;
        start = int'(dpc[2:1]);
        nc = 0;
        for (int j = start; j < 4; j++)
            if (kind_at[base + j] >= 3'd2 && kind_at[base + j] <= 3'd4) begin
                // a 32-bit instruction that starts in the last halfword is hinted on the next dword
                if (j == 3 && (mem[base + 3][1:0] == 2'b11)) continue;
                cand_hw[nc] = j; cand_x[nc] = 1'b0; nc++;
            end
        if (start == 0 && base >= 1 && kind_at[base - 1] >= 3'd2 && kind_at[base - 1] <= 3'd4 && mem[base - 1][1:0] == 2'b11
            && (base - 1) % 4 == 3) begin
            cand_hw[nc] = 0; cand_x[nc] = 1'b1; nc++;
        end
        r = $urandom % 100;
        if (r < p_true && nc > 0) begin
            c  = $urandom % nc;
            h  = 1'b1; ho = 2'(cand_hw[c]); hx = cand_x[c];
            tg = tgt_at[(hx ? base - 1 : base + cand_hw[c])];
            ht = (kind_at[(hx ? base - 1 : base + cand_hw[c])] == 3'd2) ? tg : 64'(starts[$urandom % n_starts] * 2);
            hints_true++;
            if (!hx && kind_at[base + cand_hw[c]] == 3'd2 && !jal_at[base + cand_hw[c]] && tgt_at[base + cand_hw[c]] > 64'(2 * (base + cand_hw[c])))
                true_fwd++;
            if (kind_at[hx ? base - 1 : base + cand_hw[c]] == 3'd3) true_jalr++;
        end else if (r < p_true + p_wrong && nc > 0) begin
            c  = $urandom % nc;
            h  = 1'b1; ho = 2'(cand_hw[c]); hx = cand_x[c];
            ht = 64'(starts[$urandom % n_starts] * 2);
            hints_wrong++;
        end else if (r < p_true + p_wrong + p_phantom) begin
            h  = 1'b1; ho = 2'(start + ($urandom % (4 - start))); hx = (start == 0) && (($urandom % 4) == 0);
            if (hx) ho = 2'd0;
            ht = 64'(starts[$urandom % n_starts] * 2);
            hints_phantom++;
        end
    endtask

    logic        nh, nhx;
    logic [1:0]  nho;
    logic [63:0] nht;
    int          wr;
    always @(posedge clk) begin
        if (rst) begin
            fb_n <= 0; fb_rd <= 0;
        end else if (restart || flush) begin
            fb_n <= 0; fb_rd <= 0;
            fpc  <= restart_pc;
        end else if (src_en && fe_redir) begin
            fb_n <= 0; fb_rd <= 0;
            fpc  <= fe_redir_pc;
        end else begin
            int n_next, rd_next;
            n_next = fb_n; rd_next = fb_rd;
            if (buf_pop && fb_n != 0) begin n_next--; rd_next = (fb_rd + 1) % FBD; end
            if (src_en && n_next < FBD && fpc < MEM_HW * 2 - 32) begin
                pick_hint(fpc, nh, nho, nhx, nht);
                wr = (rd_next + n_next) % FBD;
                fb_pc[wr] <= fpc; fb_dat[wr] <= dword_at(fpc);
                fb_h[wr] <= nh; fb_ho[wr] <= nho; fb_hxx[wr] <= nhx; fb_ht[wr] <= nht;
                n_next++;
                fpc <= nh ? nht : {fpc[63:3], 3'b000} + 64'd8;
            end
            fb_n <= n_next; fb_rd <= rd_next;
        end
    end

    // ---------------- the table, at the cycle a branch is emitted ----------------
    int bht_errs = 0, n_bht_known = 0, n_bht_veto = 0, n_bht_s1 = 0, n_bht_pend = 0, n_bht_diff = 0;
    task automatic check_bht(input fe_instr_t i, input string slot);
        int hwi;
        logic k, t, st_taken;
        hwi = int'(i.pc[11:1]);
        // the lookups are of the right addresses: the head dword for what starts in it, the pending pc for a crossing instruction
        if (i.pc[63:3] != buf_pc[63:3] && bht_ppc !== i.pc) begin
            bht_errs++; $display("HINT_TB: %s: the pending lookup is of %h, the instruction is at %h", slot, bht_ppc, i.pc);
        end
        if (bht_base[63:3] !== buf_pc[63:3]) begin
            bht_errs++; $display("HINT_TB: %s: the dword lookup is of %h, the dword is %h", slot, bht_base, buf_pc);
        end
        if (!cond_at[hwi]) return;
        if (i.pc[63:3] == buf_pc[63:3]) begin k = bht_known[i.pc[2:1]]; t = bht_taken[i.pc[2:1]]; end
        else                            begin k = bht_pknown;            t = bht_ptaken;            end
        st_taken = tgt_at[hwi] < i.pc;
        if (k) begin
            n_bht_known++;
            if (slot == "slot 1") begin
                n_bht_s1++;
                if (bht_known[i.pc[2:1]] != bht_known[buf_pc[2:1]] || bht_taken[i.pc[2:1]] != bht_taken[buf_pc[2:1]]) n_bht_diff++;
            end
            if (i.pc[63:3] != buf_pc[63:3]) n_bht_pend++;
            if (i.pred_taken !== t) begin
                bht_errs++; $display("HINT_TB: %s: branch at %h predicted %b, the table says %b", slot, i.pc, i.pred_taken, t);
            end
            if (!t && (hint_was_here(i.pc))) n_bht_veto++;
        end else if (st_taken && !i.pred_taken) begin
            bht_errs++; $display("HINT_TB: %s: untrained backward branch at %h not predicted taken", slot, i.pc);
        end
    endtask
    // was a (right) hint on this branch in the head dword's entry?
    function automatic logic hint_was_here(input logic [63:0] pc);
        return buf_hint && !buf_hx && (buf_hoff == pc[2:1]) && (pc[63:3] == buf_pc[63:3]);
    endfunction
    always @(posedge clk) begin
        if (!rst && !flush && !restart) begin
            if (p0_valid) check_bht(p0_data, "slot 0");
            if (p1_valid) check_bht(p1_data, "slot 1");
        end
    end
    // a branch taken by its hint is not redirected on: fetch is already at its target
    int n_hint_taken = 0;
    task automatic count_hint_taken(input fe_instr_t i);
        int hwi;
        hwi = int'(i.pc[11:1]);
        if (i.pred_taken && kind_at[hwi] == 3'd2 && hint_was_here(i.pc) && i.pred_tgt === buf_htgt && !fe_redir) n_hint_taken++;
    endtask
    always @(posedge clk) begin
        if (!rst && !flush && !restart) begin
            if (p0_valid) count_hint_taken(p0_data);
            if (p1_valid) count_hint_taken(p1_data);
        end
    end
    // training: a random outcome for every conditional branch that comes out of the queue (biased per branch)
    always @(posedge clk) begin
        bht_upd_valid <= 1'b0;
        if (!rst && pop && head_valid && !flush && !restart && cond_at[head.pc[11:1]] && ($urandom % 3) == 0) begin
            bht_upd_valid <= 1'b1;
            bht_upd_pc    <= head.pc;
            bht_upd_taken <= (($urandom % 100) < (20 + (int'(head.pc[7:1]) * 7) % 70));
        end
    end

    // ---------------- checker ----------------
    logic [63:0] exp_pc;
    logic        exp_first;                         // the next instruction is the first after a restart
    logic [63:0] m_ras [0:RAS_DEPTH-1];             // model of the return-address stack, in queue order
    int          m_ras_n = 0;
    int          n_ret = 0;
    int          popped = 0, errs = 0;
    int          n_fwd = 0, n_jalr = 0, n_cross = 0;       // taken predictions only a hint can make: forward branch, JALR, crossing
    always @(posedge clk) begin
        if (rst) begin
            exp_first <= 1'b1;
        end else if (restart || flush) begin
            exp_first <= 1'b1;
            exp_pc    <= restart_pc;
            m_ras_n   = 0;
        end else if (pop && head_valid) begin
            int hwi, len;
            logic [31:0] raw;
            hwi = int'(head.pc[11:1]);
            len = (mem[hwi][1:0] == 2'b11) ? 4 : 2;
            raw = (len == 4) ? {mem[hwi + 1], mem[hwi]} : {16'b0, mem[hwi]};
            popped <= popped + 1;
            if (head.pc !== exp_pc) begin
                errs++; $display("HINT_TB: pc %h expected %h at t=%0t", head.pc, exp_pc, $time);
            end
            if (head.raw !== raw || head.rvc !== (len == 2)) begin
                errs++; $display("HINT_TB: bits at %h are %h (rvc %b), image has %h", head.pc, head.raw, head.rvc, raw);
            end
            if (kind_at[hwi] == 3'd4) begin
                // a return: predicted to the stack's top, or not at all when the stack is empty
                if (m_ras_n > 0) begin
                    n_ret++;
                    if (!head.pred_taken || head.pred_tgt !== m_ras[0]) begin
                        errs++; $display("HINT_TB: return at %h predicted %b to %h, the stack's top is %h", head.pc, head.pred_taken, head.pred_tgt, m_ras[0]);
                    end
                end else if (head.pred_taken) begin
                    errs++; $display("HINT_TB: return at %h predicted taken with an empty stack", head.pc);
                end
                if (m_ras_n > 0) begin
                    for (int i = 0; i < RAS_DEPTH - 1; i++) m_ras[i] = m_ras[i+1];
                    m_ras_n--;
                end
            end else if (call_at[hwi]) begin
                for (int i = RAS_DEPTH - 1; i > 0; i--) m_ras[i] = m_ras[i-1];
                m_ras[0] = head.pc + 64'(len);
                if (m_ras_n < RAS_DEPTH) m_ras_n++;
            end
            if (head.pred_taken && kind_at[hwi] != 3'd4) begin
                if (kind_at[hwi] < 3'd2) begin
                    errs++; $display("HINT_TB: predicted taken on a non-branch at %h (kind %0d)", head.pc, kind_at[hwi]);
                end
                if (kind_at[hwi] == 3'd2 && head.pred_tgt !== tgt_at[hwi]) begin
                    errs++; $display("HINT_TB: direct branch at %h predicted to %h, its target is %h", head.pc, head.pred_tgt, tgt_at[hwi]);
                end
            end else if (jal_at[hwi]) begin
                errs++; $display("HINT_TB: JAL at %h not predicted taken", head.pc);
            end
            if (head.pred_taken && !jal_at[hwi]) begin
                if (kind_at[hwi] == 3'd3) begin
                    n_jalr++;
                    if (len == 4 && head.pc[2:1] == 2'b11) n_cross++;
                end else if (kind_at[hwi] == 3'd2 && head.pred_tgt > head.pc) begin
                    n_fwd++;
                end
            end
            exp_pc    <= head.pred_taken ? head.pred_tgt : head.pc + 64'(len);
            exp_first <= 1'b0;
        end
    end

    // ---------------- driver ----------------
    task automatic restart_at(input logic [63:0] pc);
        @(negedge clk);
        restart_pc = pc; restart = 1'b1;
        @(negedge clk);
        restart = 1'b0;
    endtask

    int prog, n0, c, seed_cfg;
    initial begin
        for (int i = 0; i < FBD; i++) begin fb_pc[i] = '0; fb_dat[i] = '0; fb_h[i] = 1'b0; fb_ho[i] = 2'b0; fb_hxx[i] = 1'b0; fb_ht[i] = '0; end
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        for (prog = 0; prog < 24; prog++) begin
            // empty the pipeline of the last program before the image changes under it
            src_en = 1'b0;
            @(negedge clk);
            restart_pc = '0; flush = 1'b1;
            @(negedge clk);
            flush = 1'b0;
            repeat (4) @(posedge clk);
            make_program();
            // hint mixes: none, mostly right, mostly wrong, all kinds
            case (prog % 4)
                0: begin p_true = 0;  p_wrong = 0;  p_phantom = 0;  end
                1: begin p_true = 80; p_wrong = 5;  p_phantom = 5;  end
                2: begin p_true = 10; p_wrong = 40; p_phantom = 40; end
                default: begin p_true = 45; p_wrong = 15; p_phantom = 15; end
            endcase
            pop_pct = (prog % 3 == 0) ? 100 : (prog % 3 == 1) ? 60 : 25;
            src_en = 1'b0;
            restart_at(64'(starts[$urandom % (n_starts / 2)] * 2));
            n0 = popped;
            src_en = 1'b1;
            for (c = 0; c < 6000; c++) begin
                @(posedge clk);
                // now and then a flush from "commit": restart somewhere else
                if (($urandom % 400) == 0) begin
                    @(negedge clk);
                    restart_pc = 64'(starts[$urandom % (n_starts / 2)] * 2);
                    flush = 1'b1;
                    @(negedge clk);
                    flush = 1'b0;
                end
            end
            check($sformatf("program %0d: the aligner made progress", prog), 64'((popped - n0) > 300), 64'd1);
        end
        check("every instruction out was on a valid path", 64'(errs), 64'd0);
        // the hints were taken up: forward branches, indirect jumps and crossing branches predicted taken at all
        // (the static prediction makes none of these), in the runs where the hints were right
        check("hints made forward branches predicted taken", 64'(n_fwd > 20), 64'd1);
        // (the table also predicts forward branches taken once trained, so the share is judged on the indirect jumps,
        // which only a hint can predict)
        check("... a good share of the right hints on indirect jumps were taken up", 64'(n_jalr * 5 > true_jalr * 2), 64'd1);
        $display("qv_align_hint_tb: indirect jumps predicted taken %0d of %0d right hints on them (forward branches: %0d of %0d)",
                 n_jalr, true_jalr, n_fwd, true_fwd);
        check("hints made indirect jumps predicted taken", 64'(n_jalr > 20), 64'd1);
        check("hints made crossing indirect jumps predicted taken", 64'(n_cross > 2), 64'd1);
        check("returns were predicted from the stack", 64'(n_ret > 50), 64'd1);
        check("conditional branches came out as the table said", 64'(bht_errs), 64'd0);
        check("direct branches were taken on their hints without a redirect", 64'(n_hint_taken > 100), 64'd1);
        $display("qv_align_hint_tb: %0d direct branches taken by a hint with no redirect", n_hint_taken);
        check("the table was consulted", 64'(n_bht_known > 500), 64'd1);
        $display("qv_align_hint_tb: %0d branches predicted from a trained counter, %0d of them over a hint (slot 1: %0d, %0d with another counter than the start's; pending: %0d)",
                 n_bht_known, n_bht_veto, n_bht_s1, n_bht_diff, n_bht_pend);
        $display("qv_align_hint_tb (ONE_OK=%0d): %0d instructions, hints: %0d right, %0d wrong target, %0d phantom",
                 ONE_OK, popped, hints_true, hints_wrong, hints_phantom);
        $display("");
        $display("qv_align_hint_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_align_hint_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT: qv_align_hint_tb");
        $finish;
    end
endmodule
