// SPDX-License-Identifier: MIT

/*
 * qv_fetch_xl_tb -- qv_fetch with translation: the request register's translation phase, against an oracle
 * standing in for qv_xlate (a map from virtual pages to physical pages and to faults, with a programmable latency
 * and the answer held for as long as the request is). qv_fetch_tb covers the bus side without translation.
 *
 *   - translated sequential fetch: each dword goes to the bus at {physical page, offset}, the buffer entry carries
 *     the virtual pc, the physical page and xl; across a page boundary the page changes; a physical page number
 *     above 4 GB reaches the bus truncated to 32 bits; the oracle's latency (0 = a TLB hit, several = a walk)
 *     only delays
 *   - a page fault and an access fault from the translation become a fault entry (cause 12 and 1) with no bus
 *     beat at all, and fetch goes on; a bus error on a translated fetch is a cause-1 entry that still carries
 *     its page
 *   - a redirect during the translation frees the slot at once and cancels it (no bus beat for the old request,
 *     the new target is requested in the same cycle); swept over every cycle of a slow translation and of a
 *     fault answer
 *   - i_hold: a translation may finish under it but never starts a bus beat (o_idle stays high), a fault is
 *     allowed under it, and the beat starts once it drops
 *   - i_redirect_ctx: the target is not requested in the redirect's cycle but in the next, so the request is
 *     translated (or not) against the context the redirect brought in
 *   - the bus protocol, as in qv_fetch_tb: cyc low in a response cycle, never abandoned or moved
 *
 * REUSE (PAGE_REUSE, P10a; tests.list runs both): every case above, plus the last translated page -- a request in
 * it asks for no translation and goes to the bus at once, a request in another page does; a context-changing
 * redirect and i_xl_flush forget the page (a flush wins over a fill in the same cycle), a plain redirect does not;
 * a fault is never kept; translation off never uses it.
 */
module qv_fetch_xl_tb #(
    parameter bit REUSE = 1'b0
);
    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- DUT ----------------
    logic [31:0] addr;
    logic        cyc, stb, ack, err;
    logic [63:0] dat;
    logic        redirect_valid = 1'b0, redirect_ctx = 1'b0;
    logic [63:0] redirect_pc    = '0;
    logic        buf_valid, buf_err, buf_xl;
    logic [63:0] buf_pc, buf_data;
    logic [3:0]  buf_cause;
    logic [43:0] buf_pg;
    logic        pop_en = 1'b0;
    wire         buf_pop = pop_en && buf_valid;
    logic        hold = 1'b0;
    logic        idle;
    logic        xl_flush = 1'b0;

    // translation port
    logic        xl_on = 1'b1;
    wire         x_req, x_cancel;
    wire  [63:0] x_va;
    logic        x_done, x_pf, x_af;
    logic [43:0] x_ppn;

    qv_fetch #(.PAGE_REUSE(REUSE)) dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(addr), .wb_fetch_cyc_o(cyc), .wb_fetch_stb_o(stb),
        .wb_fetch_dat_i(dat), .wb_fetch_ack_i(ack), .wb_fetch_err_i(err),
        .i_redirect_valid(redirect_valid), .i_redirect_pc(redirect_pc), .i_redirect_ctx(redirect_ctx),
        .i_hold(hold), .o_idle(idle),
        .i_xl_on(xl_on), .o_xl_req(x_req), .o_xl_va(x_va), .o_xl_cancel(x_cancel),
        .i_xl_done(x_done), .i_xl_pf(x_pf), .i_xl_af(x_af), .i_xl_ppn(x_ppn), .i_xl_flush(xl_flush),
        .o_buf_valid(buf_valid), .o_buf_pc(buf_pc), .o_buf_data(buf_data), .o_buf_err(buf_err),
        .o_buf_cause(buf_cause), .o_buf_xl(buf_xl), .o_buf_pg(buf_pg),
        .i_buf_pop(buf_pop)
    );

    // ---------------- the oracle ----------------
    // virtual pages 0x40000.. (VA 0x4000_0000 + n * 0x1000)
    localparam logic [63:0] VBASE = 64'h4000_0000;
    function automatic logic [43:0] ppn_of(input logic [51:0] vpn);
        case (vpn - 52'h40000)
            52'd0:   return 44'd2;                      // PA 0x2000
            52'd1:   return 44'd1;                      // PA 0x1000
            52'd2:   return 44'h10_0003;                // PA 0x1_0000_3000: the bus sees 0x3000
            52'd5:   return 44'd2;
            52'd6:   return 44'h00FFF;                  // PA 0xFFF000: outside the memory, the bus answers with an error
            52'd9:   return 44'd0;
            default: return 44'd3;
        endcase
    endfunction
    function automatic logic is_pf(input logic [51:0] vpn);  return (vpn == 52'h40003); endfunction
    function automatic logic is_af(input logic [51:0] vpn);  return (vpn == 52'h40004); endfunction

    int  xl_latency = 0;
    int  xl_cnt = 0;
    int  cancels = 0, xl_reqs = 0;
    wire [51:0] x_vpn = x_va[63:12];
    always_comb begin
        x_done = x_req && (xl_cnt >= xl_latency);
        x_pf   = x_done && is_pf(x_vpn);
        x_af   = x_done && is_af(x_vpn);
        x_ppn  = ppn_of(x_vpn);
    end
    always @(posedge clk) begin
        if (rst || !x_req || x_cancel) xl_cnt <= 0;
        else if (!x_done)              xl_cnt <= xl_cnt + 1;
        if (!rst && x_cancel) cancels <= cancels + 1;
        if (!rst && x_req && xl_cnt == 0) xl_reqs <= xl_reqs + 1;
    end

    // ---------------- behavioral slave (16 KB at physical 0) ----------------
    localparam int MEM_WORDS = 2048;
    logic [63:0] mem [0:MEM_WORDS-1];
    int wait_cfg = 0;
    int wcnt;
    int bus_beats = 0;
    logic [31:0] beat_addrs [0:127];
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
                    dat <= mem[addr[13:3]];
                end else begin
                    err <= 1'b1;
                end
            end else begin
                wcnt <= wcnt + 1;
            end
        end
    end
    logic prev_cyc_beat = 1'b0;
    always @(posedge clk) begin
        if (!rst && cyc && !prev_cyc_beat) begin
            if (bus_beats < 128) beat_addrs[bus_beats] = addr;
            bus_beats <= bus_beats + 1;
        end
        prev_cyc_beat <= cyc;
    end

    // ---------------- protocol monitor ----------------
    logic        prev_cyc = 1'b0;
    logic [31:0] prev_addr;
    int          proto_errs = 0;
    always @(negedge clk) begin
        if (!rst) begin
            if ((ack || err) && cyc) begin
                proto_errs++; $display("PROTO: cyc still high in a response cycle at t=%0t", $time);
            end
            if (prev_cyc && !(ack || err) && (!cyc || addr != prev_addr)) begin
                proto_errs++; $display("PROTO: request abandoned or moved before its response at t=%0t", $time);
            end
        end
        prev_cyc  = cyc && !rst;
        prev_addr = addr;
    end

    // ---------------- consumer log ----------------
    localparam int LOG_MAX = 128;
    logic [63:0] log_pc    [0:LOG_MAX-1];
    logic [63:0] log_data  [0:LOG_MAX-1];
    logic        log_err   [0:LOG_MAX-1];
    logic [3:0]  log_cause [0:LOG_MAX-1];
    logic        log_xl    [0:LOG_MAX-1];
    logic [43:0] log_pg    [0:LOG_MAX-1];
    int          log_n = 0;
    always @(posedge clk) begin
        if (!rst && buf_pop && !redirect_valid && log_n < LOG_MAX) begin
            log_pc[log_n]    <= buf_pc;
            log_data[log_n]  <= buf_data;
            log_err[log_n]   <= buf_err;
            log_cause[log_n] <= buf_cause;
            log_xl[log_n]    <= buf_xl;
            log_pg[log_n]    <= buf_pg;
            log_n            <= log_n + 1;
        end
    end

    // ---------------- helpers ----------------
    task automatic do_reset();
        pop_en = 1'b0; redirect_valid = 1'b0; redirect_ctx = 1'b0; hold = 1'b0; xl_on = 1'b1; xl_flush = 1'b0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        log_n = 0; bus_beats = 0; cancels = 0; xl_reqs = 0;
        rst = 1'b0;
    endtask

    task automatic wait_log(input int n, input int max_cycles);
        int c;
        c = 0;
        while (log_n < n && c < max_cycles) begin @(posedge clk); c++; end
        #1;
    endtask

    task automatic pulse_redirect(input logic [63:0] target, input logic ctx);
        redirect_pc = target; redirect_valid = 1'b1; redirect_ctx = ctx;
        @(posedge clk); #1;
        redirect_valid = 1'b0; redirect_ctx = 1'b0;
    endtask

    // the entry k of a translated stream starting at va: pc, data from the physical dword, xl, page, no fault
    task automatic check_xl_entry(input string tag, input int idx, input logic [63:0] va);
        logic [43:0] ppn;
        logic [63:0] pa;
        begin
            ppn = ppn_of(va[63:12]);
            pa  = {8'b0, ppn, va[11:0]};
            check($sformatf("%s: entry %0d pc", tag, idx), log_pc[idx], va);
            check($sformatf("%s: entry %0d is translated", tag, idx), b(log_xl[idx]), 64'd1);
            check($sformatf("%s: entry %0d physical page", tag, idx), {20'b0, log_pg[idx]}, {20'b0, ppn});
            check($sformatf("%s: entry %0d data is the physical dword", tag, idx), log_data[idx], mem[pa[13:3]]);
            check($sformatf("%s: entry %0d no fault", tag, idx), b(log_err[idx]), 64'd0);
        end
    endtask

    int i, mark, c0;
    initial begin
        for (i = 0; i < MEM_WORDS; i++) mem[i] = 64'hD000_0000_0000_0000 | 64'(i);

        // ---- X1: translated sequential fetch across a page boundary, latency 0 (a TLB hit) ----
        wait_cfg = 0; xl_latency = 0;
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'hFE0, 1'b0);
        wait_log(8, 300);
        for (int k = 0; k < 8; k++) check_xl_entry("X1", k, VBASE + 64'hFE0 + 64'(8 * k));
        check("X1: the bus saw the physical addresses of the first page", {32'b0, beat_addrs[0]}, 64'h2FE0);
        check("X1: ... and the second page after the boundary", {32'b0, beat_addrs[4]}, 64'h1000);

        // ---- X2: a slow translation (a walk of 6 cycles) only delays ----
        xl_latency = 6;
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'hFF0, 1'b0);
        wait_log(4, 400);
        for (int k = 0; k < 4; k++) check_xl_entry("X2", k, VBASE + 64'hFF0 + 64'(8 * k));
        xl_latency = 0;

        // ---- X3: a physical page number above 4 GB: the bus sees the low 32 bits, the entry the whole page ----
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h2000 + 64'h40, 1'b0);
        wait_log(2, 300);
        check_xl_entry("X3", 0, VBASE + 64'h2040);
        check("X3: the bus address is PA[31:0]", {32'b0, beat_addrs[0]}, 64'h3040);

        // ---- X4: a page fault: a fault entry with cause 12 and no bus beat, fetch goes on ----
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h2FF0, 1'b0);          // page 2 ok (2 dwords), then page 3 (page fault)
        wait_log(5, 300);
        check_xl_entry("X4", 0, VBASE + 64'h2FF0);
        check_xl_entry("X4", 1, VBASE + 64'h2FF8);
        check("X4: the page-fault entry's pc", log_pc[2], VBASE + 64'h3000);
        check("X4: it is a fault marker", b(log_err[2]), 64'd1);
        check("X4: cause 12", {60'b0, log_cause[2]}, 64'd12);
        check("X4: fetch goes on after it", log_pc[3], VBASE + 64'h3008);
        check("X4: the faulting page's dwords are faults too", {60'b0, log_cause[3]}, 64'd12);
        check("X4: only the two dwords of the good page reached the bus (the faulting page never did)", 64'(bus_beats), 64'd2);

        // ---- X5: an access fault: cause 1 ----
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h4000, 1'b0);
        wait_log(2, 300);
        check("X5: entry is a fault marker", b(log_err[0]), 64'd1);
        check("X5: cause 1", {60'b0, log_cause[0]}, 64'd1);
        check("X5: no bus beat", 64'(bus_beats), 64'd0);

        // ---- X6: a bus error on a translated fetch: a cause-1 entry that still has its page ----
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h6000 + 64'h10, 1'b0);
        wait_log(1, 300);
        check("X6: entry is a fault marker", b(log_err[0]), 64'd1);
        check("X6: cause 1", {60'b0, log_cause[0]}, 64'd1);
        check("X6: it carries its physical page", {20'b0, log_pg[0]}, 64'h00FFF);
        check("X6: and xl", b(log_xl[0]), 64'd1);

        // ---- X6b: a bus error after a page fault: its cause is 1, the earlier fault's kind is not carried over ----
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h3000, 1'b0);          // page 3: a page fault, dword after dword
        wait_log(3, 300);
        check("X6b: the page fault is cause 12", {60'b0, log_cause[0]}, 64'd12);
        pulse_redirect(VBASE + 64'h6010, 1'b0);          // now the page whose physical address errors on the bus
        mark = log_n;
        wait_log(mark + 1, 300);
        check("X6b: the bus error after a page fault is cause 1", {60'b0, log_cause[mark]}, 64'd1);
        check("X6b: ... and a fault entry", b(log_err[mark]), 64'd1);

        // ---- X7: translation off (i_xl_on low) is the untranslated fetch, no oracle involved ----
        do_reset();
        xl_on = 1'b0;
        pop_en = 1'b1;
        pulse_redirect(64'h40, 1'b0);
        wait_log(3, 300);
        check("X7: pc", log_pc[0], 64'h40);
        check("X7: not translated", b(log_xl[0]), 64'd0);
        check("X7: data from the pc", log_data[0], mem[8]);
        check("X7: no translation request at all", 64'(xl_reqs), 64'd0);

        // ---- X8: a redirect during a slow translation: the slot is freed at once, nothing goes to the bus for it ----
        xl_latency = 20;
        for (int k = 1; k <= 24; k++) begin
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h0100, 1'b0);          // starts a slow translation
            repeat (k) begin @(posedge clk); #1; end
            mark = log_n;
            xl_latency = 0;
            c0 = cancels;
            pulse_redirect(VBASE + 64'h1200, 1'b0);          // the new target (page 1: PPN 1), the oracle answers now
            if (k <= 19)
                check($sformatf("X8 k=%0d: the redirect cancels the translation (the walker must not hand its answer to the next request)", k),
                      64'(cancels - c0), 64'd1);
            @(negedge clk);
            if (k <= 19)            // (later, the old request is on the bus and cannot be abandoned)
                check($sformatf("X8 k=%0d: the new target is asked for in the redirect's own cycle (the slot was freed)", k),
                      b(x_req && x_va == VBASE + 64'h1200), 64'd1);
            wait_log(mark + 2, 300);
            check($sformatf("X8 k=%0d: the first entry after the redirect is the new target", k), log_pc[mark], VBASE + 64'h1200);
            check($sformatf("X8 k=%0d: it is translated, from physical 0x1200", k), {20'b0, log_pg[mark]}, 64'd1);
            check($sformatf("X8 k=%0d: its data", k), log_data[mark], mem[(64'h1200) >> 3]);
            xl_latency = 20;
        end
        xl_latency = 0;

        // ---- X9: a redirect over every cycle of a fault answer (page fault at latency 3) ----
        xl_latency = 3;
        for (int k = 0; k <= 10; k++) begin
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h3000, 1'b0);          // page fault, after the oracle's 3 cycles
            repeat (k) begin @(posedge clk); #1; end
            mark = log_n;
            pulse_redirect(VBASE + 64'h1300, 1'b0);
            @(negedge clk);
            check($sformatf("X9 k=%0d: the new target is asked for in the redirect's own cycle", k),
                  b(x_req && x_va == VBASE + 64'h1300), 64'd1);
            wait_log(mark + 2, 300);
            check($sformatf("X9 k=%0d: the first entry after the redirect is the new target", k), log_pc[mark], VBASE + 64'h1300);
            check($sformatf("X9 k=%0d: it is no fault", k), b(log_err[mark]), 64'd0);
        end
        xl_latency = 0;

        // ---- X10: hold during a slow translation: it may finish, but no bus beat starts, and o_idle stays high ----
        xl_latency = 8;
        do_reset();
        pop_en = 1'b1;
        pulse_redirect(VBASE + 64'h0200, 1'b0);
        repeat (2) begin @(posedge clk); #1; end
        hold = 1'b1;
        begin
            int beats0, nonidle;
            beats0 = bus_beats; nonidle = 0;
            repeat (20) begin @(negedge clk); if (cyc || !idle) nonidle++; end
            check("X10: held: no bus beat and always idle while the translation finishes and waits", 64'(nonidle), 64'd0);
            check("X10: held: no new beat counted", 64'(bus_beats - beats0), 64'd0);
        end
        hold = 1'b0;
        mark = log_n;
        wait_log(mark + 2, 300);
        check_xl_entry("X10", mark, VBASE + 64'h0200);
        xl_latency = 0;

        // ---- X11: a fault answer under hold is delivered (it needs no bus) ----
        xl_latency = 2;
        do_reset();
        pop_en = 1'b1;
        hold = 1'b1;
        pulse_redirect(VBASE + 64'h3000, 1'b0);              // recorded, not issued while held
        hold = 1'b0;
        @(posedge clk); #1;                                   // the request is issued at this edge
        hold = 1'b1;                                          // held again right after
        repeat (12) @(posedge clk);
        #1;
        check("X11: the fault entry arrived under hold", b(log_n >= 1 && log_err[0]), 64'd1);
        check("X11: cause 12", {60'b0, log_cause[0]}, 64'd12);
        hold = 1'b0;
        xl_latency = 0;

        // ---- X12: a redirect that changes the translation context is requested one cycle later ----
        xl_latency = 0;
        for (int ctx = 0; ctx < 2; ctx++) begin
            do_reset();
            pop_en = 1'b0;                                     // the buffer fills, fetch goes idle
            repeat (25) @(posedge clk);
            #1;
            check($sformatf("X12 ctx=%0d: idle before the redirect", ctx), b(x_req) + b(cyc), 64'd0);
            pop_en = 1'b1;
            xl_on = 1'b0;                                      // the context before the redirect: not translated ...
            redirect_pc = VBASE + 64'h1400; redirect_valid = 1'b1; redirect_ctx = ctx[0];
            @(posedge clk); #1;
            redirect_valid = 1'b0; redirect_ctx = 1'b0;
            xl_on = 1'b1;                                      // ... and after it (the edge brought it in)
            @(negedge clk);
            if (ctx == 0) begin
                // no wait: the request was issued in the redirect's cycle, when the context was still the old one
                check("X12 ctx=0: issued at once (untranslated, the old context)", b(cyc), 64'd1);
                check("X12 ctx=0: at the physical address", {32'b0, addr}, 64'h4000_1400);
            end else begin
                check("X12 ctx=1: nothing in the redirect's cycle: no bus request yet", b(cyc), 64'd0);
                check("X12 ctx=1: no translation request yet either", b(x_req), 64'd0);
                @(negedge clk);
                check("X12 ctx=1: the translation request comes a cycle later", b(x_req), 64'd1);
                check("X12 ctx=1: for the target", x_va, VBASE + 64'h1400);
            end
            mark = 0;
            wait_log(1, 300);
            if (ctx == 1) begin
                check("X12 ctx=1: the first entry is the translated target", b(log_xl[0]), 64'd1);
                check("X12 ctx=1: its pc", log_pc[0], VBASE + 64'h1400);
            end else begin
                check("X12 ctx=0: the first entry is the untranslated one", b(log_xl[0]), 64'd0);
            end
        end

        // ---- X13: a ctx redirect while a bus request is outstanding: the old response is dropped, the target goes next ----
        wait_cfg = 5;
        do_reset();
        pop_en = 1'b1;
        wait_log(2, 400);
        begin
            logic was_cyc;
            int   tries;
            was_cyc = 1'b1; tries = 0;
            while (tries < 100) begin @(negedge clk); if (cyc && !was_cyc) break; was_cyc = cyc; tries++; end
        end
        @(posedge clk); #1;
        mark = log_n;
        pulse_redirect(VBASE + 64'h1500, 1'b1);
        wait_log(mark + 2, 600);
        check_xl_entry("X13", mark, VBASE + 64'h1500);
        wait_cfg = 0;

        // ---- R: the last translated page (REUSE only) ----
        if (REUSE) begin
            // R1: a run inside one page asks for one translation; every dword is fetched from the physical page
            wait_cfg = 0; xl_latency = 0;
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h040, 1'b0);
            wait_log(8, 300);
            for (int k = 0; k < 8; k++) check_xl_entry("R1", k, VBASE + 64'h040 + 64'(8 * k));
            check("R1: one translation for the whole run", 64'(xl_reqs), 64'd1);
            check("R1: the bus saw physical addresses", {32'b0, beat_addrs[3]}, 64'h2058);

            // R2: across a page edge: one more translation, for the new page
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'hFE0, 1'b0);
            wait_log(8, 300);
            for (int k = 0; k < 8; k++) check_xl_entry("R2", k, VBASE + 64'hFE0 + 64'(8 * k));
            check("R2: two translations, one per page", 64'(xl_reqs), 64'd2);

            // R3: a plain redirect into the kept page asks for nothing; one into another page does
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h100, 1'b0);
            wait_log(2, 300);
            c0 = xl_reqs; mark = log_n;
            pulse_redirect(VBASE + 64'h800, 1'b0);
            wait_log(mark + 2, 300);
            check("R3: a plain redirect inside the page: no translation", 64'(xl_reqs - c0), 64'd0);
            check_xl_entry("R3", mark, VBASE + 64'h800);
            c0 = xl_reqs; mark = log_n;
            pulse_redirect(VBASE + 64'h1100, 1'b0);
            wait_log(mark + 2, 300);
            check("R3: a redirect to another page: a translation", 64'(xl_reqs - c0), 64'd1);
            check_xl_entry("R3 other page", mark, VBASE + 64'h1100);

            // R4: a context-changing redirect forgets the page, even back into it
            c0 = xl_reqs; mark = log_n;
            pulse_redirect(VBASE + 64'h1180, 1'b1);
            wait_log(mark + 2, 300);
            check("R4: a ctx redirect into the kept page: translated again", 64'(xl_reqs - c0), 64'd1);
            check_xl_entry("R4", mark, VBASE + 64'h1180);

            // R5: i_xl_flush forgets it (an SFENCE.VMA, a halt)
            pop_en = 1'b0;
            repeat (20) @(posedge clk);
            #1;
            xl_flush = 1'b1;
            @(posedge clk); #1;
            xl_flush = 1'b0;
            pop_en = 1'b1;
            c0 = xl_reqs; mark = log_n;
            pulse_redirect(VBASE + 64'h11C0, 1'b0);
            wait_log(mark + 2, 300);
            check("R5: after i_xl_flush, a plain redirect into the page is translated again", 64'(xl_reqs - c0), 64'd1);
            check_xl_entry("R5", mark, VBASE + 64'h11C0);

            // R6: a flush in the very cycle a translation answers beats the fill
            do_reset();
            xl_latency = 4;
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h1200, 1'b0);
            while (!x_done) begin @(negedge clk); end
            xl_flush = 1'b1;                                  // in the answer's cycle
            @(posedge clk); #1;
            xl_flush = 1'b0;
            xl_latency = 0;
            wait_log(2, 300);
            check_xl_entry("R6", 0, VBASE + 64'h1200);
            check_xl_entry("R6", 1, VBASE + 64'h1208);
            check("R6: the next dword of the page was translated again (the flush won)", 64'(xl_reqs), 64'd2);

            // R7: a fault is never kept: every dword of a faulting page asks again, and none reaches the bus
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h3000, 1'b0);
            wait_log(3, 300);
            check("R7: three fault entries", b(log_err[0] && log_err[1] && log_err[2]), 64'd1);
            check("R7: a translation for each", 64'(xl_reqs >= 3), 64'd1);
            check("R7: no bus beat", 64'(bus_beats), 64'd0);

            // R8: translation off never uses the kept page
            do_reset();
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h040, 1'b0);
            wait_log(2, 300);
            pop_en = 1'b0;
            repeat (20) @(posedge clk);
            #1;
            xl_on = 1'b0;
            pop_en = 1'b1;
            mark = log_n;
            pulse_redirect(VBASE + 64'h080, 1'b0);            // in the kept page
            wait_log(mark + 1, 300);
            check("R8: translation off: an untranslated entry", b(log_xl[mark]), 64'd0);
            // the virtual address itself went to the bus (beyond the memory: an error), not the kept physical page
            check("R8: ... fetched at the virtual address", b(log_err[mark]), 64'd1);
            xl_on = 1'b1;

            // R9: under hold a translation that answers is not kept (it starts no beat); it is once the hold drops
            do_reset();
            xl_latency = 3;
            pop_en = 1'b1;
            pulse_redirect(VBASE + 64'h1300, 1'b0);
            hold = 1'b1;
            repeat (10) @(posedge clk);
            #1;
            check("R9: held: nothing kept yet", b(dut.lp_valid_q), 64'd0);
            hold = 1'b0;
            wait_log(3, 300);
            check("R9: kept once the beat starts", b(dut.lp_valid_q), 64'd1);
            check_xl_entry("R9", 0, VBASE + 64'h1300);
            check("R9: one translation", 64'(xl_reqs), 64'd1);
            xl_latency = 0;
        end

        check("protocol monitor: no violations across all tests", 64'(proto_errs), 64'd0);

        $display("");
        $display("qv_fetch_xl_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_fetch_xl_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT: qv_fetch_xl_tb");
        $finish;
    end
endmodule
