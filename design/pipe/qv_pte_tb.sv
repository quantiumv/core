// SPDX-License-Identifier: MIT

/*
 * qv_pte_tb -- standalone test for design/pipe/qv_pte.sv.
 *
 * Directed cases pin every rule ref_core.sv has, the odd ones included: a
 * pointer with a reserved bit is malformed too, a pointer at level 0
 * faults, a non-canonical address faults on whatever PTE it meets, a user
 * page is for U (and for S only with SUM, and only for data), privilege
 * 2'b10 is neither U nor S, a fetch is never SUM-aware, MXR lets a load
 * read an execute-only page but never lets a store write one, a clear A
 * always faults and a clear D faults only a data write, a superpage
 * leaf must be aligned, and the translated address of a superpage takes
 * its low page-number segments from the virtual address.
 *
 * Then a randomized sweep against a model written differently: the rules
 * as one sequential list on full-width values, the address built with
 * masks on a 56-bit number instead of three page-number segments.
 */
module qv_pte_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic [63:0] pte = '0, va = '0;
    logic [1:0]  level = 2'd0, priv = 2'b01;
    logic        is_mem = 1'b1, wr = 1'b0, sum = 1'b0, mxr = 1'b0;
    logic        leaf, fault;
    logic [43:0] ppn, next_ppn;

    qv_pte dut (
        .i_pte(pte), .i_va(va), .i_level(level), .i_is_mem(is_mem), .i_wr(wr), .i_priv(priv), .i_sum(sum), .i_mxr(mxr),
        .o_leaf(leaf), .o_fault(fault), .o_ppn(ppn), .o_next_ppn(next_ppn)
    );

    localparam logic [7:0] V = 8'h01, R = 8'h02, W = 8'h04, X = 8'h08, U = 8'h10, A = 8'h40, D = 8'h80;
    localparam logic [1:0] PU = 2'b00, PS = 2'b01, P2 = 2'b10, PM = 2'b11;

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // a PTE: ppn2, ppn1, ppn0 and the low flag byte
    function automatic logic [63:0] mkpte(input logic [25:0] p2, input logic [8:0] p1, input logic [8:0] p0, input logic [7:0] f);
        return {10'b0, p2, p1, p0, 2'b00, f};
    endfunction

    task automatic cfg(input logic [63:0] t, input logic [63:0] v, input logic [1:0] l, input logic mem, input logic w_,
                       input logic [1:0] p, input logic s, input logic m);
        pte = t; va = v; level = l; is_mem = mem; wr = w_; priv = p; sum = s; mxr = m;
        #1;
    endtask

    task automatic expect_fault(input string name, input logic f);
        check({name, ": fault"}, b(fault), b(f));
    endtask

    // ---------------- the model ----------------
    task automatic model(output logic m_leaf, output logic m_fault, output logic [55:0] m_pa, output logic [43:0] m_next);
        logic [43:0] full_ppn;
        logic [55:0] mask;
        logic        canonical;
        begin
            m_fault  = 1'b0;
            m_leaf   = pte[1] | pte[3];
            full_ppn = pte[53:10];
            m_next   = full_ppn;
            canonical = 1'b1;
            for (int i = 39; i < 64; i++) if (va[i] !== va[38]) canonical = 1'b0;
            if (!canonical) m_fault = 1'b1;
            if (!pte[0]) m_fault = 1'b1;
            if (!pte[1] && pte[2]) m_fault = 1'b1;
            if (pte[60:54] != 7'd0 || pte[62:61] != 2'd0 || pte[63]) m_fault = 1'b1;
            if (m_leaf) begin
                if (level == 2'd2 && (full_ppn & 44'h3FFFF) != 44'd0) m_fault = 1'b1;
                if (level == 2'd1 && (full_ppn & 44'h001FF) != 44'd0) m_fault = 1'b1;
                if (is_mem) begin
                    if (pte[4]) begin
                        if (!(priv == PU || (priv == PS && sum))) m_fault = 1'b1;
                    end else begin
                        if (priv == PU) m_fault = 1'b1;
                    end
                    if (wr) begin
                        if (!pte[2]) m_fault = 1'b1;
                    end else begin
                        if (!(pte[1] || (mxr && pte[3]))) m_fault = 1'b1;
                    end
                    if (wr && !pte[7]) m_fault = 1'b1;
                end else begin
                    if (pte[4]) begin
                        if (priv == PS) m_fault = 1'b1;
                    end else begin
                        if (priv == PU) m_fault = 1'b1;
                    end
                    if (!pte[3]) m_fault = 1'b1;
                end
                if (!pte[6]) m_fault = 1'b1;
            end else begin
                if (level == 2'd0) m_fault = 1'b1;
            end
            // the address of a leaf: the PTE's page number, with the low segments of a superpage replaced by the VA's
            mask = (level == 2'd2) ? 56'h3FFFFFFF : (level == 2'd1) ? 56'h1FFFFF : 56'hFFF;
            m_pa = (({12'b0, full_ppn} << 12) & ~mask) | ({16'b0, va[39:0]} & mask);
        end
    endtask

    logic        m_leaf, m_fault;
    logic [55:0] m_pa;
    logic [43:0] m_next;

    // ---------------- the sweep ----------------
    int mismatches = 0, n_sweep = 0, n_fault = 0, n_ok_leaf = 0, n_pointer_ok = 0;

    function automatic logic [31:0] rnd();
        return $urandom;
    endfunction

    task automatic random_case;
        logic [31:0] r1, r2, r3, r4, r5, r6;
        logic [7:0]  f;
        logic [25:0] p2;
        logic [8:0]  p1, p0;
        logic [63:0] t, v;
        logic [1:0]  lv;
        begin
            r1 = rnd(); r2 = rnd(); r3 = rnd(); r4 = rnd(); r5 = rnd(); r6 = rnd();
            f  = r1[7:0];
            if (r2[3:0] != 4'd0) f[0] = 1'b1;                    // mostly valid
            if (r2[7:4] < 4'd10) f[6] = 1'b1;                    // mostly accessed
            lv = (r3[1:0] == 2'd3) ? 2'd2 : r3[1:0];
            p2 = {r4[25:0]};
            p1 = r5[8:0];
            p0 = r5[17:9];
            if (r3[3:2] != 2'd0) begin                           // mostly aligned superpages
                if (lv == 2'd2) begin p1 = 9'd0; p0 = 9'd0; end
                if (lv == 2'd1) begin p0 = 9'd0; end
            end
            t = mkpte(p2, p1, p0, f);
            if (r6[4:0] == 5'd0) t[60:54] = r6[11:5] | 7'd1;     // a reserved bit now and then
            if (r6[9:5] == 5'd0) t[62:61] = r6[13:12] | 2'd1;
            if (r6[14:10] == 5'd0) t[63] = 1'b1;
            v = {r4, r5};
            v[63:39] = v[38] ? 25'h1FFFFFF : 25'h0;              // canonical
            if (r6[20:16] == 5'd0) v[63:39] = r6[31:7] | 25'd1;  // now and then not
            cfg(t, v, lv, r3[4], r3[5], r3[7:6], r3[8], r3[9]);
            model(m_leaf, m_fault, m_pa, m_next);
            n_sweep++;
            if (m_fault) n_fault++;
            if (m_leaf && !m_fault) n_ok_leaf++;
            if (!m_leaf && !m_fault) n_pointer_ok++;
            if (leaf !== m_leaf || fault !== m_fault || next_ppn !== m_next || (m_leaf && !m_fault && {ppn, va[11:0]} !== m_pa[55:0])) begin
                mismatches++;
                if (mismatches <= 10)
                    $display("MISMATCH pte=%h va=%h level=%0d mem=%b wr=%b priv=%0d sum=%b mxr=%b: dut leaf=%b fault=%b pa=%h next=%h model leaf=%b fault=%b pa=%h next=%h",
                             pte, va, level, is_mem, wr, priv, sum, mxr, leaf, fault, {ppn, va[11:0]}, next_ppn, m_leaf, m_fault, m_pa, m_next);
            end
        end
    endtask

    initial begin
        // ---------------- directed ----------------
        // a plain 4 KB leaf, read/write, accessed and dirty, for S: no fault; the address is the PTE's ppn
        cfg(mkpte(26'h123, 9'h45, 9'h67, V|R|W|A|D), 64'h0000_0000_0040_2ABC, 2'd0, 1'b1, 1'b1, PS, 1'b0, 1'b0);
        expect_fault("S store to a RW AD page", 1'b0);
        check("it is a leaf", b(leaf), 64'd1);
        check("4 KB address: ppn2:ppn1:ppn0 from the PTE", {20'b0, ppn}, {18'b0, 26'h123, 9'h45, 9'h67});

        // a pointer: not a leaf, no fault at level 2 and 1, a fault at level 0; the next table is its page number
        cfg(mkpte(26'h7, 9'h8, 9'h9, V), 64'h0, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        check("pointer: not a leaf", b(leaf), 64'd0);
        expect_fault("pointer at level 2", 1'b0);
        check("pointer: next table = the PTE's page number", {20'b0, next_ppn}, {18'b0, 26'h7, 9'h8, 9'h9});
        cfg(mkpte(26'h7, 9'h8, 9'h9, V), 64'h0, 2'd1, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("pointer at level 1", 1'b0);
        cfg(mkpte(26'h7, 9'h8, 9'h9, V), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("pointer at level 0 (no level left)", 1'b1);

        // malformed
        cfg(mkpte(26'h1, 9'h0, 9'h0, R|W|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("V clear", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|W|A|D), 64'h0, 2'd0, 1'b1, 1'b1, PS, 1'b0, 1'b0);
        expect_fault("W without R", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A) | (64'd1 << 54), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("reserved bit 54 on a leaf", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V) | (64'd1 << 60), 64'h0, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("reserved bit 60 on a pointer", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A) | (64'd1 << 61), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("PBMT bit 61", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A) | (64'd1 << 62), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("PBMT bit 62", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A) | (64'd1 << 63), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("N bit", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A|8'h20 | 8'h01), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("G bit is ignored", 1'b0);

        // superpages: alignment, and the address takes the VA's low segments
        cfg(mkpte(26'h5, 9'h0, 9'h1, V|R|W|A|D), 64'h0, 2'd1, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("megapage with ppn0 != 0", 1'b1);
        cfg(mkpte(26'h5, 9'h1, 9'h0, V|R|W|A|D), 64'h0, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("gigapage with ppn1 != 0", 1'b1);
        cfg(mkpte(26'h5, 9'h0, 9'h1, V|R|W|A|D), 64'h0, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("gigapage with ppn0 != 0", 1'b1);
        cfg(mkpte(26'h5, 9'h1, 9'h0, V|R|W|A|D), 64'h0, 2'd1, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("megapage with ppn1 != 0 is fine", 1'b0);
        cfg(mkpte(26'h5, 9'h0, 9'h0, V|R|W|A|D), {25'b0, 9'h0, 9'h1AB, 9'h0CD, 12'h123} & 64'h7FFF_FFFF_FFFF, 2'd1, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        check("megapage address: ppn2 from the PTE, ppn1 = ppn1 from the PTE, ppn0 = vpn0",
              {20'b0, ppn}, {18'b0, 26'h5, 9'h0, 9'h0CD});
        cfg(mkpte(26'h5, 9'h0, 9'h0, V|R|W|A|D), {25'b0, 9'h0, 9'h1AB, 9'h0CD, 12'h123} & 64'h7FFF_FFFF_FFFF, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        check("gigapage address: ppn2 from the PTE, ppn1 = vpn1, ppn0 = vpn0",
              {20'b0, ppn}, {18'b0, 26'h5, 9'h1AB, 9'h0CD});

        // canonical addresses
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0000_0040_0000_0000, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("bit 38 set, upper bits clear", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0000_0080_0000_0000, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("bit 39 set", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'hFFFF_FFC0_0000_0000, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("negative canonical address is fine", 1'b0);
        cfg(mkpte(26'h7, 9'h8, 9'h9, V), 64'h0000_0080_0000_0000, 2'd2, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("non-canonical address on a pointer", 1'b1);

        // privilege and the U bit
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PU, 1'b0, 1'b0);
        expect_fault("U load from a non-U page", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PU, 1'b0, 1'b0);
        expect_fault("U load from a U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("S load from a U page without SUM", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b1, 1'b0);
        expect_fault("S load from a U page with SUM", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b1, PS, 1'b1, 1'b0);
        expect_fault("S store to a U page with SUM", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|U|A), 64'h0, 2'd0, 1'b0, 1'b0, PS, 1'b1, 1'b0);
        expect_fault("S fetch from a U page, SUM set: never", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|U|A), 64'h0, 2'd0, 1'b0, 1'b0, PU, 1'b0, 1'b0);
        expect_fault("U fetch from a U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|A), 64'h0, 2'd0, 1'b0, 1'b0, PU, 1'b0, 1'b0);
        expect_fault("U fetch from a non-U page", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|A), 64'h0, 2'd0, 1'b0, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("S fetch from a non-U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0, 2'd0, 1'b1, 1'b0, P2, 1'b0, 1'b0);
        expect_fault("privilege 2 on a non-U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b0, P2, 1'b1, 1'b0);
        expect_fault("privilege 2 on a U page, data: neither U nor S", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|U|A), 64'h0, 2'd0, 1'b0, 1'b0, P2, 1'b0, 1'b0);
        expect_fault("privilege 2 fetching from a U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PM, 1'b0, 1'b0);
        expect_fault("M on a non-U page", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|U|A|D), 64'h0, 2'd0, 1'b1, 1'b0, PM, 1'b1, 1'b0);
        expect_fault("M on a U page, data: the U rule has no M case", 1'b1);

        // permissions
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|X|A), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("load from an execute-only page", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|X|A), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b1);
        expect_fault("load from an execute-only page with MXR", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|X|A|D), 64'h0, 2'd0, 1'b1, 1'b1, PS, 1'b0, 1'b1);
        expect_fault("store to an execute-only page: MXR does not help", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|A), 64'h0, 2'd0, 1'b1, 1'b1, PS, 1'b0, 1'b0);
        expect_fault("store to a read-only page", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A|D), 64'h0, 2'd0, 1'b0, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("fetch from a non-executable page", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|A), 64'h0, 2'd0, 1'b0, 1'b1, PS, 1'b0, 1'b0);
        expect_fault("i_wr means nothing for a fetch", 1'b0);

        // A and D
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|D), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("A clear: a load faults", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X), 64'h0, 2'd0, 1'b0, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("A clear: a fetch faults", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A), 64'h0, 2'd0, 1'b1, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("D clear: a load is fine", 1'b0);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|W|A), 64'h0, 2'd0, 1'b1, 1'b1, PS, 1'b0, 1'b0);
        expect_fault("D clear: a store faults", 1'b1);
        cfg(mkpte(26'h1, 9'h0, 9'h0, V|R|X|A), 64'h0, 2'd0, 1'b0, 1'b0, PS, 1'b0, 1'b0);
        expect_fault("D clear: a fetch is fine", 1'b0);

        // ---------------- randomized ----------------
        for (int i = 0; i < 200000; i++) random_case();
        check("random sweep: no mismatches against the model", 64'(mismatches), 64'd0);
        check("random sweep: plenty of faulting cases", b(n_fault > 20000), 64'd1);
        check("random sweep: plenty of clean leaves", b(n_ok_leaf > 5000), 64'd1);
        check("random sweep: plenty of clean pointers", b(n_pointer_ok > 2000), 64'd1);

        $display("");
        $display("qv_pte_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_pte_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT: qv_pte_tb");
        $finish;
    end
endmodule
