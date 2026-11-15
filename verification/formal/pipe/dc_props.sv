// SPDX-License-Identifier: MIT

/*
 * dc_props -- SymbiYosys properties for design/pipe/qv_dc.sv, the D$ inside the core (O5a), at LINES 2 x WORDS 2
 * (dc.sby's bmc4 task: 4 x 4).
 *
 * The other masters of the core's memory port are not modelled: the core keeps them off the port while a refill runs
 * (they wait on o_busy), so here the store buffer's writes (i_wr) and the LSU's own writes (i_inv) come only while no
 * refill runs, and never with a refill request; a write by another master (i_snoop, the Debug Module) may come at any
 * time, a refill's response cycle included. Memory is a shadow of one symbolic dword A (anyconst): each of the three
 * writes changes it at the edge of the cycle it is signalled in, as memory changes then. The slave is a registered
 * one (it answers a beat that was on the bus, unanswered, the cycle before), answers a beat of A with A's dword
 * (before that cycle's write), and answers anything else freely, ack and err together included.
 *
 *   - every valid copy of A equals memory, and so does a hit on A (so: no hit on an invalid line, no install after a
 *     snoop to the line or an error, no install of a
 *     line whose dwords changed while it was read, an update merged into the right dword, nothing written into a
 *     line that does not hold the address);
 *   - a refill's answer is the dword the requested beat read (A's dword when it asked for A), unless it erred;
 *   - the beats: one at a time, held unchanged until answered and dropped in the response cycle, a line's dwords in
 *     order from its first, WORDS of them unless one errs (which ends the refill), and none without a refill;
 *   - o_fill exactly once per refill, in its last response cycle.
 */
module dc_props (
    input logic         clk,
    input logic         rst,
    input logic [31:3]  addr,          // the LSU's lookup / refill address
    input logic         fill_req,
    input logic         wr, inv, snoop,
    input logic [31:3]  wr_addr, inv_addr, snoop_addr,
    input logic [7:0]   wr_sel,
    input logic [63:0]  wr_dat,
    input logic [63:0]  new_dat,       // what an LSU write or a snoop writes
    input logic         ack, err,
    input logic [63:0]  dat,
    input logic [31:3]  A
);
`ifdef DC_BIG
    localparam int LINES = 4, WORDS = 4;
`else
    localparam int LINES = 2, WORDS = 2;
`endif
    localparam int WW = $clog2(WORDS);
    localparam int IW = $clog2(LINES);
    localparam int OB = 3 + WW;

    logic        hit, busy, fill, fill_err, beat;
    logic [63:0] hdat, fill_dat;
    logic [31:3] baddr;

    qv_dc #(.LINES(LINES), .WORDS(WORDS)) dut (
        .clk(clk), .rst(rst),
        .i_addr(addr), .o_hit(hit), .o_dat(hdat), .o_busy(busy),
        .i_fill_req(fill_req), .o_fill(fill), .o_fill_dat(fill_dat), .o_fill_err(fill_err),
        .i_wr(wr), .i_wr_addr(wr_addr), .i_wr_sel(wr_sel), .i_wr_dat(wr_dat),
        .i_inv(inv), .i_inv_addr(inv_addr), .i_snoop(snoop), .i_snoop_addr(snoop_addr),
        .o_beat(beat), .o_addr(baddr), .i_ack(ack), .i_err(err), .i_dat(dat)
    );

    function automatic logic [63:0] merge(input logic [63:0] o, input logic [7:0] s, input logic [63:0] d);
        logic [63:0] r;
        r = o;
        for (int i = 0; i < 8; i++) if (s[i]) r[8*i +: 8] = d[8*i +: 8];
        return r;
    endfunction

    reg          init = 1'b1;
    reg  [31:3]  A_prev;
    reg  [63:0]  mem_a;                        // memory's dword at A
    reg          p_out = 1'b0;                 // a beat was on the bus, unanswered, the cycle before
    reg  [31:3]  p_baddr;
    reg          f_on = 1'b0;                  // a refill runs (the testbench's view)
    reg  [31:OB] f_line;
    reg  [WW-1:0] f_word;
    reg  [WW:0]  f_n;                          // beats answered so far
    reg  [63:0]  f_got;                        // what the requested beat read
    reg          f_got_v;
    reg          f_err;
    wire         resp = p_out && (ack || err);
    wire [31:3]  rd_a = {f_line, f_n[WW-1:0]};

    always @(posedge clk) begin
        init   <= 1'b0;
        A_prev <= A;
        p_out  <= !rst && beat;
        p_baddr <= baddr;
        if (!rst) begin
            if (wr && wr_addr == A)       mem_a <= merge(mem_a, wr_sel, wr_dat);
            if (inv && inv_addr == A)     mem_a <= new_dat;
            if (snoop && snoop_addr == A) mem_a <= new_dat;
        end
        if (rst) begin
            f_on <= 1'b0;
        end else begin
            if (!busy && fill_req) begin
                f_on <= 1'b1; f_line <= addr[31:OB]; f_word <= addr[OB-1:3]; f_n <= '0; f_got_v <= 1'b0; f_err <= 1'b0;
            end
            if (f_on && resp) begin
                if (f_n[WW-1:0] == f_word && !err) begin f_got <= dat; f_got_v <= 1'b1; end
                if (err) f_err <= 1'b1;
                f_n <= f_n + 1'b1;
                if (err || f_n == (WW+1)'(WORDS - 1)) f_on <= 1'b0;
            end
        end
    end

    // ---- assumptions: the core around it, and the slave ----
    always @(posedge clk) begin
        if (!init) assume (A == A_prev);
        if (init) assume (rst);
        if (busy) assume (!fill_req && !wr && !inv);       // the port is the refill's
        if (fill_req) assume (!wr && !inv);
        // two writes of the same cycle never meet (one master at a time on the bus)
        assume (!(snoop && (wr || inv)));
        assume (!(wr && inv));
        // a registered slave: an answer only to a beat on the bus, unanswered, the cycle before
        if (!p_out) assume (!ack && !err);
        // ... and a beat of A answered without an error carries A's dword
        if (p_out && ack && !err && p_baddr == A) assume (dat == mem_a);
    end

    // ---- properties ----
    wire [IW-1:0] iA = A[OB+IW-1:OB];
    wire [WW-1:0] wA = A[OB-1:3];
    always @(posedge clk) begin
        if (!rst && !init) begin
            // every valid copy of A is memory's, and a lookup of A that hits (no refill running) returns it
            if (dut.valid_q[iA] && dut.tag_q[iA] == A[31:OB+IW]) assert (dut.data_q[iA][wA] == mem_a);
            if (hit && addr == A && !busy) assert (hdat == mem_a);
            // the beats
            assert (busy == f_on);
            if (f_on) assert (f_n < (WW+1)'(WORDS) && !f_err);                   // lemmas: the count, no error yet
            if (p_out) assert (busy);
            if (beat) assert (busy && baddr == rd_a);
            if (p_out && !(ack || err)) assert (beat && baddr == p_baddr);      // held until answered
            if (ack || err) assert (!beat);                                     // dropped in the response cycle
            if (busy && !p_out) assert (beat);                                  // never idle in a refill
            // the answer
            assert (fill == (f_on && resp && (err || f_n == (WW+1)'(WORDS - 1))));
            if (fill) assert (fill_err == (f_err || err));
            if (fill && !f_err && !err) begin
                if (f_n[WW-1:0] == f_word) assert (fill_dat == dat);
                else assert (f_got_v && fill_dat == f_got);
                if ({f_line, f_word} == A && f_n[WW-1:0] != f_word) assert (f_got == mem_a || dut.kill_q || snoop);
            end
            // lemmas for the induction: the refilling line is invalid, tagged with its line, and the dwords it has
            // read so far are memory's unless a write to the line has killed it
            if (busy) begin
                assert (!dut.valid_q[dut.f_idx]);
                assert (dut.tag_q[dut.f_idx] == dut.f_line_q[31:OB+IW]);
                assert (dut.f_line_q == f_line && dut.f_word_q == f_word && dut.f_beat_q == f_n[WW-1:0]);
                assert (dut.beat_q);
                if (f_got_v) assert (dut.f_dat_q == f_got);
                assert (f_got_v == (f_n[WW-1:0] > f_word));
                if (f_line == A[31:OB] && !dut.kill_q && wA < f_n[WW-1:0]) assert (dut.data_q[dut.f_idx][wA] == mem_a);
                if (f_line == A[31:OB] && f_got_v && wA == f_word && !dut.kill_q) assert (f_got == mem_a);
            end else begin
                assert (!dut.beat_q);
            end
        end
    end

    // ---- covers: the paths are reachable ----
    always @(posedge clk) begin
        if (!rst && !init) begin
            cover (fill && !fill_err && dut.valid_q[dut.f_idx] == 1'b0);       // a refill ends
            cover (hit && dut.valid_q[iA] && addr == A);                        // A hits after its refill
            cover (busy && snoop && snoop_addr[31:OB] == f_line);               // a snoop meets a refill
            cover (fill && fill_err);                                           // a refill errs
            cover (wr && dut.valid_q[iA] && wr_addr == A);                      // an update merges into A's line
        end
    end
endmodule
