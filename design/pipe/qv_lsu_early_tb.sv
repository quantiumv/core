// SPDX-License-Identifier: MIT

/*
 * qv_lsu_early_tb -- the early accesses of design/pipe/qv_lsu.sv (EARLY = 1, with the store buffer on, SB_EN = 1),
 * on their own so qv_lsu_tb and qv_lsu_sb_tb keep testing the LSU without them.
 *
 * The PMA window is the low 1 KiB of a 2 KiB slave, as in qv_lsu_sb_tb. "Before the head" means the ROB head is
 * another, older op (head_tag one less than the op's tag); i_early is the queue's word that no barrier is older.
 *
 * Before the head, with i_early: a plain load from RAM starts its bus access (and completes, with its data, before
 * it is the head), a plain store to RAM is posted (EARLY_ST = 1; with EARLY_ST = 0 it waits for the head). Neither
 * counts as an access the head started (o_head_started stays low, also once the op is the head while its early
 * access is still on the bus). Everything else waits for the head and then does what qv_lsu does there: without
 * i_early; outside the window; misaligned (a trap at the head); PMP-denied (a trap at the head); an atomic; a
 * Program Buffer access; a load whose dword has a buffered or posted store (i_sb_match). A flush while an early load
 * is on the bus drains it (no writeback); one while it waits drops it. o_load_near, for a load near the head, says
 * yes only when it may start now: with i_early, or once it is the head.
 */
module qv_lsu_early_tb #(
    parameter bit EARLY_ST = 1'b1
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
    logic                    early_ok = 1'b0;
    logic [31:0]             addr;
    logic [63:0]             dat_o, dat_i;
    logic [7:0]              sel;
    logic                    we, cyc, stb, ack, err;
    wb_t                     wb;
    lsu_res_t                res;
    logic                    started, lock, in_bus;
    logic                    pmp_bypass = 1'b0;
    logic [1:0]              priv = 2'b11;
    logic [63:0]             pmpcfg0 = 64'h1F, pmpaddr0 = 64'h003F_FFFF_FFFF_FFFF;
    logic                    sb_empty = 1'b1, sb_match = 1'b0, sb_beat = 1'b0, sb_go = 1'b0;
    logic [31:3]             sb_addr;
    logic                    load_near, bus_busy;

    qv_lsu #(.SB_EN(1'b1), .PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(64'h400), .EARLY(1'b1), .EARLY_ST(EARLY_ST)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag), .i_early(early_ok),
        .i_priv(priv), .i_pmp_bypass(pmp_bypass),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(dat_o), .wb_mem_sel_o(sel), .wb_mem_we_o(we),
        .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat_i), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(started),
        .o_bus_busy(bus_busy),
        .i_sb_empty(sb_empty), .i_sb_match(sb_match), .i_sb_beat(sb_beat), .i_sb_go(sb_go),
        .o_sb_addr(sb_addr), .o_load_near(load_near), .o_in_bus(in_bus)
    );

    // ---------------- slave model (as in qv_lsu_sb_tb, with a settable latency) ----------------
    localparam int WORDS = 256;                      // 2 KiB
    logic [63:0] mem [0:WORDS-1];
    int   accesses = 0, writes = 0;
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    logic proto_ok = 1'b1;
    int   wait_fix = 0;                              // wait states of every access

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) busy <= 1'b0;
        else if (!busy && cyc && stb) begin
            busy <= 1'b1;
            h_addr <= addr; h_dat <= dat_o; h_sel <= sel; h_we <= we;
            wait_left <= wait_fix;
            accesses <= accesses + 1;
            if (we) writes <= writes + 1;
        end else if (busy) begin
            if (!(cyc && stb) || addr != h_addr || sel != h_sel || we != h_we) begin
                if (proto_ok) $display("PROTO: request changed or dropped before its response");
                proto_ok <= 1'b0;
            end
            if (wait_left > 0) wait_left <= wait_left - 1;
            else begin
                busy <= 1'b0;
                if (h_addr >= 32'h800) err <= 1'b1;
                else begin
                    ack <= 1'b1;
                    if (h_we)
                        for (int i = 0; i < 8; i++)
                            if (h_sel[i]) mem[h_addr[10:3]][8*i +: 8] <= h_dat[8*i +: 8];
                    dat_i <= mem[h_addr[10:3]];
                end
            end
        end
    end
    always @(negedge clk)
        if (!rst && (ack || err) && cyc) begin
            if (proto_ok) $display("PROTO: cyc still high in the response cycle");
            proto_ok = 1'b0;
        end

    // ---------------- helpers ----------------
    logic [QV_ROB_TAG_W-1:0] next_tag = 4'd5;
    logic [QV_ROB_TAG_W-1:0] last_tag;

    // dispatch one op and leave it waiting (no head)
    task automatic dispatch(input logic atomic, input qv_amo_op_e aop, input logic store, input logic [1:0] size,
                            input logic [63:0] a, input logic [63:0] data);
        @(negedge clk); #1;
        check("dispatch: slot free", {63'b0, free}, 64'd1);
        last_tag = next_tag;
        next_tag = next_tag + 1'b1;
        req       = '0;
        req.valid = 1'b1;
        req.tag   = last_tag;
        if (atomic) begin
            req.op = {1'b1, 4'(aop)};
            req.is_word = (size == 2);
            req.a = a;
            req.b = data;
        end else begin
            req.op  = {1'b0, store, 1'b1, size};
            req.a   = a;
            req.b   = store ? data : 64'd0;
            req.imm = 64'd0;
        end
        @(posedge clk); #1;
        req = '0;
    endtask

    // run `limit` cycles with the head at `t` (head_valid high); report the writeback, the bus and o_head_started
    logic        got_wb, any_started;
    int          wb_cycle, acc_d, wr_d;
    logic [63:0] wb_value;
    task automatic run_with_head(input logic [QV_ROB_TAG_W-1:0] t, input int limit);
        int acc0, wr0;
        acc0 = accesses; wr0 = writes;
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
        wr_d  = writes - wr0;
    endtask
    // before the head: an older op is the head
    task automatic before_head(input int limit); run_with_head(last_tag - 1'b1, limit); endtask
    task automatic at_head(input int limit);     run_with_head(last_tag, limit);        endtask

    task automatic settle(); repeat (6) @(posedge clk); #1; endtask
    function automatic logic [63:0] b(input logic x); return {63'b0, x}; endfunction

    // ---------------- tests ----------------
    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = {32'hA5A5_0000 + i[15:0], 32'h5A5A_0000 + i[15:0]};
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // ---- a plain load from RAM, no barrier older: it is done before it is the head ----
        early_ok = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h040, 64'd0);
        before_head(20);
        check("early load: completes before the head", b(got_wb), 64'd1);
        check("early load: one bus access", 64'(acc_d), 64'd1);
        check("early load: the memory word", wb_value, mem[8'h08]);
        check("early load: no exception", b(res.xcpt), 64'd0);
        check("early load: rvfi rdata is the bus word", res.mem_rdata, mem[8'h08]);
        check("early load: never counted as an access the head started", b(any_started), 64'd0);
        check("early load: the slot is free again", b(free), 64'd1);
        // a sub-dword one, sign-extended
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd2, 64'h04C, 64'd0);
        before_head(20);
        check("early lw: completes before the head", b(got_wb), 64'd1);
        check("early lw: sign-extended upper word", wb_value, {{32{mem[8'h09][63]}}, mem[8'h09][63:32]});

        // ---- with a barrier older (no i_early) it waits for the head ----
        early_ok = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h050, 64'd0);
        before_head(12);
        check("barrier older: no completion before the head", b(got_wb), 64'd0);
        check("barrier older: no bus access", 64'(acc_d), 64'd0);
        at_head(20);
        check("barrier older: done at the head", b(got_wb), 64'd1);
        check("barrier older: an access the head started", b(any_started), 64'd1);
        check("barrier older: the memory word", wb_value, mem[8'h0A]);
        // ... and if the barrier retires while it waits (i_early rises), it goes then
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h058, 64'd0);
        before_head(6);
        check("barrier older, still: nothing", 64'(acc_d), 64'd0);
        early_ok = 1'b1;
        before_head(20);
        check("barrier retired: goes before the head", b(got_wb), 64'd1);
        check("... the memory word", wb_value, mem[8'h0B]);

        // ---- the ones that wait for the head even with i_early ----
        early_ok = 1'b1;
        // outside the window (valid memory): only at the head
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h420, 64'd0);
        before_head(12);
        check("load outside the window: nothing before the head", 64'(acc_d), 64'd0);
        check("... no completion", b(got_wb), 64'd0);
        at_head(20);
        check("load outside the window: at the head", b(got_wb), 64'd1);
        check("... one access", 64'(acc_d), 64'd1);
        // misaligned: the trap is the head's
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h044, 64'd0);
        before_head(12);
        check("misaligned load: nothing before the head", b(got_wb), 64'd0);
        at_head(8);
        check("misaligned load: traps at the head", b(res.xcpt), 64'd1);
        check("... cause 4", {60'b0, res.cause}, 64'd4);
        check("... no bus", 64'(acc_d), 64'd0);
        // PMP-denied (U mode, region 0 NAPOT over everything, no permissions): the trap is the head's
        priv = 2'b00; pmpcfg0 = 64'h18;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h060, 64'd0);
        before_head(12);
        check("PMP-denied load: nothing before the head", b(got_wb), 64'd0);
        check("... no bus", 64'(acc_d), 64'd0);
        at_head(8);
        check("PMP-denied load: traps at the head", b(res.xcpt), 64'd1);
        check("... cause 5", {60'b0, res.cause}, 64'd5);
        priv = 2'b11; pmpcfg0 = 64'h1F;
        // an atomic: LR in RAM
        dispatch(1'b1, QV_AMO_LR, 1'b0, 2'd3, 64'h068, 64'd0);
        before_head(12);
        check("LR in RAM: nothing before the head", b(got_wb), 64'd0);
        check("... no bus", 64'(acc_d), 64'd0);
        at_head(20);
        check("LR: at the head", b(got_wb), 64'd1);
        // an AMO
        dispatch(1'b1, QV_AMO_ADD, 1'b0, 2'd3, 64'h070, 64'd1);
        before_head(12);
        check("AMO in RAM: nothing before the head", 64'(acc_d), 64'd0);
        at_head(30);
        check("AMO: at the head", b(got_wb), 64'd1);
        settle();
        // a Program Buffer access
        pmp_bypass = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h078, 64'd0);
        before_head(12);
        check("Program Buffer load: nothing before the head", b(got_wb), 64'd0);
        at_head(20);
        check("Program Buffer load: at the head", b(got_wb), 64'd1);
        pmp_bypass = 1'b0;
        // a load whose dword has a store not in memory yet
        sb_match = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h080, 64'd0);
        before_head(12);
        check("load with a matching store: waits", b(got_wb), 64'd0);
        check("... no bus", 64'(acc_d), 64'd0);
        sb_match = 1'b0;
        before_head(20);
        check("match gone: goes before the head", b(got_wb), 64'd1);

        // ---- a plain store to RAM: posted before the head (EARLY_ST), or at the head ----
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h088, 64'h0123_4567_89AB_CDEF);
        before_head(8);
        if (EARLY_ST) begin
            check("early store: posted before the head", b(got_wb), 64'd1);
            check("early store: posted", b(res.posted), 64'd1);
            check("early store: no bus", 64'(acc_d), 64'd0);
            check("early store: the data in o_res", res.mem_wdata, 64'h0123_4567_89AB_CDEF);
        end else begin
            check("store, loads only early: nothing before the head", b(got_wb), 64'd0);
            at_head(8);
            check("store, loads only early: posted at the head", b(res.posted), 64'd1);
            check("... in the head cycle", 64'(wb_cycle), 64'd0);
        end
        // a store that is not postable (outside the window) only at the head
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h430, 64'h1);
        before_head(12);
        check("store outside the window: nothing before the head", b(got_wb), 64'd0);
        check("... no bus", 64'(acc_d), 64'd0);
        at_head(20);
        check("store outside the window: on the bus at the head", 64'(wr_d), 64'd1);

        // ---- an early load still on the bus when it becomes the head is not the head's access ----
        wait_fix = 4;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h090, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1;
        @(posedge clk); #1;
        check("slow early load: on the bus", b(cyc), 64'd1);
        @(negedge clk); head_tag = last_tag;           // the older op retired: this one is the head now
        #1;
        check("... now the head, its early access in flight: not one the head started", b(started), 64'd0);
        at_head(20);
        check("... completes", b(got_wb), 64'd1);
        check("... never counted as the head's", b(any_started), 64'd0);
        check("... the memory word", wb_value, mem[8'h12]);
        // a head load on a slow slave: o_head_started high while it is on the bus (the control)
        early_ok = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h098, 64'd0);
        at_head(20);
        check("slow head load: counted as the head's", b(any_started), 64'd1);
        early_ok = 1'b1;

        // ---- a flush while an early load is on the bus: drained, no writeback ----
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h0A0, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1;
        @(posedge clk); #1;
        check("early load to flush: on the bus", b(cyc), 64'd1);
        @(negedge clk); flush = 1'b1; head_valid = 1'b0;
        @(posedge clk); #1; flush = 1'b0;
        check("flushed early load: the request is held (drained)", b(cyc), 64'd1);
        begin
            logic wb_seen; wb_seen = 1'b0;
            for (int c = 0; c < 10; c++) begin #1; if (wb.valid) wb_seen = 1'b1; @(posedge clk); end
            check("flushed early load: no writeback", b(wb_seen), 64'd0);
        end
        check("flushed early load: the slot is free after the response", b(free), 64'd1);
        // ... one that waits (a match holds it) is dropped
        sb_match = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h0A8, 64'd0);
        @(negedge clk); flush = 1'b1;
        @(posedge clk); #1; flush = 1'b0; sb_match = 1'b0;
        check("flushed waiting load: the slot is free at once", b(free), 64'd1);
        settle();
        check("... with no bus access", b(cyc), 64'd0);
        wait_fix = 0;

        // ---- o_load_near: only for a load that may start now ----
        sb_beat = 1'b1;                                  // a drain beat holds every start off
        early_ok = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h0B0, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 1'b1;
        #1;
        check("load next to the head, barrier older: the drain does not yield to it", b(load_near), 64'd0);
        early_ok = 1'b1; #1;
        check("... with no barrier: it does", b(load_near), 64'd1);
        early_ok = 1'b0; head_tag = last_tag; #1;
        check("... barrier older but it is the head: it does", b(load_near), 64'd1);
        sb_beat = 1'b0;
        at_head(20);
        check("... then it runs", b(got_wb), 64'd1);
        early_ok = 1'b1;

        settle();
        check("bus protocol kept throughout", b(proto_ok), 64'd1);
        $display("");
        $display("qv_lsu_early_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsu_early_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
