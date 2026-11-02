// SPDX-License-Identifier: MIT

/*
 * lsq_props -- SymbiYosys properties for design/pipe/qv_lsq.sv together with design/pipe/qv_lsu.sv as the core runs
 * them (O2): the queue in front of the engine, with early accesses (EARLY), the handoff (HANDOFF) and the store buffer
 * (SB_EN, a RAM window of 4 KiB at 0). Around them a model of issue and the ROB: tags are allocated in order, one uop a
 * cycle at most, a memory op (dispatched to the queue when it has room) or another uop (which may be a barrier); the
 * head is the oldest unretired tag; commit retires the head once it is complete (a memory op when the engine has
 * completed it, another uop when the environment says so); a flush empties everything. Requests, operands, the PMP
 * state, the reservation, the store buffer's own signals (free; the buffer's match only covers stores that retired),
 * bus data and responses are free; the slave answers only a request that was on the bus, unanswered, the cycle before.
 *
 * Properties:
 *   - the engine takes the memory ops in the order they were dispatched;
 *   - an access that starts, or a store that is posted, before its op is the ROB head is a plain one inside the RAM
 *     window (a load or a postable store, not an atomic, not in a Program Buffer run), aligned, allowed by the PMP,
 *     with no unretired barrier older than it;
 *   - no load starts (early or at the head) while an older store to its dword is posted and has not retired;
 *   - when a memory op retires, the queue retires its entry, and the result commit reads is the one the engine wrote
 *     when it completed that op;
 *   - a started access stays on the bus, unchanged, until it is answered; the queue never overflows.
 * Proven by bounded model checking (the bmc task) with covers; no k-induction (the ROB model and the per-tag ghosts
 * would need many strengthening lemmas).
 */
module lsq_props (
    input logic                             clk,
    input logic                             rst,
    input logic                             flush,
    // issue
    input logic                             want_mem,       // dispatch a memory op this cycle (if there is room)
    input logic                             want_other,     // ... else allocate another uop
    input logic                             other_bar,      // ... which is a barrier
    input logic [4:0]                       op,
    input logic                             is_word,
    input logic [63:0]                      a, b, imm,
    // commit
    input logic                             other_done,     // a head that is not a memory op is complete
    input logic                             want_pop,
    // the rest of the engine's world
    input logic                             res_valid,
    input logic [63:0]                      res_addr,
    input logic [1:0]                       priv,
    input logic                             pb,
    input logic [63:0]                      pmpcfg0, pmpaddr0,
    input logic                             sb_empty, sb_match_retired, sb_beat, sb_go,
    input logic [63:0]                      dat,
    input logic                             ack, err
);
    import qv_pkg::*;

    localparam int ROB = 4;                     // entries alive at most: tags [head, tail), tag[1:0] unique among them
    localparam int QD  = 2;                     // the queue's depth

    // ---------------- the ROB model ----------------
    logic [QV_ROB_TAG_W-1:0] head_t, tail_t;
    wire  [QV_ROB_TAG_W-1:0] count = tail_t - head_t;
    wire                     rob_room = (count < QV_ROB_TAG_W'(ROB));
    logic                    is_mem [ROB], done [ROB], is_bar [ROB];
    wire  [1:0]              hi = head_t[1:0], ti = tail_t[1:0];

    logic lsq_free;
    wire  d_mem   = !rst && !flush && want_mem && lsq_free && rob_room;
    wire  d_other = !rst && !flush && !d_mem && want_other && rob_room;
    wire  head_valid    = (count != '0);
    wire  head_complete = is_mem[hi] ? done[hi] : other_done;
    wire  pop     = !rst && !flush && want_pop && head_valid && head_complete;

    fu_req_t req;
    always_comb begin
        req         = '0;
        req.valid   = d_mem;
        req.tag     = tail_t;
        req.op      = op;
        req.is_word = is_word;
        req.a       = a;
        req.b       = b;
        req.imm     = imm;
    end

    // ---------------- the two units ----------------
    fu_req_t     eng_req;
    logic        eng_free, eng_take, early, lsq_match;
    wb_t         wb;
    lsu_res_t    eng_res, head_res;
    logic [31:0] addr;
    logic [63:0] wdat;
    logic [7:0]  sel;
    logic        cyc, stb, we, lock, head_started, load_near, in_bus, bus_busy;
    logic [31:3] sb_addr;

    qv_lsq #(.DEPTH(QD)) lsq (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(lsq_free),
        .o_eng_req(eng_req), .i_eng_take(eng_take), .i_eng_wb(wb), .i_eng_res(eng_res),
        .i_pop(pop), .i_pop_tag(head_t), .o_head_res(head_res),
        .i_bar_alloc(d_other && other_bar), .i_bar_tag(tail_t), .o_early(early),
        .i_match_addr(sb_addr), .o_match(lsq_match)
    );

    qv_lsu #(.SB_EN(1'b1), .PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(64'h1000), .EARLY(1'b1), .HANDOFF(1'b1)) lsu (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(eng_req), .o_free(eng_free),
        .i_head_valid(head_valid), .i_head_tag(head_t), .i_early(early),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_priv(priv), .i_pmp_bypass(pb), .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(wdat), .wb_mem_sel_o(sel), .wb_mem_we_o(we),
        .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(eng_res), .o_head_started(head_started),
        .o_bus_busy(bus_busy),
        .i_sb_empty(sb_empty), .i_sb_match(sb_match_retired || lsq_match), .i_sb_beat(sb_beat), .i_sb_go(sb_go),
        .o_sb_addr(sb_addr), .o_load_near(load_near), .o_in_bus(in_bus), .o_take(eng_take)
    );

    // ---------------- ghosts ----------------
    reg               init = 1'b1;
    reg               p_valid = 1'b0, p_out = 1'b0, p_we;
    reg [31:0]        p_addr;
    reg [63:0]        p_wdat;
    reg [7:0]         p_sel;
    // the memory ops in dispatch order, and how many the engine has taken
    reg [QV_ROB_TAG_W-1:0] seq [4];
    reg [1:0]         n_disp = '0, n_take = '0;
    // per tag (index tag[1:0]): a store that was posted and has not retired, its dword; the result written at completion
    reg               posted [ROB];
    reg [31:3]        pdw    [ROB];
    reg               res_ok [ROB];              // ghost_res holds the completed op's result
    reg               g_xcpt [ROB], g_posted [ROB];
    reg [3:0]         g_cause [ROB];
    reg [63:0]        g_maddr [ROB], g_rdata [ROB];
    reg               cmpl_d = 1'b0;             // the engine completed an op last cycle ...
    reg [1:0]         cmpl_i_d;                  // ... this one
    wire              start = cyc && stb && !p_out;
    wire [1:0]        eti = lsu.tag_q[1:0];

    always @(posedge clk) begin
        init    <= 1'b0;
        p_valid <= !rst;
        p_out   <= !rst && cyc && stb && !ack && !err;
        p_addr  <= addr; p_wdat <= wdat; p_sel <= sel; p_we <= we;
        cmpl_d  <= !rst && !flush && wb.valid;
        cmpl_i_d <= wb.tag[1:0];
        if (rst || flush) begin
            head_t <= tail_t;
            n_disp <= '0; n_take <= '0;
            for (int i = 0; i < ROB; i++) begin
                is_mem[i] <= 1'b0; done[i] <= 1'b0; is_bar[i] <= 1'b0; posted[i] <= 1'b0; res_ok[i] <= 1'b0;
            end
            if (rst) begin head_t <= '0; tail_t <= '0; end
        end else begin
            if (d_mem || d_other) begin
                tail_t     <= tail_t + 1'b1;
                is_mem[ti] <= d_mem; done[ti] <= 1'b0; is_bar[ti] <= d_other && other_bar;
                posted[ti] <= 1'b0; res_ok[ti] <= 1'b0;
            end
            if (d_mem) begin seq[n_disp] <= tail_t; n_disp <= n_disp + 1'b1; end
            if (eng_take) n_take <= n_take + 1'b1;
            if (wb.valid) begin
                done[wb.tag[1:0]] <= 1'b1;
                if (lsu.post_done) begin posted[wb.tag[1:0]] <= 1'b1; pdw[wb.tag[1:0]] <= lsu.pa[31:3]; end
            end
            if (cmpl_d) begin
                res_ok[cmpl_i_d]  <= 1'b1;
                g_xcpt[cmpl_i_d]  <= eng_res.xcpt;   g_posted[cmpl_i_d] <= eng_res.posted;
                g_cause[cmpl_i_d] <= eng_res.cause;  g_maddr[cmpl_i_d]  <= eng_res.mem_addr;
                g_rdata[cmpl_i_d] <= eng_res.mem_rdata;
            end
            if (pop) begin
                head_t <= head_t + 1'b1;
                posted[hi] <= 1'b0; is_bar[hi] <= 1'b0;
            end
        end
    end

    // is tag t older than tag u (both alive)?
    function automatic logic older(input logic [QV_ROB_TAG_W-1:0] t, input logic [QV_ROB_TAG_W-1:0] u);
        return (t - head_t) < (u - head_t);
    endfunction
    function automatic logic alive(input logic [QV_ROB_TAG_W-1:0] t);
        return (t - head_t) < count;
    endfunction

    // an unretired barrier older than tag u; an unretired posted store older than u to dword d
    logic bar_older, posted_older;
    always_comb begin
        bar_older = 1'b0; posted_older = 1'b0;
        for (int k = 0; k < ROB; k++) begin
            logic [QV_ROB_TAG_W-1:0] t;
            t = head_t + QV_ROB_TAG_W'(k);
            if (alive(t) && older(t, lsu.tag_q) && is_bar[t[1:0]])  bar_older = 1'b1;
            if (alive(t) && older(t, lsu.tag_q) && posted[t[1:0]] && pdw[t[1:0]] == lsu.pa[31:3]) posted_older = 1'b1;
        end
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        if (!(p_valid && p_out)) assume (!ack && !err);
        if (op[4]) assume (op[3:0] <= 4'(QV_AMO_MAXU));
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && !init) begin
            // order
            // (with nothing queued, the engine takes the op dispatched in this very cycle, not recorded yet)
            if (eng_take) assert (eng_req.tag == ((n_take == n_disp) ? req.tag : seq[n_take]));
            if (eng_take && n_take == n_disp) assert (d_mem);
            // what goes before the head
            if ((lsu.start || lsu.post_done) && !lsu.at_head) begin
                assert (lsu.pa_in_window && !lsu.atomic_q && !pb && lsu.pa_valid && !lsu.misaligned_q && !lsu.pmp_deny);
                assert (!bar_older);
                assert (alive(lsu.tag_q) && is_mem[eti]);
            end
            // no load passes an older posted store to its dword
            if (lsu.start && !lsu.store_q && !lsu.atomic_q && lsu.pa_in_window && !pb) assert (!posted_older);
            // retirement: the queue retires its entry, with the engine's result
            if (pop && is_mem[hi]) begin
                assert (lsq.pop);
                if (res_ok[hi])
                    assert (head_res.xcpt == g_xcpt[hi] && head_res.posted == g_posted[hi] && head_res.cause == g_cause[hi]
                            && head_res.mem_addr == g_maddr[hi] && head_res.mem_rdata == g_rdata[hi]);
                else
                    assert (cmpl_d && cmpl_i_d == hi && head_res == eng_res);
            end
            if (pop && !is_mem[hi]) assert (!lsq.pop);
            // the bus
            if (p_valid && p_out && !ack && !err) begin
                assert (cyc && stb);
                assert (addr == p_addr && we == p_we && sel == p_sel && wdat == p_wdat);
            end
            if (req.valid) assert (lsq_free);
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst && !init) begin
            cover (lsu.start && !lsu.at_head && !lsu.store_q);                  // an early load starts
            cover (lsu.post_done && !lsu.at_head);                              // a store is posted early
            cover (eng_take && wb.valid);                                       // a handoff
            cover (lsq_match && lsu.state_q == 2'd1 && !lsu.at_head);           // a load waits for a posted store
            cover (pop && is_mem[hi] && res_ok[hi]);                            // a memory op retires from its copy
            cover (lsu.start && lsu.at_head && bar_older == 1'b0 && count > 2); // a head access with others behind
        end
    end
endmodule
