// SPDX-License-Identifier: MIT

/*
 * qv_pmp_tb -- standalone test for design/pipe/qv_pmp.sv.
 *
 * Two parts. Directed cases pin the spec's rules (errata E5): the lowest
 * region holding any byte of the access decides, and an access it holds
 * only part of fails, in M mode too, even when a later region would hold
 * it whole; TOR region 0 starts at 0 and a TOR region is empty unless its
 * bottom is below its top; an unlocked deciding region never limits M, a
 * locked one does; privilege 2'b10 is not M; no region at all denies
 * everything below M.
 *
 * Then a randomized sweep against a model written differently (a loop
 * over the regions, bounds as inclusive ranges, sizes from counting
 * trailing ones) over random configurations whose addresses are kept small
 * enough that spans really do fall on, across and beside the region edges.
 */
module qv_pmp_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic [63:0] cfg = '0, pa0 = '0, pa1 = '0, pa2 = '0, pa3 = '0;
    logic [63:0] addr = '0, endb = '0;
    logic [1:0]  priv = 2'b11;
    logic        r_ok, w_ok, x_ok;

    qv_pmp dut (
        .i_pmpcfg0(cfg), .i_pmpaddr0(pa0), .i_pmpaddr1(pa1), .i_pmpaddr2(pa2), .i_pmpaddr3(pa3),
        .i_addr(addr), .i_end(endb), .i_priv(priv),
        .o_read_ok(r_ok), .o_write_ok(w_ok), .o_exec_ok(x_ok)
    );

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    localparam logic [1:0] A_OFF = 2'b00, A_TOR = 2'b01, A_NA4 = 2'b10, A_NAPOT = 2'b11;

    function automatic logic [7:0] cfgb(input logic l, input logic [1:0] a, input logic x, input logic w, input logic r);
        return {l, 2'b00, a, x, w, r};
    endfunction

    task automatic acc(input logic [63:0] a, input int size, input logic [1:0] p);
        addr = a; endb = a + 64'(size) - 64'd1; priv = p;
        #1;
    endtask

    task automatic expect_rwx(input string name, input logic r, input logic w, input logic x);
        check({name, ": read"}, b(r_ok), b(r));
        check({name, ": write"}, b(w_ok), b(w));
        check({name, ": exec"}, b(x_ok), b(x));
    endtask

    // ---------------- the model ----------------
    // region i as a byte range [lo, hi] (inclusive), or none
    task automatic region_range(input int i, output bit valid, output logic [63:0] lo, output logic [63:0] hi);
        logic [1:0]  a;
        logic [53:0] p, prev;
        logic [63:0] sz;
        int          t;
        logic [63:0] pas [4];
        pas[0] = pa0; pas[1] = pa1; pas[2] = pa2; pas[3] = pa3;
        a = cfg[8*i+3 +: 2];
        p = pas[i][53:0];
        valid = 1'b1;
        lo = '0; hi = '0;
        case (a)
            A_OFF: valid = 1'b0;
            A_TOR: begin
                prev = (i == 0) ? 54'd0 : pas[i-1][53:0];
                lo = {8'b0, prev, 2'b0};
                hi = {8'b0, p, 2'b0} - 64'd1;
                if (!(prev < p)) valid = 1'b0;                                    // empty
            end
            A_NA4: begin
                lo = {8'b0, p, 2'b0};
                hi = lo + 64'd3;
            end
            default: begin
                // size from the trailing ones: 2^(t+3) bytes, capped at the field width
                t = 0;
                while (t < 54 && p[t]) t++;
                if (t + 3 > 56) sz = 64'd1 << 56; else sz = 64'd1 << (t + 3);
                lo = {8'b0, p, 2'b0} & ~(sz - 64'd1);
                hi = lo + sz - 64'd1;
            end
        endcase
    endtask

    // whether region i holds any byte of [a0, a1] (touch) and all of them (whole)
    task automatic in_region(input int i, input logic [63:0] a0, input logic [63:0] a1, output logic touch,
                             output logic whole);
        bit          valid;
        logic [63:0] lo, hi;
        region_range(i, valid, lo, hi);
        touch = valid && !(a1 < lo || a0 > hi);
        whole = valid && (a0 >= lo) && (a1 <= hi);
    endtask

    task automatic model(input logic [63:0] a0, input logic [63:0] a1, input logic [1:0] p,
                         output logic mr, output logic mw, output logic mx);
        int hit;
        logic l, r, w, x, t, wh, hit_whole;
        hit = -1;
        hit_whole = 1'b0;
        for (int i = 0; i < 4; i++) begin
            in_region(i, a0, a1, t, wh);
            if (hit < 0 && t) begin hit = i; hit_whole = wh; end
        end
        if (hit < 0) begin
            mr = (p == 2'b11); mw = (p == 2'b11); mx = (p == 2'b11);
        end else if (!hit_whole) begin
            mr = 1'b0; mw = 1'b0; mx = 1'b0;                 // the deciding region holds only part of it
        end else begin
            l = cfg[8*hit+7]; r = cfg[8*hit]; w = cfg[8*hit+1]; x = cfg[8*hit+2];
            if (p == 2'b11 && !l) begin mr = 1'b1; mw = 1'b1; mx = 1'b1; end
            else begin mr = r; mw = w; mx = x; end
        end
    endtask

    // ---------------- random sweep ----------------
    // (iverilog cannot bit-select a function result, so the dice are plain variables)
    logic [31:0] r1, r2, r3, r4, r5, r6, r7, r8, r9;
    task automatic reroll();
        r1 = $urandom; r2 = $urandom; r3 = $urandom; r4 = $urandom; r5 = $urandom;
        r6 = $urandom; r7 = $urandom; r8 = $urandom; r9 = $urandom;
    endtask

    logic mr, mw, mx;
    int   mismatches = 0;
    task automatic random_config();
        // small addresses, in word units, so spans land around the edges
        cfg = '0;
        reroll();
        for (int i = 0; i < 4; i++) begin
            cfg[8*i +: 8] = cfgb(r1[4*i +: 4] == 0, r2[2*i +: 2], r3[3*i], r3[3*i+1], r3[3*i+2]);
        end
        pa0 = {58'b0, r4[5:0]};
        pa1 = {57'b0, r4[12:6]};
        pa2 = {56'b0, r4[20:13]};
        pa3 = {55'b0, r4[29:21]};
        // now and then make a NAPOT-looking address (trailing ones) or a huge one
        case (r5[3:0])
            0: pa0 = (pa0 << 3) | 64'h7;
            1: pa1 = (pa1 << 2) | 64'h3;
            2: pa2 = (pa2 << 4) | 64'hF;
            3: pa3 = {10'b0, 44'hFFF_FFFF_FFFF, 10'b0} | 64'h3FF;
            4: pa1 = 64'h003F_FFFF_FFFF_FFFF;
            default: ;
        endcase
    endtask

    int n_hits_rw = 0;
    initial begin
        // ------------------------------------------------ directed ------------------------------------------------
        // nothing configured
        cfg = '0; pa0 = '0; pa1 = '0; pa2 = '0; pa3 = '0;
        acc(64'h1000, 4, 2'b11);  expect_rwx("no regions, M", 1, 1, 1);
        acc(64'h1000, 4, 2'b01);  expect_rwx("no regions, S", 0, 0, 0);
        acc(64'h1000, 4, 2'b00);  expect_rwx("no regions, U", 0, 0, 0);
        acc(64'h1000, 4, 2'b10);  expect_rwx("no regions, privilege 2", 0, 0, 0);

        // TOR region 0: [0, 0x100) read+execute
        cfg[7:0] = cfgb(0, A_TOR, 1, 0, 1);  pa0 = 64'h100 >> 2;
        acc(64'h0,   8, 2'b01);  expect_rwx("tor0: bottom", 1, 0, 1);
        acc(64'hF8,  8, 2'b01);  expect_rwx("tor0: last dword", 1, 0, 1);
        acc(64'hFC,  4, 2'b01);  expect_rwx("tor0: last word", 1, 0, 1);
        acc(64'hFC,  8, 2'b01);  expect_rwx("tor0: spills over the top: partial, fails", 0, 0, 0);
        acc(64'h100, 4, 2'b01);  expect_rwx("tor0: just above", 0, 0, 0);
        acc(64'hFC,  8, 2'b11);  expect_rwx("tor0: partial overlap fails in M too", 0, 0, 0);

        // TOR region 1 above it: [0x100, 0x200) read+write
        cfg[15:8] = cfgb(0, A_TOR, 0, 1, 1);  pa1 = 64'h200 >> 2;
        acc(64'h100, 8, 2'b01);  expect_rwx("tor1: bottom", 1, 1, 0);
        acc(64'hFC,  8, 2'b01);  expect_rwx("tor1: straddles tor0/tor1: tor0 decides, partial", 0, 0, 0);
        acc(64'hFC,  8, 2'b11);  expect_rwx("tor1: straddles tor0/tor1, M: fails", 0, 0, 0);
        acc(64'h1F8, 8, 2'b00);  expect_rwx("tor1: top, U", 1, 1, 0);

        // NA4 at 0x300: a 4-byte access fits, a fetch span of 8 never does
        cfg[23:16] = cfgb(0, A_NA4, 1, 1, 1);  pa2 = 64'h300 >> 2;
        acc(64'h300, 4, 2'b01);  expect_rwx("na4: the word", 1, 1, 1);
        acc(64'h300, 1, 2'b01);  expect_rwx("na4: a byte in it", 1, 1, 1);
        acc(64'h300, 8, 2'b01);  expect_rwx("na4: an 8-byte span never fits", 0, 0, 0);
        acc(64'h300, 8, 2'b11);  expect_rwx("na4: an 8-byte span, M: fails too", 0, 0, 0);
        acc(64'h2FC, 8, 2'b11);  expect_rwx("na4: a dword ending in it, M: fails", 0, 0, 0);
        acc(64'h302, 2, 2'b01);  expect_rwx("na4: a parcel in it", 1, 1, 1);
        acc(64'h304, 4, 2'b01);  expect_rwx("na4: the next word", 0, 0, 0);
        acc(64'h2FE, 4, 2'b01);  expect_rwx("na4: straddling its start", 0, 0, 0);

        // NAPOT 64 bytes at 0x400 (pmpaddr = 0x400>>2 | 0x7), read-only
        cfg[31:24] = cfgb(0, A_NAPOT, 0, 0, 1);  pa3 = (64'h400 >> 2) | 64'h7;
        acc(64'h400, 8, 2'b01);  expect_rwx("napot: start", 1, 0, 0);
        acc(64'h438, 8, 2'b01);  expect_rwx("napot: last dword", 1, 0, 0);
        acc(64'h43C, 8, 2'b01);  expect_rwx("napot: spills over: partial, fails", 0, 0, 0);
        acc(64'h3F8, 8, 2'b01);  expect_rwx("napot: below, no match", 0, 0, 0);
        // an address above bit 55 never matches a NAPOT region
        acc(64'h0100_0000_0000_0400, 8, 2'b01);  expect_rwx("napot: bit 56 set", 0, 0, 0);

        // lowest matching region wins, even when a later one would allow
        cfg = '0;
        cfg[7:0]   = cfgb(0, A_NAPOT, 0, 0, 0);  pa0 = (64'h0 >> 2) | 64'h1FF;   // [0, 4 KiB) no permission
        cfg[15:8]  = cfgb(0, A_NAPOT, 1, 1, 1);  pa1 = (64'h0 >> 2) | 64'h3FF;   // [0, 8 KiB) all
        acc(64'h10,   8, 2'b01);  expect_rwx("priority: region 0 (none) beats region 1 (all)", 0, 0, 0);
        acc(64'h1800, 8, 2'b01);  expect_rwx("priority: only region 1 contains it", 1, 1, 1);
        acc(64'h10,   8, 2'b11);  expect_rwx("priority: unlocked region never denies M", 1, 1, 1);
        cfg[7] = 1'b1;                                                         // lock region 0
        acc(64'h10,   8, 2'b11);  expect_rwx("priority: a locked region denies M", 0, 0, 0);
        acc(64'h1800, 8, 2'b11);  expect_rwx("priority: M outside the locked region, matched by an unlocked one", 1, 1, 1);
        acc(64'h10,   8, 2'b10);  expect_rwx("privilege 2 is checked like S/U", 0, 0, 0);
        cfg[7:0]  = cfgb(1, A_NAPOT, 1, 0, 1);                                // locked, read+execute
        acc(64'h10,   8, 2'b11);  expect_rwx("locked region's own permissions apply to M", 1, 0, 1);

        // the lowest region touching the access decides even when a later one holds it whole
        cfg = '0;
        cfg[7:0]   = cfgb(0, A_NA4, 1, 1, 1);    pa0 = 64'h1004 >> 2;           // [0x1004, 0x1007] all
        cfg[15:8]  = cfgb(0, A_NAPOT, 1, 1, 1);  pa1 = (64'h0 >> 2) | 64'h3FF;   // [0, 8 KiB) all
        acc(64'h1000, 8, 2'b01);  expect_rwx("partial in region 0, whole in region 1: fails", 0, 0, 0);
        acc(64'h1000, 4, 2'b01);  expect_rwx("beside region 0, whole in region 1", 1, 1, 1);
        acc(64'h1004, 4, 2'b01);  expect_rwx("whole in region 0", 1, 1, 1);
        // an empty TOR region (bottom not below top) holds nothing
        cfg = '0;
        cfg[7:0]   = cfgb(0, A_NAPOT, 1, 1, 1);  pa0 = 64'h3FF;                  // [0, 8 KiB) all
        cfg[15:8]  = cfgb(1, A_TOR, 0, 0, 0);    pa1 = 64'h3FF;                  // [0x...1FF8, 0x...1FF8): empty
        acc(64'h10,   8, 2'b01);  expect_rwx("region 0 decides before an empty TOR", 1, 1, 1);
        cfg[7:0]   = cfgb(0, A_OFF, 0, 0, 0);
        acc(64'h10,   8, 2'b01);  expect_rwx("an empty TOR region matches nothing, S", 0, 0, 0);
        acc(64'h10,   8, 2'b11);  expect_rwx("an empty TOR region matches nothing, M", 1, 1, 1);

        // L only matters at M: it does not give S/U anything
        cfg = '0;
        cfg[7:0] = cfgb(1, A_NAPOT, 1, 1, 1); pa0 = 64'h1FF;
        acc(64'h10, 8, 2'b01);  expect_rwx("locked rwx, S", 1, 1, 1);
        acc(64'h10, 8, 2'b11);  expect_rwx("locked rwx, M", 1, 1, 1);

        // pmpaddr all ones: the whole low 2^56
        cfg = '0;
        cfg[7:0] = cfgb(0, A_NAPOT, 1, 1, 1); pa0 = 64'h003F_FFFF_FFFF_FFFF;
        acc(64'h0000_0000_1234_5678, 8, 2'b01);  expect_rwx("napot all ones: low", 1, 1, 1);
        acc(64'h00FF_FFFF_FFFF_FFF0, 8, 2'b01);  expect_rwx("napot all ones: top of 2^56", 1, 1, 1);

        // ------------------------------------------------ random ------------------------------------------------
        for (int it = 0; it < 200000; it++) begin
            logic [63:0] a;
            int          sz;
            random_config();
            reroll();
            // an address around a region edge more often than not
            case (r1[2:0])
                0: a = {58'b0, r2[5:0]};
                1: a = {50'b0, r2[13:0]};
                2: a = {54'b0, pa0[7:0], 2'b0} + 64'(r3[3:0]) - 64'd8;
                3: a = {54'b0, pa1[7:0], 2'b0} + 64'(r3[3:0]) - 64'd8;
                4: a = {54'b0, pa2[7:0], 2'b0} + 64'(r3[3:0]) - 64'd8;
                5: a = {54'b0, pa3[7:0], 2'b0} + 64'(r3[3:0]) - 64'd8;
                6: a = {r4[7:0], 48'b0} | {32'b0, r5};
                default: a = {32'b0, r5};
            endcase
            case (r6[2:0])
                0: sz = 1; 1: sz = 2; 2: sz = 4; 3: sz = 8; 4: sz = 16; default: sz = 8;
            endcase
            acc(a, sz, r7[1:0]);
            model(addr, endb, priv, mr, mw, mx);
            if ({r_ok, w_ok, x_ok} !== {mr, mw, mx}) begin
                mismatches++;
                if (mismatches <= 10)
                    $display("MISMATCH cfg=%h pa=%h/%h/%h/%h addr=%h end=%h priv=%0d: dut rwx=%b%b%b model=%b%b%b",
                             cfg[31:0], pa0, pa1, pa2, pa3, addr, endb, priv, r_ok, w_ok, x_ok, mr, mw, mx);
            end
            if (mr !== mw || mw !== mx) n_hits_rw++;
        end
        check("random sweep: no mismatches against the model", 64'(mismatches), 64'd0);
        check("random sweep: some cases had differing permissions (the sweep is not vacuous)", b(n_hits_rw > 1000), 64'd1);

        $display("");
        $display("qv_pmp_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_pmp_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT: qv_pmp_tb");
        $finish;
    end
endmodule
