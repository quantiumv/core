// SPDX-License-Identifier: MIT

/*
 * qv_tlb_tb -- standalone test for design/pipe/qv_tlb.sv.
 *
 * Directed cases pin the rules: the tag is compared only down to the
 * entry's level (gigapage: vpn2, megapage: vpn2:vpn1, page: all three), the
 * lowest-numbered matching entry wins, fills go round robin, a flush
 * invalidates everything but leaves the victim pointer where it was, a
 * flush beats a fill in the same cycle, and a TLB with one entry works.
 *
 * Then a randomized run of three sizes (4 as in the cores, 1 as in the
 * formal configuration, 3 so the victim pointer must wrap at a number that
 * is not a power of two) against a model written differently: plain arrays
 * and an integer victim index, the lookup a loop from the top down.
 */
module qv_tlb_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // shared stimulus
    logic        flush = 1'b0;
    logic [26:0] vpn = '0;
    logic        fill = 1'b0;
    logic [26:0] fvpn = '0;
    logic [1:0]  flevel = '0;
    logic [43:0] fppn = '0;
    logic        fr = 1'b0, fw = 1'b0, fx = 1'b0, fu = 1'b0, fd = 1'b0;

    // outputs of the three instances
    logic        hit4, hit1, hit3;
    logic [1:0]  lvl4, lvl1, lvl3;
    logic [43:0] ppn4, ppn1, ppn3;
    logic [4:0]  rwxud4, rwxud1, rwxud3;

    qv_tlb #(.ENTRIES(4)) d4 (.clk(clk), .rst(rst), .i_flush(flush), .i_vpn(vpn), .o_hit(hit4), .o_level(lvl4), .o_ppn(ppn4),
        .o_r(rwxud4[4]), .o_w(rwxud4[3]), .o_x(rwxud4[2]), .o_u(rwxud4[1]), .o_d(rwxud4[0]),
        .i_fill(fill), .i_fill_vpn(fvpn), .i_fill_level(flevel), .i_fill_ppn(fppn),
        .i_fill_r(fr), .i_fill_w(fw), .i_fill_x(fx), .i_fill_u(fu), .i_fill_d(fd));
    qv_tlb #(.ENTRIES(1)) d1 (.clk(clk), .rst(rst), .i_flush(flush), .i_vpn(vpn), .o_hit(hit1), .o_level(lvl1), .o_ppn(ppn1),
        .o_r(rwxud1[4]), .o_w(rwxud1[3]), .o_x(rwxud1[2]), .o_u(rwxud1[1]), .o_d(rwxud1[0]),
        .i_fill(fill), .i_fill_vpn(fvpn), .i_fill_level(flevel), .i_fill_ppn(fppn),
        .i_fill_r(fr), .i_fill_w(fw), .i_fill_x(fx), .i_fill_u(fu), .i_fill_d(fd));
    qv_tlb #(.ENTRIES(3)) d3 (.clk(clk), .rst(rst), .i_flush(flush), .i_vpn(vpn), .o_hit(hit3), .o_level(lvl3), .o_ppn(ppn3),
        .o_r(rwxud3[4]), .o_w(rwxud3[3]), .o_x(rwxud3[2]), .o_u(rwxud3[1]), .o_d(rwxud3[0]),
        .i_fill(fill), .i_fill_vpn(fvpn), .i_fill_level(flevel), .i_fill_ppn(fppn),
        .i_fill_r(fr), .i_fill_w(fw), .i_fill_x(fx), .i_fill_u(fu), .i_fill_d(fd));

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- the model: three of them, index 0 = 4 entries, 1 = 1 entry, 2 = 3 entries ----------------
    localparam int NMAX = 4;
    bit        [NMAX-1:0] mvalid [0:2];
    bit [1:0]             mlevel  [0:2][0:NMAX-1];
    bit [26:0]            mvpn    [0:2][0:NMAX-1];
    bit [43:0]            mppn    [0:2][0:NMAX-1];
    bit [4:0]             mperm   [0:2][0:NMAX-1];
    int                   mvictim [0:2];
    int                   mn      [0:2];

    task automatic m_init(input int mi, input int n);
        begin
            mn[mi] = n; mvictim[mi] = 0; mvalid[mi] = '0;
            for (int i = 0; i < NMAX; i++) begin
                mlevel[mi][i] = 0; mvpn[mi][i] = 0; mppn[mi][i] = 0; mperm[mi][i] = 0;
            end
        end
    endtask

    function automatic bit m_match(input bit [1:0] lv, input bit [26:0] tag, input bit [26:0] v);
        bit [26:0] diff;
        begin
            diff = tag ^ v;
            if (lv == 2'd2) return diff[26:18] == 0;
            if (lv == 2'd1) return diff[26:9] == 0;
            return diff == 0;
        end
    endfunction

    // lookup: the index of the lowest matching entry, or -1
    function automatic int m_find(input int mi, input bit [26:0] v);
        int found;
        begin
            found = -1;
            for (int i = mn[mi] - 1; i >= 0; i--) begin           // the lowest index is assigned last
                if (mvalid[mi][i] && m_match(mlevel[mi][i], mvpn[mi][i], v)) found = i;
            end
            return found;
        end
    endfunction

    task automatic m_clock(input int mi);
        begin
            if (flush) begin
                mvalid[mi] = '0;
            end else if (fill) begin
                mvalid[mi][mvictim[mi]] = 1'b1;
                mlevel[mi][mvictim[mi]] = flevel;
                mvpn[mi][mvictim[mi]]   = fvpn;
                mppn[mi][mvictim[mi]]   = fppn;
                mperm[mi][mvictim[mi]]  = {fr, fw, fx, fu, fd};
                mvictim[mi] = (mvictim[mi] + 1) % mn[mi];
            end
        end
    endtask

    int mismatches = 0;
    task automatic compare(input int mi, input logic hit, input logic [1:0] lvl, input logic [43:0] ppn, input logic [4:0] perm);
        int idx;
        begin
            idx = m_find(mi, vpn);
            if (hit !== (idx >= 0)) begin
                mismatches++;
                if (mismatches <= 10) $display("MISMATCH model %0d: hit dut=%b model=%b (vpn=%h)", mi, hit, idx >= 0, vpn);
            end else if (idx >= 0 && ({lvl, ppn, perm} !== {mlevel[mi][idx], mppn[mi][idx], mperm[mi][idx]})) begin
                mismatches++;
                if (mismatches <= 10) $display("MISMATCH model %0d: fields dut=%0d/%h/%b model=%0d/%h/%b (vpn=%h idx=%0d)",
                                               mi, lvl, ppn, perm, mlevel[mi][idx], mppn[mi][idx], mperm[mi][idx], vpn, idx);
            end
        end
    endtask

    task automatic step;
        begin
            #1;
            compare(0, hit4, lvl4, ppn4, rwxud4);
            compare(1, hit1, lvl1, ppn1, rwxud1);
            compare(2, hit3, lvl3, ppn3, rwxud3);
            @(posedge clk);
            m_clock(0); m_clock(1); m_clock(2);
            #1;
            flush = 1'b0; fill = 1'b0;
        end
    endtask

    task automatic do_fill(input logic [26:0] v, input logic [1:0] l, input logic [43:0] p, input logic [4:0] perm);
        begin
            fill = 1'b1; fvpn = v; flevel = l; fppn = p; {fr, fw, fx, fu, fd} = perm;
            step();
        end
    endtask
    task automatic do_flush;
        begin flush = 1'b1; step(); end
    endtask

    // pieces of a vpn: vpn2:vpn1:vpn0
    function automatic logic [26:0] mk(input logic [8:0] v2, input logic [8:0] v1, input logic [8:0] v0);
        return {v2, v1, v0};
    endfunction

    task automatic expect_hit4(input string name, input logic [26:0] v, input logic exp_hit);
        begin vpn = v; #1; check(name, b(hit4), b(exp_hit)); end
    endtask

    logic [26:0] base [0:5];
    int sweep_n = 0;
    task automatic random_ops(input int count);
        logic [31:0] r1, r2, r3;
        logic [26:0] v;
        begin
            for (int i = 0; i < 6; i++) begin r1 = $urandom; base[i] = {r1[8:0], r1[17:9], r1[26:18]}; end
            for (int i = 0; i < count; i++) begin
                r1 = $urandom; r2 = $urandom; r3 = $urandom;
                // an address near one of a few bases, so lookups hit and share partial tags
                v = base[r1[2:0] % 6];
                if (r1[5:3] == 3'd0) v[8:0]   = r2[8:0];
                if (r1[5:3] == 3'd1) v[17:9]  = r2[17:9];
                if (r1[5:3] == 3'd2) v[26:18] = r2[26:18];
                case (r1[9:6])
                    4'd0, 4'd1, 4'd2: begin     // fill
                        fill = 1'b1; fvpn = v; flevel = r2[19:18] % 3; fppn = {r3[31:0], r2[11:0]};
                        {fr, fw, fx, fu, fd} = r3[4:0];
                    end
                    4'd3: flush = (r3[2:0] == 3'd0);               // flush (rare)
                    4'd4: begin                                     // a flush together with a fill
                        flush = (r3[1:0] == 2'd0); fill = 1'b1; fvpn = v; flevel = r2[19:18] % 3; fppn = {r3[31:0], r2[11:0]};
                        {fr, fw, fx, fu, fd} = r3[8:4];
                    end
                    default: ;                                      // lookup only
                endcase
                vpn = (r1[10]) ? v : base[r1[13:11] % 6] ^ {18'b0, r2[26:18]};
                step();
                sweep_n++;
            end
        end
    endtask

    initial begin
        m_init(0, 4); m_init(1, 1); m_init(2, 3);
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(posedge clk); #1;

        // empty: miss
        expect_hit4("empty TLB misses", mk(9'h1, 9'h2, 9'h3), 1'b0);

        // a 4 KB page entry: matches only the exact vpn
        do_fill(mk(9'h1, 9'h2, 9'h3), 2'd0, 44'hABC, 5'b10110);
        expect_hit4("page entry: same vpn hits", mk(9'h1, 9'h2, 9'h3), 1'b1);
        check("page entry: level", {62'b0, lvl4}, 64'd0);
        check("page entry: ppn", {20'b0, ppn4}, 64'hABC);
        check("page entry: r w x u d", {59'b0, rwxud4}, 64'b10110);
        expect_hit4("page entry: other vpn0 misses", mk(9'h1, 9'h2, 9'h4), 1'b0);
        expect_hit4("page entry: other vpn1 misses", mk(9'h1, 9'h3, 9'h3), 1'b0);
        expect_hit4("page entry: other vpn2 misses", mk(9'h2, 9'h2, 9'h3), 1'b0);

        // a megapage entry: vpn0 is ignored
        do_fill(mk(9'h10, 9'h20, 9'h0), 2'd1, 44'h5000, 5'b11001);
        expect_hit4("megapage: any vpn0 hits", mk(9'h10, 9'h20, 9'h1F3), 1'b1);
        expect_hit4("megapage: other vpn1 misses", mk(9'h10, 9'h21, 9'h0), 1'b0);

        // a gigapage entry: vpn1 and vpn0 are ignored
        do_fill(mk(9'h30, 9'h0, 9'h0), 2'd2, 44'hA000, 5'b11111);
        expect_hit4("gigapage: any vpn1:vpn0 hits", mk(9'h30, 9'h1AA, 9'h155), 1'b1);
        expect_hit4("gigapage: other vpn2 misses", mk(9'h31, 9'h0, 9'h0), 1'b0);

        // the lowest index wins: a page inside the gigapage (slot 2), filled into slot 3
        do_fill(mk(9'h30, 9'h5, 9'h6), 2'd0, 44'h777, 5'b10000);
        expect_hit4("overlap: hits", mk(9'h30, 9'h5, 9'h6), 1'b1);
        check("overlap: the lower slot (the gigapage) wins", {62'b0, lvl4}, 64'd2);

        // round robin: the fifth fill replaces slot 0 (the first page entry)
        do_fill(mk(9'h77, 9'h7, 9'h7), 2'd0, 44'h111, 5'b00001);
        expect_hit4("fifth fill: slot 0 is gone", mk(9'h1, 9'h2, 9'h3), 1'b0);
        expect_hit4("fifth fill: it is in", mk(9'h77, 9'h7, 9'h7), 1'b1);
        expect_hit4("fifth fill: slot 1 is still there", mk(9'h10, 9'h20, 9'h1), 1'b1);
        do_fill(mk(9'h78, 9'h8, 9'h8), 2'd0, 44'h222, 5'b00010);        // slot 1
        expect_hit4("sixth fill: slot 1 is gone", mk(9'h10, 9'h20, 9'h1), 1'b0);

        // a flush clears everything but leaves the victim pointer (now at slot 2)
        do_flush();
        expect_hit4("after a flush: miss", mk(9'h77, 9'h7, 9'h7), 1'b0);
        expect_hit4("after a flush: miss (gigapage)", mk(9'h30, 9'h0, 9'h0), 1'b0);
        do_fill(mk(9'h41, 9'h1, 9'h1), 2'd0, 44'h1, 5'b00100);          // slot 2, not slot 0
        do_fill(mk(9'h42, 9'h2, 9'h2), 2'd0, 44'h2, 5'b00100);          // slot 3
        do_fill(mk(9'h43, 9'h3, 9'h3), 2'd0, 44'h3, 5'b00100);          // slot 0
        do_fill(mk(9'h44, 9'h4, 9'h4), 2'd0, 44'h4, 5'b00100);          // slot 1
        do_fill(mk(9'h45, 9'h5, 9'h5), 2'd0, 44'h5, 5'b00100);          // slot 2 again: the first of these is gone
        expect_hit4("victim pointer survived the flush: the first fill is replaced after four more", mk(9'h41, 9'h1, 9'h1), 1'b0);
        expect_hit4("... and the next one is still there", mk(9'h42, 9'h2, 9'h2), 1'b1);

        // a flush beats a fill in the same cycle (and the victim pointer does not move)
        flush = 1'b1; fill = 1'b1; fvpn = mk(9'h50, 9'h0, 9'h0); flevel = 2'd0; fppn = 44'h50; {fr, fw, fx, fu, fd} = 5'b10000;
        step();
        expect_hit4("flush + fill: nothing is filled", mk(9'h50, 9'h0, 9'h0), 1'b0);
        expect_hit4("flush + fill: the flush happened", mk(9'h42, 9'h2, 9'h2), 1'b0);

        // the one-entry TLB: every fill replaces the entry
        do_fill(mk(9'h60, 9'h0, 9'h0), 2'd0, 44'h60, 5'b10000);
        vpn = mk(9'h60, 9'h0, 9'h0); #1; check("one entry: hit", b(hit1), 64'd1);
        do_fill(mk(9'h61, 9'h0, 9'h0), 2'd0, 44'h61, 5'b10000);
        vpn = mk(9'h60, 9'h0, 9'h0); #1; check("one entry: the old one is gone", b(hit1), 64'd0);
        vpn = mk(9'h61, 9'h0, 9'h0); #1; check("one entry: the new one is in", b(hit1), 64'd1);

        // the three-entry TLB wraps at 3
        do_flush();
        do_fill(mk(9'h1, 9'h0, 9'h0), 2'd0, 44'h1, 5'b0);
        do_fill(mk(9'h2, 9'h0, 9'h0), 2'd0, 44'h2, 5'b0);
        do_fill(mk(9'h3, 9'h0, 9'h0), 2'd0, 44'h3, 5'b0);
        do_fill(mk(9'h4, 9'h0, 9'h0), 2'd0, 44'h4, 5'b0);               // slot 0 again
        vpn = mk(9'h1, 9'h0, 9'h0); #1; check("three entries: wrapped, slot 0 replaced", b(hit3), 64'd0);
        vpn = mk(9'h2, 9'h0, 9'h0); #1; check("three entries: slot 1 still there", b(hit3), 64'd1);
        vpn = mk(9'h4, 9'h0, 9'h0); #1; check("three entries: the fourth fill is in", b(hit3), 64'd1);

        // a reset empties the TLB and puts the victim pointer back at slot 0
        do_fill(mk(9'h7, 9'h0, 9'h0), 2'd0, 44'h7, 5'b0);
        do_fill(mk(9'h8, 9'h0, 9'h0), 2'd0, 44'h8, 5'b0);
        rst = 1'b1; @(posedge clk); #1; @(posedge clk); #1; rst = 1'b0;
        m_init(0, 4); m_init(1, 1); m_init(2, 3);
        vpn = mk(9'h7, 9'h0, 9'h0); #1;
        check("reset: the 4-entry TLB is empty", b(hit4), 64'd0);
        check("reset: the 1-entry TLB is empty", b(hit1), 64'd0);
        check("reset: the 3-entry TLB is empty", b(hit3), 64'd0);
        vpn = mk(9'h8, 9'h0, 9'h0); #1;
        check("reset: the second old entry is gone too", b(hit4) + b(hit3), 64'd0);
        do_fill(mk(9'h11, 9'h0, 9'h0), 2'd0, 44'h11, 5'b0);                // slot 0
        do_fill(mk(9'h12, 9'h0, 9'h0), 2'd0, 44'h12, 5'b0);                // slot 1
        do_fill(mk(9'h13, 9'h0, 9'h0), 2'd0, 44'h13, 5'b0);                // slot 2
        do_fill(mk(9'h14, 9'h0, 9'h0), 2'd0, 44'h14, 5'b0);                // slot 3
        do_fill(mk(9'h15, 9'h0, 9'h0), 2'd0, 44'h15, 5'b0);                // slot 0 again: the victim pointer restarted at 0
        vpn = mk(9'h11, 9'h0, 9'h0); #1; check("reset: the victim pointer restarted at slot 0", b(hit4), 64'd0);
        vpn = mk(9'h12, 9'h0, 9'h0); #1; check("reset: ... and slot 1 is still there", b(hit4), 64'd1);

        check("directed cases: the three DUTs agreed with their models throughout", 64'(mismatches), 64'd0);

        // ---------------- randomized ----------------
        mismatches = 0;
        random_ops(60000);
        check("random run: no mismatches against the model (4, 1 and 3 entries)", 64'(mismatches), 64'd0);

        $display("");
        $display("qv_tlb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_tlb_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT: qv_tlb_tb");
        $finish;
    end
endmodule
