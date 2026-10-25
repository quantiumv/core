// SPDX-License-Identifier: MIT

/*
 * qv_fetch_stream_tb -- design/pipe/qv_fetch.sv with STREAM = 1 (back-to-back requests), random stimulus
 * against a scoreboard, plus the rate it exists for.
 *
 * The slave answers the cycle after a request, like wb4_sram and the caches on a hit (a request is taken at
 * the edge that ends the cycle it is shown in, whether or not an answer to the previous one is in that
 * cycle), with a random number of extra wait states, and optionally ignores a request shown in an answer's
 * cycle (what wb_arbiter2's DROP_REQ_ON_RESP does): the master has to hold it until it is answered.
 *
 * Scoreboard: every entry the consumer pops is the next one expected -- the target of the latest redirect, then
 * each following dword -- with the data of its own address (or an error beyond the end of the memory). Run with
 * redirects, holds, yields and pops at random on every cycle.
 *
 * Checked every cycle: a request on the bus stays, unchanged, until it is answered; a request shown in an
 * answer's cycle is the next sequential dword or the redirect target, and only when there is no redirect, hold or
 * yield in that cycle; idle means nothing on the bus; held and idle means nothing starts; the buffer never
 * overflows (the scoreboard sees every response).
 *
 * Translation: fetch is asked to translate at random (i_xl_on, sampled when a request issues) by a translator that
 * answers after 0 to 2 cycles with the identity (a fault beyond the memory) and keeps the answer until the request
 * drops; a request is never streamed while translation is on.
 *
 * Rate (no redirect, hold or yield; the consumer pops every cycle): one dword per cycle on a zero-wait slave; with
 * a slave that ignores the streamed request, or with yield held high, one per two.
 */
module qv_fetch_stream_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int FBD = 4;
    localparam int MEM_WORDS = 64;                  // 0x200 bytes; above that -> err

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [31:0] addr;
    logic        cyc, stb, ack, err;
    logic [63:0] dat;
    logic        redirect_valid = 1'b0;
    logic [63:0] redirect_pc    = '0;
    logic        buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic        pop_en = 1'b0;
    wire         buf_pop = pop_en && buf_valid && !redirect_valid;
    logic        hold = 1'b0, yield = 1'b0;
    logic        idle;
    logic        xl_on = 1'b0;
    logic        xl_req, xl_cancel, xl_done, xl_pf, xl_af;
    logic [63:0] xl_va;
    logic [43:0] xl_ppn;
    logic        buf_xl;
    logic [3:0]  buf_cause;
    logic [43:0] buf_pg;

    qv_fetch #(.FB_DEPTH(FBD), .STREAM(1'b1)) dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(addr), .wb_fetch_cyc_o(cyc), .wb_fetch_stb_o(stb),
        .wb_fetch_dat_i(dat), .wb_fetch_ack_i(ack), .wb_fetch_err_i(err),
        .i_redirect_valid(redirect_valid), .i_redirect_pc(redirect_pc),
        .i_hold(hold), .o_idle(idle), .i_yield(yield),
        .i_xl_on(xl_on), .o_xl_req(xl_req), .o_xl_va(xl_va), .o_xl_cancel(xl_cancel),
        .i_xl_done(xl_done), .i_xl_pf(xl_pf), .i_xl_af(xl_af), .i_xl_ppn(xl_ppn),
        .o_buf_valid(buf_valid), .o_buf_pc(buf_pc), .o_buf_data(buf_data),
        .o_buf_err(buf_err), .o_buf_cause(buf_cause), .o_buf_xl(buf_xl), .o_buf_pg(buf_pg), .i_buf_pop(buf_pop)
    );

    // ---------------- translator ----------------
    // the answer comes xl_lat cycles after the request appeared, and stays while the request is held
    int xl_lat = 0;
    int xl_cnt = 0;
    always @(posedge clk) begin
        if (rst || !xl_req || xl_cancel) xl_cnt <= 0;
        else if (xl_cnt <= 3) xl_cnt <= xl_cnt + 1;
    end
    assign xl_done = xl_req && !xl_cancel && (xl_cnt >= xl_lat);
    assign xl_pf   = xl_done && (xl_va[31:0] >= MEM_WORDS * 8);
    assign xl_af   = 1'b0;
    assign xl_ppn  = xl_va[55:12];

    // ---------------- slave ----------------
    int   wait_max = 0;                             // extra wait states, 0..wait_max
    logic swallow  = 1'b0;                          // ignore a request shown in an answer's cycle
    logic busy = 1'b0;
    int   wleft;
    logic [31:0] b_addr;

    function automatic logic [63:0] mem_word(input logic [31:0] a);
        return {a[31:3], 3'b000, ~{a[31:3], 3'b000}};
    endfunction

    task automatic respond(input logic [31:0] a);
        if (a < MEM_WORDS * 8) begin ack <= 1'b1; dat <= mem_word(a); end
        else                   begin err <= 1'b1; end
    endtask

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) busy <= 1'b0;
        else if (busy) begin
            if (wleft == 0) begin respond(b_addr); busy <= 1'b0; end
            else wleft <= wleft - 1;
        end else if (cyc && stb && !(swallow && (ack || err))) begin
            int w;
            w = (wait_max == 0) ? 0 : ($urandom % (wait_max + 1));
            if (w == 0) respond(addr);
            else begin busy <= 1'b1; b_addr <= addr; wleft <= w - 1; end
        end
    end

    // ---------------- monitors ----------------
    logic        p_cyc = 1'b0, p_resp = 1'b0, p_hold_idle = 1'b0;
    logic [31:0] p_addr;
    int          proto_errs = 0;
    // sampled at the clock edge, before the registers move: the stimulus changes at the falling edge
    always @(posedge clk) begin
        if (!rst) begin
            // moved or dropped before its answer
            if (p_cyc && !(ack || err) && (!cyc || addr != p_addr)) begin
                proto_errs++; $display("PROTO: request moved or dropped before its answer at t=%0t", $time);
            end
            // a request shown in an answer's cycle needs a quiet cycle
            if (cyc && (ack || err) && (redirect_valid || hold || yield)) begin
                proto_errs++; $display("PROTO: request shown in an answer's cycle with redirect/hold/yield at t=%0t", $time);
            end
            if (cyc && (ack || err) && xl_on) begin
                proto_errs++; $display("PROTO: request shown in an answer's cycle with translation on at t=%0t", $time);
            end
            if (idle && cyc) begin proto_errs++; $display("PROTO: idle with cyc at t=%0t", $time); end
            if (p_hold_idle && cyc) begin proto_errs++; $display("PROTO: a request started under hold at t=%0t", $time); end
        end
        p_cyc       = cyc && !rst;
        p_addr      = addr;
        p_hold_idle = hold && idle && !rst;
    end

    // ---------------- scoreboard ----------------
    logic [63:0] exp_pc;
    int          popped = 0, sb_errs = 0;
    always @(posedge clk) begin
        if (rst) begin
            exp_pc <= '0;
        end else if (redirect_valid) begin
            exp_pc <= redirect_pc;
        end else if (buf_pop) begin
            popped <= popped + 1;
            if (buf_pc !== exp_pc) begin
                sb_errs++; $display("SCOREBOARD: popped pc %h expected %h at t=%0t", buf_pc, exp_pc, $time);
            end else if (buf_pc[31:0] < MEM_WORDS * 8) begin
                if (buf_err || buf_data !== mem_word(buf_pc[31:0])) begin
                    sb_errs++; $display("SCOREBOARD: pc %h wrong data/err (err=%b data=%h) at t=%0t", buf_pc, buf_err, buf_data, $time);
                end
            end else if (!buf_err) begin
                sb_errs++; $display("SCOREBOARD: pc %h beyond memory without err at t=%0t", buf_pc, $time);
            end
            if (buf_xl && !buf_err && buf_pg !== buf_pc[55:12]) begin
                sb_errs++; $display("SCOREBOARD: pc %h translated to page %h at t=%0t", buf_pc, buf_pg, $time);
            end
            if (buf_err && buf_cause !== 4'd1 && buf_cause !== 4'd12) begin
                sb_errs++; $display("SCOREBOARD: pc %h fault cause %0d at t=%0t", buf_pc, buf_cause, $time);
            end
            exp_pc <= {exp_pc[63:3], 3'b000} + 64'd8;
        end
    end

    task automatic do_reset();
        pop_en = 1'b0; redirect_valid = 1'b0; hold = 1'b0; yield = 1'b0; xl_on = 1'b0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        rst = 1'b0;
        popped = 0;
    endtask

    // random stimulus: per-cycle probabilities in percent
    task automatic random_run(input int cycles, input int p_redir, input int p_hold_on, input int p_yield, input int p_pop,
                              input int wmax, input bit swl, input int p_xl = 0);
        wait_max = wmax; swallow = swl;
        do_reset();
        for (int c = 0; c < cycles; c++) begin
            @(negedge clk);
            redirect_valid = ($urandom % 100) < p_redir;
            redirect_pc    = redirect_valid ? ((($urandom % 100) < 8) ? 64'(32'h200 + ($urandom % 64) * 2)    // beyond the memory
                                                                       : 64'(($urandom % (MEM_WORDS * 4)) * 2)) : 64'b0;
            if (hold) hold = ($urandom % 100) >= 30; else hold = ($urandom % 100) < p_hold_on;
            yield  = ($urandom % 100) < p_yield;
            pop_en = ($urandom % 100) < p_pop;
            if (($urandom % 100) < 5) xl_on = ($urandom % 100) < p_xl;
            if (($urandom % 100) < 10) xl_lat = $urandom % 3;
        end
        @(negedge clk);
        redirect_valid = 1'b0; hold = 1'b0; yield = 1'b0; pop_en = 1'b1; xl_on = 1'b0;
        repeat (40) @(posedge clk);
        #1;
    endtask

    // the rate: dwords popped over a window
    task automatic rate_run(input int wmax, input bit swl, input bit yl, output int per_100_cycles);
        int n0, n1;
        wait_max = wmax; swallow = swl;
        do_reset();
        @(negedge clk);
        redirect_valid = 1'b1; redirect_pc = 64'h0;
        @(negedge clk);
        redirect_valid = 1'b0;
        yield = yl; pop_en = 1'b1;
        repeat (20) @(posedge clk);          // warm up (the stream ends at the memory's end: loop it)
        n0 = popped;
        for (int c = 0; c < 300; c++) begin
            @(negedge clk);
            if (c % 20 == 19) begin redirect_valid = 1'b1; redirect_pc = 64'h0; end   // keep inside the memory
            else redirect_valid = 1'b0;
            @(posedge clk);
        end
        @(negedge clk);
        redirect_valid = 1'b0;
        n1 = popped;
        // 15 redirects cost a few cycles each; the figure is per 100 cycles
        per_100_cycles = ((n1 - n0) * 100) / 300;
    endtask

    int r0, r1, r2;
    initial begin
        // ---- rate ----
        rate_run(0, 1'b0, 1'b0, r0);
        check("zero-wait slave: streaming rate is well over one dword per two cycles", 64'(r0 > 75), 64'd1);
        rate_run(0, 1'b1, 1'b0, r1);
        check("slave ignoring the streamed request: about one dword per two cycles", 64'(r1 > 25 && r1 < 55), 64'd1);
        rate_run(0, 1'b0, 1'b1, r2);
        check("yield held high: about one dword per two cycles", 64'(r2 > 25 && r2 < 55), 64'd1);
        $display("qv_fetch_stream_tb: dwords per 100 cycles: stream %0d, swallowing slave %0d, yielding %0d", r0, r1, r2);
        check("rate runs: protocol", 64'(proto_errs), 64'd0);
        check("rate runs: scoreboard", 64'(sb_errs), 64'd0);

        // ---- random: slaves, consumers, redirect/hold/yield densities ----
        for (int w = 0; w <= 3; w += 1)
            for (int s = 0; s < 2; s++) begin
                random_run(6000, 4,  3, 10, 70, w, s[0]);
                random_run(6000, 15, 5, 30, 40, w, s[0]);
                random_run(6000, 1,  1,  0, 100, w, s[0]);
                random_run(6000, 0, 10, 50, 20, w, s[0]);       // a slow consumer: the buffer fills
                random_run(6000, 4,  3, 10, 70, w, s[0], 50);   // translation on and off
                random_run(6000, 1,  2,  5, 90, w, s[0], 80);
            end
        check("random runs: protocol", 64'(proto_errs), 64'd0);
        check("random runs: scoreboard", 64'(sb_errs), 64'd0);
        check("random runs: entries were consumed", 64'(popped > 100), 64'd1);

        $display("");
        $display("qv_fetch_stream_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_fetch_stream_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
