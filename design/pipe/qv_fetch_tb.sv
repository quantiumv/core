// SPDX-License-Identifier: MIT

/*
 * qv_fetch_tb -- standalone test for design/pipe/qv_fetch.sv.
 *
 * The slave is a small behavioral model with a programmable wait-state
 * count rather than wb4_sram.sv itself: wait=0 reproduces wb4_sram's
 * timing exactly (registered ack one cycle after the request), and
 * wait>0 keeps a request outstanding for several cycles, which is what
 * makes the mid-request redirect test actually mid-request.
 *
 * A protocol monitor runs every cycle of every test:
 *   - cyc must be low in any cycle ack or err is high (the master
 *     releases in the response cycle, so a slave that re-acks while
 *     cyc&&stb stay high -- wb4_sram does -- never produces a ghost ack);
 *   - once cyc is high, it stays high with the same address until the
 *     response arrives (a request is never abandoned or moved).
 */
module qv_fetch_tb;
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic [31:0] addr;
    logic        cyc, stb, ack, err;
    logic [63:0] dat;
    logic        redirect_valid = 1'b0;
    logic [63:0] redirect_pc    = '0;
    logic        buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    logic        pop_en = 1'b0;
    wire         buf_pop = pop_en && buf_valid;
    logic        hold = 1'b0;
    logic        idle;

    qv_fetch dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(addr), .wb_fetch_cyc_o(cyc), .wb_fetch_stb_o(stb),
        .wb_fetch_dat_i(dat), .wb_fetch_ack_i(ack), .wb_fetch_err_i(err),
        .i_redirect_valid(redirect_valid), .i_redirect_pc(redirect_pc),
        .i_hold(hold), .o_idle(idle),
        .o_buf_valid(buf_valid), .o_buf_pc(buf_pc), .o_buf_data(buf_data),
        .o_buf_err(buf_err), .i_buf_pop(buf_pop)
    );

    // ---------------- behavioral slave ----------------
    localparam int MEM_WORDS = 64;                  // 0x200 bytes; above that -> err
    logic [63:0] mem [0:MEM_WORDS-1];
    int wait_cfg = 0;
    int wcnt;

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) begin
            wcnt <= 0;
        end else if (cyc && stb && !ack && !err) begin
            if (wcnt >= wait_cfg) begin
                wcnt <= 0;
                if (addr < MEM_WORDS * 8) begin
                    ack <= 1'b1;
                    dat <= mem[addr[31:3]];
                end else begin
                    err <= 1'b1;
                end
            end else begin
                wcnt <= wcnt + 1;
            end
        end
    end

    // ---------------- protocol monitor ----------------
    logic        prev_cyc = 1'b0;
    logic [31:0] prev_addr;
    int          proto_errs = 0;
    always @(negedge clk) begin
        if (!rst) begin
            if ((ack || err) && cyc) begin
                proto_errs++;
                $display("PROTO: cyc still high in a response cycle at t=%0t", $time);
            end
            if (prev_cyc && !(ack || err) && (!cyc || addr != prev_addr)) begin
                proto_errs++;
                $display("PROTO: request abandoned or moved before its response at t=%0t (cyc=%b addr=%h prev=%h)",
                         $time, cyc, addr, prev_addr);
            end
        end
        prev_cyc  = cyc && !rst;
        prev_addr = addr;
    end

    // ---------------- consumer log ----------------
    localparam int LOG_MAX = 64;
    logic [63:0] log_pc   [0:LOG_MAX-1];
    logic [63:0] log_data [0:LOG_MAX-1];
    logic        log_err  [0:LOG_MAX-1];
    int          log_n = 0;
    always @(posedge clk) begin
        if (!rst && buf_pop && !redirect_valid && log_n < LOG_MAX) begin
            log_pc[log_n]   <= buf_pc;
            log_data[log_n] <= buf_data;
            log_err[log_n]  <= buf_err;
            log_n           <= log_n + 1;
        end
    end

    // ---------------- helpers ----------------
    task automatic do_reset();
        pop_en         = 1'b0;
        redirect_valid = 1'b0;
        rst            = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        log_n = 0;
        rst   = 1'b0;
    endtask

    task automatic wait_log(input int n, input int max_cycles);
        int c;
        c = 0;
        while (log_n < n && c < max_cycles) begin
            @(posedge clk);
            c++;
        end
        #1;
    endtask

    task automatic pulse_redirect(input logic [63:0] target);
        redirect_pc    = target;
        redirect_valid = 1'b1;
        @(posedge clk);
        #1;
        redirect_valid = 1'b0;
    endtask

    task automatic check_seq(input string tag, input int first, input int n, input logic [63:0] base);
        for (int k = 0; k < n; k++) begin
            check($sformatf("%s: entry %0d pc", tag, k), log_pc[first + k], base + 64'(8 * k));
            check($sformatf("%s: entry %0d data", tag, k), log_data[first + k],
                  mem[(base + 64'(8 * k)) >> 3]);
            check($sformatf("%s: entry %0d err", tag, k), {63'b0, log_err[first + k]}, 64'd0);
        end
    endtask

    int i, mark, stall_bus;
    logic [31:0] old_addr;

    initial begin
        for (i = 0; i < MEM_WORDS; i++) mem[i] = 64'hD000_0000_0000_0000 | 64'(i);

        // ---- T1: sequential, zero wait states (wb4_sram timing) ----
        wait_cfg = 0;
        do_reset();
        pop_en = 1'b1;
        wait_log(8, 200);
        check("T1: got 8 entries", 64'(log_n >= 8), 64'd1);
        check_seq("T1", 0, 8, 64'h0);

        // ---- T2: sequential, 3 wait states ----
        wait_cfg = 3;
        do_reset();
        pop_en = 1'b1;
        wait_log(6, 200);
        check("T2: got 6 entries", 64'(log_n >= 6), 64'd1);
        check_seq("T2", 0, 6, 64'h0);
        wait_cfg = 0;

        // ---- T3: backpressure -- fetch fills its buffer and goes idle ----
        do_reset();
        repeat (30) @(posedge clk);
        #1;
        check("T3: buffer holding data while stalled", {63'b0, buf_valid}, 64'd1);
        stall_bus = 0;
        repeat (10) begin
            @(negedge clk);
            if (cyc) stall_bus++;
        end
        check("T3: no bus activity once the buffer is full", 64'(stall_bus), 64'd0);
        pop_en = 1'b1;
        wait_log(6, 200);
        check_seq("T3", 0, 6, 64'h0);

        // ---- T4: redirect with nothing outstanding ----
        do_reset();
        repeat (30) @(posedge clk);       // buffer full, fetch idle
        @(negedge clk);
        check("T4: idle before redirect", {63'b0, cyc}, 64'd0);
        @(posedge clk); #1;
        pulse_redirect(64'h40);
        @(negedge clk);
        check("T4: new target requested the cycle after redirect", {63'b0, cyc}, 64'd1);
        check("T4: new target address", {32'b0, addr}, 64'h40);
        pop_en = 1'b1;
        wait_log(3, 200);
        check_seq("T4", 0, 3, 64'h40);

        // ---- T5: redirect while a request is genuinely outstanding ----
        // Redirect one cycle after a fresh request starts, so with 5 wait
        // states it must stay held, unchanged, for several cycles AFTER
        // the redirect too -- not just happen to complete right away.
        wait_cfg = 5;
        do_reset();
        pop_en = 1'b1;
        wait_log(2, 200);                 // let a couple of entries through first
        begin
            logic was_cyc;
            int   tries;
            was_cyc = 1'b1;
            tries   = 0;
            while (tries < 100) begin
                @(negedge clk);
                if (cyc && !was_cyc) break;    // a request just started
                was_cyc = cyc;
                tries++;
            end
            check("T5: saw a fresh request start", 64'(tries < 100), 64'd1);
        end
        old_addr = addr;
        @(posedge clk); #1;
        mark = log_n;
        pulse_redirect(64'h80);
        @(negedge clk);
        check("T5: old request still held the cycle after redirect", {63'b0, cyc}, 64'd1);
        check("T5: old request's address unchanged after redirect", {32'b0, addr}, {32'b0, old_addr});
        wait_log(mark + 3, 400);
        check_seq("T5 (post-redirect)", mark, 3, 64'h80);

        // ---- T8: two redirects while one request is outstanding ----
        // (an align redirect, then a trap at commit). The old response
        // must still be dropped: the second redirect must not revive it.
        wait_cfg = 8;
        do_reset();
        pop_en = 1'b1;
        wait_log(2, 400);
        begin
            logic was_cyc;
            int   tries;
            was_cyc = 1'b1;
            tries   = 0;
            while (tries < 100) begin
                @(negedge clk);
                if (cyc && !was_cyc) break;
                was_cyc = cyc;
                tries++;
            end
            check("T8: saw a fresh request start", 64'(tries < 100), 64'd1);
        end
        old_addr = addr;
        @(posedge clk); #1;
        mark = log_n;
        pulse_redirect(64'h80);
        @(posedge clk); #1;
        pulse_redirect(64'h100);
        @(negedge clk);
        check("T8: old request still held after both redirects", {63'b0, cyc}, 64'd1);
        check("T8: old request's address unchanged", {32'b0, addr}, {32'b0, old_addr});
        wait_log(mark + 3, 600);
        check_seq("T8 (after the second redirect)", mark, 3, 64'h100);

        // ---- T9: hold (FENCE.I) ----
        // Raised mid-request: that request still completes, then nothing
        // new goes out and idle stays high. A redirect while held (align's
        // static prediction) is fetched first once the hold drops.
        wait_cfg = 4;
        do_reset();
        pop_en = 1'b1;
        wait_log(2, 400);
        begin
            logic was_cyc;
            int   tries;
            was_cyc = 1'b1;
            tries   = 0;
            while (tries < 100) begin
                @(negedge clk);
                if (cyc && !was_cyc) break;
                was_cyc = cyc;
                tries++;
            end
            check("T9: saw a fresh request start", 64'(tries < 100), 64'd1);
        end
        @(posedge clk); #1;
        hold = 1'b1;
        @(negedge clk);
        check("T9: not idle while the request is outstanding", {63'b0, idle}, 64'd0);
        begin
            int c;
            c = 0;
            while (!idle && c < 50) begin @(negedge clk); c++; end
            check("T9: idle once the outstanding request completes", {63'b0, idle}, 64'd1);
        end
        stall_bus = 0;
        repeat (6) begin @(negedge clk); if (cyc || !idle) stall_bus++; end
        @(posedge clk); #1;
        mark = log_n;
        pulse_redirect(64'h140);
        repeat (6) begin @(negedge clk); if (cyc || !idle) stall_bus++; end
        check("T9: no request while held, redirect included", 64'(stall_bus), 64'd0);
        @(posedge clk); #1;
        hold = 1'b0;
        @(negedge clk);
        check("T9: released: nothing out in the release cycle itself", {63'b0, cyc}, 64'd0);
        @(negedge clk);
        check("T9: released: the redirect target goes out first", {32'b0, addr}, 64'h140);
        check("T9: released: request out", {63'b0, cyc}, 64'd1);
        wait_log(mark + 3, 400);
        check_seq("T9 (after release)", mark, 3, 64'h140);
        wait_cfg = 0;

        // ---- T6: redirect to a non-dword-aligned target ----
        do_reset();
        repeat (30) @(posedge clk);
        pulse_redirect(64'hC4);
        @(negedge clk);
        check("T6: bus address is dword-aligned", {32'b0, addr}, 64'hC0);
        pop_en = 1'b1;
        wait_log(2, 200);
        check("T6: first pc keeps the low bits", log_pc[0], 64'hC4);
        check("T6: first data is the containing dword", log_data[0], mem[8'hC0 >> 3]);
        check("T6: next pc is the following dword", log_pc[1], 64'hC8);

        // ---- T7: bus error becomes a fault marker, fetch keeps going ----
        do_reset();
        repeat (30) @(posedge clk);
        pulse_redirect(64'h1F8);
        pop_en = 1'b1;
        wait_log(3, 200);
        check("T7: last in-range dword ok pc", log_pc[0], 64'h1F8);
        check("T7: last in-range dword ok err", {63'b0, log_err[0]}, 64'd0);
        check("T7: out-of-range pc", log_pc[1], 64'h200);
        check("T7: out-of-range marked err", {63'b0, log_err[1]}, 64'd1);
        check("T7: fetch continues after an error", log_pc[2], 64'h208);

        check("protocol monitor: no violations across all tests", 64'(proto_errs), 64'd0);

        $display("");
        $display("qv_fetch_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_fetch_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT: qv_fetch_tb");
        $finish;
    end
endmodule
