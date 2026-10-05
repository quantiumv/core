// SPDX-License-Identifier: MIT

/*
 * lsu_props -- SymbiYosys properties for design/pipe/qv_lsu.sv. Requests,
 * the ROB head, flushes and bus data are free; the slave is a registered
 * one (it answers a request that was on the bus, unanswered, the cycle
 * before -- see fetch_props.sv).
 *
 * Ghost state follows the one uop the LSU holds: accepted (live), whether
 * its access started, whether it completed. Properties:
 *   - an access starts only when its uop is the ROB head (and not in a
 *     flush cycle), at most once per uop, never for a misaligned one;
 *   - a started access stays on the bus, unchanged, until answered;
 *   - each uop completes (o_wb) at most once, with its own tag, and not
 *     after a flush; a misaligned one completes with cause 4/6;
 *   - a free LSU is off the bus.
 */
module lsu_props (
    input logic                             clk,
    input logic                             rst,
    input logic                             flush,
    input qv_pkg::fu_req_t                  req,
    input logic                             head_valid,
    input logic [qv_pkg::QV_ROB_TAG_W-1:0]  head_tag,
    input logic [63:0]                      dat,
    input logic                             ack, err
);
    import qv_pkg::*;

    logic        free, head_started, cyc, stb, we;
    logic [31:0] addr;
    logic [63:0] wdat;
    logic [7:0]  sel;
    wb_t         wb;
    lsu_res_t    res;

    qv_lsu dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(wdat), .wb_mem_sel_o(sel),
        .wb_mem_we_o(we), .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb),
        .wb_mem_dat_i(dat), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(head_started)
    );

    // the uop as the LSU sees it at dispatch
    wire        accept = !rst && req.valid && free && !flush;
    wire        st     = req.op[3];
    wire [1:0]  sz     = req.op[1:0];
    wire [63:0] ra     = req.a + (st ? req.imm : req.b);
    wire        mis    = (sz == 2'd1) ? ra[0] : (sz == 2'd2) ? (ra[1:0] != 2'd0)
                       : (sz == 2'd3) ? (ra[2:0] != 3'd0) : 1'b0;

    reg                  init = 1'b1;
    reg                  p_valid = 1'b0, p_out = 1'b0, p_we, p_wbmis = 1'b0;
    reg [31:0]           p_addr;
    reg [63:0]           p_wdat;
    reg [7:0]            p_sel;
    reg                  live = 1'b0, started = 1'b0, done = 1'b0, g_mis = 1'b0, g_st = 1'b0;
    reg [QV_ROB_TAG_W-1:0] g_tag;
    wire                 start = cyc && stb && !p_out;   // a new request on the bus

    always @(posedge clk) begin
        init    <= 1'b0;
        p_valid <= !rst;
        p_out   <= !rst && cyc && stb && !ack && !err;
        p_addr  <= addr;
        p_wdat  <= wdat;
        p_sel   <= sel;
        p_we    <= we;
        p_wbmis <= !rst && wb.valid && g_mis;
        if (rst) begin
            live <= 1'b0; started <= 1'b0; done <= 1'b0;
        end else if (accept) begin
            live <= 1'b1; started <= 1'b0; done <= 1'b0;
            g_tag <= req.tag;
            g_mis <= mis;
            g_st  <= st;
        end else begin
            if (start)    started <= 1'b1;
            if (wb.valid) done <= 1'b1;
            if (wb.valid || flush) live <= 1'b0;
        end
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        if (!(p_valid && p_out)) assume (!ack && !err);
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && p_valid) begin
            if (start) begin
                assert (head_valid && head_tag == g_tag && !flush);
                assert (live && !started && !g_mis);
            end
            if (p_out && !ack && !err) begin
                assert (cyc && stb);
                assert (addr == p_addr && we == p_we && sel == p_sel && wdat == p_wdat);
            end
            if (wb.valid) assert (live && !done && wb.tag == g_tag);
            if (p_wbmis) assert (res.xcpt && (res.cause == 4'd4 || res.cause == 4'd6));
            if (free) assert (!cyc);
        end
    end

    // ---------------- induction lemmas ----------------
    // qv_lsu's state_e: 0 IDLE, 1 WAIT_HEAD, 2 BUS, 3 DRAIN
    wire idle_s = (dut.state_q == 2'd0), wait_s = (dut.state_q == 2'd1);
    wire bus_s  = (dut.state_q == 2'd2), drain_s = (dut.state_q == 2'd3);
    always @* begin
        if (!init && !rst) begin
            assert (free == idle_s);
            if (!free)  assert (dut.tag_q == g_tag && dut.misaligned_q == g_mis);
            if (idle_s)  assert (!live);
            if (wait_s)  assert (live && !started && !done);
            if (bus_s)   assert (live && started && !done);
            if (drain_s) assert (!live && started);
            if (bus_s || drain_s) assert (!dut.misaligned_q);
            if (p_valid && p_out) assert (bus_s || drain_s);
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst) begin
            cover (wb.valid && !g_mis && !g_st && !err);   // a load completes
            cover (p_wbmis && res.cause == 4'd6);          // a misaligned store traps
            cover (ack && drain_s);                        // a flushed access drains
            cover (err && bus_s);                          // a bus error
        end
    end
endmodule
