// SPDX-License-Identifier: MIT
/*
 * qv_gshare_tb -- design/pipe/qv_gshare.sv against a model of its contract.
 *
 * Directed: the speculative history shifts in a conditional's predicted direction and nothing else; a restore puts
 * back the mispredicted branch's history and then its real direction (the opposite of its prediction) when it is a
 * conditional, its history alone when not; a flush copies the committed history as this cycle's retirement leaves
 * it; flush beats restore beats the shift; a counter is trained at the branch's pc XOR the committed history, set
 * weakly towards its first outcome and saturating; an untrained counter is not known. A branch that alternates is
 * learned through the history (its two counters), which a table indexed by the pc alone cannot do.
 *
 * Random: lookups at random dwords and pending pcs, the aligner's conditional, restores, flushes and training at
 * random, every output against the model every cycle (H and BITS from the parameters: tests.list runs the shipping
 * 12/12 and the formal small 3/3).
 */
module qv_gshare_tb #(
    parameter int H    = 12,
    parameter int BITS = 12
);
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int ENTRIES = 1 << BITS;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [63:0] base_pc = '0, base1_pc = '0, pend_pc = '0, upd_pc = '0, rh64 = '0;
    logic        cnd = 1'b0, prd = 1'b0, flush = 1'b0, restore = 1'b0, r_cond = 1'b0, r_pred = 1'b0;
    logic        upd_valid = 1'b0, upd_taken = 1'b0;
    wire [H-1:0] r_h = rh64[H-1:0];
    logic [3:0]  known, taken, known1, taken1;
    logic        pknown, ptaken;
    logic [H-1:0] hist, hist_c;

    qv_gshare #(.H(H), .BITS(BITS)) dut (
        .clk(clk), .rst(rst),
        .i_base_pc(base_pc), .i_base1_pc(base1_pc), .i_pend_pc(pend_pc),
        .o_known(known), .o_taken(taken), .o_known1(known1), .o_taken1(taken1),
        .o_pend_known(pknown), .o_pend_taken(ptaken), .o_hist(hist),
        .i_cond(cnd), .i_pred(prd),
        .i_flush(flush), .i_restore(restore), .i_restore_h(r_h), .i_restore_cond(r_cond), .i_restore_pred(r_pred),
        .i_upd_valid(upd_valid), .i_upd_pc(upd_pc), .i_upd_taken(upd_taken), .o_hist_c(hist_c)
    );

    // ---------------- model ----------------
    logic [1:0]   m_ctr [0:ENTRIES-1];
    logic         m_v   [0:ENTRIES-1];
    logic [H-1:0] m_h = '0, m_hc = '0;

    function automatic logic [H-1:0] m_shift(input logic [H-1:0] h, input logic b);
        logic [H:0] t;
        t = {h, b};
        return t[H-1:0];
    endfunction
    function automatic int m_idx(input logic [63:0] pc, input logic [H-1:0] h);
        logic [BITS-1:0] a;
        a = pc[BITS:1];
        return int'(a ^ BITS'(h));
    endfunction
    function automatic logic m_known(input logic [63:0] pc);
        return m_v[m_idx(pc, m_h)];
    endfunction
    function automatic logic m_taken(input logic [63:0] pc);
        int i;
        i = m_idx(pc, m_h);
        return m_v[i] && m_ctr[i][1];
    endfunction
    task automatic m_reset();
        for (int i = 0; i < ENTRIES; i++) begin m_v[i] = 1'b0; m_ctr[i] = 2'b01; end
        m_h = '0; m_hc = '0;
    endtask
    // the clock edge, as the model sees it (all inputs as driven this cycle)
    task automatic m_step();
        logic [H-1:0] hc_next;
        int u;
        hc_next = upd_valid ? m_shift(m_hc, upd_taken) : m_hc;
        if (upd_valid) begin
            u = m_idx(upd_pc, m_hc);
            if (!m_v[u])        m_ctr[u] = upd_taken ? 2'b10 : 2'b01;
            else if (upd_taken) m_ctr[u] = (m_ctr[u] == 2'b11) ? 2'b11 : m_ctr[u] + 2'b01;
            else                m_ctr[u] = (m_ctr[u] == 2'b00) ? 2'b00 : m_ctr[u] - 2'b01;
            m_v[u] = 1'b1;
        end
        if (flush)        m_h = hc_next;
        else if (restore) m_h = r_cond ? m_shift(r_h, !r_pred) : r_h;
        else if (cnd)     m_h = m_shift(m_h, prd);
        m_hc = hc_next;
    endtask

    int errs = 0;
    task automatic compare(input string what);
        logic e;
        e = 1'b0;
        for (int p = 0; p < 4; p++) begin
            logic [63:0] a, a1;
            a  = {base_pc[63:3], 2'(p), 1'b0};
            a1 = {base1_pc[63:3], 2'(p), 1'b0};
            if (known[p] !== m_known(a) || taken[p] !== m_taken(a)) e = 1'b1;
            if (known1[p] !== m_known(a1) || taken1[p] !== m_taken(a1)) e = 1'b1;
        end
        if (pknown !== m_known(pend_pc) || ptaken !== m_taken(pend_pc)) e = 1'b1;
        if (hist !== m_h || hist_c !== m_hc) e = 1'b1;
        if (e) begin
            errs++;
            if (errs < 10) $display("GSHARE_TB: %s: mismatch at t=%0t (hist %h/%h, model %h/%h)", what, $time,
                                    hist, hist_c, m_h, m_hc);
        end
    endtask

    // one cycle with the inputs as set, then everything idle again
    task automatic cycle(input string what);
        #1 compare({what, " (before the edge)"});
        m_step();
        @(posedge clk); #1;
        compare({what, " (after the edge)"});
        cnd = 1'b0; prd = 1'b0; flush = 1'b0; restore = 1'b0; upd_valid = 1'b0;
        @(negedge clk);
    endtask

    task automatic train(input logic [63:0] pc, input logic t);
        upd_valid = 1'b1; upd_pc = pc; upd_taken = t;
        cycle("train");
    endtask

    logic [H-1:0] hsave;
    int ok_alt;
    initial begin
        m_reset();
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        check("reset: speculative history 0", 64'(hist), 64'd0);
        check("reset: committed history 0", 64'(hist_c), 64'd0);
        base_pc = 64'h1000; #1;
        check("reset: nothing known", 64'(known), 64'd0);

        // the speculative history shifts in a conditional's predicted direction only
        cnd = 1'b1; prd = 1'b1; cycle("shift taken");
        check("shift: 1", 64'(hist), 64'd1);
        cnd = 1'b1; prd = 1'b0; cycle("shift not taken");
        check("shift: 10", 64'(hist), 64'(2'b10 & ((1 << H) - 1)));
        cycle("no conditional");
        check("idle: unchanged", 64'(hist), 64'(2'b10 & ((1 << H) - 1)));
        check("the committed history did not move", 64'(hist_c), 64'd0);

        // a restore: a conditional's history, then its real direction (the opposite of its prediction)
        hsave = H'(64'h5a5);
        restore = 1'b1; rh64 = 64'(hsave); r_cond = 1'b1; r_pred = 1'b1; cycle("restore a conditional");
        check("restore: the conditional's history and its real direction", 64'(hist), 64'(m_shift(hsave, 1'b0)));
        restore = 1'b1; rh64 = 64'(hsave); r_cond = 1'b0; r_pred = 1'b1; cycle("restore a jump");
        check("restore: a jump's history alone", 64'(hist), 64'(hsave));
        // restore beats the aligner's shift
        restore = 1'b1; rh64 = 64'(hsave); r_cond = 1'b0; cnd = 1'b1; prd = 1'b1; cycle("restore and shift");
        check("restore beats the shift", 64'(hist), 64'(hsave));

        // training moves the committed history; a flush copies it, this cycle's retirement included
        train(64'h2000, 1'b1);
        check("committed history after one taken", 64'(hist_c), 64'd1);
        upd_valid = 1'b1; upd_pc = 64'h2004; upd_taken = 1'b1;
        flush = 1'b1; restore = 1'b1; rh64 = 64'(hsave); cnd = 1'b1; prd = 1'b0;
        cycle("flush with a retirement, a restore and a shift");
        check("flush: the committed history with this cycle's retirement", 64'(hist), 64'(2'b11 & ((1 << H) - 1)));

        // a counter: weak towards its first outcome, saturating; trained at pc XOR the committed history
        m_reset(); rst = 1'b1; @(posedge clk); @(negedge clk) rst = 1'b0;
        for (int i = 0; i < 4; i++) train(64'h3008, 1'b0);     // committed history stays 0
        base_pc = 64'h3008; #1;
        check("a not-taken branch is known", {63'b0, known[0]}, 64'd1);
        check("... and not taken", {63'b0, taken[0]}, 64'd0);
        train(64'h3008, 1'b1);                                    // 00 -> 01, committed history now 1
        base_pc = 64'h3008; #1;
        check("training does not move the speculative history", {63'b0, known[0]}, 64'd1);
        flush = 1'b1; cycle("flush to the committed history");
        base_pc = 64'h3008; #1;
        check("the history moved: a different counter, not trained yet", {63'b0, known[0]}, 64'd0);

        // an alternating branch, learned through the history: T N T N ... (each outcome moves the history, both the
        // committed one and, here, the speculative one with it as a real aligner would on the right path)
        m_reset(); rst = 1'b1; @(posedge clk); @(negedge clk) rst = 1'b0;
        for (int i = 0; i < 40; i++) begin
            cnd = 1'b1; prd = (i % 2 == 0);
            upd_valid = 1'b1; upd_pc = 64'h4000; upd_taken = (i % 2 == 0);
            cycle("alternate");
        end
        ok_alt = 0;
        for (int i = 40; i < 48; i++) begin
            pend_pc = 64'h4000; #1;
            if (pknown && (ptaken == (i % 2 == 0))) ok_alt++;
            cnd = 1'b1; prd = (i % 2 == 0);
            upd_valid = 1'b1; upd_pc = 64'h4000; upd_taken = (i % 2 == 0);
            cycle("alternate, predicted");
        end
        check("an alternating branch is predicted right through the history", 64'(ok_alt), 64'd8);

        // random against the model
        m_reset(); rst = 1'b1; @(posedge clk); @(negedge clk) rst = 1'b0;
        for (int i = 0; i < 20000; i++) begin
            base_pc  = 64'h8000 + 64'(($urandom % 64) * 8);
            base1_pc = base_pc + 64'd8;
            pend_pc  = 64'h8000 + 64'(($urandom % 256) * 2);
            cnd = ($urandom % 3) == 0;  prd = $urandom % 2;
            restore = ($urandom % 23) == 0; rh64 = {$urandom, $urandom}; r_cond = $urandom % 2; r_pred = $urandom % 2;
            flush = ($urandom % 41) == 0;
            upd_valid = ($urandom % 2) == 0; upd_pc = 64'h8000 + 64'(($urandom % 256) * 2); upd_taken = $urandom % 2;
            cycle("random");
        end
        check("every output against the model, every cycle", 64'(errs), 64'd0);

        $display("");
        $display("qv_gshare_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_gshare_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
