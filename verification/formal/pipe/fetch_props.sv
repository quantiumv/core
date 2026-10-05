// SPDX-License-Identifier: MIT

/*
 * fetch_props -- SymbiYosys properties for design/pipe/qv_fetch.sv,
 * checked at its ports only. Redirects, holds, pops and the slave's
 * responses are all free, except that the slave answers only a request
 * that is on the bus (ack and err together allowed, as the caches do)
 * and returns data that is a fixed function of the address asked for.
 *
 * Properties:
 *   - a request on the bus stays there, unchanged, until answered
 *     (never abandoned: wb_arbiter2 would hand a late ack elsewhere);
 *   - every entry fetch hands out is the next one expected: the target
 *     of the latest redirect, then each following dword in turn. A stale
 *     response (one issued before a redirect) or a dropped/duplicated
 *     one breaks this. Its data is the data of its own address;
 *   - while held (FENCE.I), no new request starts; held and idle means
 *     nothing on the bus.
 */
module fetch_props (
    input logic        clk,
    input logic        rst,
    input logic        ack, err,
    input logic        redirect_valid,
    input logic [63:0] redirect_pc,
    input logic        hold,
    input logic        pop
);
    localparam logic [63:0] RESET_PC = 64'h0;

    logic [31:0] addr;
    logic        cyc, stb, idle, buf_valid, buf_err;
    logic [63:0] buf_pc, buf_data;
    wire  [63:0] dat = {addr, ~addr};      // the slave's memory: data = f(address)

    qv_fetch #(.RESET_PC(RESET_PC)) dut (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(addr), .wb_fetch_cyc_o(cyc), .wb_fetch_stb_o(stb),
        .wb_fetch_dat_i(dat), .wb_fetch_ack_i(ack), .wb_fetch_err_i(err),
        .i_redirect_valid(redirect_valid), .i_redirect_pc(redirect_pc),
`ifndef FETCH_OLD
        .i_hold(hold), .o_idle(idle),
`endif
        .o_buf_valid(buf_valid), .o_buf_pc(buf_pc), .o_buf_data(buf_data),
        .o_buf_err(buf_err), .i_buf_pop(pop)
    );

    // previous cycle, as plain registers (no $past dependence). p_out: a
    // request was on the bus last cycle and not answered in it.
    reg        init = 1'b1;
    reg        p_valid = 1'b0, p_out = 1'b0, p_hold = 1'b0, p_idle_hold = 1'b0;
    reg [31:0] p_addr;
    reg [63:0] exp_pc = RESET_PC;
    reg        redirected = 1'b0;
    always @(posedge clk) begin
        init        <= 1'b0;
        p_valid     <= !rst;
        p_out       <= !rst && cyc && stb && !ack && !err;
        p_addr      <= addr;
        p_hold      <= hold && !rst;
        p_idle_hold <= hold && idle && !rst;
        if (rst) begin
            exp_pc <= RESET_PC;
        end else if (redirect_valid) begin
            exp_pc     <= redirect_pc;
            redirected <= 1'b1;
        end else if (buf_valid && pop) begin
            exp_pc <= {exp_pc[63:3], 3'b000} + 64'd8;
        end
    end

    // ---------------- environment ----------------
    // A registered Wishbone slave, like wb4_sram: it answers a request
    // that was on the bus, unanswered, the cycle before. (Masters here
    // drop cyc combinationally in the response cycle, so "only while cyc
    // is high" would rule responses out altogether.)
    always @* begin
        if (init) assume (rst);
        if (!(p_valid && p_out)) assume (!ack && !err);
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && p_valid) begin
            // never abandoned or moved before its response
            if (p_out && !ack && !err) begin
                assert (cyc && stb);
                assert (addr == p_addr);
            end
            // held: nothing new starts; held and idle: nothing on the bus
`ifndef FETCH_OLD
            if (p_hold && cyc) assert (p_out);
            if (p_idle_hold) assert (!cyc);
`endif
        end
        if (!rst && buf_valid && !redirect_valid) begin
            assert (buf_pc == exp_pc);
            if (!buf_err) assert (buf_data == {exp_pc[31:3], 3'b000, ~{exp_pc[31:3], 3'b000}});
        end
`ifndef FETCH_OLD
        if (idle) assert (!cyc);
`endif
    end

`ifndef FETCH_OLD
    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst) begin
            cover (buf_valid && pop && !redirect_valid && redirected);   // an entry after a redirect
            cover (ack && dut.req_stale_q);                              // a stale response dropped
            cover (err && p_out);                                        // a bus error
            cover (p_idle_hold && redirected);                           // held to idle
        end
    end

    // ---------------- induction lemmas ----------------
    // The ghost exp_pc is the pc of the buffer's head entry (or of the
    // next push when empty); the entries, the request in flight and
    // fpc_q follow it dword by dword. FB_DEPTH = 2 (the default).
    function automatic logic [63:0] nxt(input logic [63:0] p);
        return {p[63:3], 3'b000} + 64'd8;
    endfunction
    function automatic logic [63:0] word(input logic [63:0] p);
        return {p[31:3], 3'b000, ~{p[31:3], 3'b000}};
    endfunction

    wire [1:0]  cnt  = dut.fb_count_q;
    wire        rd   = dut.fb_rd_q;
    wire [63:0] e1   = nxt(exp_pc);
    wire [63:0] npush = (cnt == 2'd0) ? exp_pc : (cnt == 2'd1) ? e1 : nxt(e1);

    always @* begin
        if (!init && !rst) begin
            assert (cnt <= 2'd2);
            assert (dut.fb_wr_q == (rd ^ cnt[0]));
            if (cnt >= 2'd1) begin
                assert (dut.fb_pc[rd] == exp_pc);
                if (!dut.fb_err[rd]) assert (dut.fb_data[rd] == word(exp_pc));
            end
            if (cnt == 2'd2) begin
                assert (dut.fb_pc[!rd] == e1);
                if (!dut.fb_err[!rd]) assert (dut.fb_data[!rd] == word(e1));
            end
            if (dut.req_valid_q && !dut.req_stale_q) begin
                assert (cnt <= 2'd1);           // issue reserved its response's slot
                assert (dut.req_pc_q == npush);
                assert (dut.fpc_q == nxt(npush));
            end else begin
                assert (dut.fpc_q == npush);
            end
            if (p_valid && p_out) assert (dut.req_valid_q && p_addr == {dut.req_pc_q[31:3], 3'b000});
        end
    end
`else
    assign idle = 1'b0;     // the pre-FENCE.I version has no o_idle
`endif
endmodule
