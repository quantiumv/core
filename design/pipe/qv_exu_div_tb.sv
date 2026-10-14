// SPDX-License-Identifier: MIT

/*
 * qv_exu_div_tb -- standalone test for design/pipe/qv_exu_div.sv.
 *
 * All eight divide/remainder operations against a golden model written
 * straight from the M-extension spec (division by zero, INT_MIN / -1,
 * every operand sign combination, the W forms with junk in the upper
 * halves), directed first and then random. Also the unit's own contract:
 * the writeback is a single one-cycle pulse carrying the request's tag, a
 * fixed 65 edges after the accepting one; o_free is low from acceptance
 * through the pulse; a request offered while busy is ignored; ignored op
 * bits really are ignored.
 *
 * And the point of the unit being killable: a flush at every interesting
 * moment -- in the accepting cycle, just after, mid-divide, in the cycle
 * the divider finishes, in the pulse cycle itself, just after it -- must
 * leave no writeback behind (a dead instruction's result would complete
 * whatever owns its ROB tag by then), free the unit at once, and leave it
 * able to divide correctly next.
 */
module qv_exu_div_tb;
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic    flush = 1'b0;
    fu_req_t req   = '0;
    logic    free;
    wb_t     wb;

    qv_exu_div dut (.clk(clk), .rst(rst), .i_flush(flush), .i_req(req), .o_free(free), .o_wb(wb));

    // ---------------- golden model ----------------
    localparam logic [63:0] MIN64 = 64'h8000_0000_0000_0000;

    function automatic logic [63:0] sx32(input logic [63:0] x); return {{32{x[31]}}, x[31:0]}; endfunction
    function automatic logic [63:0] zx32(input logic [63:0] x); return {32'b0, x[31:0]}; endfunction

    // op = {quotient, signed}
    function automatic logic [63:0] golden(input logic quot, input logic sgn, input logic word,
                                           input logic [63:0] a, input logic [63:0] b);
        logic [63:0] x, y, q, r, res;
        x = !word ? a : sgn ? sx32(a) : zx32(a);
        y = !word ? b : sgn ? sx32(b) : zx32(b);
        if (y == 64'd0) begin
            q = '1;
            r = x;
        end else if (sgn && x == MIN64 && y == '1) begin
            q = x;
            r = 64'd0;
        end else if (sgn) begin
            q = 64'($signed(x) / $signed(y));
            r = 64'($signed(x) % $signed(y));
        end else begin
            q = x / y;
            r = x % y;
        end
        res = quot ? q : r;
        return word ? sx32(res) : res;
    endfunction

    function automatic string op_name(input logic quot, input logic sgn, input logic word);
        return {quot ? "DIV" : "REM", sgn ? "" : "U", word ? "W" : ""};
    endfunction

    // ---------------- writeback monitor ----------------
    int          pulses;                  // cycles with wb.valid, sampled at each edge
    logic [63:0] last_value;
    logic [QV_ROB_TAG_W-1:0] last_tag;
    always @(posedge clk) begin
        if (wb.valid) begin
            pulses     <= pulses + 1;
            last_value <= wb.value;
            last_tag   <= wb.tag;
        end
    end

    function automatic fu_req_t mk(input logic quot, input logic sgn, input logic word,
                                   input logic [63:0] a, input logic [63:0] b,
                                   input logic [QV_ROB_TAG_W-1:0] tag, input logic [2:0] junk = 3'b000);
        fu_req_t r;
        r         = '0;
        r.valid   = 1'b1;
        r.tag     = tag;
        r.op      = {junk, quot, sgn};
        r.is_word = word;
        r.a       = a;
        r.b       = b;
        r.pc      = 64'hDEAD_0000;     // none of these matter to a divide
        r.imm     = 64'h1234;
        r.rvc     = junk[0];
        r.pred_next = 64'h5678;
        return r;
    endfunction

    // one clean divide, request presented for exactly one cycle
    int n_tag = 0;
    task automatic divide(input string name, input logic quot, input logic sgn, input logic word,
                          input logic [63:0] a, input logic [63:0] b, input logic [2:0] junk = 3'b000);
        logic [QV_ROB_TAG_W-1:0] tag;
        int lat, waited;
        tag = QV_ROB_TAG_W'(n_tag++);
        while (!free) @(posedge clk);                     // (only after a test that left it busy)
        @(negedge clk);
        pulses = 0;
        req = mk(quot, sgn, word, a, b, tag, junk);
        @(posedge clk); #1;                               // the accepting edge
        req = '0;
        check({name, ": busy after accept"}, {63'b0, free}, 64'd0);
        lat = 0; waited = 0;
        while (!wb.valid && waited < 200) begin
            @(posedge clk); #1;
            lat++; waited++;
        end
        check({name, ": result arrives"}, {63'b0, wb.valid}, 64'd1);
        check({name, ": latency (edges after accept)"}, 64'(lat), 64'd65);
        check({name, ": tag"}, {60'b0, wb.tag}, {60'b0, tag});
        check({name, ": value"}, wb.value, golden(quot, sgn, word, a, b));
        check({name, ": still busy in the pulse cycle"}, {63'b0, free}, 64'd0);
        check({name, ": no redirect"}, {63'b0, wb.mispredict}, 64'd0);
        @(posedge clk); #1;
        check({name, ": single-cycle pulse"}, {63'b0, wb.valid}, 64'd0);
        check({name, ": free again"}, {63'b0, free}, 64'd1);
    endtask

    // ---------------- directed operand values ----------------
    localparam int NV = 14;
    logic [63:0] vals [0:NV-1] = '{
        64'd0, 64'd1, 64'hFFFF_FFFF_FFFF_FFFF, 64'd2, 64'd7, 64'hFFFF_FFFF_FFFF_FFF9,
        MIN64, 64'h7FFF_FFFF_FFFF_FFFF, 64'h0000_0000_8000_0000, 64'h0000_0000_7FFF_FFFF,
        64'h0000_0000_FFFF_FFFF, 64'hFFFF_FFFF_8000_0000, 64'hDEAD_BEEF_0000_0003, 64'h1234_5678_FFFF_FFFF
    };

    // ---------------- flush at a chosen moment ----------------
    // k = 0: flush in the accepting cycle itself; k >= 1: flush in the cycle
    // ending at the k-th edge after the accepting one. The divider's pulse
    // is the cycle ending at edge 66 (visible after edge 65).
    task automatic kill_at(input int k);
        logic [QV_ROB_TAG_W-1:0] tag;
        int saw_valid_with_flush;
        tag = QV_ROB_TAG_W'(n_tag++);
        saw_valid_with_flush = 0;
        while (!free) @(posedge clk);
        @(negedge clk);
        pulses = 0;
        req = mk(1'b1, 1'b1, 1'b0, 64'd100, 64'd7, tag);
        if (k == 0) flush = 1'b1;
        @(posedge clk); #1;
        req = '0; flush = 1'b0;
        for (int j = 1; j <= 100; j++) begin
            @(negedge clk);
            flush = (j == k);
            #1;
            if (flush && wb.valid) saw_valid_with_flush++;
            @(posedge clk); #1;
            flush = 1'b0;
            if (j == k) begin
                check($sformatf("kill@%0d: free right after the flush", k), {63'b0, free}, 64'd1);
            end
        end
        check($sformatf("kill@%0d: no writeback while flushing", k), 64'(saw_valid_with_flush), 64'd0);
        // a flush after the pulse (k >= 67) comes too late to stop it; any earlier one must
        check($sformatf("kill@%0d: writeback pulses", k), 64'(pulses), (k >= 67) ? 64'd1 : 64'd0);
        check($sformatf("kill@%0d: free at the end", k), {63'b0, free}, 64'd1);
        // and the unit is intact: the next divide is right
        divide($sformatf("after kill@%0d", k), 1'b1, 1'b1, 1'b0, 64'd1000, 64'd13);
        divide($sformatf("after kill@%0d (rem, W)", k), 1'b0, 1'b1, 1'b1, 64'd1000, 64'd13);
    endtask

    int seed = 20261012;
    initial begin
        pulses = 0;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: free", {63'b0, free}, 64'd1);
        check("reset: no writeback", {63'b0, wb.valid}, 64'd0);

        // ---- every op on a ladder of edge operands ----
        for (int op = 0; op < 8; op++) begin
            for (int i = 0; i < NV; i++) begin
                for (int j = 0; j < NV; j++) begin
                    // the full cross product for the two spec-defining ops, a diagonal band for the rest
                    if ((op == 0 || op == 4) || ((i + j) % 3 == 0))
                        divide($sformatf("%s %0d/%0d", op_name(op[1], op[0], op[2]), i, j),
                               op[1], op[0], op[2], vals[i], vals[j]);
                end
            end
        end

        // ---- ignored op bits and fu_req fields (operands where signedness matters) ----
        for (int jk = 0; jk < 8; jk++) begin
            for (int m = 0; m < 4; m++) begin
                divide($sformatf("junk op[4:2]=%0d %s", jk, op_name(m[1], m[0], 1'b0)), m[1], m[0], 1'b0,
                       64'hFFFF_FFFF_FFFF_FC18, 64'd7, 3'(jk));      // -1000 or a huge unsigned
                divide($sformatf("junk op[4:2]=%0d %s W", jk, op_name(m[1], m[0], 1'b1)), m[1], m[0], 1'b1,
                       64'hABCD_EF01_FFFF_FC18, 64'hABCD_EF01_0000_0007, 3'(jk));
            end
        end

        // ---- a request offered while busy is ignored ----
        begin
            logic [QV_ROB_TAG_W-1:0] tag_a;
            tag_a = QV_ROB_TAG_W'(n_tag++);
            n_tag++;
            @(negedge clk);
            pulses = 0;
            req = mk(1'b1, 1'b1, 1'b0, 64'd77, 64'd7, tag_a);
            @(posedge clk); #1;
            req = '0;
            repeat (10) @(posedge clk);
            #1;
            @(negedge clk);
            req = mk(1'b1, 1'b1, 1'b0, 64'd5, 64'd5, tag_a + QV_ROB_TAG_W'(1));
            @(posedge clk); #1;
            req = '0;
            repeat (100) @(posedge clk);
            #1;
            check("offered while busy: exactly one result", 64'(pulses), 64'd1);
            check("offered while busy: it is the first request's", last_value, 64'd11);
            check("offered while busy: the first request's tag", {60'b0, last_tag}, {60'b0, tag_a});
        end

        // ---- flush at every interesting moment ----
        kill_at(0);       // in the accepting cycle: never accepted
        kill_at(1);       // the registered request, divider not started
        kill_at(2);       // the divider's load cycle
        kill_at(3);
        kill_at(30);
        kill_at(64);      // the cycle before the last iteration
        kill_at(65);      // the last iteration: done would be raised at this edge
        kill_at(66);      // the pulse cycle itself: masked
        kill_at(67);      // after the pulse: too late, the pulse stands
        kill_at(68);

        // ---- back-to-back with a flush in between ----
        for (int k = 0; k < 6; k++) begin
            @(negedge clk);
            req = mk(1'b1, 1'b0, 1'b0, 64'd90 + 64'(k), 64'd9, QV_ROB_TAG_W'(n_tag++));
            @(posedge clk); #1;
            req = '0;
            repeat (k * 7) @(posedge clk);
            @(negedge clk); flush = 1'b1;
            @(posedge clk); #1; flush = 1'b0;
            // the very next cycle: accept a fresh request straight away
            @(negedge clk);
            pulses = 0;
            req = mk(1'b0, 1'b0, 1'b0, 64'd1000 + 64'(k), 64'd7, QV_ROB_TAG_W'(n_tag++));
            @(posedge clk); #1;
            req = '0;
            repeat (120) @(posedge clk);
            #1;
            check($sformatf("flush then immediate request %0d: exactly one result", k), 64'(pulses), 64'd1);
            check($sformatf("flush then immediate request %0d: its value", k), last_value,
                  golden(1'b0, 1'b0, 1'b0, 64'd1000 + 64'(k), 64'd7));
        end

        // ---- random ----
        void'($urandom(seed));
        for (int n = 0; n < 400; n++) begin
            logic [63:0] a, b;
            logic        quot, sgn, word;
            a = {$urandom, $urandom};
            b = {$urandom, $urandom};
            case ($urandom % 6)                 // shapes that stress the divider and the W trimming
                0: b = b >> ($urandom % 64);
                1: a = a >> ($urandom % 64);
                2: b = {32'b0, b[31:0]} | 64'h8000_0000;
                3: a = a & 64'hFFFF_FFFF_0000_0000 | 64'h0000_0000_8000_0000;
                default: ;
            endcase
            quot = $urandom; sgn = $urandom; word = $urandom;
            divide($sformatf("rand %0d %s", n, op_name(quot, sgn, word)), quot, sgn, word, a, b);
        end

        $display("");
        $display("qv_exu_div_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_exu_div_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT: qv_exu_div_tb");
        $finish;
    end
endmodule
