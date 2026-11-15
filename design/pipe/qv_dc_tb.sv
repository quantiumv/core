// SPDX-License-Identifier: MIT

/*
 * qv_dc_tb -- the in-core D$ (qv_dc, O5a) against a golden memory.
 *
 * The memory is a small array; the slave answers each beat 1..1+WAIT_MAX cycles after it is presented (never in the
 * cycle it is presented, as every slave of the core's port), sometimes with an error. Writes to memory come from the
 * three sources the core has: the store buffer's beat (i_wr, in its response cycle: memory and the D$ at the same
 * edge), the LSU's own write past the buffer (i_inv), and another master (i_snoop, which may also land while a refill
 * runs). Checked every cycle: every valid line equals memory (so a missed update, invalidation or kill shows), a hit
 * returns memory's dword, the beat protocol (one beat at a time, held with its address until its response, dropped in
 * it, a line's dwords in order, WORDS beats unless one errs), and each refill's answer (the dword its own beat read,
 * and the error).
 */
module qv_dc_tb;
    parameter int LINES    = 4;
    parameter int WORDS    = 4;
    parameter int WAIT_MAX = 3;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    localparam int MW = 8 * LINES * WORDS;        // dwords of memory: 8 lines map to each index
    localparam int OB = 3 + $clog2(WORDS);
    localparam int IW = $clog2(LINES);
    localparam int WW = $clog2(WORDS);
    typedef logic [IW-1:0] iw_t;
    typedef logic [WW-1:0] ww_t;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    logic [31:3] addr = '0;
    logic        hit, busy, fill, fill_err;
    logic [63:0] dat, fill_dat;
    logic        fill_req = 1'b0;
    logic        wr = 1'b0, inv = 1'b0, snoop = 1'b0;
    logic [31:3] wr_addr = '0, inv_addr = '0, snoop_addr = '0;
    logic [7:0]  wr_sel = '0;
    logic [63:0] wr_dat = '0;
    logic        beat, ack = 1'b0, err = 1'b0;
    logic [31:3] baddr;
    logic [63:0] rdat = '0;

    qv_dc #(.LINES(LINES), .WORDS(WORDS)) dut (
        .clk(clk), .rst(rst),
        .i_addr(addr), .o_hit(hit), .o_dat(dat), .o_busy(busy),
        .i_fill_req(fill_req), .o_fill(fill), .o_fill_dat(fill_dat), .o_fill_err(fill_err),
        .i_wr(wr), .i_wr_addr(wr_addr), .i_wr_sel(wr_sel), .i_wr_dat(wr_dat),
        .i_inv(inv), .i_inv_addr(inv_addr), .i_snoop(snoop), .i_snoop_addr(snoop_addr),
        .o_beat(beat), .o_addr(baddr), .i_ack(ack), .i_err(err), .i_dat(rdat)
    );

    // ---------------- the golden memory and the slave ----------------
    logic [63:0] mem [MW];
    int          err_pct = 0;                    // the chance a beat errs
    int          wait_left = -1;                 // the beat on the port: cycles until its response (-1: none)
    logic [31:3] beat_addr_q;
    int          errs = 0;

    function automatic logic [63:0] merge(input logic [63:0] old, input logic [7:0] sel, input logic [63:0] d);
        logic [63:0] r = old;
        for (int b = 0; b < 8; b++) if (sel[b]) r[8*b +: 8] = d[8*b +: 8];
        return r;
    endfunction

    // the refill the testbench expects: its line, the requested dword, the next beat, what that beat read
    logic        f_on = 1'b0;
    logic [31:OB] f_line;
    int          f_word, f_next;
    logic [63:0] f_exp;
    logic        f_err;

    always @(posedge clk) if (!rst) begin
        // the slave: a response the cycle(s) after a beat is presented (ack/err are raised by step() in the cycle
        // the count reaches 0)
        if (wait_left > 0) wait_left <= wait_left - 1;
        if (wait_left == 0) wait_left <= -1;
        if (beat && wait_left < 0) begin
            beat_addr_q <= baddr;
            wait_left   <= $urandom % (WAIT_MAX + 1);
        end
    end
    // the response is raised for one cycle when its count runs out: combinational from the counter
    always_comb begin
        rdat = (wait_left == 0) ? mem[beat_addr_q % MW] : 64'hDEAD_BEEF_0000_0000;
    end

    // ---------------- every cycle, at the falling edge (after the DUT's edge) ----------------
    task automatic fail(input string what);
        errs++;
        if (errs <= 10) $display("FAIL at %0t: %s", $time, what);
    endtask

    logic [31:3] chk_a;
    always @(negedge clk) if (!rst) begin
        // every valid line equals memory
        for (int i = 0; i < LINES; i++)
            if (dut.valid_q[i])
                for (int w = 0; w < WORDS; w++) begin
                    chk_a = {dut.tag_q[i], iw_t'(i), ww_t'(w)};
                    if (dut.data_q[i][w] !== mem[chk_a % MW]) fail($sformatf("line %0d dword %0d differs from memory", i, w));
                end
    end

    // ---------------- one cycle of stimulus ----------------
    // drive the inputs for the next posedge, check the DUT's combinational outputs in this cycle, then step
    task automatic step();
        // the response cycle: the beat must be off, and the answer must be what it read
        ack = 1'b0; err = 1'b0;
        if (wait_left == 0) begin
            if (($urandom % 100) < err_pct) err = 1'b1; else ack = 1'b1;
        end
        #1;
        if ((ack || err) && beat) fail("the beat is still presented in its response cycle");
        if (beat && !busy) fail("a beat with no refill");
        if (beat && wait_left > 0 && baddr !== beat_addr_q) fail("the beat changed its address before its response");
        if (f_on && (ack || err)) begin
            if (baddr !== beat_addr_q && beat) fail("beat address");
            if (beat_addr_q !== {f_line, ww_t'(f_next)}) fail($sformatf("beat %0d of the line out of order", f_next));
            if (ww_t'(f_next) == ww_t'(f_word)) f_exp = err ? 64'bx : mem[beat_addr_q % MW];
            if (err) f_err = 1'b1;
            if (f_next == WORDS - 1 || err) begin
                if (!fill) fail("no fill in the last response cycle");
                else begin
                    if (fill_err !== f_err) fail("fill error flag");
                    if (!f_err && fill_dat !== f_exp) fail($sformatf("fill dword %h, expected %h", fill_dat, f_exp));
                end
            end else if (fill) fail("a fill before the last beat");
        end else if (fill) fail("a fill with no response");
        if (hit && !busy && dat !== mem[addr % MW]) fail($sformatf("hit at %h returns %h, memory %h", addr, dat, mem[addr % MW]));
        @(posedge clk);
        // the testbench's own model of the refill and of memory, at the same edge as the DUT
        if (f_on && (ack || err)) begin
            if (f_next == WORDS - 1 || err) f_on = 1'b0; else f_next++;
        end
        if (fill_req && !busy) begin
            f_on = 1'b1; f_line = addr[31:OB]; f_word = addr[OB-1:3]; f_next = 0; f_err = 1'b0;
        end
        if (wr)    mem[wr_addr % MW]    = merge(mem[wr_addr % MW], wr_sel, wr_dat);
        if (inv)   mem[inv_addr % MW]   = merge(mem[inv_addr % MW], 8'hFF, {$urandom, $urandom});
        if (snoop) mem[snoop_addr % MW] = merge(mem[snoop_addr % MW], 8'hFF, {$urandom, $urandom});
        @(negedge clk);
        fill_req = 1'b0; wr = 1'b0; inv = 1'b0; snoop = 1'b0; ack = 1'b0; err = 1'b0;
    endtask

    function automatic logic [31:3] rnd_addr();
        return 29'($urandom % MW);
    endfunction

    // a load at a: if it misses and no refill runs, refill; returns whether it hit
    task automatic load(input logic [31:3] a);
        addr = a; #1;
        if (!hit && !busy) fill_req = 1'b1;
        step();
    endtask
    // look at a in a fresh cycle (realigned to the falling edge, so settle delays never reach the next edge)
    task automatic look(input logic [31:3] a);
        @(negedge clk); addr = a; #1;
    endtask
    task automatic idle(input int n);
        for (int i = 0; i < n; i++) step();
    endtask
    task automatic until_idle();
        int guard = 0;
        while ((busy || f_on) && guard < 200) begin step(); guard++; end
    endtask

    int r;
    initial begin
        for (int i = 0; i < MW; i++) mem[i] = {$urandom, $urandom};
        @(negedge clk); rst = 1'b0;

        // 1: a miss refills the line; every dword of it then hits with memory's value
        look(29'd5);
        check("cold: a miss", 64'(hit), 64'd0);
        load(29'd5); until_idle();
        for (int w = 0; w < WORDS; w++) begin
            look({addr[31:OB], ww_t'(w)});
            check($sformatf("refilled: dword %0d hits", w), 64'(hit), 64'd1);
            check($sformatf("refilled: dword %0d is memory's", w), dat, mem[addr % MW]);
        end

        // 2: an update merges into a held line by its byte select; one to a missing line allocates nothing
        wr = 1'b1; wr_addr = 29'd5; wr_sel = 8'h0F; wr_dat = 64'h1111_2222_3333_4444; step();
        look(29'd5);
        check("update: merged", dat, mem[5]);
        wr = 1'b1; wr_addr = 29'(MW - 1); wr_sel = 8'hFF; wr_dat = 64'h5; step();
        look(29'(MW - 1));
        check("update to a missing line: still a miss", 64'(hit), 64'd0);

        // 3: a snoop to the line being refilled: not installed, but the load still gets its dword
        look(29'(2 * WORDS));
        load(addr); step();
        snoop = 1'b1; snoop_addr = 29'(2 * WORDS + 1); step();
        until_idle();
        look(29'(2 * WORDS));
        check("snoop during the refill: line not installed", 64'(hit), 64'd0);

        // 4: a snoop to another line during a refill does not stop the install
        load(29'(3 * WORDS)); step();
        snoop = 1'b1; snoop_addr = 29'(7 * WORDS); step();
        until_idle();
        look(29'(3 * WORDS));
        check("snoop elsewhere: line installed", 64'(hit), 64'd1);

        // 5: an invalidation and a snoop of a held line remove it
        inv = 1'b1; inv_addr = 29'(3 * WORDS + 1); step();
        look(29'(3 * WORDS));
        check("inv: line gone", 64'(hit), 64'd0);
        load(29'd5); until_idle();
        snoop = 1'b1; snoop_addr = 29'd4; step();
        look(29'd5);
        check("snoop: line gone", 64'(hit), 64'd0);

        // 6: a beat that errs ends the refill with the error, and nothing is installed
        err_pct = 100;
        load(29'(4 * WORDS)); until_idle();
        err_pct = 0;
        look(29'(4 * WORDS));
        check("error: line not installed", 64'(hit), 64'd0);

        // random: loads, updates, invalidations, snoops (during refills too), errors now and then
        err_pct = 3;
        for (int i = 0; i < 40000; i++) begin
            r = $urandom % 100;
            if (busy) begin
                addr = rnd_addr();
                if (r < 10) begin snoop = 1'b1; snoop_addr = rnd_addr(); end
                step();
            end else if (r < 55) load(rnd_addr());
            else if (r < 75) begin wr = 1'b1; wr_addr = rnd_addr(); wr_sel = 8'($urandom); wr_dat = {$urandom, $urandom}; step(); end
            else if (r < 82) begin inv = 1'b1; inv_addr = rnd_addr(); step(); end
            else if (r < 90) begin snoop = 1'b1; snoop_addr = rnd_addr(); step(); end
            else begin addr = rnd_addr(); step(); end
        end
        until_idle();
        check("random: every line equals memory, every hit, beat and fill checked", 64'(errs), 64'd0);

        $display("");
        $display("qv_dc_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_dc_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
