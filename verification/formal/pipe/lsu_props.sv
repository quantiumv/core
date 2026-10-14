// SPDX-License-Identifier: MIT

/*
 * lsu_props -- SymbiYosys properties for design/pipe/qv_lsu.sv. Requests,
 * the ROB head, flushes, the commit-side reservation and bus data are
 * free; the slave is a registered one (it answers a request that was on
 * the bus, unanswered, the cycle before -- see fetch_props.sv).
 *
 * Ghost state follows the one uop the LSU holds: accepted (live), how many
 * bus requests it has started, whether it completed. Properties:
 *   - an access starts only when its uop is the ROB head (and not in a
 *     flush cycle), never for a misaligned one;
 *   - a started access stays on the bus, unchanged, until answered;
 *   - each uop completes (o_wb) at most once, with its own tag, and not
 *     after a flush; a misaligned one completes with cause 4/6 (6 for every
 *     atomic, LR included);
 *   - a free LSU is off the bus.
 * The A extension:
 *   - a load or LR makes one read; a store one write; an SC one write, and
 *     only if the reservation matched its address when it became the head
 *     -- otherwise it completes with no request at all;
 *   - an AMO makes a read, and only after that read is answered without an
 *     error (and not flushed) a write to the same address: never a second
 *     read, never a third request, no write after a faulting read;
 *   - wb_mem_lock_o is up exactly while an AMO's sequence is in progress:
 *     from its first request cycle through the response cycle of its last
 *     request (the write's, or the read's if that errors or is abandoned),
 *     continuously, and never at any other time.
 */
module lsu_props (
    input logic                             clk,
    input logic                             rst,
    input logic                             flush,
    input qv_pkg::fu_req_t                  req,
    input logic                             head_valid,
    input logic [qv_pkg::QV_ROB_TAG_W-1:0]  head_tag,
    input logic                             res_valid,
    input logic [63:0]                      res_addr,
    input logic [63:0]                      dat,
    input logic                             ack, err
);
    import qv_pkg::*;

    logic        free, head_started, cyc, stb, we, lock;
    logic [31:0] addr;
    logic [63:0] wdat;
    logic [7:0]  sel;
    wb_t         wb;
    lsu_res_t    res;

    qv_lsu dut (
        .clk(clk), .rst(rst), .i_flush(flush),
        .i_req(req), .o_free(free),
        .i_head_valid(head_valid), .i_head_tag(head_tag),
        .i_res_valid(res_valid), .i_res_addr(res_addr),
        .wb_mem_addr_o(addr), .wb_mem_dat_o(wdat), .wb_mem_sel_o(sel),
        .wb_mem_we_o(we), .wb_mem_cyc_o(cyc), .wb_mem_stb_o(stb), .wb_mem_lock_o(lock),
        .wb_mem_dat_i(dat), .wb_mem_ack_i(ack), .wb_mem_err_i(err),
        .o_wb(wb), .o_res(res), .o_head_started(head_started)
    );

    // the uop as the LSU sees it at dispatch
    wire        accept = !rst && req.valid && free && !flush;
    wire        atom   = req.op[4];
    wire [3:0]  aop    = req.op[3:0];
    wire        is_sc  = atom && (aop == 4'(QV_AMO_SC));
    wire        is_amo = atom && (aop > 4'(QV_AMO_SC));
    wire        st     = !atom && req.op[3];
    wire [1:0]  sz     = atom ? (req.is_word ? 2'd2 : 2'd3) : req.op[1:0];
    wire [63:0] ra     = atom ? req.a : req.a + (st ? req.imm : req.b);
    wire        mis    = (sz == 2'd1) ? ra[0] : (sz == 2'd2) ? (ra[1:0] != 2'd0)
                       : (sz == 2'd3) ? (ra[2:0] != 3'd0) : 1'b0;

    reg                  init = 1'b1;
    reg                  p_valid = 1'b0, p_out = 1'b0, p_we, p_wbmis = 1'b0;
    reg [31:0]           p_addr;
    reg [63:0]           p_wdat;
    reg [7:0]            p_sel;
    reg                  live = 1'b0, done = 1'b0, g_mis = 1'b0, g_st = 1'b0;
    reg                  g_atom = 1'b0, g_sc = 1'b0, g_amo = 1'b0;
    reg [63:0]           g_ra;
    reg [31:0]           g_busaddr;
    reg [1:0]            nreq = 2'd0;                // requests started for this uop
    reg                  read_ok = 1'b0;             // the AMO's read was answered cleanly, not flushed
    reg                  amo_seq = 1'b0;             // an AMO's request sequence is in progress
    reg [QV_ROB_TAG_W-1:0] g_tag;
    wire                 start = cyc && stb && !p_out;   // a new request on the bus
    wire                 resp  = p_valid && p_out && (ack || err);
    // the response that ends an AMO's sequence: the write's, a faulting read's, or an abandoned read's
    wire                 seq_end = resp && g_amo && (p_we || err || !live || flush);
    wire                 sc_match = res_valid && (res_addr == g_ra);

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
            live <= 1'b0; nreq <= 2'd0; done <= 1'b0; read_ok <= 1'b0; amo_seq <= 1'b0;
            g_mis <= 1'b0; g_st <= 1'b0; g_atom <= 1'b0; g_sc <= 1'b0; g_amo <= 1'b0;
        end else if (accept) begin
            live <= 1'b1; nreq <= 2'd0; done <= 1'b0; read_ok <= 1'b0;
            g_tag <= req.tag;
            g_mis <= mis;
            g_st  <= st;
            g_atom <= atom; g_sc <= is_sc; g_amo <= is_amo;
            g_ra  <= ra;
        end else begin
            if (start) begin
                nreq <= nreq + 2'd1;
                if (nreq == 2'd0) g_busaddr <= addr;
            end
            if (wb.valid)         done <= 1'b1;
            if (wb.valid || flush) live <= 1'b0;
            // the AMO's read was answered without an error, and nothing flushed it
            if (resp && g_amo && nreq == 2'd1 && ack && !err && !flush && live) read_ok <= 1'b1;
        end
        if (!rst) begin
            if (start && g_amo && nreq == 2'd0) amo_seq <= 1'b1;
            else if (seq_end)                   amo_seq <= 1'b0;
        end
    end

    // ---------------- environment ----------------
    always @* begin
        if (init) assume (rst);
        if (!(p_valid && p_out)) assume (!ack && !err);
        if (req.op[4]) assume (req.op[3:0] <= 4'(QV_AMO_MAXU));   // only real A-extension operations
    end

    // ---------------- properties ----------------
    always @* begin
        if (!rst && p_valid) begin
            if (start) begin
                if (nreq == 2'd0) begin
                    // the first request: only at the head, once, never misaligned
                    assert (head_valid && head_tag == g_tag && !flush);
                    assert (live && !g_mis);
                    // an SC goes out only with its reservation
                    if (g_sc) assert (sc_match);
                    // its direction: stores and SC write; loads, LR and the AMO's first half read
                    assert (we == (g_st || g_sc));
                end else begin
                    // an AMO's write: right after a clean, unflushed read, same address (a flush in its first cycle is too late to stop it)
                    assert (nreq == 2'd1 && g_amo && read_ok && live);
                    assert (we && addr == g_busaddr);
                end
            end
            if (p_out && !ack && !err) begin
                assert (cyc && stb);
                assert (addr == p_addr && we == p_we && sel == p_sel && wdat == p_wdat);
            end
            if (wb.valid) assert (live && !done && wb.tag == g_tag);
            // a completion with no request at all: misaligned, or an SC without its reservation
            if (wb.valid && nreq == 2'd0) assert (g_mis || g_sc);
            // an AMO completes after both requests, or after a faulting read (a pulse in a flush cycle is ignored by the ROB)
            if (wb.valid && g_amo && !g_mis && !flush) assert (nreq == 2'd2 || (nreq == 2'd1 && err));
            if (p_wbmis) begin
                assert (res.xcpt);
                assert (g_atom ? (res.cause == 4'd6) : (res.cause == (g_st ? 4'd6 : 4'd4)));
            end
            if (free) assert (!cyc);
            // lock: exactly an AMO's own sequence
            assert (lock == (g_amo && (amo_seq || (start && nreq == 2'd0))));
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
            if (!free)  assert (dut.addr_q == g_ra);
            if (!free)  assert (dut.sc_q == g_sc);
            if (!free)  assert (dut.atomic_q == g_atom && dut.amo_q == g_amo && dut.store_q == (g_st || g_sc));
            if (idle_s)  assert (!live);
            if (wait_s)  assert (live && nreq == 2'd0 && !done);
            if (bus_s)   assert (live && nreq != 2'd0 && !done);
            if (drain_s) assert (!live && nreq != 2'd0);
            if (bus_s || drain_s) assert (!dut.misaligned_q);
            // the ghost flags describe one kind of op
            assert (!(g_amo && g_sc));
            if (g_amo || g_sc) assert (g_atom);
            if (g_st) assert (!g_atom);
            // the ghost counters: at most two requests, the second only after a clean read
            assert (nreq != 2'd3);
            if (read_ok) assert (g_amo && nreq != 2'd0);
            if (nreq == 2'd2) assert (read_ok);
            if (done) assert (!live);
            // the write half has begun exactly once the read was answered cleanly
            if (!free) assert (dut.phase_wr_q == read_ok);
            if (nreq != 2'd0) assert (g_busaddr == {dut.addr_q[31:3], 3'b000});
            // an AMO's sequence is exactly its time on the bus
            assert (amo_seq == (g_amo && (bus_s || drain_s)));
            if (p_valid && p_out) assert (bus_s || drain_s);
            // an outstanding request is the read (first) or, once the read was answered, the write (second)
            if (p_valid && p_out) assert (nreq == (dut.phase_wr_q ? 2'd2 : 2'd1));
        end
    end

    // ---------------- non-vacuity (sby cover task) ----------------
    always @* begin
        if (!rst) begin
            cover (wb.valid && !g_mis && !g_st && !g_atom && !err);   // a load completes
            cover (p_wbmis && res.cause == 4'd6);          // a misaligned store traps
            cover (ack && drain_s);                        // a flushed access drains
            cover (err && bus_s);                          // a bus error
            cover (start && nreq == 2'd1 && g_amo);        // an AMO's write goes out
            cover (wb.valid && g_amo && nreq == 2'd2);     // an AMO completes
            cover (wb.valid && g_sc && nreq == 2'd1);      // an SC with its reservation completes
            cover (wb.valid && g_sc && nreq == 2'd0 && !g_mis);   // an SC without it completes
            cover (seq_end && g_amo && !live);             // an AMO abandoned by a flush
        end
    end
endmodule
