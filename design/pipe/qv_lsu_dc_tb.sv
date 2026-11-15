// SPDX-License-Identifier: MIT

/*
 * qv_lsu_dc_tb -- the LSU with the D$ inside the core (qv_lsu DC_EN = 1 beside a real qv_dc, O5a), wired as
 * design/pipe/core.sv wires them: the D$ looks up the LSU's physical dword (o_sb_addr), a refill holds the memory port
 * (the port mux gives it the bus while o_busy), the store buffer's writes update the D$ (here the testbench plays the
 * buffer: a posted store is written to memory and to the D$ a few cycles later, and loads to its dword see i_sb_match
 * until then), and the LSU's own writes past the buffer invalidate their line (o_dc_inv).
 *
 * The PMA window is the low 1 KiB of a 2 KiB slave; the line at 0x3C0 errs (a refill of it fails); above 0x800 the slave
 * errs as well. "Before the head" means an older op is the ROB head.
 *
 * Checked: a miss refills its line (WORDS beats, nothing else on the port) and completes with memory's dword; a hit
 * completes in its first cycle with no bus access, and with HANDOFF one load a cycle; a refill is never an access the
 * head started; a flush or a kill during a refill drains it (no writeback) and the line is still installed; a refill
 * that errs completes with cause 5 and installs nothing; head-only ops (an AMO, a load outside the window, a Program
 * Buffer access) go to the bus, and the writes among them empty their line from the D$; a load whose dword the buffer
 * still holds waits for it; a misaligned load traps without the D$; o_load_near is low for a hit. Then a random stream of
 * loads and stores against a golden memory, every load's value and raw RVFI word checked.
 */
module qv_lsu_dc_tb #(
    parameter bit HANDOFF = 1'b1
);
    import qv_pkg::*;

    int   pass_count = 0;
    int   fail_count = 0;
    logic quiet_on_pass = 1'b1;
    `include "check_lib.sv"

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic                    flush = 1'b0;
    fu_req_t                 req = '0;
    logic                    free;
    logic                    head_valid = 1'b0;
    logic [QV_ROB_TAG_W-1:0] head_tag = '0;
    logic                    early_ok = 1'b1;
    logic [31:0]             l_addr, addr;
    logic [63:0]             l_dat, dat_i;
    logic [7:0]              l_sel, sel;
    logic                    l_we, l_cyc, l_stb, we, cyc, ack, err;
    wb_t                     wb;
    lsu_res_t                res;
    logic                    started, lock, in_bus;
    logic                    pmp_bypass = 1'b0;
    logic                    sb_match = 1'b0, sb_beat = 1'b0;
    logic [31:3]             sb_addr;
    logic                    load_near, bus_busy, take;
    logic [(1<<QV_ROB_TAG_W)-1:0] kill_vec = '0;
    logic                    res_valid = 1'b0;
    logic [63:0]             res_addr = '0;
    // the D$
    logic        dc_hit, dc_busy, dc_fill_req, dc_fill, dc_fill_err, dc_inv, dc_cyc;
    logic [63:0] dc_dat, dc_fill_dat;
    logic [31:3] dc_addr;
    logic        tb_wr = 1'b0;                       // the testbench's "store buffer" writes a store
    logic [31:3] tb_wr_addr = '0;
    logic [7:0]  tb_wr_sel = '0;
    logic [63:0] tb_wr_dat = '0;

    qv_lsu #(.SB_EN(1'b1), .PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(64'h400), .EARLY(1'b1), .EARLY_ST(1'b1),
             .HANDOFF(HANDOFF), .DC_EN(1'b1)) dut (
        .i_kill_vec(kill_vec),
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag), .i_early(early_ok),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .i_pmp_bypass(pmp_bypass),
        .wb_mem_addr_o(l_addr), .wb_mem_dat_o(l_dat), .wb_mem_sel_o(l_sel), .wb_mem_we_o(l_we),
        .wb_mem_cyc_o(l_cyc), .wb_mem_stb_o(l_stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat_i), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(started),
        .o_bus_busy(bus_busy),
        .i_sb_empty(1'b1), .i_sb_match(sb_match), .i_sb_beat(sb_beat),
        .o_sb_addr(sb_addr), .o_load_near(load_near), .o_in_bus(in_bus), .o_take(take),
        .i_dc_hit(dc_hit), .i_dc_dat(dc_dat), .i_dc_busy(dc_busy), .o_dc_fill_req(dc_fill_req),
        .i_dc_fill(dc_fill), .i_dc_fill_dat(dc_fill_dat), .i_dc_fill_err(dc_fill_err), .o_dc_inv(dc_inv)
    );
    qv_dc #(.LINES(4), .WORDS(4)) dc0 (
        .clk(clk), .rst(rst),
        .i_addr(sb_addr), .o_hit(dc_hit), .o_dat(dc_dat), .o_busy(dc_busy),
        .i_fill_req(dc_fill_req), .o_fill(dc_fill), .o_fill_dat(dc_fill_dat), .o_fill_err(dc_fill_err),
        .i_wr(tb_wr), .i_wr_addr(tb_wr_addr), .i_wr_sel(tb_wr_sel), .i_wr_dat(tb_wr_dat),
        .i_inv(dc_inv), .i_inv_addr(sb_addr),
        .o_beat(dc_cyc), .o_addr(dc_addr), .i_ack(ack), .i_err(err), .i_dat(dat_i)
    );
    // the port, as core.sv muxes it
    assign addr = dc_busy ? {dc_addr, 3'b000} : l_addr;
    assign sel  = dc_busy ? 8'hFF : l_sel;
    assign we   = dc_busy ? 1'b0 : l_we;
    assign cyc  = dc_busy ? dc_cyc : l_cyc;

    // ---------------- the slave and the golden memory ----------------
    localparam int WORDS = 256;                      // 2 KiB
    logic [63:0] mem [0:WORDS-1];
    int   accesses = 0, writes = 0;
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    logic proto_ok = 1'b1;
    int   wait_max = 0;
    function automatic logic [63:0] merge(input logic [63:0] o, input logic [7:0] s, input logic [63:0] d);
        logic [63:0] r;
        r = o;
        for (int i = 0; i < 8; i++) if (s[i]) r[8*i +: 8] = d[8*i +: 8];
        return r;
    endfunction
    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) busy <= 1'b0;
        else if (!busy && cyc) begin
            busy <= 1'b1;
            h_addr <= addr; h_dat <= l_dat; h_sel <= sel; h_we <= we;
            wait_left <= (wait_max > 0) ? ($urandom % (wait_max + 1)) : 0;
            accesses <= accesses + 1;
            if (we) writes <= writes + 1;
        end else if (busy) begin
            if (!cyc || addr != h_addr || sel != h_sel || we != h_we) begin
                if (proto_ok) $display("PROTO: request changed or dropped before its response at %0t", $time);
                proto_ok <= 1'b0;
            end
            if (wait_left > 0) wait_left <= wait_left - 1;
            else begin
                busy <= 1'b0;
                if (h_addr >= 32'h800 || h_addr[31:6] == 26'(32'h3C0 >> 6)) err <= 1'b1;
                else begin
                    ack <= 1'b1;
                    if (h_we) mem[h_addr[10:3]] <= merge(mem[h_addr[10:3]], h_sel, h_dat);
                    dat_i <= mem[h_addr[10:3]];
                end
            end
        end
    end
    always @(negedge clk)
        if (!rst && (ack || err) && cyc) begin
            if (proto_ok) $display("PROTO: cyc still high in the response cycle at %0t", $time);
            proto_ok = 1'b0;
        end
    // the refill is alone on the port: the LSU drives nothing while the D$ refills
    logic overlap = 1'b0;
    always @(negedge clk) if (!rst && dc_busy && l_cyc) overlap = 1'b1;

    // ---------------- helpers ----------------
    logic [QV_ROB_TAG_W-1:0] next_tag = 4'd5;
    logic [QV_ROB_TAG_W-1:0] last_tag;
    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    task automatic dispatch(input logic atomic, input qv_amo_op_e aop, input logic store, input logic [1:0] size,
                            input logic [63:0] a, input logic [63:0] data);
        @(negedge clk); #1;
        check("dispatch: slot free", b(free), 64'd1);
        last_tag = next_tag;
        next_tag = next_tag + 1'b1;
        req       = '0;
        req.valid = 1'b1;
        req.tag   = last_tag;
        if (atomic) begin
            req.op = {1'b1, 4'(aop)}; req.is_word = (size == 2); req.a = a; req.b = data;
        end else begin
            req.op = {1'b0, store, 1'b1, size}; req.a = a; req.b = store ? data : 64'd0; req.imm = 64'd0;
        end
        @(posedge clk); #1;
        req = '0;
    endtask

    logic        got_wb, any_started;
    int          wb_cycle, acc_d;
    logic [63:0] wb_value;
    task automatic run_with_head(input logic [QV_ROB_TAG_W-1:0] t, input int limit);
        int acc0;
        acc0 = accesses;
        got_wb = 1'b0; wb_cycle = -1; any_started = 1'b0;
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;
        for (int c = 0; c < limit; c++) begin
            #1;
            if (started) any_started = 1'b1;
            if (wb.valid && !got_wb) begin
                got_wb = 1'b1; wb_cycle = c; wb_value = wb.value;
                check("wb tag", {60'b0, wb.tag}, {60'b0, last_tag});
            end
            @(posedge clk);
            if (got_wb) c = limit;
        end
        #1;
        @(negedge clk);
        head_valid = 1'b0;
        acc_d = accesses - acc0;
    endtask
    task automatic before_head(input int limit); run_with_head(last_tag - 1'b1, limit); endtask
    task automatic at_head(input int limit);     run_with_head(last_tag, limit);        endtask
    task automatic settle(); repeat (8) @(posedge clk); #1; endtask

    // the testbench's store buffer: write a posted store to memory and to the D$ (one cycle, the port idle)
    task automatic drain(input logic [31:3] a, input logic [7:0] s, input logic [63:0] d);
        @(negedge clk);
        while (dc_busy || l_cyc || busy) @(negedge clk);
        tb_wr = 1'b1; tb_wr_addr = a; tb_wr_sel = s; tb_wr_dat = d;
        mem[a[10:3]] = merge(mem[a[10:3]], s, d);
        @(negedge clk);
        tb_wr = 1'b0;
    endtask

    // ---------------- tests ----------------
    logic [QV_ROB_TAG_W-1:0] t1;
    int   c_hit0, c_hit1;
    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = {32'hA5A5_0000 + i[15:0], 32'h5A5A_0000 + i[15:0]};
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // ---- a miss refills the line, then a hit takes no bus at all ----
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h048, 64'd0);
        before_head(30);
        check("miss: completes before the head", b(got_wb), 64'd1);
        check("miss: the line's 4 beats", 64'(acc_d), 64'd4);
        check("miss: memory's dword", wb_value, mem[8'h09]);
        check("miss: rvfi rdata is the dword", res.mem_rdata, mem[8'h09]);
        check("miss: no exception", b(res.xcpt), 64'd0);
        check("miss: the refill is not an access the head started", b(any_started), 64'd0);
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd2, 64'h05C, 64'd0);
        before_head(10);
        check("hit: completes", b(got_wb), 64'd1);
        check("hit: in its first cycle", 64'(wb_cycle), 64'd0);
        check("hit: no bus access", 64'(acc_d), 64'd0);
        check("hit: the sign-extended upper word", wb_value, {{32{mem[8'h0B][63]}}, mem[8'h0B][63:32]});
        check("hit: rvfi rdata is the dword", res.mem_rdata, mem[8'h0B]);
        // at the head too
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h050, 64'd0);
        at_head(10);
        check("hit at the head: completes in its first cycle", 64'(wb_cycle), 64'd0);
        check("hit at the head: no bus", 64'(acc_d), 64'd0);

        // ---- with HANDOFF, two hits back to back: the second is taken in the first's cycle ----
        if (HANDOFF) begin
            @(negedge clk); #1;
            head_valid = 1'b1; head_tag = next_tag - 1'b1;      // an older op is the head: both go early
            req = '0; req.valid = 1'b1; req.tag = next_tag; req.op = {1'b0, 1'b0, 1'b1, 2'd3}; req.a = 64'h040;
            last_tag = next_tag; next_tag = next_tag + 1'b1;
            @(posedge clk); #1;
            req.tag = next_tag; req.a = 64'h058; t1 = next_tag; last_tag = next_tag; next_tag = next_tag + 1'b1;
            c_hit0 = -1; c_hit1 = -1;
            for (int c = 0; c < 6; c++) begin
                if (take && req.tag == t1 && !(wb.valid && wb.tag == t1)) begin end
                if (wb.valid && wb.tag == t1 - 1'b1) c_hit0 = c;
                if (wb.valid && wb.tag == t1) c_hit1 = c;
                if (take && req.tag == t1) begin @(posedge clk); #1; req = '0; end
                else begin @(posedge clk); #1; end
            end
            check("handoff: first hit completes", b(c_hit0 >= 0), 64'd1);
            check("handoff: the second the very next cycle", 64'(c_hit1 - c_hit0), 64'd1);
            @(negedge clk); head_valid = 1'b0; req = '0;
        end

        // ---- a flush during a refill drains it; the line is still installed ----
        wait_max = 2;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h080, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1;
        repeat (3) @(posedge clk); #1;
        check("flush: a refill in progress", b(dc_busy), 64'd1);
        @(negedge clk); flush = 1'b1; @(negedge clk); flush = 1'b0; head_valid = 1'b0;
        got_wb = 1'b0;
        for (int c = 0; c < 30; c++) begin @(posedge clk); #1; if (wb.valid) got_wb = 1'b1; end
        check("flush: no writeback", b(got_wb), 64'd0);
        check("flush: the slot is free again", b(free), 64'd1);
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h088, 64'd0);
        before_head(10);
        check("flush: the line was installed (a hit)", 64'(acc_d), 64'd0);
        check("flush: memory's dword", wb_value, mem[8'h11]);

        // ---- a kill during a refill (an early load): drained, no writeback ----
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h0C0, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1;
        repeat (3) @(posedge clk); #1;
        @(negedge clk); kill_vec[last_tag] = 1'b1; @(negedge clk); kill_vec = '0; head_valid = 1'b0;
        got_wb = 1'b0;
        for (int c = 0; c < 30; c++) begin @(posedge clk); #1; if (wb.valid) got_wb = 1'b1; end
        check("kill: no writeback", b(got_wb), 64'd0);
        check("kill: the slot is free again", b(free), 64'd1);
        wait_max = 0;

        // ---- a refill that errs: cause 5, nothing installed ----
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h3C8, 64'd0);
        at_head(30);
        check("refill error: completes", b(got_wb), 64'd1);
        check("refill error: an exception", b(res.xcpt), 64'd1);
        check("refill error: cause 5", {60'b0, res.cause}, 64'd5);
        check("a refill at the head: not an access the head started", b(any_started), 64'd0);
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h3C8, 64'd0);
        at_head(30);
        check("refill error: not installed (refilled again)", b(acc_d > 0), 64'd1);

        // ---- head-only ops go to the bus; the writes among them empty their line ----
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h040, 64'd0);                 // the line at 0x40 (index 2: the
        before_head(30);                                                         // 0xC0 and 0x3C0 refills took it)
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h040, 64'd0);
        before_head(10);
        check("held line: a hit", 64'(acc_d), 64'd0);
        dispatch(1'b1, QV_AMO_ADD, 1'b0, 2'd3, 64'h040, 64'd7);                // an AMO at the head
        before_head(10);
        check("AMO: nothing before the head", b(got_wb), 64'd0);
        at_head(30);
        check("AMO: on the bus (read and write)", 64'(acc_d), 64'd2);
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h040, 64'd0);
        before_head(30);
        check("after the AMO: the line was emptied (a refill)", 64'(acc_d), 64'd4);
        check("after the AMO: the new dword", wb_value, mem[8'h08]);
        // a Program Buffer store: to the bus, the line goes
        pmp_bypass = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h048, 64'h1234);
        at_head(20);
        check("progbuf store: on the bus", 64'(acc_d), 64'd1);
        pmp_bypass = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h048, 64'd0);
        before_head(30);
        check("after the progbuf store: refilled", 64'(acc_d), 64'd4);
        check("after the progbuf store: its data", wb_value, 64'h1234);
        // a Program Buffer load: to the bus at the head, even from a held line
        pmp_bypass = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h048, 64'd0);
        before_head(8);
        check("progbuf load: nothing early", b(got_wb), 64'd0);
        at_head(20);
        check("progbuf load: one bus access, not the D$", 64'(acc_d), 64'd1);
        check("progbuf load: its data", wb_value, 64'h1234);
        pmp_bypass = 1'b0;
        // a drain beat in flight holds a miss back: no refill until it is over
        sb_beat = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h100, 64'd0);
        before_head(6);
        check("drain beat: the miss waits", b(got_wb), 64'd0);
        check("drain beat: no refill beat", 64'(acc_d), 64'd0);
        sb_beat = 1'b0;
        before_head(30);
        check("drain beat over: refilled", 64'(acc_d), 64'd4);
        check("drain beat over: memory's dword", wb_value, mem[8'h20]);
        // a load outside the window: the bus, at the head only
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h500, 64'd0);
        before_head(8);
        check("outside the window: nothing early", b(got_wb), 64'd0);
        at_head(20);
        check("outside the window: one bus access", 64'(acc_d), 64'd1);
        check("outside the window: memory's dword", wb_value, mem[8'hA0]);

        // ---- a load whose dword the buffer still holds waits; misaligned traps; load_near ----
        sb_match = 1'b1; early_ok = 1'b0;                // at the head (an early one would go the cycle it clears)
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h050, 64'd0);
        at_head(8);
        check("buffer match: waits", b(got_wb), 64'd0);
        sb_match = 1'b0;
        at_head(8);
        check("buffer match gone: a hit", b(got_wb), 64'd1);
        check("buffer match gone: no bus", 64'(acc_d), 64'd0);
        early_ok = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h052, 64'd0);   // its dword's line is held
        before_head(8);
        check("misaligned: nothing before the head (no D$ answer)", b(got_wb), 64'd0);
        at_head(8);
        check("misaligned: traps", b(res.xcpt), 64'd1);
        check("misaligned: no bus", 64'(acc_d), 64'd0);
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h050, 64'd0);
        early_ok = 1'b0;
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1; #1;
        check("a hit: not a load near the head (it needs no port)", b(load_near), 64'd0);
        early_ok = 1'b1;
        at_head(8);

        // ---- random: loads and stores (posted, then drained into memory and the D$) against memory ----
        wait_max = 2;
        for (int i = 0; i < 3000; i++) begin
            logic [63:0] a, d;
            logic        st;
            logic [1:0]  sz;
            sz = 2'($urandom % 4);
            a  = 64'(($urandom % 120) * 8) + ((sz == 0) ? 64'($urandom % 8) : (sz == 1) ? 64'(($urandom % 4) * 2)
                                              : (sz == 2) ? 64'(($urandom % 2) * 4) : 64'd0);
            st = ($urandom % 3) == 0;
            d  = {$urandom, $urandom};
            dispatch(1'b0, QV_AMO_LR, st, sz, a, d);
            if (($urandom % 2) == 0) before_head(40); else at_head(40);
            if (!got_wb) at_head(40);
            check($sformatf("random %0d: completes", i), b(got_wb), 64'd1);
            if (st) begin
                check($sformatf("random %0d: a store is posted", i), b(res.posted), 64'd1);
                drain(a[31:3], res.mem_wmask, res.mem_wdata);
            end else begin
                logic [63:0] w, sh, v;
                w  = mem[a[10:3]];
                sh = w >> {a[2:0], 3'b000};
                v  = (sz == 0) ? {{56{sh[7]}}, sh[7:0]} : (sz == 1) ? {{48{sh[15]}}, sh[15:0]}
                   : (sz == 2) ? {{32{sh[31]}}, sh[31:0]} : sh;
                check($sformatf("random %0d: no exception", i), b(res.xcpt), 64'd0);
                check($sformatf("random %0d: the load's value", i), wb_value, v);
                check($sformatf("random %0d: the raw dword", i), res.mem_rdata, w);
            end
        end
        settle();
        check("the port's protocol held throughout", b(proto_ok), 64'd1);
        check("the LSU never drove the port during a refill", b(overlap), 64'd0);

        $display("");
        $display("qv_lsu_dc_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsu_dc_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
