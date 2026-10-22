// SPDX-License-Identifier: MIT

/*
 * qv_xlate_tb -- standalone test for design/pipe/qv_xlate.sv: the TLB, the
 * check of a hit and the handshake with the shared walker, two clients (data
 * and fetch) on one qv_ptw, over the page-table environment of
 * testbench/qv_pt_env.svh.
 *
 * Directed: translation off answers in the same cycle with no walk; a miss
 * walks (three reads), fills, and the same request then hits in the cycle it
 * is presented with no read at all; a hit is judged again against the live
 * context (a stale entry with D clear faults a store, a changed SUM or MXR
 * turns a hit into a fault, a non-canonical address in a cached page faults);
 * a fault is answered until the request goes away and is never cached (the
 * next request walks again); an access fault likewise; a megapage entry
 * serves other addresses in the same megapage; the data and fetch TLBs are
 * separate; the TLB has four entries and fills round robin; a flush empties
 * it; and a cancel or a flush at any cycle of a walk leaves nothing behind
 * (including in the very cycle the walker reports the leaf: no fill).
 *
 * Then a random sweep of requests of both kinds in random contexts, flushes,
 * cancels and memory changes (always with a flush), every answered request
 * compared with the model's walk of the same address.
 */
module qv_xlate_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- the DUTs: a walker and two translators ----------------
    wire  [31:0] bus_addr;
    wire         bus_cyc;
    logic [63:0] bus_dat = '0;
    logic        bus_ack = 1'b0, bus_err = 1'b0;
    logic        lsu_busy = 1'b0;
    wire         beat;
    logic [63:0] pmpcfg0 = '0, pmpaddr0 = '0, pmpaddr1 = '0, pmpaddr2 = '0, pmpaddr3 = '0;

    logic [43:0] satp_root = 44'd2;

    // data client
    logic        xd_req = 1'b0, xd_wr = 1'b0, xd_active = 1'b1, xd_sum = 1'b0, xd_mxr = 1'b0, xd_cancel = 1'b0, xd_flush = 1'b0;
    logic [63:0] xd_va = '0;
    logic [1:0]  xd_priv = 2'b01;
    wire         xd_done, xd_pf, xd_af, xd_wreq, xd_wcancel;
    wire  [43:0] xd_ppn;
    // fetch client
    logic        xf_req = 1'b0, xf_active = 1'b1, xf_cancel = 1'b0, xf_flush = 1'b0;
    logic [63:0] xf_va = '0;
    logic [1:0]  xf_priv = 2'b01;
    wire         xf_done, xf_pf, xf_af, xf_wreq, xf_wcancel;
    wire  [43:0] xf_ppn;
    // the walker's results
    wire         w_d_done, w_f_done, w_ok, w_pf, w_af, w_r, w_w, w_x, w_u, w_d;
    wire  [26:0] w_vpn;
    wire  [1:0]  w_level;
    wire  [43:0] w_ppn;

    qv_ptw ptw0 (
        .clk(clk), .rst(rst),
        .o_bus_addr(bus_addr), .o_bus_cyc(bus_cyc), .i_bus_dat(bus_dat), .i_bus_ack(bus_ack), .i_bus_err(bus_err),
        .i_lsu_busy(lsu_busy), .o_beat(beat),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1), .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .i_d_req(xd_wreq), .i_d_va(xd_va), .i_d_wr(xd_wr), .i_d_priv(xd_priv), .i_d_sum(xd_sum), .i_d_mxr(xd_mxr),
        .i_d_root(satp_root), .i_d_cancel(xd_wcancel), .o_d_done(w_d_done),
        .i_f_req(xf_wreq), .i_f_va(xf_va), .i_f_priv(xf_priv), .i_f_root(satp_root), .i_f_cancel(xf_wcancel), .o_f_done(w_f_done),
        .o_res_ok(w_ok), .o_res_pf(w_pf), .o_res_af(w_af), .o_res_vpn(w_vpn), .o_res_level(w_level), .o_res_ppn(w_ppn),
        .o_res_r(w_r), .o_res_w(w_w), .o_res_x(w_x), .o_res_u(w_u), .o_res_d(w_d)
    );

    qv_xlate #(.TLB_ENTRIES(4)) xd (
        .clk(clk), .rst(rst),
        .i_req(xd_req), .i_va(xd_va), .i_is_mem(1'b1), .i_wr(xd_wr), .i_active(xd_active), .i_priv(xd_priv),
        .i_sum(xd_sum), .i_mxr(xd_mxr), .i_cancel(xd_cancel), .i_flush_tlb(xd_flush),
        .o_done(xd_done), .o_pf(xd_pf), .o_af(xd_af), .o_ppn(xd_ppn),
        .o_w_req(xd_wreq), .o_w_cancel(xd_wcancel),
        .i_w_done(w_d_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn), .i_w_level(w_level), .i_w_ppn(w_ppn),
        .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u), .i_w_d(w_d)
    );
    qv_xlate #(.TLB_ENTRIES(4)) xf (
        .clk(clk), .rst(rst),
        .i_req(xf_req), .i_va(xf_va), .i_is_mem(1'b0), .i_wr(1'b0), .i_active(xf_active), .i_priv(xf_priv),
        .i_sum(1'b0), .i_mxr(1'b0), .i_cancel(xf_cancel), .i_flush_tlb(xf_flush),
        .o_done(xf_done), .o_pf(xf_pf), .o_af(xf_af), .o_ppn(xf_ppn),
        .o_w_req(xf_wreq), .o_w_cancel(xf_wcancel),
        .i_w_done(w_f_done), .i_w_ok(w_ok), .i_w_pf(w_pf), .i_w_af(w_af), .i_w_vpn(w_vpn), .i_w_level(w_level), .i_w_ppn(w_ppn),
        .i_w_r(w_r), .i_w_w(w_w), .i_w_x(w_x), .i_w_u(w_u), .i_w_d(w_d)
    );

    // the walker only reads
    wire         bus_we = 1'b0;
    wire  [7:0]  bus_sel = 8'hFF;
    wire  [63:0] bus_dato = 64'b0;
    `include "qv_pt_env.svh"

    // ---------------- driving ----------------
    // the PA page the model says an ok walk gives (the leaf's own number, with the VA's low segments for a superpage)
    function automatic logic [43:0] resolved_ppn(input logic [43:0] raw, input logic [1:0] level, input logic [63:0] va);
        if (level == 2'd0) return raw;
        if (level == 2'd1) return {raw[43:9], va[20:12]};
        return {raw[43:18], va[29:21], va[20:12]};
    endfunction

    // an answered request: what came back and how many cycles it took
    logic        r_done, r_pf, r_af;
    logic [43:0] r_ppn;
    int          r_cycles, r_beats;

    // present a data request and wait for the answer, then drop it. Returns with r_*.
    task automatic ask_d(input logic [63:0] va, input logic wr, input logic [1:0] priv, input logic sum, input logic mxr,
                         input int timeout);
        begin
            xd_va = va; xd_wr = wr; xd_priv = priv; xd_sum = sum; xd_mxr = mxr;
            beat_log_n = 0;
            xd_req = 1'b1;
            r_done = 1'b0; r_cycles = 0;
            #1;
            while (!xd_done && r_cycles < timeout) begin
                @(posedge clk); #1;
                r_cycles++;
            end
            r_done = xd_done; r_pf = xd_pf; r_af = xd_af; r_ppn = xd_ppn;
            // the user consumes the answer at the next edge with its request still up (it registers the answer and drops the
            // request then): a translator that asks the walker for something it has already answered shows by the reads
            // that follow
            @(posedge clk); #1;
            xd_req = 1'b0;
            repeat (5) begin @(posedge clk); #1; end
            r_beats = beat_log_n;
        end
    endtask

    task automatic ask_f(input logic [63:0] va, input logic [1:0] priv, input int timeout);
        begin
            xf_va = va; xf_priv = priv;
            beat_log_n = 0;
            xf_req = 1'b1;
            r_done = 1'b0; r_cycles = 0;
            #1;
            while (!xf_done && r_cycles < timeout) begin
                @(posedge clk); #1;
                r_cycles++;
            end
            r_done = xf_done; r_pf = xf_pf; r_af = xf_af; r_ppn = xf_ppn;
            @(posedge clk); #1;
            xf_req = 1'b0;
            repeat (5) begin @(posedge clk); #1; end
            r_beats = beat_log_n;
        end
    endtask

    task automatic flush_all;
        begin xd_flush = 1'b1; xf_flush = 1'b1; @(posedge clk); #1; xd_flush = 1'b0; xf_flush = 1'b0; end
    endtask

    // compare the last answer with the model's walk of the same request
    task automatic expect_model(input string name, input logic [63:0] va, input logic is_mem, input logic wr,
                                input logic [1:0] priv, input logic sum, input logic mxr);
        begin
            model_walk(va, is_mem, wr, priv, sum, mxr, satp_root);
            check({name, ": answered"}, b(r_done), 64'd1);
            check({name, ": page fault"}, b(r_pf), b(m_kind == 1));
            check({name, ": access fault"}, b(r_af), b(m_kind == 2));
            if (m_kind == 0)
                check({name, ": PA page"}, {20'b0, r_ppn}, {20'b0, resolved_ppn(m_ppn, m_level, va)});
        end
    endtask

    // a standard address: vpn2 = 1, vpn1 = 2, vpn0 = page, offset
    function automatic logic [63:0] va_pg(input logic [8:0] pg);
        return va_of(9'd1, 9'd2, pg, 12'h5A8);
    endfunction

    // ---------------- the cancel / flush sweeps ----------------
    int sweep_viol_refill = 0, sweep_runs = 0, sweep_early = 0;
    // request, then at cycle k kill it -- kind 0: cancel, 1: SFENCE.VMA flush, 2: just drop the request, no cancel or
    // flush -- with the request dropped in the same cycle or (hold) still up in it; then ask again and require a full
    // walk: nothing was filled. (The cycle the walker reports its leaf is one of the k, and with the request held it is
    // the one where a fill would otherwise land.)
    task automatic kill_run(input int k, input int kind, input bit hold, input bit use_f);
        bit finished;
        begin
            std_map(use_f ? (V|R|X|A) : (V|R|W|A|D));
            set_pmp();
            flush_all();
            beat_log_n = 0;
            finished = 1'b0;
            if (use_f) begin xf_va = va_pg(9'd3); xf_priv = 2'b01; xf_req = 1'b1; end
            else begin xd_va = va_pg(9'd3); xd_wr = 1'b0; xd_priv = 2'b01; xd_sum = 1'b0; xd_mxr = 1'b0; xd_req = 1'b1; end
            #1;
            for (int i = 0; i < k && !finished; i++) begin
                @(posedge clk); #1;
                if (use_f ? xf_done : xd_done) finished = 1'b1;
            end
            sweep_runs++;
            if (finished) begin
                sweep_early++;
                if (use_f) xf_req = 1'b0; else xd_req = 1'b0;
                @(posedge clk); #1;
            end else begin
                if (kind == 1) begin xd_flush = 1'b1; xf_flush = 1'b1; end
                else if (kind == 0) begin if (use_f) xf_cancel = 1'b1; else xd_cancel = 1'b1; end
                if (!hold) begin if (use_f) xf_req = 1'b0; else xd_req = 1'b0; end
                @(posedge clk); #1;
                xd_flush = 1'b0; xf_flush = 1'b0; xd_cancel = 1'b0; xf_cancel = 1'b0;
                xd_req = 1'b0; xf_req = 1'b0;                      // (a held request goes after the kill cycle)
                repeat (40) begin @(posedge clk); #1; end
                // the walker is idle, nothing was filled: the same request walks again from the top
                if (use_f) ask_f(va_pg(9'd3), 2'b01, 200); else ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 200);
                if (!r_done || r_pf || r_af || r_beats != 3) begin
                    sweep_viol_refill++;
                    $display("KILL RUN k=%0d kind=%0d hold=%b f=%b: done=%b pf=%b af=%b beats=%0d (expected a full walk, ok)",
                             k, kind, hold, use_f, r_done, r_pf, r_af, r_beats);
                end
            end
        end
    endtask

    // ---------------- the random sweep ----------------
    int sw_mismatch = 0, sw_checked = 0, sw_ok = 0, sw_pf = 0, sw_af = 0, sw_hits = 0, sw_cancels = 0;
    task automatic random_map2;
        logic [31:0] r;
        logic [63:0] pte;
        bit          tidy;
        begin
            // mostly a tidy tree (every pointer there, most leaves fine) so that requests succeed and the TLB hits;
            // now and then a messy one (missing and malformed entries) for the faults
            tidy = ($urandom % 5) != 0;
            clear_mem();
            if (tidy) begin
                for (int i = 0; i < 8; i++) begin
                    put(ROOT, i, pte_of(L1T, V));
                    put(L1T, i, pte_of(L0T, V));
                    r = $urandom;
                    case (r[3:0])
                        0, 1, 2, 3, 4, 5, 6, 7, 8, 9: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|X|A|D);
                        10: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|A|D|U);
                        11: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|A);
                        12: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|X|A);
                        13: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|A);
                        14: pte = 64'd0;
                        default: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, r[15:8] | V);
                    endcase
                    put(L0T, i, pte);
                end
                return;
            end
            for (int i = 0; i < 8; i++) begin
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: pte = pte_of(L1T, V);
                    12: pte = pte_of({r[25:20], 18'b0}, r[7:0] | V | R | A);
                    13: pte = {r, $urandom};
                    default: pte = 64'd0;
                endcase
                put(ROOT, i, pte);
            end
            for (int i = 0; i < 8; i++) begin
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: pte = pte_of(L0T, V);
                    12: pte = pte_of({r[25:20], 18'b0} | {r[31:26], 9'b0}, r[7:0] | V | R | A);
                    13: pte = {r, $urandom};
                    default: pte = 64'd0;
                endcase
                put(L1T, i, pte);
            end
            for (int i = 0; i < 8; i++) begin
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10: begin
                        case (r[3:0])
                            0, 1, 2, 3, 4, 5: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|X|A|D);
                            6:       pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|A|D|U);
                            7:       pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|A);
                            8:       pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|X|A);
                            9:       pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|W|A);
                            10:      pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, V|R|X|A);
                            default: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, r[15:8] | V);
                        endcase
                    end
                    11: pte = pte_of(L0T, V);
                    12: pte = {r, $urandom};
                    default: pte = 64'd0;
                endcase
                put(L0T, i, pte);
            end
        end
    endtask

    logic [63:0] hot [0:5];
    task automatic new_hot_set;
        logic [31:0] r;
        begin
            for (int i = 0; i < 6; i++) begin
                r = $urandom;
                hot[i] = va_of({6'b0, r[2:0]}, {6'b0, r[5:3]}, {6'b0, r[8:6]}, 12'h0);
            end
        end
    endtask

    task automatic random_op;
        logic [31:0] r1, r2, r3;
        logic [63:0] va;
        logic [1:0]  priv_;
        logic        wr_, sum_, mxr_;
        begin
            r1 = $urandom; r2 = $urandom; r3 = $urandom;
            va = {r2, r3};
            va[38:30] = {6'b0, r1[2:0]}; va[29:21] = {6'b0, r1[5:3]}; va[20:12] = {6'b0, r1[8:6]};
            va[63:39] = va[38] ? 25'h1FFFFFF : 25'h0;
            if (r3[14:12] < 5) begin                                        // mostly a few hot pages, so the TLB hits
                va = hot[r3[17:15] % 6];
                va[11:0] = r2[11:0];
            end
            if (r1[12:9] == 0) va[63:39] = r2[31:7];                       // a non-canonical address now and then
            wr_ = (r3[7:5] < 3); sum_ = r1[19]; mxr_ = r1[20];
            priv_ = (r3[10:8] < 6) ? 2'b01 : (r3[10:8] < 7) ? 2'b00 : r1[22:21];
            lat_min = 0; lat_max = r2[3:2];
            case (r1[31:28])
                0: begin                                                    // a flush
                    flush_all();
                end
                1: begin                                                    // new memory, always with a flush
                    random_map2();
                    new_hot_set();
                    flush_all();
                end
                2: begin                                                    // a request cancelled part-way: no answer expected
                    if (r1[27]) begin
                        xf_va = va; xf_priv = priv_; xf_req = 1'b1;
                        repeat (r3[14:11]) begin @(posedge clk); #1; end
                        xf_cancel = 1'b1; xf_req = 1'b0; @(posedge clk); #1; xf_cancel = 1'b0;
                    end else begin
                        xd_va = va; xd_wr = wr_; xd_priv = priv_; xd_sum = sum_; xd_mxr = mxr_; xd_req = 1'b1;
                        repeat (r3[14:11]) begin @(posedge clk); #1; end
                        xd_cancel = 1'b1; xd_req = 1'b0; @(posedge clk); #1; xd_cancel = 1'b0;
                    end
                    repeat (30) begin @(posedge clk); #1; end
                    sw_cancels++;
                end
                3: begin                                                    // a walk with an error or a denied page on it: flushed around
                    flush_all();
                    err_addr = {(r1[24] ? L1T : (r1[25] ? L0T : ROOT)), 12'b0} + {44'd0, r3[2:0], 3'b000};
                    err_with_ack = r1[26];
                    if (r1[27]) begin err_addr = '1; deny_ppn = (r3[3] ? L1T : (r3[4] ? L0T : ROOT)); end
                    set_pmp();
                    if (r1[23]) begin
                        ask_f(va, priv_, 300);
                        expect_model("error/denied fetch", va, 1'b0, 1'b0, priv_, 1'b0, 1'b0);
                    end else begin
                        ask_d(va, wr_, priv_, sum_, mxr_, 300);
                        expect_model("error/denied data", va, 1'b1, wr_, priv_, sum_, mxr_);
                    end
                    err_addr = '1; deny_ppn = '1; set_pmp();
                    flush_all();
                    sw_checked++;
                    if (r_pf) sw_pf++;
                    if (r_af) sw_af++;
                    if (!r_pf && !r_af) sw_ok++;
                end
                default: begin                                              // an ordinary request, answered, compared
                    if (r1[23]) begin
                        ask_f(va, priv_, 300);
                        expect_model("random fetch", va, 1'b0, 1'b0, priv_, 1'b0, 1'b0);
                    end else begin
                        ask_d(va, wr_, priv_, sum_, mxr_, 300);
                        expect_model("random data", va, 1'b1, wr_, priv_, sum_, mxr_);
                    end
                    sw_checked++;
                    if (r_cycles == 0 && !r_pf && !r_af && r_beats == 0) sw_hits++;
                    if (!r_pf && !r_af) sw_ok++;
                    if (r_pf) sw_pf++;
                    if (r_af) sw_af++;
                end
            endcase
        end
    endtask

    initial begin
        clear_mem();
        set_pmp();
        repeat (4) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk); #1;
        lat_min = 0; lat_max = 1;

        // ---------------- translation off ----------------
        std_map(V|R|W|A|D);
        xd_active = 1'b0;
        ask_d(64'h0000_0000_1234_5678, 1'b0, 2'b11, 1'b0, 1'b0, 20);
        check("inactive: answered in the cycle it is presented", {32'b0, r_cycles[31:0]}, 64'd0);
        check("inactive: no fault", b(r_pf) + b(r_af), 64'd0);
        check("inactive: identity page number", {20'b0, r_ppn}, 64'h12345);
        check("inactive: no walk", 64'(r_beats), 64'd0);
        xd_active = 1'b1;

        // ---------------- a miss walks and fills; the same request then hits ----------------
        std_map(V|R|W|A|D);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("miss: answered", b(r_done), 64'd1);
        check("miss: it took cycles", b(r_cycles > 5), 64'd1);
        check("miss: three PTE reads", 64'(r_beats), 64'd3);
        check("miss: PA page is the leaf's", {20'b0, r_ppn}, 64'h12345);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("hit: answered in the cycle it is presented", {32'b0, r_cycles[31:0]}, 64'd0);
        check("hit: no PTE read", 64'(r_beats), 64'd0);
        check("hit: PA page is the same", {20'b0, r_ppn}, 64'h12345);
        ask_d(va_pg(9'd3) + 64'h10, 1'b1, 2'b01, 1'b0, 1'b0, 100);
        check("hit by another address in the page, a store to a page with D set: ok, no read", 64'(r_beats) + b(r_pf) + b(r_af), 64'd0);

        // ---------------- a hit is judged again ----------------
        // D clear: a load fills, a store then faults on the hit (nothing walked), and stays faulting until a flush
        std_map(V|R|W|A);
        flush_all();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("D clear: the load fills", b(r_done) + 64'(r_beats), 64'd4);
        ask_d(va_pg(9'd3), 1'b1, 2'b01, 1'b0, 1'b0, 100);
        check("D clear: the store faults on the hit", b(r_pf) + 64'(r_beats) * 2 + 64'(r_cycles) * 4, 64'd1);
        put(L0T, 3, pte_of(44'h12345, V|R|W|A|D));
        ask_d(va_pg(9'd3), 1'b1, 2'b01, 1'b0, 1'b0, 100);
        check("D set in memory, no flush: the stale entry still faults the store", b(r_pf) + 64'(r_beats), 64'd1);
        flush_all();
        ask_d(va_pg(9'd3), 1'b1, 2'b01, 1'b0, 1'b0, 100);
        check("after the flush: the store walks and succeeds", b(r_done) + b(!r_pf) + b(!r_af) + 64'(r_beats), 64'd6);

        // SUM: a U page, loaded by S with SUM, then without
        std_map(V|R|W|U|A|D);
        flush_all();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b1, 1'b0, 100);
        check("SUM=1: S loads a U page", b(!r_pf) + b(!r_af) + b(r_done), 64'd3);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("SUM=0 on the cached entry: page fault, no read", b(r_pf) + 64'(r_beats) * 2, 64'd1);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b1, 1'b0, 100);
        check("SUM=1 again: hit, ok", b(!r_pf) + 64'(r_beats) * 2 + 64'(r_cycles) * 4, 64'd1);
        // MXR: an execute-only page
        std_map(V|X|A);
        flush_all();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b1, 100);
        check("MXR=1: S loads an execute-only page", b(!r_pf) + b(r_done), 64'd2);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("MXR=0 on the cached entry: page fault, no read", b(r_pf) + 64'(r_beats) * 2, 64'd1);
        // the privilege changes under a cached entry: U on a non-U page
        std_map(V|R|W|A|D);
        flush_all();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        ask_d(va_pg(9'd3), 1'b0, 2'b00, 1'b0, 1'b0, 100);
        check("S fills, U asks: page fault on the hit", b(r_pf) + 64'(r_beats) * 2, 64'd1);
        // a non-canonical address in a cached page (same VA[38:12]) faults on the hit
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        ask_d(va_pg(9'd3) | (64'd1 << 40), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("non-canonical address in a cached page: page fault, no read", b(r_pf) + 64'(r_beats) * 2, 64'd1);

        // ---------------- faults are answered while the request stays, and are not cached ----------------
        std_map(V|R|W|A|D);
        put(L0T, 3, 64'd0);
        flush_all();
        xd_va = va_pg(9'd3); xd_wr = 1'b0; xd_priv = 2'b01; xd_sum = 1'b0; xd_mxr = 1'b0;
        beat_log_n = 0; xd_req = 1'b1; r_cycles = 0; #1;
        while (!xd_done && r_cycles < 100) begin @(posedge clk); #1; r_cycles++; end
        check("invalid leaf: page fault answered", b(xd_done) + b(xd_pf) + b(!xd_af), 64'd3);
        check("invalid leaf: three reads", 64'(beat_log_n), 64'd3);
        repeat (6) begin @(posedge clk); #1; end
        check("... still answered with the same fault 6 cycles later", b(xd_done) + b(xd_pf), 64'd2);
        check("... and no further read", 64'(beat_log_n), 64'd3);
        xd_req = 1'b0; @(posedge clk); #1;
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("a new request after the fault walks again (faults are never cached)", 64'(r_beats) * 4 + b(r_pf), 64'd13);
        // an access fault: a bus error on the level-1 read
        std_map(V|R|W|A|D);
        flush_all();
        err_addr = 56'h3010; err_with_ack = 1'b1;
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("bus error: access fault", b(r_af) + b(!r_pf) + b(r_done), 64'd3);
        err_addr = '1;
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("the error is gone and nothing was cached: the walk succeeds", b(!r_af) + b(!r_pf) + 64'(r_beats), 64'd5);
        // a PMP-denied table page
        flush_all();
        deny_ppn = L0T; set_pmp();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("PMP-denied level-0 table: access fault, two reads", b(r_af) + 64'(r_beats) * 2, 64'd5);
        deny_ppn = '1; set_pmp(); flush_all();

        // ---------------- superpages ----------------
        std_map(V|R|W|A|D);
        put(L1T, 2, pte_of({26'h77, 9'h5, 9'h0}, V|R|W|A|D));
        flush_all();
        ask_d(va_of(9'd1, 9'd2, 9'd7, 12'h100), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("megapage: two reads", 64'(r_beats) + b(r_done), 64'd3);
        check("megapage: PA page = ppn2:ppn1 from the PTE, vpn0 from the address", {20'b0, r_ppn}, {20'b0, 26'h77, 9'h5, 9'd7});
        ask_d(va_of(9'd1, 9'd2, 9'd200, 12'h8), 1'b1, 2'b01, 1'b0, 1'b0, 100);
        check("megapage: another vpn0 hits with no read", 64'(r_beats) + 64'(r_cycles), 64'd0);
        check("megapage: and gets its own vpn0", {20'b0, r_ppn}, {20'b0, 26'h77, 9'h5, 9'd200});

        // ---------------- the data and fetch TLBs are separate ----------------
        std_map(V|R|W|X|A|D);
        flush_all();
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        ask_f(va_pg(9'd3), 2'b01, 100);
        check("the fetch side does not hit on a data fill: it walks", 64'(r_beats), 64'd3);
        ask_f(va_pg(9'd3), 2'b01, 100);
        check("the fetch side then hits", 64'(r_beats) + 64'(r_cycles), 64'd0);

        // ---------------- capacity and round robin ----------------
        std_map(V|R|W|A|D);
        for (int pg = 0; pg < 8; pg++) put(L0T, pg, pte_of(44'h100 + pg, V|R|W|A|D));
        flush_all();
        for (int pg = 0; pg < 5; pg++) ask_d(va_pg(pg[8:0]), 1'b0, 2'b01, 1'b0, 1'b0, 100);   // fills 0,1,2,3 then 4 over 0
        ask_d(va_pg(9'd0), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("five pages in four entries: the first was replaced (walks again)", 64'(r_beats), 64'd3);
        ask_d(va_pg(9'd3), 1'b0, 2'b01, 1'b0, 1'b0, 100);
        check("... the fourth is still there", 64'(r_beats), 64'd0);

        // ---------------- identity again after fills ----------------
        xd_active = 1'b0;
        ask_d(va_pg(9'd3), 1'b1, 2'b01, 1'b0, 1'b0, 20);
        check("translation turned off: identity, no fault, no read", 64'(r_beats) + b(r_pf) + b(r_af) + b(!r_done), 64'd0);
        xd_active = 1'b1;

        // ---------------- a cancelled walk goes on in the walker; nothing of it reaches the next request ----------------
        // A (an invalid leaf: the walk ends in a page fault at its third read) is cancelled in a cycle where its request
        // stays up, and B (a good page) is presented in the very next cycle, as the fetch unit does after a redirect. The
        // walker finishes A's reads and drops the result; B gets a walk of its own and its own answer. For the later
        // cancels A's fault has been found already and is being answered: the cancel must clear it.
        for (int cl = 0; cl < 2; cl++)
            for (int c = 1; c < 30; c++) begin : cancel_next
                std_map(V|R|W|X|A|D);
                put(L0T, 4, 64'd0);
                lat_min = 2; lat_max = 3;
                flush_all();
                repeat (40) begin @(posedge clk); #1; end
                beat_log_n = 0;
                if (cl == 0) begin xd_va = va_pg(9'd4); xd_wr = 1'b0; xd_priv = 2'b01; xd_sum = 1'b0; xd_mxr = 1'b0; xd_req = 1'b1; end
                else         begin xf_va = va_pg(9'd4); xf_priv = 2'b01; xf_req = 1'b1; end
                repeat (c) begin @(posedge clk); #1; end
                if (cl == 0) xd_cancel = 1'b1; else xf_cancel = 1'b1;
                @(posedge clk); #1;
                xd_cancel = 1'b0; xf_cancel = 1'b0;
                if (cl == 0) xd_va = va_pg(9'd3); else xf_va = va_pg(9'd3);
                r_cycles = 0; #1;
                while (!(cl == 0 ? xd_done : xf_done) && r_cycles < 300) begin @(posedge clk); #1; r_cycles++; end
                if (cl == 0) begin r_done = xd_done; r_pf = xd_pf; r_af = xd_af; r_ppn = xd_ppn; end
                else         begin r_done = xf_done; r_pf = xf_pf; r_af = xf_af; r_ppn = xf_ppn; end
                check($sformatf("%s, A cancelled after %0d cycles, B at once: B is answered", cl == 0 ? "D" : "F", c), b(r_done), 64'd1);
                check($sformatf("%s, A cancelled after %0d cycles, B at once: no fault of A's", cl == 0 ? "D" : "F", c), b(r_pf) + b(r_af), 64'd0);
                check($sformatf("%s, A cancelled after %0d cycles, B at once: B's own page", cl == 0 ? "D" : "F", c), {20'b0, r_ppn}, 64'h12345);
                xd_req = 1'b0; xf_req = 1'b0;
                repeat (6) begin @(posedge clk); #1; end
            end
        // a remembered fault goes with a flush as well, request up or not
        std_map(V|R|W|X|A|D);
        put(L0T, 4, 64'd0);
        lat_min = 0; lat_max = 1;
        flush_all();
        xd_va = va_pg(9'd4); xd_wr = 1'b0; xd_priv = 2'b01; xd_sum = 1'b0; xd_mxr = 1'b0; xd_req = 1'b1;
        r_cycles = 0; #1;
        while (!xd_done && r_cycles < 100) begin @(posedge clk); #1; r_cycles++; end
        check("A: the page fault is answered", b(xd_done) + b(xd_pf), 64'd2);
        repeat (3) begin @(posedge clk); #1; end
        xd_flush = 1'b1; xf_flush = 1'b1; @(posedge clk); #1; xd_flush = 1'b0; xf_flush = 1'b0;
        xd_va = va_pg(9'd3);
        r_cycles = 0; #1;
        while (!xd_done && r_cycles < 100) begin @(posedge clk); #1; r_cycles++; end
        check("a flush clears the remembered fault: B is answered, ok", b(xd_done) + b(!xd_pf) + b(!xd_af), 64'd3);
        xd_req = 1'b0;
        repeat (6) begin @(posedge clk); #1; end

        // ---------------- a flush mid-walk with the request still up: the walk is redone ----------------
        // The result of a walk that a flush overtook is dropped (the PTEs it read may be the ones the SFENCE.VMA is about): the
        // held request is walked again from the top, so after the flush there are three more reads
        for (int c = 1; c < 14; c++) begin : flush_redo
            int n0;
            std_map(V|R|W|X|A|D);
            lat_min = 2; lat_max = 3;
            flush_all();
            repeat (40) begin @(posedge clk); #1; end
            beat_log_n = 0;
            xd_va = va_pg(9'd3); xd_wr = 1'b0; xd_priv = 2'b01; xd_sum = 1'b0; xd_mxr = 1'b0; xd_req = 1'b1;
            repeat (c) begin @(posedge clk); #1; end
            n0 = beat_log_n;
            xd_flush = 1'b1; xf_flush = 1'b1; @(posedge clk); #1; xd_flush = 1'b0; xf_flush = 1'b0;
            r_cycles = 0; #1;
            while (!xd_done && r_cycles < 300) begin @(posedge clk); #1; r_cycles++; end
            check($sformatf("flush after %0d cycles, request up: answered ok", c), b(xd_done) + b(!xd_pf) + b(!xd_af), 64'd3);
            check($sformatf("flush after %0d cycles, request up: the walk was redone (three reads after the flush)", c),
                  b(beat_log_n - n0 >= 3), 64'd1);
            xd_req = 1'b0;
            repeat (6) begin @(posedge clk); #1; end
        end

        // ---------------- cancel and flush at every cycle of a walk ----------------
        lat_min = 1; lat_max = 2;
        for (int k = 0; k < 30; k++) begin
            for (int kind = 0; kind < 3; kind++)
                for (int f = 0; f < 2; f++) begin
                    kill_run(k, kind, 1'b0, f[0]);
                    if (kind < 2) kill_run(k, kind, 1'b1, f[0]);       // the request still up in the kill cycle
                end
        end
        check("cancel / flush at every cycle: nothing was filled behind the kill", 64'(sweep_viol_refill), 64'd0);
        check("cancel / flush at every cycle: most runs killed a walk in progress", b(sweep_runs - sweep_early > 60), 64'd1);

        // ---------------- random sweep ----------------
        random_map2();
        new_hot_set();
        flush_all();
        for (int i = 0; i < 25000; i++) random_op();
        check("random sweep: some requests answered ok", b(sw_ok > 1000), 64'd1);
        check("random sweep: some page faults", b(sw_pf > 500), 64'd1);
        check("random sweep: some access faults", b(sw_af > 20), 64'd1);
        check("random sweep: plenty of TLB hits (answered in the same cycle with no read)", b(sw_hits > 800), 64'd1);

        check("bus protocol: no violations", 64'(proto_errors), 64'd0);
        $display("");
        $display("qv_xlate_tb: %0d passed, %0d failed (sweep: %0d compared, %0d ok, %0d page faults, %0d access faults, %0d hits, %0d cancelled)",
                 pass_count, fail_count, sw_checked, sw_ok, sw_pf, sw_af, sw_hits, sw_cancels);
        if (fail_count > 0) $display("qv_xlate_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT: qv_xlate_tb");
        $finish;
    end
endmodule
