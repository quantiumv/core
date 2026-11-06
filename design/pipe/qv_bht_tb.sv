// SPDX-License-Identifier: MIT

/*
 * qv_bht_tb -- design/pipe/qv_bht.sv against a model of its contract: ENTRIES two-bit counters indexed by pc[9:1]
 * (no tag), each with a trained bit.
 *
 * Directed: an untrained branch is not "known"; the first retirement sets the counter weakly towards the outcome
 * (taken: 2, not taken: 1), so it is known and predicts right away; the counter counts up on taken and down on
 * not taken, saturating at 3 and 0, and predicts taken from 2 up (two not-taken outcomes are needed to turn a
 * taken-trained branch round, from the weakly-taken state one); the four halfword positions of a dword and the
 * pending instruction's pc are looked up independently; two pcs that differ only above the index share a counter.
 *
 * Random: updates and lookups at random against the model.
 */
module qv_bht_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int ENTRIES = 16;
    localparam int IDX_W = $clog2(ENTRIES);

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [63:0] base_pc = '0, pend_pc = '0;
    logic [3:0]  known, taken;
    logic        pknown, ptaken;
    logic        upd_valid = 1'b0, upd_taken = 1'b0;
    logic [63:0] upd_pc = '0;

    qv_bht #(.ENTRIES(ENTRIES)) dut (
        .clk(clk), .rst(rst),
        .i_base_pc(base_pc), .i_pend_pc(pend_pc), .o_known(known), .o_taken(taken),
        .o_pend_known(pknown), .o_pend_taken(ptaken),
        .i_upd_valid(upd_valid), .i_upd_pc(upd_pc), .i_upd_taken(upd_taken)
    );

    // ---------------- model ----------------
    logic       m_v [0:ENTRIES-1];
    int         m_c [0:ENTRIES-1];

    task automatic m_reset();
        for (int i = 0; i < ENTRIES; i++) begin m_v[i] = 1'b0; m_c[i] = 1; end
    endtask
    function automatic int idx(input logic [63:0] pc);
        return int'(pc[IDX_W:1]);
    endfunction

    task automatic update(input logic [63:0] pc, input logic t);
        int i;
        @(negedge clk);
        upd_valid = 1'b1; upd_pc = pc; upd_taken = t;
        @(posedge clk); #1;
        upd_valid = 1'b0;
        i = idx(pc);
        if (!m_v[i]) begin m_v[i] = 1'b1; m_c[i] = t ? 2 : 1; end
        else if (t)  m_c[i] = (m_c[i] == 3) ? 3 : m_c[i] + 1;
        else         m_c[i] = (m_c[i] == 0) ? 0 : m_c[i] - 1;
    endtask

    task automatic look(input string name, input logic [63:0] dword, input logic [63:0] pend);
        base_pc = dword; pend_pc = pend;
        #1;
        for (int p = 0; p < 4; p++) begin
            int i;
            i = idx({dword[63:3], 3'b000} + 64'(2 * p));
            check($sformatf("%s: position %0d known", name, p), {63'b0, known[p]}, {63'b0, m_v[i]});
            check($sformatf("%s: position %0d taken", name, p), {63'b0, taken[p]}, {63'b0, m_v[i] && m_c[i] >= 2});
        end
        check({name, ": pending known"}, {63'b0, pknown}, {63'b0, m_v[idx(pend)]});
        check({name, ": pending taken"}, {63'b0, ptaken}, {63'b0, m_v[idx(pend)] && m_c[idx(pend)] >= 2});
    endtask

    int errs0;
    initial begin
        m_reset();
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        look("untrained", 64'h100, 64'h106);
        check("an untrained branch is not known", {60'b0, known}, 64'd0);

        // the first retirement: weakly towards the outcome
        update(64'h104, 1'b1);
        look("after one taken", 64'h100, 64'h104);
        check("known at its own position", {63'b0, known[2]}, 64'd1);
        check("taken from the first retirement", {63'b0, taken[2]}, 64'd1);
        check("the other positions stay untrained", {60'b0, known & 4'b1011}, 64'd0);
        update(64'h106, 1'b0);
        look("after one not taken", 64'h100, 64'h106);
        check("a not-taken first retirement predicts not taken", {63'b0, taken[3]}, 64'd0);
        check("... and is known", {63'b0, known[3]}, 64'd1);

        // hysteresis: from weakly taken one not-taken turns it, from strongly taken it takes two
        update(64'h104, 1'b0);
        look("taken once, then not taken", 64'h100, 64'h104);
        check("weakly taken, one not taken: now not taken", {63'b0, taken[2]}, 64'd0);
        update(64'h104, 1'b1); update(64'h104, 1'b1); update(64'h104, 1'b1);     // up to 3
        look("strongly taken", 64'h100, 64'h104);
        update(64'h104, 1'b0);
        look("strongly taken, one not taken", 64'h100, 64'h104);
        check("... still taken", {63'b0, taken[2]}, 64'd1);
        update(64'h104, 1'b0);
        look("two not taken", 64'h100, 64'h104);
        check("... now not taken", {63'b0, taken[2]}, 64'd0);
        // saturation at the bottom and the top
        for (int i = 0; i < 6; i++) update(64'h104, 1'b0);
        update(64'h104, 1'b1);
        look("saturated low, then taken once", 64'h100, 64'h104);
        check("from 0 one taken is not enough", {63'b0, taken[2]}, 64'd0);
        for (int i = 0; i < 6; i++) update(64'h104, 1'b1);
        update(64'h104, 1'b0);
        look("saturated high, then not taken once", 64'h100, 64'h104);
        check("from 3 one not taken is not enough", {63'b0, taken[2]}, 64'd1);

        // an alias above the index shares the counter
        look("alias", 64'h100 + 64'(2 * ENTRIES), 64'h104 + 64'(2 * ENTRIES));
        check("the alias sees the same counter", {63'b0, pknown}, {63'b0, m_v[idx(64'h104)]});

        // random
        m_reset();
        rst = 1'b1; repeat (2) @(posedge clk); #1 rst = 1'b0;
        errs0 = fail_count;
        for (int i = 0; i < 5000; i++) begin
            logic [63:0] pc;
            pc = 64'h1000 + 64'(($urandom % 96) * 2);
            if (($urandom % 3) != 0) update(pc, ($urandom % 3) != 0);
            look("random", 64'h1000 + 64'(($urandom % 12) * 8), 64'h1000 + 64'(($urandom % 96) * 2));
        end
        check("random run: no mismatch", 64'(fail_count - errs0), 64'd0);

        $display("");
        $display("qv_bht_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_bht_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
