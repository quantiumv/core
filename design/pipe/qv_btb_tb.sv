// SPDX-License-Identifier: MIT

/*
 * qv_btb_tb -- design/pipe/qv_btb.sv against a model of its own contract.
 *
 * Directed: a taken branch is found by a lookup of its dword, at or before its halfword and not after it (the
 * entry names where the branch is; a request that starts later in the dword has passed it); a not-taken update
 * removes the entry only if it is that branch's own; a second taken branch in the same dword replaces the first; two
 * dwords that map to the same entry replace each other, and the tag tells them apart; a crossing 32-bit branch (the
 * last halfword of a dword) is filed under the next dword at halfword 0 with the crossing flag, and its not-taken
 * update removes that entry only.
 *
 * Random: updates and lookups at random against a model that keeps one record per index.
 */
module qv_btb_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int ENTRIES = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [63:0] lk_pc = '0;
    logic        hit, x;
    logic [1:0]  off;
    logic [63:0] tgt;
    logic        upd_valid = 1'b0, upd_taken = 1'b0, upd_cross = 1'b0;
    logic [63:0] upd_pc = '0, upd_tgt = '0;

    qv_btb #(.ENTRIES(ENTRIES)) dut (
        .clk(clk), .rst(rst),
        .i_lk_pc(lk_pc), .o_hit(hit), .o_off(off), .o_x(x), .o_tgt(tgt),
        .i_upd_valid(upd_valid), .i_upd_pc(upd_pc), .i_upd_taken(upd_taken), .i_upd_cross(upd_cross), .i_upd_tgt(upd_tgt)
    );

    // ---------------- model ----------------
    logic        m_v   [0:ENTRIES-1];
    logic [63:0] m_tag [0:ENTRIES-1];
    logic [1:0]  m_off [0:ENTRIES-1];
    logic        m_x   [0:ENTRIES-1];
    logic [63:0] m_tgt [0:ENTRIES-1];

    task automatic m_reset();
        for (int i = 0; i < ENTRIES; i++) m_v[i] = 1'b0;
    endtask

    task automatic m_update(input logic [63:0] pc, input logic taken, input logic xing, input logic [63:0] t);
        logic [63:0] key;
        int idx;
        key = xing ? pc + 64'd2 : pc;
        idx = int'(key[3 +: $clog2(ENTRIES)]);
        if (taken) begin
            m_v[idx] = 1'b1; m_tag[idx] = {key[63:3], 3'b000}; m_off[idx] = key[2:1]; m_x[idx] = xing; m_tgt[idx] = t;
        end else if (m_v[idx] && m_tag[idx] == {key[63:3], 3'b000} && m_off[idx] == key[2:1] && m_x[idx] == xing) begin
            m_v[idx] = 1'b0;
        end
    endtask

    function automatic logic m_hit(input logic [63:0] pc);
        int idx;
        idx = int'(pc[3 +: $clog2(ENTRIES)]);
        return m_v[idx] && m_tag[idx] == {pc[63:3], 3'b000} && m_off[idx] >= pc[2:1];
    endfunction

    task automatic check_lookup(input string name, input logic [63:0] pc);
        int idx;
        lk_pc = pc;
        #1;
        idx = int'(pc[3 +: $clog2(ENTRIES)]);
        check({name, ": hit"}, {63'b0, hit}, {63'b0, m_hit(pc)});
        if (m_hit(pc)) begin
            check({name, ": halfword"}, {62'b0, off}, {62'b0, m_off[idx]});
            check({name, ": crossing flag"}, {63'b0, x}, {63'b0, m_x[idx]});
            check({name, ": target"}, tgt, m_tgt[idx]);
        end
    endtask

    task automatic update(input logic [63:0] pc, input logic taken, input logic xing, input logic [63:0] t);
        @(negedge clk);
        upd_valid = 1'b1; upd_pc = pc; upd_taken = taken; upd_cross = xing; upd_tgt = t;
        @(posedge clk); #1;
        upd_valid = 1'b0;
        m_update(pc, taken, xing, t);
    endtask

    int errs0;
    initial begin
        m_reset();
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        check_lookup("empty", 64'h100);

        // a taken branch at halfword 2 of dword 0x100
        update(64'h104, 1'b1, 1'b0, 64'h200);
        check_lookup("lookup from the dword start", 64'h100);
        check_lookup("lookup from halfword 1", 64'h102);
        check_lookup("lookup from the branch's own halfword", 64'h104);
        check_lookup("lookup past the branch", 64'h106);
        check_lookup("other dword", 64'h108);
        lk_pc = 64'h100; #1;
        check("halfword 2 is named", {62'b0, off}, 64'd2);
        check("target", tgt, 64'h200);
        check("not a crossing branch", {63'b0, x}, 64'd0);

        // a second taken branch in the same dword replaces it
        update(64'h102, 1'b1, 1'b0, 64'h300);
        lk_pc = 64'h100; #1;
        check("replaced: halfword", {62'b0, off}, 64'd1);
        check("replaced: target", tgt, 64'h300);

        // a not-taken update of another branch of the dword leaves the entry
        update(64'h106, 1'b0, 1'b0, 64'h0);
        check_lookup("other branch not taken: entry stays", 64'h100);
        // its own removes it
        update(64'h102, 1'b0, 1'b0, 64'h0);
        check_lookup("own branch not taken: entry gone", 64'h100);

        // aliasing: 0x100 and 0x100 + 8 * ENTRIES share an entry, the tag tells them apart
        update(64'h100, 1'b1, 1'b0, 64'h400);
        check_lookup("before the alias", 64'h100);
        check_lookup("the alias is not a hit", 64'h100 + 64'(8 * ENTRIES));
        update(64'h100 + 64'(8 * ENTRIES), 1'b1, 1'b0, 64'h500);
        check_lookup("the alias replaced it", 64'h100 + 64'(8 * ENTRIES));
        check_lookup("the first one is gone", 64'h100);
        // not taken at the old address does not remove the new owner
        update(64'h100, 1'b0, 1'b0, 64'h0);
        check_lookup("a different dword's not-taken update leaves the owner", 64'h100 + 64'(8 * ENTRIES));

        // a crossing branch: starts at halfword 3 of 0x218, filed under 0x220 at halfword 0
        update(64'h21E, 1'b1, 1'b1, 64'h900);
        check_lookup("crossing: not found under its own dword", 64'h218);
        lk_pc = 64'h220; #1;
        check("crossing: found under the next dword", {63'b0, hit}, 64'd1);
        check("crossing: halfword 0", {62'b0, off}, 64'd0);
        check("crossing: flag", {63'b0, x}, 64'd1);
        check("crossing: target", tgt, 64'h900);
        check_lookup("crossing: a request that starts at halfword 1 has passed it", 64'h222);
        // a non-crossing not-taken update at that dword's halfword 0 is not the same branch
        update(64'h220, 1'b0, 1'b0, 64'h0);
        check_lookup("crossing: a plain branch's not-taken update leaves it", 64'h220);
        update(64'h21E, 1'b0, 1'b1, 64'h0);
        check_lookup("crossing: its own not-taken update removes it", 64'h220);

        // random against the model
        m_reset();
        rst = 1'b1; repeat (2) @(posedge clk); #1 rst = 1'b0;
        errs0 = fail_count;
        for (int i = 0; i < 4000; i++) begin
            logic [63:0] pc;
            logic [1:0] r;
            pc = 64'h1000 + 64'((($urandom % 4) * 64) + (($urandom % 8) * 8) + (($urandom % 4) * 2));
            r = 2'($urandom);
            if (($urandom % 3) != 0) begin
                logic cr;
                cr = (pc[2:1] == 2'b11) && (($urandom % 2) == 0);
                update(pc, r != 2'd0, cr, 64'(($urandom % 512) * 2));
            end
            check_lookup("random", 64'h1000 + 64'((($urandom % 4) * 64) + (($urandom % 8) * 8) + (($urandom % 4) * 2)));
        end
        check("random run: no mismatch", 64'(fail_count - errs0), 64'd0);

        $display("");
        $display("qv_btb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_btb_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
