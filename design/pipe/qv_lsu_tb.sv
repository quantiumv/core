// SPDX-License-Identifier: MIT

/*
 * qv_lsu_tb -- standalone test for design/pipe/qv_lsu.sv.
 *
 * A Wishbone slave model with random wait states checks the protocol on
 * every cycle -- a request stays stable until its response, cyc drops in
 * the ack/err cycle, nothing reaches the bus before the uop is the ROB
 * head, no access is ever issued twice -- and a golden memory model checks
 * every load's value and every store's effect, for every size, offset and
 * sign. Also: misaligned accesses (no bus, cause 4/6), bus errors (5/7,
 * including err raised together with ack), the RVFI fields in o_res, the
 * slot freeing at the response edge, a flush while waiting (dropped) and a
 * flush while in flight (never abandoned, result discarded).
 */
module qv_lsu_tb;
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
    logic                    started;

    qv_lsu dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(dat_o), .wb_mem_sel_o(sel), .wb_mem_we_o(we),
        .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb),
        .wb_mem_dat_i(dat_i), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(started)
    );

    // ---------------- slave model ----------------
    localparam int WORDS = 64;                       // 512 bytes; anything above 0x800 errors
    logic [63:0] mem [0:WORDS-1];
    logic [63:0] gold [0:WORDS-1];
    int   wait_max = 0;
    logic err_with_ack = 1'b0;                       // raise ack together with err
    int   accesses = 0;                              // requests the slave accepted
    logic busy = 1'b0;
    int   wait_left;
    logic [31:0] h_addr; logic [63:0] h_dat; logic [7:0] h_sel; logic h_we;
    logic proto_ok = 1'b1;

    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy && cyc && stb) begin
            busy <= 1'b1;
            h_addr <= addr; h_dat <= dat_o; h_sel <= sel; h_we <= we;
            wait_left <= (wait_max == 0) ? 0 : $urandom % (wait_max + 1);
            accesses <= accesses + 1;
        end else if (busy) begin
            if (!(cyc && stb) || addr != h_addr || sel != h_sel || we != h_we || (we && dat_o != h_dat)) begin
                if (proto_ok) $display("PROTO: request changed or dropped before its response");
                proto_ok <= 1'b0;
            end
            if (wait_left > 0) begin
                wait_left <= wait_left - 1;
            end else begin
                busy <= 1'b0;
                if (h_addr >= 32'h800) begin
                    err <= 1'b1;
                    ack <= err_with_ack;
                end else begin
                    ack <= 1'b1;
                    if (h_we)
                        for (int i = 0; i < 8; i++)
                            if (h_sel[i]) mem[h_addr[8:3]][8*i +: 8] <= h_dat[8*i +: 8];
                    dat_i <= mem[h_addr[8:3]];
                end
            end
        end
    end
    // cyc must be low in every response cycle (no request held into it)
    always @(negedge clk) begin
        if (!rst && (ack || err) && cyc) begin
            if (proto_ok) $display("PROTO: cyc still high in the response cycle");
            proto_ok = 1'b0;
        end
    end

    // ---------------- helpers ----------------
    logic [QV_ROB_TAG_W-1:0] next_tag = '0;

    function automatic logic [63:0] golden_load(input logic [63:0] a, input logic [1:0] size, input logic sgn);
        logic [63:0] w, s;
        w = gold[a[8:3]];
        s = w >> {a[2:0], 3'b000};
        case (size)
            2'd0:    return sgn ? {{56{s[7]}}, s[7:0]}   : {56'b0, s[7:0]};
            2'd1:    return sgn ? {{48{s[15]}}, s[15:0]} : {48'b0, s[15:0]};
            2'd2:    return sgn ? {{32{s[31]}}, s[31:0]} : {32'b0, s[31:0]};
            default: return w >> {a[2:0], 3'b000};
        endcase
    endfunction

    function automatic logic [7:0] golden_sel(input logic [63:0] a, input logic [1:0] size);
        logic [7:0] m;
        m = (size == 0) ? 8'h01 : (size == 1) ? 8'h03 : (size == 2) ? 8'h0F : 8'hFF;
        return m << a[2:0];
    endfunction

    function automatic logic misaligned(input logic [63:0] a, input logic [1:0] size);
        return (size == 1) ? a[0] : (size == 2) ? (a[1:0] != 0) : (size == 3) ? (a[2:0] != 0) : 1'b0;
    endfunction

    // dispatch one op; return its tag
    task automatic dispatch(input logic store, input logic [1:0] size, input logic sgn,
                            input logic [63:0] base, input logic [63:0] off, input logic [63:0] data,
                            output logic [QV_ROB_TAG_W-1:0] t);
        @(negedge clk);
        #1;
        check("dispatch: slot free", {63'b0, free}, 64'd1);
        t = next_tag;
        next_tag = next_tag + 1'b1;
        req       = '0;
        req.valid = 1'b1;
        req.tag   = t;
        req.op    = {1'b0, store, sgn, size};
        req.a     = base;
        req.b     = store ? data : off;
        req.imm   = store ? off : 64'hDEAD;              // loads must not use imm
        @(posedge clk); #1;
        req = '0;
    endtask

    // make t the head after `delay` cycles, wait for completion, check everything
    task automatic run_op(input string name, input logic store, input logic [1:0] size, input logic sgn,
                          input logic [63:0] base, input logic [63:0] off, input logic [63:0] data,
                          input int delay);
        logic [QV_ROB_TAG_W-1:0] t;
        logic [63:0] a, exp_v, exp_wdata;
        logic [7:0]  exp_sel;
        logic        mis, bad, got_wb;
        int          acc0, c;
        logic [63:0] wb_value;
        a   = base + off;
        mis = misaligned(a, size);
        bad = !mis && a[31:0] >= 32'h800;
        exp_sel   = golden_sel(a, size);
        exp_wdata = (store ? data : off) << {a[2:0], 3'b000};
        exp_v     = (!store && !mis && !bad) ? golden_load(a, size, sgn) : 64'b0;
        acc0 = accesses;
        dispatch(store, size, sgn, base, off, data, t);
        check({name, ": slot busy after dispatch"}, {63'b0, free}, 64'd0);
        // a different op at the head first: nothing may happen
        @(negedge clk);
        head_valid = 1'b1; head_tag = t + 1'b1;
        repeat (delay) begin
            @(posedge clk); #1;
            check({name, ": no bus before head"}, {63'b0, cyc}, 64'd0);
            check({name, ": no completion before head"}, {63'b0, wb.valid}, 64'd0);
        end
        @(negedge clk);
        head_tag = t;
        got_wb = 1'b0;
        for (c = 0; c < 50 && !got_wb; c++) begin
            #1;
            if (wb.valid) begin
                got_wb = 1'b1;
                wb_value = wb.value;
                check({name, ": wb tag"}, {60'b0, wb.tag}, {60'b0, t});
            end
            @(posedge clk);
        end
        #1;
        head_valid = 1'b0;
        check({name, ": completed"}, {63'b0, got_wb}, 64'd1);
        check({name, ": slot free at once"}, {63'b0, free}, 64'd1);
        check({name, ": bus accesses"}, 64'(accesses - acc0), mis ? 64'd0 : 64'd1);
        check({name, ": exception"}, {63'b0, res.xcpt}, {63'b0, mis || bad});
        if (mis)      check({name, ": cause"}, {60'b0, res.cause}, store ? 64'd6 : 64'd4);
        else if (bad) check({name, ": cause"}, {60'b0, res.cause}, store ? 64'd7 : 64'd5);
        if (mis || bad) check({name, ": tval = address"}, res.tval, a);
        check({name, ": rvfi addr"}, res.mem_addr, {a[63:3], 3'b000});
        check({name, ": rvfi rmask"}, {56'b0, res.mem_rmask}, store ? 64'd0 : {56'b0, exp_sel});
        check({name, ": rvfi wmask"}, {56'b0, res.mem_wmask}, store ? {56'b0, exp_sel} : 64'd0);
        check({name, ": rvfi wdata"}, res.mem_wdata, exp_wdata);
        if (!store) check({name, ": load value"}, wb_value, exp_v);
        if (store && !mis && !bad)
            for (int i = 0; i < 8; i++)
                if (exp_sel[i]) gold[a[8:3]][8*i +: 8] = exp_wdata[8*i +: 8];
        if (!mis && !bad && !store)
            check({name, ": rvfi rdata (raw word)"}, res.mem_rdata, gold[a[8:3]]);
    endtask

    int s, k;
    logic [QV_ROB_TAG_W-1:0] t;
    logic [63:0] v;

    initial begin
        for (int i = 0; i < WORDS; i++) begin
            v = {$urandom, $urandom};
            mem[i] = v; gold[i] = v;
        end
        repeat (2) @(posedge clk);
        #1 rst = 1'b0;
        #1;
        check("reset: free", {63'b0, free}, 64'd1);
        check("reset: idle bus", {63'b0, cyc}, 64'd0);

        // ---- every size x offset x sign, loads then stores, then loads again ----
        for (int sz = 0; sz < 4; sz++)
            for (int o = 0; o < 8; o++) begin
                run_op($sformatf("LD sz%0d off%0d signed", sz, o), 1'b0, 2'(sz), 1'b1, 64'h100, 64'(o), 0, 0);
                run_op($sformatf("LD sz%0d off%0d unsigned", sz, o), 1'b0, 2'(sz), 1'b0, 64'h100, 64'(o), 0, 1);
                run_op($sformatf("ST sz%0d off%0d", sz, o), 1'b1, 2'(sz), 1'b0, 64'h108, 64'(o),
                       {$urandom, $urandom}, 2);
                run_op($sformatf("LD back sz%0d off%0d", sz, o), 1'b0, 2'(sz), 1'b1, 64'h108, 64'(o), 0, 0);
            end
        // negative offsets and a store-data register wider than the access
        run_op("LD negative offset", 1'b0, 2'd3, 1'b0, 64'h200, -64'd8, 0, 0);
        run_op("SB of all ones only writes one byte", 1'b1, 2'd0, 1'b0, 64'h210, 64'd3, '1, 0);
        run_op("LD sees just that byte", 1'b0, 2'd3, 1'b0, 64'h210, 64'd0, 0, 0);

        // ---- bus errors ----
        run_op("LD error", 1'b0, 2'd3, 1'b1, 64'h800, 64'd0, 0, 0);
        run_op("SW error", 1'b1, 2'd2, 1'b0, 64'h1000, 64'd4, 64'h5555, 0);
        err_with_ack = 1'b1;
        run_op("LD error+ack", 1'b0, 2'd2, 1'b1, 64'h900, 64'd4, 0, 0);
        run_op("SH error+ack", 1'b1, 2'd1, 1'b0, 64'h900, 64'd2, 64'h7777, 0);
        err_with_ack = 1'b0;

        // ---- misaligned: never on the bus ----
        run_op("LH misaligned", 1'b0, 2'd1, 1'b1, 64'h100, 64'd1, 0, 0);
        run_op("LW misaligned", 1'b0, 2'd2, 1'b0, 64'h100, 64'd6, 0, 0);
        run_op("LD misaligned", 1'b0, 2'd3, 1'b0, 64'h100, 64'd4, 0, 2);
        run_op("SH misaligned", 1'b1, 2'd1, 1'b0, 64'h100, 64'd7, 64'h1, 0);
        run_op("SD misaligned", 1'b1, 2'd3, 1'b0, 64'h100, 64'd1, 64'h1, 0);
        run_op("misaligned beyond memory still misaligned", 1'b0, 2'd2, 1'b0, 64'h800, 64'd2, 0, 0);

        // ---- flush while waiting for the head: dropped, nothing on the bus ----
        k = accesses;
        dispatch(1'b1, 2'd3, 1'b0, 64'h100, 64'd0, 64'hBAD, t);
        @(negedge clk);
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        check("flush waiting: slot free", {63'b0, free}, 64'd1);
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;                  // the stale tag becoming "head" must do nothing
        repeat (3) begin
            @(posedge clk); #1;
            check("flush waiting: never starts", {63'b0, cyc}, 64'd0);
            check("flush waiting: never completes", {63'b0, wb.valid}, 64'd0);
        end
        head_valid = 1'b0;
        check("flush waiting: no access", 64'(accesses - k), 64'd0);

        // ---- flush in flight: request held to its response, result dropped ----
        wait_max = 0;
        dispatch(1'b0, 2'd3, 1'b0, 64'h100, 64'd0, 0, t);
        @(negedge clk);
        head_valid = 1'b1; head_tag = t;
        wait_max = 6;
        @(posedge clk); #1;                               // request out
        check("flush in flight: started", {63'b0, started}, 64'd1);
        @(negedge clk);
        head_valid = 1'b0;
        flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        for (s = 0; s < 20 && !free; s++) begin
            check("flush in flight: no completion", {63'b0, wb.valid}, 64'd0);
            @(posedge clk); #1;
        end
        check("flush in flight: slot freed after the response", {63'b0, free}, 64'd1);
        wait_max = 0;

        // ---- random: mixed ops, random wait states and head delays ----
        for (s = 0; s < 3000; s++) begin
            logic st;
            logic [1:0] sz;
            logic [63:0] base, off;
            wait_max = $urandom % 4;
            st   = $urandom % 2;
            sz   = $urandom % 4;
            base = 64'h100 + 64'($urandom % 64) * 8;
            off  = ($urandom % 10 == 0) ? 64'(int'($urandom % 2048) - 1024) : 64'($urandom % 16);
            if ($urandom % 20 == 0) base = 64'h900;       // into the error range
            run_op($sformatf("random %0d", s), st, sz, 1'($urandom), base, off, {$urandom, $urandom},
                   $urandom % 3);
        end

        check("bus protocol held throughout", {63'b0, proto_ok}, 64'd1);
        for (int i = 0; i < WORDS; i++) check($sformatf("final memory dword %0d", i), mem[i], gold[i]);

        $display("");
        $display("qv_lsu_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("qv_lsu_tb: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT: qv_lsu_tb");
        $finish;
    end
endmodule
