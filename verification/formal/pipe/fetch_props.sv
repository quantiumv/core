// SPDX-License-Identifier: MIT

/*
 * fetch_props -- SymbiYosys properties for design/pipe/qv_fetch.sv,
 * checked at its ports only. Redirects, holds, yields, pops and the slave's
 * responses are all free, except that the slave answers only a request
 * that was on the bus the cycle before (ack and err together allowed, as the
 * caches do) and returns data that is a fixed function of the address asked for.
 *
 * Properties:
 *   - a request on the bus stays there, unchanged, until answered
 *     (never abandoned: wb_arbiter2 would hand a late ack elsewhere);
 *   - every entry fetch hands out is the next one expected: the target
 *     of the latest redirect, then each following dword in turn. A stale
 *     response (one issued before a redirect) or a dropped/duplicated
 *     one breaks this. Its data is the data of its own address;
 *   - while held (FENCE.I), no new request starts; held and idle means
 *     nothing on the bus; nothing is on the bus in reset (from its second cycle);
 *   - a hint from the branch target buffer (free here, at a halfword at or after the request's first, as the BTB
 *     promises) redirects the stream: the dword after a hinted one is the hint's target, and the hint travels with
 *     its dword unchanged;
 *   - streaming (STREAM): a request presented in the cycle another is answered
 *     needs no redirect, hold or yield in that cycle and a free slot in the
 *     buffer for its own answer; the buffer never overflows;
 *   - (O8b) the entry behind the head (o_buf1_*) is where the head leads, with the data of its own address, and
 *     popping both (i_buf_pop2, free here) moves the head two entries on; with IDLE_GO a request may go out from an
 *     idle bus in the cycle it is issued (no hold, redirect or yield in that cycle, a slot for its answer), so the
 *     hold properties allow a request in the first cycle without a hold.
 *
 *   - (W3b, -DF16) FETCH16: every request asks for the 16-byte block of its pc and the slave answers both dwords
 *     (the upper one a fixed function of its address too); the second BTB lookup (the upper dword's) is free. The
 *     properties above hold as they are, the entries being dwords; a request presented in an answer's cycle, or from
 *     an idle bus, needs room for two entries; the lemmas say a request pushes two exactly when it starts in the lower
 *     dword with no hint there, and is then followed by the upper dword's hint or the next block.
 *
 * Built for FB_DEPTH = FBD (default 4; -DFBD=2 for the formal small
 * configuration), STREAM (default on; -DNOSTREAM for the old rate) and IDLE_GO (-DIDLEGO: the window aligner's).
 */
`ifndef FBD
`define FBD 4
`endif
module fetch_props (
    input logic        clk,
    input logic        rst,
    input logic        ack, err,
    input logic        redirect_valid,
    input logic [63:0] redirect_pc,
    input logic        hold,
    input logic        yield,
    input logic        pop,
    input logic        pop2,
    input logic        btb_hit,
    input logic [1:0]  btb_off,
    input logic        btb_x,
    input logic [63:0] btb_tgt,
    input logic        btb2_hit,
    input logic [1:0]  btb2_off,
    input logic        btb2_x,
    input logic [63:0] btb2_tgt
);
    localparam logic [63:0] RESET_PC = 64'h0;
    localparam int FBD = `FBD;
`ifdef NOSTREAM
    localparam bit STREAM = 1'b0;
`else
    localparam bit STREAM = 1'b1;
`endif
    localparam int CW = $clog2(FBD + 1);
`ifdef IDLEGO
    localparam bit IDLE_GO = 1'b1;
`else
    localparam bit IDLE_GO = 1'b0;
`endif
`ifdef F16
    localparam bit F16 = 1'b1;
`else
    localparam bit F16 = 1'b0;
`endif
    // (F16) a request needs room for two entries
    localparam int ROOM = F16 ? 2 : 1;

    logic [31:0] addr;
    logic        cyc, stb, idle, buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic [63:0] btb_pc, buf_htgt;
    logic        buf_hint, buf_hx;
    logic [1:0]  buf_hoff;
    logic        buf1_valid, buf1_err, buf1_hint, buf1_hx;
    logic [63:0] buf1_pc, buf1_data, buf1_htgt;
    logic [1:0]  buf1_hoff;
    // the slave's memory: data = f(address), registered like wb4_sram's (the data of the request seen the cycle before)
    reg  [63:0]  dat = 64'b0;
    always @(posedge clk) dat <= {addr, ~addr};
    // (F16) the block's upper dword, the same function of its own address
    reg  [63:0]  dat_hi = 64'b0;
    always @(posedge clk) dat_hi <= {addr | 32'h8, ~(addr | 32'h8)};
    logic [63:0] btb2_pc;

`ifdef FETCH_OLD
    qv_fetch #(.RESET_PC(RESET_PC)) dut (
`else
    qv_fetch #(.RESET_PC(RESET_PC), .FB_DEPTH(FBD), .STREAM(STREAM), .BTB_EN(1'b1), .IDLE_GO(IDLE_GO), .FETCH16(F16)) dut (
`endif
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(addr), .wb_fetch_cyc_o(cyc), .wb_fetch_stb_o(stb),
        .wb_fetch_dat_i(dat), .wb_fetch_ack_i(ack), .wb_fetch_err_i(err),
        .i_redirect_valid(redirect_valid), .i_redirect_pc(redirect_pc),
`ifndef FETCH_OLD
        .i_hold(hold), .o_idle(idle), .i_yield(yield),
        .o_btb_pc(btb_pc), .i_btb_hit(btb_hit), .i_btb_off(btb_off), .i_btb_x(btb_x), .i_btb_tgt(btb_tgt),
        .wb_fetch_dat_hi_i(dat_hi),
        .o_btb2_pc(btb2_pc), .i_btb2_hit(btb2_hit), .i_btb2_off(btb2_off), .i_btb2_x(btb2_x), .i_btb2_tgt(btb2_tgt),
        .o_buf_hint(buf_hint), .o_buf_hoff(buf_hoff), .o_buf_hx(buf_hx), .o_buf_htgt(buf_htgt),
        .o_buf1_valid(buf1_valid), .o_buf1_pc(buf1_pc), .o_buf1_data(buf1_data), .o_buf1_err(buf1_err),
        .o_buf1_hint(buf1_hint), .o_buf1_hoff(buf1_hoff), .o_buf1_hx(buf1_hx), .o_buf1_htgt(buf1_htgt),
        .i_buf_pop2(pop2),
`endif
        .o_buf_valid(buf_valid), .o_buf_pc(buf_pc), .o_buf_data(buf_data),
        .o_buf_err(buf_err), .i_buf_pop(pop)
    );

    // previous cycle, as plain registers (no $past dependence). p_cyc: a
    // request was on the bus last cycle (it is answered, at the earliest, now).
    reg        init = 1'b1;
    reg        p_valid = 1'b0, p_cyc = 1'b0, p_out = 1'b0, p_hold = 1'b0, p_idle_hold = 1'b0;
    reg [31:0] p_addr;
    reg [63:0] exp_pc = RESET_PC;
    reg        redirected = 1'b0;
    always @(posedge clk) begin
        init        <= 1'b0;
        p_valid     <= !rst;
        p_cyc       <= !rst && cyc && stb;
        p_out       <= !rst && cyc && stb && !ack && !err;
        p_addr      <= addr;
        p_hold      <= hold && !rst;
        p_idle_hold <= hold && idle && !rst;
        if (rst) begin
            exp_pc <= RESET_PC;
        end else if (redirect_valid) begin
            exp_pc     <= redirect_pc;
            redirected <= 1'b1;
        end else if (buf_valid && pop) begin
`ifdef FETCH_OLD
            exp_pc <= {exp_pc[63:3], 3'b000} + 64'd8;
`else
            if (pop2 && buf1_valid) exp_pc <= buf1_hint ? buf1_htgt : {buf1_pc[63:3], 3'b000} + 64'd8;
            else                    exp_pc <= buf_hint ? buf_htgt : {exp_pc[63:3], 3'b000} + 64'd8;
`endif
        end
    end

    // ---------------- environment ----------------
    // A registered Wishbone slave, like wb4_sram: it answers a request
    // that was on the bus the cycle before (and, with a streaming master,
    // the request it is shown in an answer's cycle is answered in the next).
    always @* begin
        if (init) assume (rst);
        if (!(p_valid && p_cyc)) assume (!ack && !err);
`ifndef FETCH_OLD
        // the BTB's promise: its branch is at or after the first halfword of the request being issued
        if (btb_hit) assume (btb_off >= btb_pc[2:1]);
`endif
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && p_valid) begin
            // never abandoned or moved before its response
            if (p_cyc && !ack && !err) begin
                assert (cyc && stb);
                assert (addr == p_addr);
            end
            // (F16) every request is for a 16-byte block, and the second lookup is its upper dword
            if (F16 && cyc) assert (addr[3:0] == 4'h0);
            if (F16) assert (btb2_pc == {btb_pc[63:4], 4'b1000});
            // held: nothing new starts; held and idle: nothing on the bus (IDLE_GO: a request may go out in the
            // first cycle without a hold, from an idle bus)
`ifndef FETCH_OLD
            if (p_hold && cyc) assert (p_out || (IDLE_GO && !hold));
            if (p_idle_hold) assert (!cyc || (IDLE_GO && !hold));
`endif
        end
        if (!rst && buf_valid && !redirect_valid) begin
            assert (buf_pc == exp_pc);
            if (!buf_err) assert (buf_data == {exp_pc[31:3], 3'b000, ~{exp_pc[31:3], 3'b000}});
        end
`ifndef FETCH_OLD
        // the entry behind the head: where the head leads, its own data
        if (!rst && buf1_valid && !redirect_valid) begin
            assert (buf_valid);
            assert (buf1_pc == (buf_hint ? buf_htgt : {exp_pc[63:3], 3'b000} + 64'd8));
            if (!buf1_err) assert (buf1_data == {buf1_pc[31:3], 3'b000, ~{buf1_pc[31:3], 3'b000}});
        end
        // a request from an idle bus in its issue cycle: nothing holds, redirects or yields, and its answer has a slot
        if (!rst && !init && cyc && !dut.req_valid_q) begin
            assert (IDLE_GO);
            assert (!redirect_valid && !hold && !yield);
            assert (dut.fb_count_next < CW'(FBD + 1 - ROOM));
            assert (addr == (F16 ? {dut.fpc_q[31:4], 4'b0000} : {dut.fpc_q[31:3], 3'b000}));
        end
`endif
`ifndef FETCH_OLD
        // idle: nothing on the bus (IDLE_GO: unless a request goes out from the idle bus, which a hold stops; o_idle
        // is read only while held, by the FENCE.I commit)
        if (idle && (hold || !IDLE_GO)) assert (!cyc);
        // a reset cycle after a reset cycle: nothing on the bus (the slaves and arbiters are in reset too)
        if (rst && !init && !p_valid) assert (!cyc);
        // a request presented in an answer's cycle: only when streaming, and only when nothing redirects, holds or
        // yields in it and the buffer will have a slot for that request's own answer
        if (!rst && !init && cyc && (ack || err)) begin
            assert (STREAM);
            assert (!redirect_valid);
            assert (!hold);
            assert (!yield);
            assert (dut.fb_count_next < CW'(FBD + 1 - ROOM));
        end
`endif
    end

`ifndef FETCH_OLD
    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst) begin
            cover (buf_valid && pop && !redirect_valid && redirected);   // an entry after a redirect
            cover (ack && dut.req_stale_q);                              // a stale response dropped
            cover (err && p_out);                                        // a bus error
            cover (p_idle_hold && redirected);                           // held to idle
            cover (STREAM && cyc && (ack || err) && p_cyc && !p_hold);   // a request presented in an answer's cycle
            cover (STREAM && yield && ack && p_cyc && !cyc);             // a stream paused by a yield
            cover (buf1_valid && pop && pop2 && !redirect_valid);        // two entries popped
            if (F16) begin
                cover (dut.fb_push2 && redirected);                       // an answer that fills two entries
                cover (dut.fb_push2 && dut.req_h2_q && redirected);       // ... the upper one hinted
                cover (dut.fb_push && !dut.fb_push2 && dut.req_pc_q[3]);  // a start in the upper dword: one entry
                cover (dut.fb_push2 && err);                              // an error answer: two fault entries
            end
`ifdef IDLEGO
            cover (cyc && !dut.req_valid_q && redirected);              // a request from an idle bus
`endif
        end
    end

    // ---------------- induction lemmas ----------------
    // The ghost exp_pc is the pc of the buffer's head entry (or of the
    // next push when empty); the entries, the request in flight and
    // fpc_q follow it dword by dword.
    function automatic logic [63:0] word(input logic [63:0] p);
        return {p[31:3], 3'b000, ~{p[31:3], 3'b000}};
    endfunction
    // the pc of the j-th dword after exp_pc's own
    function automatic logic [63:0] ahead(input logic [63:0] p, input int j);
        return {p[63:3], 3'b000} + 64'd8 * 64'(j);
    endfunction

    wire [CW-1:0] cnt = dut.fb_count_q;

    // the pc fetch continues at after entry j of the buffer: the hint's target, or the next dword
    function automatic logic [63:0] after(input int j);
        int k;
        k = (int'(dut.fb_rd_q) + j) % FBD;
        return dut.fb_hint[k] ? dut.fb_htgt[k] : ahead(dut.fb_pc[k], 1);
    endfunction
    // where the next push (the next response) lands: the head's pc when the buffer is empty, else after the last entry
    wire [63:0]   npush = (cnt == '0) ? exp_pc : after(int'(cnt) - 1);

    always @* begin
        if (!init && !rst) begin
            assert (cnt <= CW'(FBD));
            // (F16's FB_DEPTH 5 and 3 are not powers of two: the pointers have values no buffer slot has)
            assert (int'(dut.fb_rd_q) < FBD);
            assert (int'(dut.fb_wr_q) < FBD);
            assert (int'(dut.fb_wr_q) == (int'(dut.fb_rd_q) + int'(cnt)) % FBD);
            for (int j = 0; j < FBD; j++) begin
                if (j < int'(cnt)) begin
                    // the head is the expected pc; every later entry is where the one before it led
                    assert (dut.fb_pc[(int'(dut.fb_rd_q) + j) % FBD] == ((j == 0) ? exp_pc : after(j - 1)));
                    if (!dut.fb_err[(int'(dut.fb_rd_q) + j) % FBD])
                        assert (dut.fb_data[(int'(dut.fb_rd_q) + j) % FBD] == word(dut.fb_pc[(int'(dut.fb_rd_q) + j) % FBD]));
                    // a hint never names a halfword before the dword's own first one
                    if (dut.fb_hint[(int'(dut.fb_rd_q) + j) % FBD])
                        assert (dut.fb_hoff[(int'(dut.fb_rd_q) + j) % FBD] >= dut.fb_pc[(int'(dut.fb_rd_q) + j) % FBD][2:1]);
                end
            end
            if (dut.req_valid_q && !dut.req_stale_q) begin
                assert (cnt <= CW'(FBD - ROOM));   // issue reserved its response's slots
                assert (dut.req_pc_q == npush);
                if (F16) begin
                    // two entries exactly when it starts in the lower dword with no taken branch there; then the
                    // upper dword's hint or the next block follows
                    assert (dut.req_two_q == (!dut.req_pc_q[3] && !dut.req_hint_q));
                    if (dut.req_two_q) assert (dut.fpc_q == (dut.req_h2_q ? dut.req_h2tgt_q : ahead(npush, 2)));
                    else               assert (dut.fpc_q == (dut.req_hint_q ? dut.req_htgt_q : ahead(npush, 1)));
                end else begin
                    assert (!dut.req_two_q);
                    assert (dut.fpc_q == (dut.req_hint_q ? dut.req_htgt_q : ahead(npush, 1)));
                end
                if (dut.req_hint_q) assert (dut.req_hoff_q >= dut.req_pc_q[2:1]);
            end else begin
                assert (dut.fpc_q == npush);
            end
            if (p_valid && p_cyc) assert (dut.req_valid_q);
            if (p_valid && p_out) assert (p_addr == (F16 ? {dut.req_pc_q[31:4], 4'b0000} : {dut.req_pc_q[31:3], 3'b000}));
        end
    end
`else
    assign idle = 1'b0;     // the pre-FENCE.I version has no o_idle
`endif
endmodule
