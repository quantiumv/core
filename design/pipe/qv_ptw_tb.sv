// SPDX-License-Identifier: MIT

/*
 * qv_ptw_tb -- standalone test for design/pipe/qv_ptw.sv, the page-table
 * walker, against a PTE memory with random latency, bus errors and a PMP
 * pocket, and a software model of the walk.
 *
 * Directed: the shape of a walk (three reads for a 4 KB leaf, two for a
 * megapage, one for a gigapage, the addresses read), every fault class of
 * a PTE, access faults (a bus error, ack and err together, a PMP-denied
 * table page that is never read), a bus error that beats a PTE that would
 * have page-faulted, a non-canonical address (the level-2 PTE is read
 * first), an address of 4 GB or more (the bus sees the low 32 bits, the
 * PMP the full address), D before F at an idle walker, the LSU holding the
 * bus off, and a cancel at every cycle of a walk (no done pulse, no beat
 * started after the cancel, the walker free again afterwards).
 *
 * Then a random sweep: random page tables, addresses, access kinds,
 * latencies, errors, LSU busy phases and a denied page, every walk
 * compared with the model -- its kind, its fields, and the exact sequence
 * of PTE addresses read.
 *
 * The bus protocol is monitored throughout: a beat is never dropped before
 * its response, its address is stable, it never starts while the LSU is
 * busy, and o_beat covers it.
 *
 * WINDOW (P10d; tests.list runs both): a RAM window [0, 64 KB) is set, and an F
 * beat whose PTE address is outside it may go out only while i_f_nonspec is
 * high (the monitor checks every beat). Directed: such a walk waits before that
 * beat and finishes once the fetch is on the real path; a D request meanwhile
 * takes the walker (F is given up, accepted again afterwards, and walks from
 * the root); D's own walks outside the window never wait; a PMP-denied read
 * outside it is reported without waiting; a walk inside the window never waits.
 * The sweep runs with i_f_nonspec random every cycle.
 */
module qv_ptw_tb #(
    parameter bit WINDOW = 1'b0
);
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // ---------------- the DUT ----------------
    wire  [31:0] bus_addr;
    wire         bus_cyc;
    logic [63:0] bus_dat = '0;
    logic        bus_ack = 1'b0, bus_err = 1'b0;
    logic        lsu_busy = 1'b0;
    wire         beat;

    logic [63:0] pmpcfg0 = '0, pmpaddr0 = '0, pmpaddr1 = '0, pmpaddr2 = '0, pmpaddr3 = '0;

    logic        d_req = 1'b0, d_wr = 1'b0, d_sum = 1'b0, d_mxr = 1'b0, d_cancel = 1'b0;
    logic [63:0] d_va = '0;
    logic [1:0]  d_priv = 2'b01;
    logic [43:0] d_root = '0;
    logic        f_req = 1'b0, f_cancel = 1'b0;
    logic [63:0] f_va = '0;
    logic [1:0]  f_priv = 2'b01;
    logic [43:0] f_root = '0;
    logic        f_nonspec = 1'b1;
    bit          nonspec_random = 1'b0;
    always @(negedge clk) if (nonspec_random) f_nonspec = ($urandom % 2) == 0;
    wire         d_done, f_done;
    wire         res_ok, res_pf, res_af;
    wire  [26:0] res_vpn;
    wire  [1:0]  res_level;
    wire  [43:0] res_ppn;
    wire         res_r, res_w, res_x, res_u, res_d;

    qv_ptw #(.PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(WINDOW ? 64'h1_0000 : 64'h0)) dut (
        .clk(clk), .rst(rst),
        .o_bus_addr(bus_addr), .o_bus_cyc(bus_cyc), .i_bus_dat(bus_dat), .i_bus_ack(bus_ack), .i_bus_err(bus_err),
        .i_lsu_busy(lsu_busy), .o_beat(beat),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0), .i_pmpaddr1(pmpaddr1), .i_pmpaddr2(pmpaddr2), .i_pmpaddr3(pmpaddr3),
        .i_d_req(d_req), .i_d_va(d_va), .i_d_wr(d_wr), .i_d_priv(d_priv), .i_d_sum(d_sum), .i_d_mxr(d_mxr),
        .i_d_root(d_root), .i_d_cancel(d_cancel), .o_d_done(d_done),
        .i_f_req(f_req), .i_f_va(f_va), .i_f_priv(f_priv), .i_f_root(f_root), .i_f_cancel(f_cancel), .o_f_done(f_done),
        .i_f_nonspec(f_nonspec),
        .o_res_ok(res_ok), .o_res_pf(res_pf), .o_res_af(res_af), .o_res_vpn(res_vpn), .o_res_level(res_level),
        .o_res_ppn(res_ppn), .o_res_r(res_r), .o_res_w(res_w), .o_res_x(res_x), .o_res_u(res_u), .o_res_d(res_d)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // the walker only reads
    wire         bus_we = 1'b0;
    wire  [7:0]  bus_sel = 8'hFF;
    wire  [63:0] bus_dato = 64'b0;
    `include "qv_pt_env.svh"

    // an F beat outside the window starts only on the real path (the beat flag rises at the edge after the decision,
    // so the f_nonspec of the decision's cycle is what counts)
    int window_errs = 0;
    logic prev_beat = 1'b0;
    logic f_nonspec_at_start = 1'b1;
    always @(posedge clk) begin
        if (!rst && WINDOW && beat && !prev_beat && dut.cl_q && ({32'b0, bus_addr} >= 64'h1_0000 || dut.pte_addr[55:32] != 0)
            && !f_nonspec_at_start)
            window_errs++;
        prev_beat <= beat;
        f_nonspec_at_start <= f_nonspec;
    end

    // ---------------- driving a client ----------------
    int  t_to = 0;
    logic got_done, got_ok, got_pf, got_af;
    logic [26:0] got_vpn; logic [1:0] got_level; logic [43:0] got_ppn;
    logic got_r, got_w, got_x, got_u, got_d;

    task automatic capture_result;
        begin
            got_ok = res_ok; got_pf = res_pf; got_af = res_af; got_vpn = res_vpn; got_level = res_level; got_ppn = res_ppn;
            got_r = res_r; got_w = res_w; got_x = res_x; got_u = res_u; got_d = res_d;
        end
    endtask

    // issue a D request and wait for its done pulse (the request drops in the cycle after it)
    task automatic walk_d(input logic [63:0] va, input logic wr, input logic [1:0] priv, input logic sum, input logic mxr,
                          input logic [43:0] root, input int timeout);
        begin
            d_va = va; d_wr = wr; d_priv = priv; d_sum = sum; d_mxr = mxr; d_root = root; d_req = 1'b1;
            got_done = 1'b0; t_to = 0;
            beat_log_n = 0;
            while (!got_done && t_to < timeout) begin
                @(posedge clk); #1;
                if (d_done) begin got_done = 1'b1; capture_result(); end
                t_to++;
            end
            d_req = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    task automatic walk_f(input logic [63:0] va, input logic [1:0] priv, input logic [43:0] root, input int timeout);
        begin
            f_va = va; f_priv = priv; f_root = root; f_req = 1'b1;
            got_done = 1'b0; t_to = 0;
            beat_log_n = 0;
            while (!got_done && t_to < timeout) begin
                @(posedge clk); #1;
                if (f_done) begin got_done = 1'b1; capture_result(); end
                t_to++;
            end
            f_req = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // compare what a finished walk gave with the model's
    task automatic check_against_model(input string name, input logic [63:0] va);
        begin
            check({name, ": a done pulse came"}, b(got_done), 64'd1);
            check({name, ": kind (ok)"}, b(got_ok), b(m_kind == 0));
            check({name, ": kind (page fault)"}, b(got_pf), b(m_kind == 1));
            check({name, ": kind (access fault)"}, b(got_af), b(m_kind == 2));
            check({name, ": number of PTE reads"}, 64'(beat_log_n), 64'(m_beats));
            for (int i = 0; i < m_beats && i < beat_log_n; i++)
                check($sformatf("%s: PTE read %0d address", name, i), {32'b0, beat_log[i]}, {32'b0, m_addrs[i]});
            if (m_kind == 0) begin
                check({name, ": leaf level"}, {62'b0, got_level}, {62'b0, m_level});
                check({name, ": leaf ppn"}, {20'b0, got_ppn}, {20'b0, m_ppn});
                check({name, ": vpn of the walk"}, {37'b0, got_vpn}, {37'b0, va[38:12]});
                check({name, ": leaf flags r w x u d"}, {59'b0, got_r, got_w, got_x, got_u, got_d},
                      {59'b0, m_pte[1], m_pte[2], m_pte[3], m_pte[4], m_pte[7]});
            end
        end
    endtask

    // ---------------- the cancel experiment ----------------
    // raise a request, cancel it k cycles later (dropping the request in the same cycle, as the user does), and see what
    // the walker does: no done pulse for it, no new beat after the cancel cycle, free again afterwards
    int cancel_violations_done = 0, cancel_violations_beat = 0, cancel_runs = 0, cancel_early = 0;
    task automatic cancel_run(input int k, input logic use_f);
        int n_before, total_after, seen_done_after;
        bit finished_early;
        begin
            std_map(use_f ? (V|R|X|A) : (V|R|W|A|D));          // a fetch needs X, a load needs R
            set_pmp();
            beat_log_n = 0;
            finished_early = 1'b0;
            if (use_f) begin f_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); f_priv = 2'b01; f_root = ROOT; f_req = 1'b1; end
            else begin d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT; d_req = 1'b1; end
            for (int i = 0; i < k && !finished_early; i++) begin
                @(posedge clk); #1;
                if (use_f ? f_done : d_done) begin           // the walk was over before the cancel: nothing to test
                    finished_early = 1'b1;
                    if (use_f) f_req = 1'b0; else d_req = 1'b0;
                end
            end
            cancel_runs++;
            if (finished_early) begin
                cancel_early++;
                @(posedge clk); #1;
            end else begin
                // the cancel cycle: raise cancel and drop the request. A beat whose cyc is up right now has started
                n_before = beats_total + ((bus_cyc && !prev_cyc) ? 1 : 0);
                if (use_f) begin f_cancel = 1'b1; f_req = 1'b0; end else begin d_cancel = 1'b1; d_req = 1'b0; end
                @(posedge clk); #1;
                if (use_f) f_cancel = 1'b0; else d_cancel = 1'b0;
                seen_done_after = 0;
                for (int i = 0; i < 60; i++) begin
                    if (d_done || f_done) seen_done_after++;
                    @(posedge clk); #1;
                end
                total_after = beats_total;
                if (seen_done_after != 0) cancel_violations_done++;
                if (total_after != n_before) cancel_violations_beat++;
            end
        end
    endtask

    // ---------------- the sweep ----------------
    int sweep_mismatch = 0, sweep_walks = 0, sweep_ok = 0, sweep_pf = 0, sweep_af = 0, sweep_multi = 0;

    function automatic logic [7:0] good_flags(input logic [31:0] r);
        case (r[3:0])
            0, 1, 2: return V|R|W|A|D;
            3:       return V|R|A;
            4:       return V|R|X|A;
            5:       return V|X|A;
            6:       return V|R|W|A|D|U;
            7:       return V|R|X|A|D|U;
            default: return r[15:8] | V;                        // anything
        endcase
    endfunction

    task automatic random_map;
        logic [31:0] r;
        logic [63:0] pte;
        begin
            clear_mem();
            for (int i = 0; i < 8; i++) begin               // the root table: mostly pointers to the level-1 table
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: pte = pte_of(L1T, V);
                    12: pte = pte_of({r[25:20], 18'b0}, good_flags(r));   // a gigapage (aligned)
                    13: pte = {r, $urandom};                                // junk
                    default: pte = 64'd0;
                endcase
                put(ROOT, i, pte);
            end
            for (int i = 0; i < 8; i++) begin               // the level-1 table: mostly pointers to the level-0 table
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: pte = pte_of(L0T, V);
                    12: pte = pte_of({r[25:20], 18'b0} | {r[31:26], 9'b0}, good_flags(r));   // a megapage (aligned)
                    13: pte = {r, $urandom};
                    default: pte = 64'd0;
                endcase
                put(L1T, i, pte);
            end
            for (int i = 0; i < 8; i++) begin               // the level-0 table: mostly leaves
                r = $urandom;
                case (r[19:16])
                    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10: pte = pte_of({r[31:20], r[15:0], 16'b0} >> 4, good_flags(r));
                    11: pte = pte_of(L0T, V);                                // a pointer at the last level
                    12: pte = {r, $urandom};
                    default: pte = 64'd0;
                endcase
                put(L0T, i, pte);
            end
        end
    endtask

    task automatic random_walk;
        logic [31:0] r1, r2, r3;
        logic [63:0] va;
        logic [43:0] root;
        logic        use_f, wr_, sum_, mxr_;
        logic [1:0]  priv_;
        begin
            r1 = $urandom; r2 = $urandom; r3 = $urandom;
            va = {r2[31:0], r3[31:0]};
            va[38:30] = {6'b0, r1[2:0]}; va[29:21] = {6'b0, r1[5:3]}; va[20:12] = {6'b0, r1[8:6]};
            va[63:39] = va[38] ? 25'h1FFFFFF : 25'h0;
            if (r1[13:9] == 0) va[63:39] = r2[31:7];                   // non-canonical now and then
            root = ROOT;
            if (r1[16:14] == 0) root = ROOT + 44'h10_0000;        // above 4 GB: the bus sees the low bits only
            use_f = r1[17];
            wr_ = (r3[7:5] < 3); sum_ = r1[19]; mxr_ = r1[20];
            priv_ = (r3[10:8] < 4) ? 2'b01 : (r3[10:8] < 6) ? 2'b00 : r1[22:21];
            // errors and the denied page on the way, now and then
            err_addr = '1; deny_ppn = '1; err_with_ack = r1[23];
            if (r1[26:24] == 0)
                err_addr = {(r1[27] ? L1T : (r1[28] ? L0T : ROOT)) + (root[20] ? 44'h10_0000 : 44'd0), 12'b0} + {44'd0, r3[2:0], 3'b000};
            if (r1[31:29] == 0)
                deny_ppn = (r3[3] ? L1T : (r3[4] ? L0T : ROOT)) + (root[20] ? 44'h10_0000 : 44'd0);
            lat_min = 0; lat_max = r2[3:2];
            lsu_busy = 1'b0;
            set_pmp();
            if (use_f) begin
                model_walk(va, 1'b0, 1'b0, priv_, 1'b0, 1'b0, root);
                walk_f(va, priv_, root, 200);
            end else begin
                model_walk(va, 1'b1, wr_, priv_, sum_, mxr_, root);
                walk_d(va, wr_, priv_, sum_, mxr_, root, 200);
            end
            sweep_walks++;
            if (m_kind == 0) sweep_ok++;
            if (m_kind == 1) sweep_pf++;
            if (m_kind == 2) sweep_af++;
            if (m_beats > 1) sweep_multi++;
            if (!got_done || got_ok !== (m_kind == 0) || got_pf !== (m_kind == 1) || got_af !== (m_kind == 2)
                || beat_log_n != m_beats
                || (m_kind == 0 && (got_level !== m_level || got_ppn !== m_ppn || got_vpn !== va[38:12]
                                    || {got_r, got_w, got_x, got_u, got_d} !== {m_pte[1], m_pte[2], m_pte[3], m_pte[4], m_pte[7]}))) begin
                sweep_mismatch++;
                if (sweep_mismatch <= 8)
                    $display("MISMATCH va=%h root=%h wr=%b priv=%0d sum=%b mxr=%b f=%b err=%h deny=%h: dut done=%b ok=%b pf=%b af=%b beats=%0d level=%0d ppn=%h model kind=%0d beats=%0d level=%0d ppn=%h",
                             va, root, wr_, priv_, sum_, mxr_, use_f, err_addr, deny_ppn, got_done, got_ok, got_pf, got_af, beat_log_n, got_level, got_ppn,
                             m_kind, m_beats, m_level, m_ppn);
            end else begin
                for (int i = 0; i < m_beats; i++)
                    if (beat_log[i] !== m_addrs[i]) begin
                        sweep_mismatch++;
                        if (sweep_mismatch <= 8) $display("MISMATCH va=%h: beat %0d address dut=%h model=%h", va, i, beat_log[i], m_addrs[i]);
                    end
            end
            err_addr = '1; deny_ppn = '1;
        end
    endtask

    initial begin
        clear_mem();
        set_pmp();
        repeat (4) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk); #1;

        // ---------------- the shape of a walk ----------------
        std_map(V|R|W|A|D);
        lat_min = 0; lat_max = 2;
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h5A8), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h5A8), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check_against_model("4 KB leaf", va_of(9'd1, 9'd2, 9'd3, 12'h5A8));
        check("4 KB leaf: three reads", 64'(beat_log_n), 64'd3);
        check("4 KB leaf: read 0 is root + vpn2 * 8", {32'b0, beat_log[0]}, 64'h2008);
        check("4 KB leaf: read 1 is the level-1 table + vpn1 * 8", {32'b0, beat_log[1]}, 64'h3010);
        check("4 KB leaf: read 2 is the level-0 table + vpn0 * 8", {32'b0, beat_log[2]}, 64'h4018);
        check("4 KB leaf: the leaf's page number", {20'b0, got_ppn}, 64'h12345);
        check("4 KB leaf: level 0", {62'b0, got_level}, 64'd0);

        // a megapage (level 1 leaf) and a gigapage (level 2 leaf)
        std_map(V|R|W|A|D);
        put(L1T, 2, pte_of({26'h77, 9'h5, 9'h0}, V|R|W|A|D));
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h100), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h100), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check_against_model("megapage", va_of(9'd1, 9'd2, 9'd3, 12'h100));
        check("megapage: two reads, level 1", 64'(beat_log_n) * 4 + {62'b0, got_level}, 64'd9);
        std_map(V|R|W|A|D);
        put(ROOT, 1, pte_of({26'h99, 9'h0, 9'h0}, V|R|W|A|D));
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h100), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h100), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check_against_model("gigapage", va_of(9'd1, 9'd2, 9'd3, 12'h100));
        check("gigapage: one read, level 2", 64'(beat_log_n) * 4 + {62'b0, got_level}, 64'd6);

        // ---------------- page faults ----------------
        for (int k = 0; k < 9; k++) begin
            std_map(V|R|W|A|D);
            case (k)
                0: put(ROOT, 1, 64'd0);                                       // invalid at level 2
                1: put(L1T, 2, 64'd0);                                        // invalid at level 1
                2: put(L0T, 3, 64'd0);                                        // invalid at level 0
                3: put(L0T, 3, pte_of(44'h12345, V|W|A|D));                   // W without R
                4: put(L0T, 3, pte_of(44'h12345, V|R|A|D) | (64'd1 << 57));   // reserved bit
                5: put(L1T, 2, pte_of({26'h77, 9'h5, 9'h1}, V|R|W|A|D));      // misaligned megapage
                6: put(L0T, 3, pte_of(L0T, V));                               // a pointer at the last level
                7: put(L0T, 3, pte_of(44'h12345, V|R|W));                     // A clear
                default: put(ROOT, 1, pte_of(L1T, V) | (64'd1 << 63));        // N bit on a pointer
            endcase
            model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
            walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
            check_against_model($sformatf("page fault case %0d", k), va_of(9'd1, 9'd2, 9'd3, 12'h0));
            check($sformatf("page fault case %0d: it is a page fault", k), b(got_pf), 64'd1);
        end
        // the permission rules arrive here too (the full matrix is qv_pte_tb's): a store to a read-only page, a U page for S
        std_map(V|R|A);
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b1, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check_against_model("store to a read-only page", va_of(9'd1, 9'd2, 9'd3, 12'h0));
        check("store to a read-only page: page fault", b(got_pf), 64'd1);
        std_map(V|R|U|A);
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("S load from a U page without SUM: page fault", b(got_pf), 64'd1);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b1, 1'b0, ROOT, 100);
        check("S load from a U page with SUM: ok", b(got_ok), 64'd1);
        check("S load from a U page with SUM: the leaf's flags r w x u d", {59'b0, got_r, got_w, got_x, got_u, got_d}, 64'b10010);
        std_map(V|R|A);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("load from a clean page (A set, D clear): ok", b(got_ok), 64'd1);
        check("load from a clean page: the leaf's flags r w x u d (d is 0)", {59'b0, got_r, got_w, got_x, got_u, got_d}, 64'b10000);
        std_map(V|R|X|W|A|D);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("load from a RWX AD page: the leaf's flags r w x u d", {59'b0, got_r, got_w, got_x, got_u, got_d}, 64'b11101);

        std_map(V|X|A);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("load from an execute-only page: page fault", b(got_pf), 64'd1);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b1, ROOT, 100);
        check("load from an execute-only page with MXR: ok", b(got_ok), 64'd1);
        walk_f(va_of(9'd1, 9'd2, 9'd3, 12'h0), 2'b01, ROOT, 100);
        check("S fetch from an executable page: ok", b(got_ok), 64'd1);

        // ---------------- access faults ----------------
        // a bus error on the level-1 read; with and without ack alongside
        for (int k = 0; k < 2; k++) begin
            std_map(V|R|W|A|D);
            err_addr = 56'h3010; err_with_ack = (k == 1);
            model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
            walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
            check_against_model(k == 0 ? "bus error (err alone)" : "bus error (err with ack)", va_of(9'd1, 9'd2, 9'd3, 12'h0));
            check("bus error: access fault", b(got_af), 64'd1);
            check("bus error: two reads", 64'(beat_log_n), 64'd2);
        end
        // a bus error beats a PTE that would have page-faulted
        std_map(V|R|W|A|D);
        put(L1T, 2, 64'd0);
        err_addr = 56'h3010; err_with_ack = 1'b0;
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("a bus error beats the PTE contents: access fault", b(got_af), 64'd1);
        check("a bus error beats the PTE contents: not a page fault", b(got_pf), 64'd0);
        err_addr = '1;
        // a PMP-denied table page: the read never reaches the bus
        std_map(V|R|W|A|D);
        deny_ppn = L0T; set_pmp();
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check_against_model("PMP-denied level-0 table", va_of(9'd1, 9'd2, 9'd3, 12'h0));
        check("PMP-denied level-0 table: access fault", b(got_af), 64'd1);
        check("PMP-denied level-0 table: only the first two reads went out", 64'(beat_log_n), 64'd2);
        deny_ppn = ROOT; set_pmp();
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("PMP-denied root: access fault with no read at all", 64'(beat_log_n) * 2 + b(got_af), 64'd1);
        deny_ppn = '1; set_pmp();
        // a non-canonical address: the level-2 PTE is read first, then the page fault
        std_map(V|R|W|A|D);
        model_walk(64'h0000_0080_0000_0000 | va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT);
        walk_d(64'h0000_0080_0000_0000 | va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("non-canonical: one read, then a page fault", 64'(beat_log_n) * 2 + b(got_pf), 64'd3);
        // ... and if that read is denied, the access fault wins
        deny_ppn = ROOT; set_pmp();
        walk_d(64'h0000_0080_0000_0000 | va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("non-canonical with the root read denied: access fault", b(got_af), 64'd1);
        deny_ppn = '1; set_pmp();
        // a table at or above 4 GB: the bus sees the low 32 bits, the PMP the whole address
        std_map(V|R|W|A|D);
        model_walk(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b1, 1'b0, 2'b01, 1'b0, 1'b0, ROOT + 44'h10_0000);
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT + 44'h10_0000, 100);
        check("root above 4 GB: the first read is at the low 32 bits", {32'b0, beat_log[0]}, 64'h2008);
        check("root above 4 GB: it works (8 GB PMP region)", b(got_done) + b(got_ok) + b(!got_af), 64'd3);

        // ---------------- D before F, one done pulse each ----------------
        std_map(V|R|W|A|D);
        begin : prio
            int d_t, f_t, order;
            d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT;
            f_va = va_of(9'd1, 9'd2, 9'd3, 12'h8); f_priv = 2'b01; f_root = ROOT;
            beat_log_n = 0;
            d_req = 1'b1; f_req = 1'b1;
            d_t = -1; f_t = -1; order = 0;
            for (int i = 0; i < 100; i++) begin
                @(posedge clk); #1;
                if (d_done && d_t < 0) begin d_t = i; d_req = 1'b0; end
                if (f_done && f_t < 0) begin f_t = i; f_req = 1'b0; end
            end
            check("both clients: D finishes first", b(d_t >= 0 && f_t > d_t), 64'd1);
            check("both clients: F finishes too", b(f_t >= 0), 64'd1);
            check("both clients: six reads in all", 64'(beat_log_n), 64'd6);
        end

        // ---------------- the LSU holds the bus off ----------------
        std_map(V|R|W|A|D);
        lat_min = 0; lat_max = 0;
        lsu_busy = 1'b1;
        d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT; d_req = 1'b1;
        beat_log_n = 0;
        repeat (20) begin @(posedge clk); #1; end
        check("LSU busy: no beat starts", 64'(beat_log_n), 64'd0);
        lsu_busy = 1'b0;
        got_done = 1'b0;
        for (int i = 0; i < 60 && !got_done; i++) begin @(posedge clk); #1; if (d_done) begin got_done = 1'b1; capture_result(); end end
        d_req = 1'b0; @(posedge clk); #1;
        check("LSU released: the walk completes", b(got_done) + b(got_ok), 64'd2);
        // busy again in the gap between two beats: the LSU gets the bus, the walk resumes afterwards
        begin : gap
            int stalls;
            d_req = 1'b1; beat_log_n = 0; stalls = 0; got_done = 1'b0;
            for (int i = 0; i < 100 && !got_done; i++) begin
                @(posedge clk); #1;
                lsu_busy = (i % 7 == 3) || (i % 7 == 4);
                if (d_done) begin got_done = 1'b1; capture_result(); end
            end
            lsu_busy = 1'b0;
            d_req = 1'b0; @(posedge clk); #1;
            check("LSU busy in short phases: the walk still completes with three reads", b(got_done) + b(got_ok), 64'd2);
            check("LSU busy in short phases: three reads", 64'(beat_log_n), 64'd3);
        end

        // ---------------- a request held past its done pulse ----------------
        // The pulse is the client's cue to drop its request; one that sees it a cycle late (the request still up in the
        // pulse's cycle) must not get a second walk
        std_map(V|R|W|A|D);
        lat_min = 0; lat_max = 1;
        for (int k = 0; k < 2; k++) begin : late_drop
            int extra_done;
            beat_log_n = 0; extra_done = 0; got_done = 1'b0;
            if (k == 0) begin
                d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT; d_req = 1'b1;
            end else begin
                f_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); f_priv = 2'b01; f_root = ROOT; f_req = 1'b1;
            end
            for (int i = 0; i < 100 && !got_done; i++) begin
                @(posedge clk); #1;
                if (k == 0 ? d_done : f_done) got_done = 1'b1;
            end
            @(posedge clk); #1;                                        // the end of the pulse's cycle, the request still up
            d_req = 1'b0; f_req = 1'b0;
            repeat (60) begin @(posedge clk); #1; if (d_done || f_done) extra_done++; end
            check($sformatf("%s client, request dropped a cycle late: one walk, three reads", k == 0 ? "D" : "F"),
                  64'(beat_log_n), 64'd3);
            check($sformatf("%s client, request dropped a cycle late: no second done pulse", k == 0 ? "D" : "F"),
                  64'(extra_done), 64'd0);
        end

        // ---------------- a request cancelled in the cycle it arrives ----------------
        for (int k = 0; k < 2; k++) begin : cancel_arrive
            int extra_done;
            beat_log_n = 0; extra_done = 0;
            if (k == 0) begin
                d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT;
                d_req = 1'b1; d_cancel = 1'b1;
            end else begin
                f_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); f_priv = 2'b01; f_root = ROOT; f_req = 1'b1; f_cancel = 1'b1;
            end
            @(posedge clk); #1;
            d_req = 1'b0; d_cancel = 1'b0; f_req = 1'b0; f_cancel = 1'b0;
            repeat (60) begin @(posedge clk); #1; if (d_done || f_done) extra_done++; end
            check($sformatf("%s client, request cancelled as it arrives: no walk", k == 0 ? "D" : "F"), 64'(beat_log_n), 64'd0);
            check($sformatf("%s client, request cancelled as it arrives: no done pulse", k == 0 ? "D" : "F"), 64'(extra_done), 64'd0);
        end

        // ---------------- the PMP judges the whole dword of a PTE read ----------------
        // The level-0 PTE of the walk below is the dword at 0x4018. A 4-byte no-permission region over its first half only
        // overlaps it in part: that is no match, and the open region behind it decides (the walk works).
        std_map(V|R|W|A|D);
        lat_min = 0; lat_max = 0;
        pmpaddr0 = 64'h4018 >> 2; pmpaddr1 = 64'h3FFFFFFF; pmpaddr2 = 64'd0;
        pmpcfg0  = {48'b0, 8'h1F, 8'h10};                              // region 0 NA4 --- ; region 1 NAPOT 8 GB rwx
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("PMP: a 4-byte region over half of the PTE is no match (the PTE read is allowed)", b(got_done) + b(got_ok) + 64'(beat_log_n), 64'd5);
        // An 8-byte read-only region exactly over it matches, even though a no-permission page region follows it: the
        // dword read is inside region 0. (A span longer than the dword would overlap region 0 only in part and fall to region 1.)
        pmpaddr0 = 64'h4018 >> 2; pmpaddr1 = (64'h4000 >> 2) | 64'h1FF; pmpaddr2 = 64'h3FFFFFFF;
        pmpcfg0  = {40'b0, 8'h19, 8'h18, 8'h19};                       // region 0 NAPOT 8 B r ; region 1 NAPOT 4 KB --- ; region 2 NAPOT 8 GB r
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("PMP: an 8-byte region exactly over the PTE matches the dword read", b(got_done) + b(got_ok) + 64'(beat_log_n), 64'd5);
        // ... and one over the next dword does not touch it: the page region behind it denies the read
        pmpaddr0 = 64'h4020 >> 2;
        walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
        check("PMP: a region over the next dword leaves the read to the page region (denied)", b(got_done) + b(got_af), 64'd2);
        set_pmp();

        // ---------------- cancel at every cycle ----------------
        lat_min = 1; lat_max = 2;
        for (int k = 0; k < 40; k++) begin
            cancel_run(k, 1'b0);
            // the walker is free afterwards: a normal walk works
            walk_d(va_of(9'd1, 9'd2, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 200);
            check($sformatf("after a D cancel at cycle %0d: a new walk completes ok", k), b(got_done) + b(got_ok), 64'd2);
        end
        for (int k = 0; k < 40; k++) begin
            cancel_run(k, 1'b1);
            walk_f(va_of(9'd1, 9'd2, 9'd3, 12'h0), 2'b01, ROOT, 200);
            check($sformatf("after an F cancel at cycle %0d: a new walk completes ok", k), b(got_done) + b(got_ok), 64'd2);
        end
        check("cancel at every cycle: no done pulse for a cancelled request", 64'(cancel_violations_done), 64'd0);
        check("cancel at every cycle: no beat started after the cancel cycle", 64'(cancel_violations_beat), 64'd0);
        check("cancel at every cycle: most runs really cancelled a walk in progress", b(cancel_runs - cancel_early > 30), 64'd1);

        // ---------------- ack and err ignored when no beat is in flight ----------------
        std_map(V|R|W|A|D);
        d_req = 1'b0; f_req = 1'b0;
        repeat (3) begin @(posedge clk); #1; end
        bus_ack = 1'b1; bus_err = 1'b1; repeat (3) begin @(posedge clk); #1; end
        check("stray ack/err with no request: no done pulse and no beat", 64'(d_done) + 64'(f_done) + 64'(bus_cyc), 64'd0);
        bus_ack = 1'b0; bus_err = 1'b0;

        // ---------------- the RAM window: F's reads outside it wait for the real path (WINDOW only) ----------------
        if (WINDOW) begin : window
            localparam logic [43:0] FAR = 44'h18;              // a table page at 96 KB: in the memory, outside the window
            int c, d_t, f_t;
            clear_mem();
            put(ROOT, 1, pte_of(L1T, V));
            put(L1T, 2, pte_of(L0T, V));                       // vpn1 = 2: tables inside the window
            put(L0T, 3, pte_of(44'h12345, V|R|W|X|A|D));
            put(L1T, 5, pte_of(FAR, V));                       // vpn1 = 5: the level-0 table outside it
            put(FAR, 3, pte_of(44'h23456, V|R|W|X|A|D));
            lat_min = 0; lat_max = 1; err_addr = '1; deny_ppn = '1; set_pmp();
            // a walk outside the window waits before its third read until the fetch is on the real path
            f_nonspec = 1'b0;
            f_va = va_of(9'd1, 9'd5, 9'd3, 12'h0); f_priv = 2'b01; f_root = ROOT; f_req = 1'b1;
            beat_log_n = 0; got_done = 1'b0;
            for (c = 0; c < 60; c++) begin @(posedge clk); #1; if (f_done) got_done = 1'b1; end
            check("window: F waits before the read outside the window", b(got_done), 64'd0);
            check("window: ... after its two reads inside it", 64'(beat_log_n), 64'd2);
            f_nonspec = 1'b1;
            for (c = 0; c < 60 && !got_done; c++) begin @(posedge clk); #1; if (f_done) begin got_done = 1'b1; capture_result(); end end
            f_req = 1'b0; @(posedge clk); #1;
            check("window: on the real path it reads and finishes", b(got_done) + b(got_ok), 64'd2);
            check("window: three reads", 64'(beat_log_n), 64'd3);
            check("window: the last one outside the window", {32'b0, beat_log[2]}, 64'h1_8018);
            check("window: the leaf's page", {20'b0, got_ppn}, 64'h23456);
            // D asks while F waits: D's walk goes first, F walks again from the root and waits again
            f_nonspec = 1'b0;
            f_req = 1'b1; beat_log_n = 0;
            repeat (30) begin @(posedge clk); #1; end
            d_va = va_of(9'd1, 9'd2, 9'd3, 12'h0); d_wr = 1'b0; d_priv = 2'b01; d_sum = 1'b0; d_mxr = 1'b0; d_root = ROOT;
            d_req = 1'b1; d_t = -1; f_t = -1;
            for (c = 0; c < 80; c++) begin
                @(posedge clk); #1;
                if (d_done && d_t < 0) begin d_t = c; d_req = 1'b0; end
                if (f_done && f_t < 0) f_t = c;
            end
            check("window: a D request while F waits is served", b(d_t >= 0), 64'd1);
            check("window: ... and F still waits", b(f_t < 0), 64'd1);
            check("window: F's two reads, D's three, F's two again", 64'(beat_log_n), 64'd7);
            f_nonspec = 1'b1;
            for (c = 0; c < 60 && f_t < 0; c++) begin @(posedge clk); #1; if (f_done) f_t = c; end
            f_req = 1'b0; @(posedge clk); #1;
            check("window: F finishes once on the real path", b(f_t >= 0), 64'd1);
            // D never waits, outside the window or not
            f_nonspec = 1'b0;
            walk_d(va_of(9'd1, 9'd5, 9'd3, 12'h0), 1'b0, 2'b01, 1'b0, 1'b0, ROOT, 100);
            check("window: D's walk outside the window does not wait", b(got_done) + b(got_ok) + 64'(beat_log_n), 64'd5);
            // an F walk inside the window does not wait
            walk_f(va_of(9'd1, 9'd2, 9'd3, 12'h0), 2'b01, ROOT, 100);
            check("window: F's walk inside the window does not wait", b(got_done) + b(got_ok) + 64'(beat_log_n), 64'd5);
            // ... with its level-0 table in the window's last page either
            put(L1T, 6, pte_of(44'hF, V));
            put(44'hF, 3, pte_of(44'h34567, V|R|W|X|A|D));
            walk_f(va_of(9'd1, 9'd6, 9'd3, 12'h0), 2'b01, ROOT, 100);
            check("window: a table in the window's last page does not wait", b(got_done) + b(got_ok) + 64'(beat_log_n), 64'd5);
            check("window: ... its leaf", {20'b0, got_ppn}, 64'h34567);
            // a PMP-denied read outside the window: the access fault comes at once, no wait and no read
            deny_ppn = FAR; set_pmp();
            walk_f(va_of(9'd1, 9'd5, 9'd3, 12'h0), 2'b01, ROOT, 60);
            check("window: a denied read outside it is an access fault without waiting", b(got_done) + b(got_af), 64'd2);
            check("window: ... after the two reads inside", 64'(beat_log_n), 64'd2);
            deny_ppn = '1; set_pmp();
            f_nonspec = 1'b1;
            nonspec_random = 1'b1;                             // the sweep, with the real path coming and going
        end

        // ---------------- random sweep ----------------
        for (int m = 0; m < 6; m++) begin
            random_map();
            for (int w = 0; w < 2000; w++) begin
                if (w % 80 == 79) random_map();
                random_walk();
            end
        end
        nonspec_random = 1'b0; f_nonspec = 1'b1;
        check("random sweep: no mismatches against the model", 64'(sweep_mismatch), 64'd0);
        check("random sweep: some walks ended ok", b(sweep_ok > 100), 64'd1);
        check("random sweep: some page faults", b(sweep_pf > 100), 64'd1);
        check("random sweep: some access faults", b(sweep_af > 50), 64'd1);
        check("random sweep: many multi-read walks", b(sweep_multi > 500), 64'd1);

        check("bus protocol: no violations", 64'(proto_errors), 64'd0);
        check("window: no F read outside it off the real path", 64'(window_errs), 64'd0);
        $display("");
        $display("qv_ptw_tb: %0d passed, %0d failed (%0d walks in the sweep: %0d ok, %0d page faults, %0d access faults)",
                 pass_count, fail_count, sweep_walks, sweep_ok, sweep_pf, sweep_af);
        if (fail_count > 0) $display("qv_ptw_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #1000000000;
        $display("TIMEOUT: qv_ptw_tb");
        $finish;
    end
endmodule
