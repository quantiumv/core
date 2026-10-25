// SPDX-License-Identifier: MIT

/*
 * qv_sb_tb -- standalone test for design/pipe/qv_sb.sv, the store buffer.
 *
 * A Wishbone slave model with random wait states and a golden list of what was pushed check, on every
 * cycle of directed and random runs: the beats come out in the order the stores went in with the exact
 * address, byte select and data; a beat stays stable from its first cycle to its response, and cyc is low
 * in the response cycle; a beat never starts while the LSU's access is on the bus or the walker's beat is in
 * flight, nor (unless the buffer is full or the drain has yielded for YIELD_MAX cycles) while an LSU access is
 * ready to start or a load sits among the oldest ROB entries; o_start_now is followed by the beat in the next
 * cycle; the gap between two back-to-back beats is one cycle; o_ready and o_empty follow the count; o_match
 * is exactly "an unwritten entry for that dword"; a response that is not the buffer's own (nobody's beat is
 * in flight) is ignored; an error response drops the entry and the drain goes on. Memory ends up equal to the
 * golden image.
 */
module qv_sb_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int DEPTH     = 4;
    localparam int YIELD_MAX = 6;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic        push = 1'b0;
    logic [31:3] push_addr = '0;
    logic [7:0]  push_sel = '0;
    logic [63:0] push_data = '0;
    logic        ready, empty;
    logic [31:3] match_addr = '0;
    logic        match;
    logic        lsu_busy = 1'b0, lsu_inflight = 1'b0, ptw_beat = 1'b0, load_near = 1'b0;
    logic        start_now, beat, cyc;
    logic [31:0] addr;
    logic [63:0] dat;
    logic [7:0]  sel;
    logic        ack = 1'b0, err = 1'b0;
    logic        foreign_ack = 1'b0;

    qv_sb #(.DEPTH(DEPTH), .YIELD_MAX(YIELD_MAX)) dut (
        .clk(clk), .rst(rst),
        .i_push(push), .i_push_addr(push_addr), .i_push_sel(push_sel), .i_push_data(push_data),
        .o_ready(ready), .o_empty(empty),
        .i_match_addr(match_addr), .o_match(match),
        .i_lsu_busy(lsu_busy), .i_lsu_inflight(lsu_inflight), .i_ptw_beat(ptw_beat), .i_load_near(load_near),
        .o_start_now(start_now), .o_beat(beat), .o_cyc(cyc), .o_addr(addr), .o_dat(dat), .o_sel(sel),
        .i_ack(ack | foreign_ack), .i_err(err)
    );

    // ---------------- slave model ----------------
    localparam int WORDS = 256;
    logic [63:0] mem  [0:WORDS-1];
    logic [63:0] gold [0:WORDS-1];
    int   wait_max = 0;                              // random wait states per access, 0..wait_max
    logic [31:0] err_addr = 32'hFFFF_FFFF;           // a write to this address errors
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel;
    logic proto_ok = 1'b1;
    int   beats = 0;

    task automatic apply(input logic [31:0] a, input logic [63:0] d, input logic [7:0] s);
        for (int i = 0; i < 8; i++)
            if (s[i]) mem[a[10:3]][8*i +: 8] = d[8*i +: 8];
    endtask

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy && cyc) begin
            // a request is sampled here; the answer comes wait_left + 1 cycles later
            h_addr <= addr; h_dat <= dat; h_sel <= sel;
            beats <= beats + 1;
            if (wait_max == 0) begin
                if (addr == err_addr) err <= 1'b1;
                else begin ack <= 1'b1; apply(addr, dat, sel); end
            end else begin
                busy <= 1'b1;
                wait_left <= $urandom % (wait_max + 1);
            end
        end else if (busy) begin
            if (!cyc || addr != h_addr || sel != h_sel || dat != h_dat) begin
                if (proto_ok) $display("PROTO: a beat changed or dropped before its response");
                proto_ok <= 1'b0;
            end
            if (wait_left > 0) begin
                wait_left <= wait_left - 1;
            end else begin
                busy <= 1'b0;
                if (h_addr == err_addr) err <= 1'b1;
                else begin ack <= 1'b1; apply(h_addr, h_dat, h_sel); end
            end
        end
    end
    // cyc must be low in every response cycle
    always @(negedge clk)
        if (!rst && (ack || err) && cyc) begin
            if (proto_ok) $display("PROTO: cyc still high in the response cycle");
            proto_ok = 1'b0;
        end

    // ---------------- the golden list ----------------
    logic [31:3] e_addr [0:4095];
    logic [7:0]  e_sel  [0:4095];
    logic [63:0] e_dat  [0:4095];
    logic        e_err  [0:4095];
    int e_head = 0, e_tail = 0;          // pushed and not yet answered: e_head .. e_tail-1
    int pushes = 0, answered = 0;
    int cnt_model;
    assign cnt_model = e_tail - e_head;

    // the push is accepted when ready is high at the edge
    always @(posedge clk) begin
        if (!rst && push && ready) begin
            e_addr[e_tail % 4096] = push_addr;
            e_sel [e_tail % 4096] = push_sel;
            e_dat [e_tail % 4096] = push_data;
            e_err [e_tail % 4096] = ({push_addr, 3'b000} == err_addr);
            e_tail = e_tail + 1;
            pushes = pushes + 1;
            if (!(({push_addr, 3'b000} == err_addr)))
                for (int i = 0; i < 8; i++)
                    if (push_sel[i]) gold[push_addr[10:3]][8*i +: 8] = push_data[8*i +: 8];
        end
    end

    // beat monitor: the first cycle of a beat is checked against the head of the list; a response pops it
    logic in_beat = 1'b0;
    int   cyc_rises = 0;
    int   last_rise = -100, cycle_n = 0;
    int   gap_min = 1000;
    logic gap_check = 1'b0;               // measure the gap between back-to-back beats
    int   resp_cycle = -100;
    always @(posedge clk) begin
        cycle_n <= cycle_n + 1;
        if (!rst) begin
            if (cyc) begin
                if (!in_beat) begin
                    in_beat = 1'b1;
                    cyc_rises = cyc_rises + 1;
                    check("beat: something to write", {63'b0, e_head != e_tail}, 64'd1);
                    if (e_head != e_tail) begin
                        check("beat: address", {32'b0, addr}, {32'b0, e_addr[e_head % 4096], 3'b000});
                        check("beat: select", {56'b0, sel}, {56'b0, e_sel[e_head % 4096]});
                        check("beat: data", dat, e_dat[e_head % 4096]);
                    end
                    if (gap_check && resp_cycle >= 0) begin
                        // the response cycle is the one cycle in between: the next beat's first cyc is the cycle after
                        if (cycle_n - resp_cycle < gap_min) gap_min = cycle_n - resp_cycle;
                    end
                end
            end
            if (beat && (ack || err)) begin
                in_beat = 1'b0;
                resp_cycle = cycle_n;
                answered = answered + 1;
                if (e_head != e_tail) e_head = e_head + 1;
            end
        end
    end

    // ---------------- per-cycle invariants ----------------
    logic prev_start = 1'b0;
    always @(negedge clk) begin
        if (!rst) begin
            #1;
            check("o_empty follows the count", {63'b0, empty}, {63'b0, cnt_model == 0});
            check("o_ready follows the count", {63'b0, ready}, {63'b0, cnt_model < DEPTH});
            // o_match is exactly "an unanswered entry for that dword"
            begin
                logic m;
                m = 1'b0;
                for (int i = e_head; i < e_tail; i++)
                    if (e_addr[i % 4096] == match_addr) m = 1'b1;
                check("o_match", {63'b0, match}, {63'b0, m});
            end
            if (start_now) begin
                check("start: not while the LSU is on the bus", {63'b0, lsu_inflight}, 64'd0);
                check("start: not while the walker's beat is in flight", {63'b0, ptw_beat}, 64'd0);
                check("start: something to write", {63'b0, cnt_model > ((ack || err) && beat ? 1 : 0)}, 64'd1);
                if (cnt_model < DEPTH && !(dut.held_q >= YIELD_MAX))
                    check("start: not while a load goes first (not full, not yielded out)",
                          {63'b0, lsu_busy || load_near}, 64'd0);
            end
            check("o_start_now is followed by a beat", {63'b0, prev_start ? beat : 1'b1}, 64'd1);
            prev_start = start_now;
        end
    end

    // ---------------- driver helpers ----------------
    task automatic do_push(input logic [31:3] a, input logic [7:0] s, input logic [63:0] d);
        @(negedge clk);
        push = 1'b1; push_addr = a; push_sel = s; push_data = d;
        @(posedge clk); #1;
        push = 1'b0;
    endtask

    task automatic wait_empty(input int limit);
        int c;
        c = 0;
        while (!(empty && !beat) && c < limit) begin @(posedge clk); #1; c++; end
        check("drained in time", {63'b0, empty && !beat}, 64'd1);
    endtask

    task automatic quiet_inputs();
        lsu_busy = 1'b0; lsu_inflight = 1'b0; ptw_beat = 1'b0; load_near = 1'b0;
    endtask

    task automatic compare_memory(input string name);
        int bad;
        bad = 0;
        for (int i = 0; i < WORDS; i++) if (mem[i] !== gold[i]) bad++;
        check({name, ": memory equals the golden image"}, 64'(bad), 64'd0);
    endtask

    // ---------------- tests ----------------
    int t0, t1;
    initial begin
        for (int i = 0; i < WORDS; i++) begin mem[i] = '0; gold[i] = '0; end
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // ---- one store: drained, in the right place ----
        do_push(29'h10, 8'hF0, 64'h1122_3344_5566_7788);
        wait_empty(20);
        check("one store: arrives", mem[8'h10], gold[8'h10]);

        // ---- order and content: several stores, some to the same dword with different lanes ----
        do_push(29'h11, 8'h0F, 64'hAAAA_AAAA_BBBB_BBBB);
        do_push(29'h11, 8'hC0, 64'hCCCC_DDDD_EEEE_FFFF);
        do_push(29'h12, 8'hFF, 64'h0123_4567_89AB_CDEF);
        wait_empty(60);
        compare_memory("order");
        check("same-dword stores merge in order", mem[8'h11], gold[8'h11]);

        // ---- the gap between two back-to-back beats is one cycle (a latency-1 slave) ----
        gap_check = 1'b1; gap_min = 1000;
        for (int i = 0; i < 4; i++) do_push(29'h20 + i, 8'hFF, 64'h1000 + i);
        wait_empty(60);
        // the cycle after the response is the next beat's first cycle: cycle_n - resp_cycle == 1
        check("back-to-back beats: the next one starts the cycle after the response", 64'(gap_min), 64'd1);
        gap_check = 1'b0;

        // ---- full: o_ready low, a push while full is ignored ----
        lsu_inflight = 1'b1;                        // nothing may drain
        for (int i = 0; i < DEPTH; i++) do_push(29'h30 + i, 8'hFF, 64'h2000 + i);
        @(negedge clk); #1;
        check("full: not ready", {63'b0, ready}, 64'd0);
        check("full: not empty", {63'b0, empty}, 64'd0);
        push = 1'b1; push_addr = 29'h3F; push_sel = 8'hFF; push_data = 64'hDEAD;     // refused: the model ignores it too
        @(posedge clk); #1; push = 1'b0;
        check("full, LSU on the bus: no beat", {63'b0, beat || start_now}, 64'd0);
        quiet_inputs();
        wait_empty(80);
        compare_memory("full");
        check("the refused push never reached memory", mem[8'h3F], gold[8'h3F]);

        // ---- the LSU goes first: a ready access holds the drain off for up to YIELD_MAX cycles ----
        lsu_busy = 1'b1;
        t0 = cycle_n;
        do_push(29'h40, 8'hFF, 64'h3000);
        repeat (YIELD_MAX - 3) @(posedge clk);
        #1;
        check("LSU access ready: no beat yet", {63'b0, beat || start_now}, 64'd0);
        while (!beat && !start_now && cycle_n - t0 < 40) begin @(posedge clk); #1; end
        check("LSU access ready: it yields only so long", 64'(cycle_n - t0 <= YIELD_MAX + 4), 64'd1);
        quiet_inputs();
        wait_empty(40);
        compare_memory("lsu first");

        // ---- a full buffer does not wait for the LSU or for a load ----
        lsu_busy = 1'b1; load_near = 1'b1;
        for (int i = 0; i < DEPTH; i++) do_push(29'h44 + i, 8'hFF, 64'h3100 + i);
        t0 = cycle_n;
        while (!beat && !start_now && cycle_n - t0 < 20) begin @(posedge clk); #1; end
        check("full: the drain goes at once", 64'(cycle_n - t0 <= 2), 64'd1);
        quiet_inputs();
        wait_empty(80);
        compare_memory("full overrides");

        // ---- yield to a load, for YIELD_MAX cycles at most ----
        load_near = 1'b1;
        t0 = cycle_n;
        do_push(29'h50, 8'hFF, 64'h4000);
        while (!beat && !start_now && cycle_n - t0 < 40) begin @(posedge clk); #1; end
        t1 = cycle_n - t0;
        check("yield: waited for the load", 64'(t1 >= YIELD_MAX), 64'd1);
        check("yield: and no longer than YIELD_MAX + 4 cycles", 64'(t1 <= YIELD_MAX + 4), 64'd1);
        quiet_inputs();
        wait_empty(40);
        compare_memory("yield");

        // ---- the walker's beat and an LSU access on the bus hold it off whatever else is going on ----
        ptw_beat = 1'b1;
        for (int i = 0; i < DEPTH; i++) do_push(29'h60 + i, 8'hFF, 64'h5000 + i);
        repeat (8) @(posedge clk); #1;
        check("walker beat in flight: no drain even when full", {63'b0, beat || start_now}, 64'd0);
        quiet_inputs();
        wait_empty(80);
        compare_memory("walker");

        // ---- a response that is not ours is ignored ----
        do_push(29'h70, 8'hFF, 64'h6000);
        lsu_busy = 1'b1;                            // hold the drain off, then fire foreign acks at it
        repeat (2) @(posedge clk); #1;
        @(negedge clk); foreign_ack = 1'b1;
        @(posedge clk); #1; foreign_ack = 1'b0;
        check("foreign ack: still one entry", 64'(cnt_model), 64'd1);
        check("foreign ack: still not empty", {63'b0, empty}, 64'd0);
        quiet_inputs();
        wait_empty(40);
        compare_memory("foreign ack");

        // ---- an error response drops the entry and the drain goes on ----
        err_addr = {29'h80, 3'b000};
        do_push(29'h80, 8'hFF, 64'h7000);
        do_push(29'h81, 8'hFF, 64'h7001);
        wait_empty(60);
        check("after an error: the next entry arrived", mem[8'h81], gold[8'h81]);
        check("after an error: the failing entry was dropped", mem[8'h80], 64'd0);
        err_addr = 32'hFFFF_FFFF;

        // ---- random: pushes, a busy LSU, a walker, loads, wait states ----
        for (int round = 0; round < 6; round++) begin
            wait_max = (round % 3);                  // 0, 1, 2 extra wait cycles
            for (int c = 0; c < 4000; c++) begin
                @(negedge clk);
                if (!beat) begin
                    lsu_inflight = ($urandom % 8) == 0;
                    ptw_beat     = !lsu_inflight && (($urandom % 12) == 0);
                end else begin
                    lsu_inflight = 1'b0; ptw_beat = 1'b0;
                end
                lsu_busy  = lsu_inflight || (($urandom % 4) == 0);
                load_near = ($urandom % 3) == 0;
                match_addr = $urandom % 32 + 29'h100;
                push = (($urandom % 5) < 2);
                push_addr = $urandom % 32 + 29'h100;
                push_sel  = $urandom;
                push_data = {$urandom, $urandom};
                @(posedge clk); #1;
            end
            push = 1'b0;
            quiet_inputs();
            wait_empty(400);
            compare_memory($sformatf("random round %0d", round));
        end

        check("all pushes answered", 64'(answered), 64'(pushes));
        check("slave protocol held", {63'b0, proto_ok}, 64'd1);

        $display("");
        $display("qv_sb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_sb_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
