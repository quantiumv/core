// SPDX-License-Identifier: MIT

/*
 * ptw_props -- SymbiYosys properties for design/pipe/qv_ptw.sv, checked at
 * its ports and a few internals. Everything outside is free: both clients'
 * requests and cancels, the PMP configuration, the LSU's busy flag, the data
 * and the bus answers (ack and err at any time, even with no beat of the
 * walker's in flight: the shared bus and the formal wrapper drive them
 * freely).
 *
 * Properties:
 *   - a PTE read on the bus stays there, unchanged, until answered (never
 *     abandoned: wb_arbiter2 would hand a late ack elsewhere), and cyc is low
 *     in the response cycle;
 *   - a beat starts only when the LSU had nothing started or ready to start in
 *     the cycle before, and only for an address the PMP allows at S privilege
 *     (a denied read never reaches the bus);
 *   - a walk is at most three beats;
 *   - a walk whose client cancelled it at any time since it was accepted never
 *     reports a result (nothing may be filled behind a cancel);
 *   - a result that came from reading a PTE needs a response to a beat of the
 *     walker's own (a stray ack or err is ignored);
 *   - (P10d, a RAM window [0, 256 MB) set, i_f_nonspec free) a beat of client F
 *     to a PTE outside the window starts only after a cycle with i_f_nonspec high,
 *     and an F walk waiting for it gives the walker up at once when D asks.
 */
module ptw_props (
    input logic        clk,
    input logic        rst,
    input logic        ack, err,
    input logic [63:0] dat,
    input logic        lsu_busy,
    input logic [63:0] pmpcfg0, pmpaddr0, pmpaddr1, pmpaddr2, pmpaddr3,
    input logic        d_req, d_wr, d_sum, d_mxr, d_cancel,
    input logic [63:0] d_va,
    input logic [1:0]  d_priv,
    input logic [43:0] d_root,
    input logic        f_req, f_cancel,
    input logic [63:0] f_va,
    input logic [1:0]  f_priv,
    input logic [43:0] f_root,
    input logic        f_nonspec
);
    logic [31:0] addr;
    logic        cyc, beat, d_done, f_done;
    logic        res_ok, res_pf, res_af, res_r, res_w, res_x, res_u, res_d;
    logic [26:0] res_vpn;
    logic [1:0]  res_level;
    logic [43:0] res_ppn;

    qv_ptw #(.PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(64'h1000_0000)) dut (
        .clk(clk), .rst(rst),
        .o_bus_addr(addr), .o_bus_cyc(cyc), .i_bus_dat(dat), .i_bus_ack(ack), .i_bus_err(err),
        .i_lsu_busy(lsu_busy), .o_beat(beat),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1), .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .i_d_req(d_req), .i_d_va(d_va), .i_d_wr(d_wr), .i_d_priv(d_priv), .i_d_sum(d_sum), .i_d_mxr(d_mxr),
        .i_d_root(d_root), .i_d_cancel(d_cancel), .o_d_done(d_done),
        .i_f_req(f_req), .i_f_va(f_va), .i_f_priv(f_priv), .i_f_root(f_root), .i_f_cancel(f_cancel), .o_f_done(f_done),
        .i_f_nonspec(f_nonspec),
        .o_res_ok(res_ok), .o_res_pf(res_pf), .o_res_af(res_af), .o_res_vpn(res_vpn), .o_res_level(res_level),
        .o_res_ppn(res_ppn), .o_res_r(res_r), .o_res_w(res_w), .o_res_x(res_x), .o_res_u(res_u), .o_res_d(res_d)
    );

    // ---------------- ghost state: plain registers, no $past ----------------
    reg        init = 1'b1;
    reg        p_valid = 1'b0, p_cyc = 1'b0, p_beat = 1'b0, p_busy = 1'b0, p_ok = 1'b0, p_resp = 1'b0;
    reg [31:0] p_addr;
    reg [2:0]  nbeats = 3'd0;         // PTE reads started by the walk in progress
    reg        canc = 1'b0;           // the serving client cancelled since the walk was accepted
    reg        resp_seen = 1'b0;      // a response to a beat of this walk arrived
    reg        p_in_ram = 1'b1, p_nonspec = 1'b1, p_giveup = 1'b0;
    wire       accept = dut.accept_d || dut.accept_f;
    wire       brise  = beat && !p_beat;      // a beat starts (in the first cycle o_beat is up)
    always @(posedge clk) begin
        init    <= 1'b0;
        p_valid <= !rst;
        p_cyc   <= cyc && !rst;
        p_beat  <= beat && !rst;
        p_resp  <= ack || err;
        p_addr  <= addr;
        p_busy  <= lsu_busy;
        p_ok    <= dut.pmp_r_ok;
        p_in_ram  <= dut.pte_in_ram;
        p_nonspec <= f_nonspec;
        // F waits in W_GO for the real path and D asks: the walker is to give F up at this edge
        p_giveup  <= !rst && dut.st_q == 2'd1 && !dut.stale_eff && !dut.pmp_deny && dut.f_wait && dut.d_can;
        if (rst) begin
            nbeats    <= 3'd0;
            canc      <= 1'b0;
            resp_seen <= 1'b0;
        end else begin
            if (accept) begin
                nbeats    <= 3'd0;
                canc      <= 1'b0;
                resp_seen <= 1'b0;
            end else begin
                if (brise)                             nbeats    <= nbeats + 3'd1;
                if (dut.st_q != 2'd0 && dut.cancel_srv) canc     <= 1'b1;
                if (dut.resp)                          resp_seen <= 1'b1;
            end
        end
    end

    always @* if (init) assume (rst);

    // ---------------- properties ----------------
    always @* begin
        if (!rst && p_valid) begin
            // never abandoned or moved before its response
            if (p_cyc && !ack && !err) begin
                assert (cyc);
                assert (addr == p_addr);
            end
            // a beat starts only after a cycle with the LSU idle and the read permitted
            if (brise) begin
                assert (!p_busy);
                assert (p_ok);
                // ... and an F read outside the RAM window only on the architectural path
                if (dut.cl_q) assert (p_in_ram || p_nonspec);
            end
            // a waiting F walk gives the walker up as soon as D asks
            if (p_giveup) assert (dut.st_q == 2'd0);
        end
        if (!rst) begin
            assert (!(cyc && (ack || err)));     // cyc is low in the response cycle
            assert (beat || !cyc);
            assert (nbeats <= 3'd3);
            // nothing is reported for a walk that was cancelled
            if (dut.rep_any) assert (!canc && !dut.cancel_srv);
            // a result that came from reading a PTE needs a response to a beat of the walker's own
            if (dut.rep_any && !dut.pmp_deny) assert (resp_seen);
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst && p_valid) begin
            cover (brise && p_ok);                        // a beat started
            cover (nbeats == 3'd3 && dut.rep_any);        // a walk of three reads that ended
            cover (dut.rep_any && dut.rep_ok);            // a leaf
            cover (dut.rep_any && dut.rep_pf);            // a page fault
            cover (dut.rep_any && dut.rep_af);            // an access fault
            cover (canc && dut.st_q == 2'd0);             // a cancelled walk wound down
            cover (!p_beat && (ack || err));              // a stray response
            cover (dut.st_q == 2'd1 && dut.f_wait);       // F waits for the real path
            cover (p_giveup);                             // ... and gives the walker up to D
            cover (brise && dut.cl_q && !p_in_ram);       // F reads outside the window, on the real path
        end
    end

    // ---------------- induction lemmas ----------------
    // the number of beats follows the level being read; a beat in flight is the walker's own
    always @* begin
        if (!init && !rst) begin
            if (dut.st_q == 2'd1)  assert (nbeats == (3'd2 - {1'b0, dut.level_q}));                    // W_GO
            if (dut.st_q == 2'd2)  assert (nbeats == (brise ? (3'd2 - {1'b0, dut.level_q})
                                                            : (3'd3 - {1'b0, dut.level_q})));          // W_BEAT
            if (dut.st_q == 2'd3)  assert (nbeats == (3'd3 - {1'b0, dut.level_q}));                    // W_DEC
            // the ghosts follow the walker's own bookkeeping
            if (dut.st_q != 2'd0) assert (canc == dut.stale_q);
            if (dut.st_q == 2'd3 || (dut.st_q == 2'd1 && dut.level_q != 2'd2)) assert (resp_seen);
            if (dut.beat_q) assert (dut.st_q == 2'd2);
            if (dut.st_q != 2'd0) assert (dut.level_q <= 2'd2);
            if (p_valid && p_beat && !p_resp) assert (dut.beat_q);
        end
    end
endmodule
