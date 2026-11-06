// SPDX-License-Identifier: MIT

/*
 * sb_props -- SymbiYosys properties for design/pipe/qv_sb.sv, the store buffer (DEPTH 2, YIELD_MAX 3 here).
 * Pushes, the match address, the LSU's and the walker's state and the answers are free; the slave is a
 * registered one (it answers a request that was on the bus, unanswered, the cycle before -- see fetch_props.sv),
 * and the LSU and the walker are never on the bus while one of the buffer's beats is in flight (the core makes
 * that so: they are held off by o_beat and o_start_now).
 *
 * Order and content are proved for an arbitrary entry: a symbolic index K is the K-th push; the K-th beat the
 * buffer ever starts must carry exactly what the K-th push put in. With the counters tied to the buffer's own
 * state (invariants below) that covers every entry.
 *
 *   - the K-th beat is the K-th push's address, byte select and data, and only one beat is ever in flight;
 *   - a beat stays on the bus, unchanged, until answered, and cyc is low in its response cycle;
 *   - nothing starts that has nothing to write: the beat count never passes the push count;
 *   - a beat starts only while the LSU is not on the bus and the walker's beat is not in flight; and, unless
 *     the buffer is full or has yielded for YIELD_MAX cycles, not while an LSU access is ready to start or a load
 *     is near the head;
 *   - o_start_now is followed by a beat in the next cycle, and no beat starts without it;
 *   - an answer that is not a beat's own (none in flight) changes nothing;
 *   - o_empty / o_ready follow the count, which never passes DEPTH; a push into a full buffer is refused;
 *   - o_match is exactly "an unanswered entry holds that dword".
 */
module sb_props (
    input logic         clk,
    input logic         rst,
    input logic         push,
    input logic [31:3]  push_addr,
    input logic [7:0]   push_sel,
    input logic [63:0]  push_data,
    input logic [31:3]  match_addr,
    input logic         lsu_busy, lsu_inflight, ptw_beat, load_near,
    input logic         foreign,        // another master has a request on the bus (the LSU's or the walker's)
    input logic         ack, err,
    input logic [3:0]   K
);
    localparam int DEPTH = 2;
    localparam int YIELD_MAX = 3;

    logic        ready, empty, match, start_now, start_idle, beat, cyc;
    logic [31:0] addr;
    logic [63:0] dat;
    logic [7:0]  sel;

    qv_sb #(.DEPTH(DEPTH), .YIELD_MAX(YIELD_MAX)) dut (
        .clk(clk), .rst(rst),
        .i_push(push), .i_push_addr(push_addr), .i_push_sel(push_sel), .i_push_data(push_data),
        .o_ready(ready), .o_empty(empty),
        .i_match_addr(match_addr), .o_match(match),
        .i_lsu_busy(lsu_busy), .i_lsu_inflight(lsu_inflight), .i_ptw_beat(ptw_beat), .i_load_near(load_near),
        .o_start_now(start_now), .o_start_idle(start_idle), .o_beat(beat), .o_cyc(cyc), .o_addr(addr), .o_dat(dat), .o_sel(sel),
        .i_ack(ack), .i_err(err)
    );

    reg init = 1'b1;
    reg p_valid = 1'b0, p_out = 1'b0;             // the previous cycle had an unanswered request of the buffer's on the bus
    reg p_any = 1'b0;                              // ... or of another master's
    reg p_foreign = 1'b0;                          // the previous cycle had an unanswered request of another master's
    reg [31:0] p_addr; reg [63:0] p_dat; reg [7:0] p_sel;
    reg p_start = 1'b0;                           // o_start_now in the previous cycle
    reg [3:0] npush = 4'd0, nbeat = 4'd0, nresp = 4'd0;
    reg       have_k = 1'b0;
    reg [31:3] k_addr; reg [7:0] k_sel; reg [63:0] k_dat;
    reg       in_beat = 1'b0;                     // a beat is in flight (its first cycle seen, not yet answered)

    wire accepted = !rst && push && ready;
    wire resp     = beat && (ack || err);

    always @(posedge clk) begin
        init    <= 1'b0;
        p_valid <= !rst;
        p_out   <= !rst && cyc && !ack && !err;
        p_any   <= !rst && (cyc || foreign) && !ack && !err;
        p_foreign <= !rst && foreign && !ack && !err;
        p_addr  <= addr; p_dat <= dat; p_sel <= sel;
        p_start <= !rst && start_now;
        if (rst) begin
            npush <= 4'd0; nbeat <= 4'd0; nresp <= 4'd0; have_k <= 1'b0; in_beat <= 1'b0;
        end else begin
            if (accepted) begin
                if (npush == K) begin have_k <= 1'b1; k_addr <= push_addr; k_sel <= push_sel; k_dat <= push_data; end
                npush <= npush + 4'd1;
            end
            if (cyc && !in_beat) begin nbeat <= nbeat + 4'd1; in_beat <= 1'b1; end
            if (resp) begin nresp <= nresp + 4'd1; in_beat <= 1'b0; end
        end
    end

    // ---- assumptions: the slave and the other masters ----
    reg [3:0] K_prev;
    always @(posedge clk) begin
        K_prev <= K;
        if (!init) assume (K == K_prev);                  // K is a constant
        if (init) assume (rst);
        // an answer only to a request that was on the bus, unanswered, in the cycle before
        if (!(p_valid && p_any)) assume (!ack && !err);
        // another master's request is on the bus only while none of the buffer's is
        if (foreign) assume (!beat);
        if (cyc) assume (!foreign);
        // ... and its owner is flagged as on the bus (the LSU's o_in_bus, the walker's beat) through the response cycle too
        if (foreign || p_foreign) assume (lsu_inflight || ptw_beat);
        // the LSU and the walker are off the port while a beat of the buffer is in flight, and an LSU access that
        // is on the bus is ready (busy) by definition
        if (beat) assume (!lsu_inflight && !ptw_beat);
        if (lsu_inflight) assume (lsu_busy);
    end

    // ---- properties ----
    wire [3:0] cnt_model = npush - nresp;
    always @(posedge clk) begin
        if (!rst && !init) begin
            // the count, ready and empty
            assert (cnt_model <= DEPTH);
            assert (dut.cnt_q == cnt_model);
            assert (empty == (cnt_model == 0));
            assert (ready == (cnt_model < DEPTH));
            // a beat in flight is one of the entries; the beat count never passes the push count
            assert (nbeat - nresp <= 4'd1);
            assert (in_beat == (nbeat != nresp));
            assert (!(in_beat && cnt_model == 0));
            assert (beat == dut.beat_q);
            // lemmas for the induction: where the entries are, and that the K-th one is still what was pushed
            assert (dut.rd_q == nresp[0]);
            assert (dut.wr_q == npush[0]);
            for (int j = 0; j < DEPTH; j++)
                assert (dut.v_q[j] == (((4'(j) - {3'b0, nresp[0]}) & 4'd1) < cnt_model));
            if (have_k && ((K - nresp) < cnt_model)) begin
                assert (dut.addr_q[K[0]] == k_addr);
                assert (dut.sel_q[K[0]] == k_sel);
                assert (dut.dat_q[K[0]] == k_dat);
            end
            // the K-th beat is the K-th push (its first cycle: nbeat has not counted it yet)
            if (cyc && have_k && (in_beat ? (nbeat == K + 4'd1) : (nbeat == K))) begin
                assert (addr == {k_addr, 3'b000});
                assert (sel == k_sel);
                assert (dat == k_dat);
            end
            // a beat is stable until answered, and cyc is low in its response cycle
            if (p_valid && p_out) begin
                assert (cyc || ack || err);
                if (cyc) begin assert (addr == p_addr); assert (sel == p_sel); assert (dat == p_dat); end
            end
            if (ack || err) assert (!cyc);
            // when a beat starts and why
            if (start_now) begin
                assert (!lsu_inflight);
                assert (!ptw_beat);
                assert (cnt_model > (resp ? 4'd1 : 4'd0));
                if (!(cnt_model == DEPTH) && !(dut.held_q >= YIELD_MAX)) assert (!lsu_busy && !load_near);
            end
            if (p_start) assert (beat);
            // the decision the LSU takes: an idle drain's, which does not look at the response
            assert (start_idle == (start_now && !beat));
            if (beat && !p_start && !(p_valid && p_out) && !p_out) begin end
            // the first cycle of a beat is preceded by its start
            if (cyc && !in_beat) assert (p_start);
            // o_match
            begin : m
                logic mm;
                mm = 1'b0;
                for (int i = 0; i < DEPTH; i++) if (dut.v_q[i] && dut.addr_q[i] == match_addr) mm = 1'b1;
                assert (match == mm);
            end
        end
    end

    // non-vacuity
    always @(posedge clk) begin
        if (!rst && !init) begin
            cover (accepted);
            cover (cyc && !in_beat);
            cover (resp && nresp == 4'd1);
            cover (resp && cnt_model == 4'd2);
            cover (start_now && resp);                  // a beat decided in the previous beat's response cycle
            cover (cnt_model == DEPTH && start_now && lsu_busy);   // full overrides a ready LSU access
            cover (!(cnt_model == DEPTH) && dut.held_q >= YIELD_MAX && start_now && load_near);   // yielded out
            cover (push && !ready);
            cover ((ack || err) && !beat);              // a foreign answer
        end
    end
endmodule
