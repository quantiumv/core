// SPDX-License-Identifier: MIT

/*
 * qv_ras_tb -- design/pipe/qv_ras.sv against a model: two stacks (speculative, committed) of a few entries.
 *
 * (The aligner's operations are zero in a cycle it emitted nothing; only the top is read.)
 *
 * Directed: push and pop in order and the predictions read off the top; a pop on an empty stack; a full stack
 * dropping its oldest entry; two operations in one cycle (a call then a return gives the call's address back at
 * once); a flush from commit copying the committed stack, including that cycle's retirement; the aligner's own
 * operations on the flush cycle are lost.
 *
 * Random: every cycle random aligner and commit operations and flushes against the model, depth 4 so that it
 * overflows.
 */
module qv_ras_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int DEPTH = 4;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic        go = 1'b0;
    logic [1:0]  op0 = 2'b00, op1 = 2'b00;
    logic [63:0] a0 = '0, a1 = '0, ca = '0;
    logic        cpush = 1'b0, cpop = 1'b0, flush = 1'b0;
    logic [63:0] top;
    logic        has1;

    qv_ras #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst),
        .i_sp_op0(op0), .i_sp_addr0(a0), .i_sp_op1(op1), .i_sp_addr1(a1),
        .i_cm_push(cpush), .i_cm_addr(ca), .i_cm_pop(cpop), .i_flush(flush),
        .o_top(top), .o_has1(has1)
    );

    // ---------------- model ----------------
    logic [63:0] ms [0:DEPTH-1];  int ms_n = 0;       // speculative; entry 0 is the top
    logic [63:0] mc [0:DEPTH-1];  int mc_n = 0;

    task automatic m_push_s(input logic [63:0] a);
        for (int i = DEPTH - 1; i > 0; i--) ms[i] = ms[i-1];
        ms[0] = a;
        if (ms_n < DEPTH) ms_n++;
    endtask
    task automatic m_pop_s();
        if (ms_n > 0) begin
            for (int i = 0; i < DEPTH - 1; i++) ms[i] = ms[i+1];
            ms_n--;
        end
    endtask
    task automatic m_push_c(input logic [63:0] a);
        for (int i = DEPTH - 1; i > 0; i--) mc[i] = mc[i-1];
        mc[0] = a;
        if (mc_n < DEPTH) mc_n++;
    endtask
    task automatic m_pop_c();
        if (mc_n > 0) begin
            for (int i = 0; i < DEPTH - 1; i++) mc[i] = mc[i+1];
            mc_n--;
        end
    endtask

    // one cycle with the given inputs; the model advances like the design (commit first, then a flush copies it)
    task automatic cycle(input logic g, input logic [1:0] o0, input logic [63:0] x0, input logic [1:0] o1, input logic [63:0] x1,
                         input logic cp, input logic [63:0] cx, input logic cq, input logic fl);
        @(negedge clk);
        go = g; op0 = g ? o0 : 2'b00; a0 = x0; op1 = g ? o1 : 2'b00; a1 = x1; cpush = cp; ca = cx; cpop = cq; flush = fl;
        @(posedge clk); #1;
        go = 1'b0; op0 = 2'b00; op1 = 2'b00; cpush = 1'b0; cpop = 1'b0; flush = 1'b0;
        if (cq) m_pop_c();
        if (cp) m_push_c(cx);
        if (fl) begin
            for (int i = 0; i < DEPTH; i++) ms[i] = mc[i];
            ms_n = mc_n;
        end else if (g) begin
            if (o0 == 2'b01) m_push_s(x0); else if (o0 == 2'b10) m_pop_s();
            if (o1 == 2'b01) m_push_s(x1); else if (o1 == 2'b10) m_pop_s();
        end
    endtask

    task automatic compare(input string name);
        #1;
        check({name, ": has one"}, {63'b0, has1}, {63'b0, ms_n >= 1});
        if (ms_n >= 1) check({name, ": top"}, top, ms[0]);
    endtask

    int errs0;
    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        compare("empty");

        cycle(1, 2'b01, 64'h100, 2'b00, 0, 0, 0, 0, 0);       compare("push 100");
        cycle(1, 2'b01, 64'h200, 2'b00, 0, 0, 0, 0, 0);       compare("push 200");
        check("top is the last pushed", top, 64'h200);
        cycle(1, 2'b10, 0, 2'b00, 0, 0, 0, 0, 0);             compare("pop");
        check("top after the pop", top, 64'h100);
        cycle(1, 2'b10, 0, 2'b00, 0, 0, 0, 0, 0);             compare("pop to empty");
        cycle(1, 2'b10, 0, 2'b00, 0, 0, 0, 0, 0);             compare("pop of an empty stack");
        // overflow: five pushes into four entries
        for (int i = 1; i <= 5; i++) cycle(1, 2'b01, 64'(i * 16), 2'b00, 0, 0, 0, 0, 0);
        compare("full");
        check("the oldest entry is gone: top is the fifth", top, 64'h50);
        // two operations at once: a call then a return gives the call's address back
        cycle(1, 2'b01, 64'h999, 2'b10, 0, 0, 0, 0, 0);       compare("push then pop in one cycle");
        check("push then pop leaves the stack as it was", top, 64'h50);
        cycle(1, 2'b10, 0, 2'b01, 64'h777, 0, 0, 0, 0);       compare("pop then push in one cycle");
        check("pop then push replaces the top", top, 64'h777);
        cycle(1, 2'b10, 0, 2'b10, 0, 0, 0, 0, 0);             compare("two pops in one cycle");
        // the aligner's operations without go do not count
        cycle(0, 2'b01, 64'hBAD, 2'b01, 64'hBAD, 0, 0, 0, 0); compare("operations without go");
        // commit's stack and a flush
        cycle(0, 0, 0, 0, 0, 1, 64'hA00, 0, 0);               compare("commit pushes, no flush: speculative untouched");
        cycle(0, 0, 0, 0, 0, 1, 64'hB00, 0, 1);               compare("flush: the speculative stack is the committed one");
        check("flush: top is the retiring push of that cycle", top, 64'hB00);
        cycle(1, 2'b01, 64'hC00, 2'b00, 0, 0, 0, 0, 1);       compare("the aligner's push on a flush cycle is lost");
        cycle(1, 2'b01, 64'hD00, 2'b00, 0, 0, 0, 1, 1);       compare("a retiring return on the flush cycle");

        // random
        errs0 = fail_count;
        for (int i = 0; i < 6000; i++) begin
            logic [1:0] o0, o1;
            o0 = 2'($urandom % 3); o1 = 2'($urandom % 3);
            cycle(($urandom % 4) != 0, o0, 64'($urandom), o1, 64'($urandom),
                  ($urandom % 5) == 0, 64'($urandom), ($urandom % 5) == 1, ($urandom % 12) == 0);
            compare("random");
        end
        check("random run: no mismatch", 64'(fail_count - errs0), 64'd0);

        $display("");
        $display("qv_ras_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_ras_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
