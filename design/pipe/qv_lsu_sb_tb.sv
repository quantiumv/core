// SPDX-License-Identifier: MIT

/*
 * qv_lsu_sb_tb -- the store-buffer side of design/pipe/qv_lsu.sv (SB_EN = 1), on its own so qv_lsu_tb keeps
 * testing the LSU without it.
 *
 * The PMA window is the low 1 KiB of a 2 KiB slave: addresses 0x000-0x3FF are RAM and are posted, 0x400-0x7FF
 * are valid memory outside the window, above that the slave errors. The store buffer is modelled by the
 * testbench's own inputs (empty, match, a beat in flight, a beat decided).
 *
 * A plain store to RAM completes in the head cycle with no bus access and o_res.posted set, the RVFI bus
 * fields in o_res, and the slot free at once; misaligned, PMP-denied or faulting ones still trap and are not
 * posted. A plain load from RAM reads memory as usual unless the buffer holds a store to its dword (it waits
 * until that is gone, with no bus access meanwhile). An atomic, a load or store outside the window, and a
 * Program Buffer access wait for an empty buffer. A drain beat in flight or decided in the cycle holds start
 * off, and the LSU's request cannot be swallowed by a response that is not its own. o_load_near is high for a
 * plain RAM load that does not wait for the buffer, among the three oldest ROB entries, once translated.
 */
module qv_lsu_sb_tb;
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
    logic                    foreign_ack = 1'b0;      // a response that is not the LSU's

    qv_lsu #(.SB_EN(1'b1), .PMA_RAM_BASE(64'h0), .PMA_RAM_SIZE(64'h400)) dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .i_priv(priv), .i_pmp_bypass(pmp_bypass),
        .i_pmpcfg0(pmpcfg0), .i_pmpaddr0(pmpaddr0),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(dat_o), .wb_mem_sel_o(sel), .wb_mem_we_o(we),
        .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat_i), .wb_mem_ack_i(ack | foreign_ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(started),
        .o_bus_busy(bus_busy),
        .i_sb_empty(sb_empty), .i_sb_match(sb_match), .i_sb_beat(sb_beat), .i_sb_go(sb_go),
        .o_sb_addr(sb_addr), .o_load_near(load_near), .o_in_bus(in_bus)
    );

    // ---------------- slave model ----------------
    localparam int WORDS = 256;                      // 2 KiB
    logic [63:0] mem [0:WORDS-1];
    int   accesses = 0, writes = 0;
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    logic proto_ok = 1'b1;
    int   wait_max = 1;

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) busy <= 1'b0;
        else if (!busy && cyc && stb) begin
            busy <= 1'b1;
            h_addr <= addr; h_dat <= dat_o; h_sel <= sel; h_we <= we;
            wait_left <= $urandom % (wait_max + 1);
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
    logic [QV_ROB_TAG_W-1:0] next_tag = '0;
    logic [QV_ROB_TAG_W-1:0] last_tag;

    // dispatch one op and leave it waiting (no head yet)
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
            req.a   = store ? a : a;
            req.b   = store ? data : 64'd0;
            req.imm = store ? 64'd0 : 64'hDEAD;
        end
        @(posedge clk); #1;
        req = '0;
    endtask

    // become the head and run for up to `limit` cycles; report when/whether wb came and the bus activity
    logic        got_wb;
    int          wb_cycle, acc_d, wr_d, cyc_cycles;
    logic [63:0] wb_value;
    task automatic go_head(input int limit);
        int acc0, wr0, c;
        acc0 = accesses; wr0 = writes;
        got_wb = 1'b0; wb_cycle = -1; cyc_cycles = 0;
        @(negedge clk);
        head_valid = 1'b1; head_tag = last_tag;
        for (c = 0; c < limit; c++) begin
            #1;
            if (cyc) cyc_cycles++;
            if (wb.valid && !got_wb) begin
                got_wb = 1'b1; wb_cycle = c; wb_value = wb.value;
                check("wb tag", {60'b0, wb.tag}, {60'b0, last_tag});
            end
            @(posedge clk);
            if (got_wb) c = limit;
        end
        #1;
        // commit would pop it now: take the head away
        @(negedge clk);
        head_valid = 1'b0;
        acc_d = accesses - acc0;
        wr_d  = writes - wr0;
    endtask

    task automatic settle(); repeat (6) @(posedge clk); #1; endtask

    // ---------------- tests ----------------
    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = {32'hA5A5_0000 + i[15:0], 32'h5A5A_0000 + i[15:0]};
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        // ---- a plain store to RAM is posted: done in the head cycle, no bus, o_res says posted ----
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h108, 64'hDEAD_BEEF_0123_4567);
        check("posted store: slot taken", {63'b0, free}, 64'd0);
        check("posted store: the match lookup names its dword", {35'b0, sb_addr}, 64'h108 >> 3);
        go_head(8);
        check("posted store: completes", {63'b0, got_wb}, 64'd1);
        check("posted store: in the head cycle", 64'(wb_cycle), 64'd0);
        check("posted store: no bus access", 64'(acc_d), 64'd0);
        check("posted store: slot free at once", {63'b0, free}, 64'd1);
        check("posted store: posted", {63'b0, res.posted}, 64'd1);
        check("posted store: no exception", {63'b0, res.xcpt}, 64'd0);
        check("posted store: rvfi address", res.mem_addr, 64'h108);
        check("posted store: rvfi wmask", {56'b0, res.mem_wmask}, 64'hFF);
        check("posted store: rvfi rmask", {56'b0, res.mem_rmask}, 64'd0);
        check("posted store: rvfi wdata", res.mem_wdata, 64'hDEAD_BEEF_0123_4567);
        check("posted store: memory untouched", mem[8'h21], {32'hA5A5_0000 + 32'd33, 32'h5A5A_0000 + 32'd33});

        // sub-dword posted stores carry their lanes
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd1, 64'h156, 64'h0000_0000_0000_ABCD);
        go_head(8);
        check("posted sh: posted", {63'b0, res.posted}, 64'd1);
        check("posted sh: select lanes 6-7", {56'b0, res.mem_wmask}, 64'hC0);
        check("posted sh: data shifted to its lane", res.mem_wdata, 64'hABCD_0000_0000_0000);
        check("posted sh: address is the dword", res.mem_addr, 64'h150);

        // it does not matter that the buffer is not empty
        sb_empty = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd2, 64'h200, 64'h1234_5678);
        go_head(8);
        check("posted store with a non-empty buffer: still posted at once", 64'(wb_cycle), 64'd0);
        check("... and posted", {63'b0, res.posted}, 64'd1);
        sb_empty = 1'b1;

        // ---- stores that are not posted ----
        // misaligned: a trap, no bus, not posted
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h104, 64'h1);
        go_head(8);
        check("misaligned store in RAM: exception", {63'b0, res.xcpt}, 64'd1);
        check("misaligned store in RAM: cause 6", {60'b0, res.cause}, 64'd6);
        check("misaligned store in RAM: not posted", {63'b0, res.posted}, 64'd0);
        check("misaligned store in RAM: no bus", 64'(acc_d), 64'd0);

        // PMP-denied (U mode, region 0 NAPOT over everything, read-only): a trap, no bus, not posted
        priv = 2'b00; pmpcfg0 = 64'h19;
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h110, 64'h1);
        go_head(8);
        check("PMP-denied store in RAM: exception", {63'b0, res.xcpt}, 64'd1);
        check("PMP-denied store in RAM: cause 7", {60'b0, res.cause}, 64'd7);
        check("PMP-denied store in RAM: not posted", {63'b0, res.posted}, 64'd0);
        check("PMP-denied store in RAM: no bus", 64'(acc_d), 64'd0);
        // ... and a load of the same page is allowed (read-only) and goes to the bus
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h110, 64'd0);
        go_head(30);
        check("read-only page: the load reads", 64'(acc_d), 64'd1);
        priv = 2'b11; pmpcfg0 = 64'h1F;
        // outside the window, inside memory: executes on the bus
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h408, 64'h5555_6666_7777_8888);
        go_head(30);
        check("store outside the window: completes", {63'b0, got_wb}, 64'd1);
        check("store outside the window: on the bus", 64'(acc_d), 64'd1);
        check("store outside the window: a write", 64'(wr_d), 64'd1);
        check("store outside the window: not posted", {63'b0, res.posted}, 64'd0);
        check("store outside the window: memory written", mem[8'h81], 64'h5555_6666_7777_8888);

        // outside the window with a non-empty buffer: waits for it to empty
        sb_empty = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h410, 64'h9999_AAAA_BBBB_CCCC);
        go_head(12);
        check("store outside the window, buffer not empty: waits", {63'b0, got_wb}, 64'd0);
        check("... with no bus access", 64'(acc_d), 64'd0);
        sb_empty = 1'b1;
        go_head(30);
        check("store outside the window: goes once the buffer is empty", {63'b0, got_wb}, 64'd1);
        settle();
        check("... as a bus write", mem[8'h82], 64'h9999_AAAA_BBBB_CCCC);

        // ---- loads ----
        // a plain RAM load, nothing buffered for its dword: reads memory even though the buffer is not empty
        sb_empty = 1'b0; sb_match = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h040, 64'd0);
        go_head(30);
        check("load from RAM, no match: reads at once", {63'b0, got_wb}, 64'd1);
        check("... one bus access", 64'(acc_d), 64'd1);
        check("... the memory word", wb_value, mem[8'h08]);
        check("... not posted", {63'b0, res.posted}, 64'd0);

        // with a match it waits, with no bus access, until the match is gone
        sb_match = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h048, 64'd0);
        go_head(12);
        check("load from RAM, matching store: waits", {63'b0, got_wb}, 64'd0);
        check("... with no bus access", 64'(acc_d), 64'd0);
        check("... and the drain is not told to yield to it", {63'b0, load_near}, 64'd0);
        sb_match = 1'b0;
        go_head(30);
        check("load from RAM: reads once the match is gone", {63'b0, got_wb}, 64'd1);
        check("... the memory word", wb_value, mem[8'h09]);
        settle();

        // a load outside the window with the buffer not empty: waits for it to be empty
        sb_empty = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h420, 64'd0);
        go_head(12);
        check("load outside the window, buffer not empty: waits", {63'b0, got_wb}, 64'd0);
        check("... with no bus access", 64'(acc_d), 64'd0);
        sb_empty = 1'b1;
        go_head(30);
        check("load outside the window: reads once the buffer is empty", {63'b0, got_wb}, 64'd1);
        settle();

        // ---- atomics wait for an empty buffer ----
        sb_empty = 1'b0;
        dispatch(1'b1, QV_AMO_ADD, 1'b0, 2'd3, 64'h060, 64'd1);
        go_head(12);
        check("AMO in RAM, buffer not empty: waits", {63'b0, got_wb}, 64'd0);
        check("... with no bus access", 64'(acc_d), 64'd0);
        sb_empty = 1'b1;
        go_head(40);
        check("AMO: runs once the buffer is empty", {63'b0, got_wb}, 64'd1);
        settle();
        check("AMO: not posted", {63'b0, res.posted}, 64'd0);
        check("AMO: a bus write", 64'(wr_d), 64'd1);

        // ---- a Program Buffer store (pmp_bypass) in RAM is not posted either ----
        pmp_bypass = 1'b1;
        sb_empty = 1'b0;
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h070, 64'h1357_9BDF_0246_8ACE);
        go_head(12);
        check("Program Buffer store: waits for an empty buffer", {63'b0, got_wb}, 64'd0);
        sb_empty = 1'b1;
        go_head(40);
        check("Program Buffer store: runs on the bus", {63'b0, got_wb}, 64'd1);
        settle();
        check("Program Buffer store: not posted", {63'b0, res.posted}, 64'd0);
        check("Program Buffer store: memory written", mem[8'h0E], 64'h1357_9BDF_0246_8ACE);
        pmp_bypass = 1'b0;

        // ---- a drain beat holds start off (in flight, or decided this cycle) ----
        sb_beat = 1'b1;
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h080, 64'd0);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag;
        repeat (6) begin
            @(posedge clk); #1;
            check("drain beat in flight: the load does not start", {63'b0, cyc}, 64'd0);
        end
        check("... but it is ready: the walker and the drain see the LSU busy", {63'b0, bus_busy}, 64'd1);
        // a response that is not ours lands while the load is ready: nothing may be swallowed or completed
        @(negedge clk); foreign_ack = 1'b1;
        @(posedge clk); #1; foreign_ack = 1'b0;
        check("a foreign ack completes nothing", {63'b0, wb.valid}, 64'd0);
        @(negedge clk); sb_beat = 1'b0; sb_go = 1'b1; #1;
        check("drain beat decided this cycle: the load does not start", {63'b0, cyc}, 64'd0);
        @(negedge clk); sb_go = 1'b0;
        begin
            int c; logic done;
            done = 1'b0;
            for (c = 0; c < 30 && !done; c++) begin #1; if (wb.valid) done = 1'b1; @(posedge clk); end
            check("the load runs once the drain steps aside", {63'b0, done}, 64'd1);
        end
        @(negedge clk); head_valid = 1'b0; settle();

        // ---- o_load_near ----
        sb_beat = 1'b1;                              // keep it from starting while we look
        dispatch(1'b0, QV_AMO_LR, 1'b0, 2'd3, 64'h088, 64'd0);
        for (int d = 0; d < 5; d++) begin
            @(negedge clk); head_valid = 1'b1; head_tag = last_tag - QV_ROB_TAG_W'(d); #1;
            check($sformatf("load_near: %0d behind the head", d), {63'b0, load_near}, {63'b0, d <= 2});
        end
        // a matching load is not near (the drain must not yield to it)
        @(negedge clk); head_tag = last_tag - QV_ROB_TAG_W'(1); sb_match = 1'b1; #1;
        check("load_near: not when it waits for the buffer", {63'b0, load_near}, 64'd0);
        sb_match = 1'b0;
        // drop the op: flush
        @(negedge clk); flush = 1'b1; head_valid = 1'b0;
        @(posedge clk); #1; flush = 1'b0; sb_beat = 1'b0;
        check("flush: the slot is free again", {63'b0, free}, 64'd1);
        // a store and an atomic are never near
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h090, 64'd1);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 4'd1; #1;
        check("load_near: not for a store", {63'b0, load_near}, 64'd0);
        @(negedge clk); flush = 1'b1; head_valid = 1'b0;
        @(posedge clk); #1; flush = 1'b0;
        dispatch(1'b1, QV_AMO_ADD, 1'b0, 2'd3, 64'h098, 64'd1);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag - 4'd1; #1;
        check("load_near: not for an atomic", {63'b0, load_near}, 64'd0);
        @(negedge clk); flush = 1'b1; head_valid = 1'b0;
        @(posedge clk); #1; flush = 1'b0;

        // ---- a flush drops a posted store that has not reached the head ----
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h0A0, 64'd7);
        @(negedge clk); flush = 1'b1;
        @(posedge clk); #1; flush = 1'b0;
        check("flush before the head: slot free", {63'b0, free}, 64'd1);
        check("flush before the head: no completion", {63'b0, wb.valid}, 64'd0);

        // a flush in the cycle it would have been posted drops it as well
        dispatch(1'b0, QV_AMO_LR, 1'b1, 2'd3, 64'h0A8, 64'd8);
        @(negedge clk); head_valid = 1'b1; head_tag = last_tag; flush = 1'b1; #1;
        check("flush in the head cycle: no completion", {63'b0, wb.valid}, 64'd0);
        @(posedge clk); #1; flush = 1'b0; head_valid = 1'b0;
        check("flush in the head cycle: slot free", {63'b0, free}, 64'd1);

        check("slave protocol held", {63'b0, proto_ok}, 64'd1);
        $display("");
        $display("qv_lsu_sb_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsu_sb_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
