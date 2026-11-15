// SPDX-License-Identifier: MIT

/*
 * qv_dc -- the data cache inside the core (O5a): direct-mapped, write-through, no write-allocate, LINES lines of WORDS
 * dwords, physically indexed and tagged. It sits beside the LSU rather than on the memory bus, so a load that hits is
 * read in the LSU's own cycle with no bus handshake at all; only a miss goes out, as a refill on the core's memory
 * port.
 *
 *   lookup   combinational from i_addr (the LSU's registered physical address): o_hit and o_dat. A hit is used only
 *            while no refill is in progress (o_busy), since a refill rewrites the line it goes to.
 *   refill   i_fill_req (a miss; only while !o_busy) refills the line of i_addr: WORDS beats in order from the line's
 *            first dword, on the port (o_beat/o_addr; i_ack/i_err/i_dat), one at a time, each held until its response
 *            and dropped in it, the next one presented the cycle after. The line is marked invalid when the refill
 *            starts and valid when the last beat has come back, unless a beat erred or a snoop or an invalidation hit
 *            the line meanwhile (fill_kill_q). o_fill pulses in that last response cycle (or in the response cycle of
 *            a beat that errs: the refill stops there), with the requested dword in o_fill_dat (that beat's own data
 *            when it is the last) and o_fill_err. A killed refill still answers the load that missed: its dwords were
 *            read from memory after it asked.
 *   update   i_wr: the store buffer's beat in its response cycle, without an error. Its bytes (i_wr_sel) are merged
 *            into the line when the line holds that dword; a missing line is left alone (no allocate). Memory and the
 *            line stay equal: the store reached both.
 *   inv      i_inv: one of the LSU's own writes that do not go through the store buffer (an SC, an AMO's write, a
 *            Program Buffer store, any store when there is no buffer) in its response cycle: the line goes.
 *   snoop    i_snoop: a write by another master (the Debug Module's system bus access) to RAM: the line goes.
 *
 * The port carries one beat at a time and the refill is never abandoned, as every master of the core's memory port
 * does (qv_sb, qv_ptw, qv_lsu): o_beat is registered (beat_q) and dropped combinationally in the response cycle, and an
 * ack or err is taken only while beat_q is set. The core gives the port to the refill only when no other master is
 * on it, and its other masters wait while o_busy.
 */
module qv_dc #(
    parameter int LINES = 64,                   // a power of 2, >= 2
    parameter int WORDS = 4                     // dwords per line, a power of 2, >= 2
) (
    input  logic        clk,
    input  logic        rst,

    // lookup
    input  logic [31:3] i_addr,
    output logic        o_hit,
    output logic [63:0] o_dat,
    output logic        o_busy,                 // a refill is in progress

    // refill
    input  logic        i_fill_req,
    output logic        o_fill,
    output logic [63:0] o_fill_dat,
    output logic        o_fill_err,

    // write-through update, invalidation, snoop
    input  logic        i_wr,
    input  logic [31:3] i_wr_addr,
    input  logic [7:0]  i_wr_sel,
    input  logic [63:0] i_wr_dat,
    input  logic        i_inv,
    /* verilator lint_off UNUSEDSIGNAL */      // the dword within the line does not matter: the line goes
    input  logic [31:3] i_inv_addr,
    input  logic        i_snoop = 1'b0,
    input  logic [31:3] i_snoop_addr = '0,
    /* verilator lint_on UNUSEDSIGNAL */

    // the memory port
    output logic        o_beat,
    output logic [31:3] o_addr,
    input  logic        i_ack,
    input  logic        i_err,
    input  logic [63:0] i_dat
);
    localparam int WW = $clog2(WORDS);          // dword within a line
    localparam int IW = $clog2(LINES);          // line index
    localparam int OB = 3 + WW;                 // the index starts above the line offset
    localparam int TW = 32 - OB - IW;           // tag bits

    logic              valid_q [LINES];
    logic [TW-1:0]     tag_q   [LINES];
    logic [63:0]       data_q  [LINES][WORDS];

    // ---------------- lookup ----------------
    wire [IW-1:0] l_idx  = i_addr[OB+IW-1:OB];
    wire [WW-1:0] l_word = i_addr[OB-1:3];
    wire [TW-1:0] l_tag  = i_addr[31:OB+IW];
    assign o_hit = valid_q[l_idx] && (tag_q[l_idx] == l_tag);
    assign o_dat = data_q[l_idx][l_word];

    // ---------------- refill ----------------
    logic              busy_q, beat_q, kill_q;
    logic [31:OB]      f_line_q;               // the line being refilled
    logic [WW-1:0]     f_word_q;               // the dword the load asked for
    logic [WW-1:0]     f_beat_q;               // the beat on the port
    logic [63:0]       f_dat_q;                // the requested dword, once its beat is back
    wire  [IW-1:0]     f_idx  = f_line_q[OB+IW-1:OB];
    wire               resp   = beat_q && (i_ack || i_err);
    wire               last   = (f_beat_q == WW'(WORDS - 1));
    wire               f_end  = resp && (last || i_err);
    assign o_busy     = busy_q;
    assign o_beat     = beat_q && !(i_ack || i_err);
    assign o_addr     = {f_line_q, f_beat_q};
    assign o_fill     = f_end;
    assign o_fill_err = f_end && i_err;
    assign o_fill_dat = (f_beat_q == f_word_q) ? i_dat : f_dat_q;

    // a write by someone else to the line being refilled: the line is not installed
    wire inv_f   = i_inv   && busy_q && (i_inv_addr[31:OB] == f_line_q);
    wire snoop_f = i_snoop && busy_q && (i_snoop_addr[31:OB] == f_line_q);

    // the store buffer's bytes over the line's dword (one whole-dword write: Icarus misplaces a non-blocking write to
    // a byte slice of an array element inside a loop)
    function automatic logic [63:0] merge(input logic [63:0] old, input logic [7:0] sel, input logic [63:0] d);
        logic [63:0] r;
        r = old;
        for (int b = 0; b < 8; b++) if (sel[b]) r[8*b +: 8] = d[8*b +: 8];
        return r;
    endfunction
    wire [IW-1:0] w_idx  = i_wr_addr[OB+IW-1:OB];
    wire [WW-1:0] w_word = i_wr_addr[OB-1:3];

    function automatic logic holds(input logic [31:OB] a);            // a line address
        return valid_q[a[OB+IW-1:OB]] && (tag_q[a[OB+IW-1:OB]] == a[31:OB+IW]);
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
            beat_q <= 1'b0;
            kill_q <= 1'b0;
            for (int i = 0; i < LINES; i++) valid_q[i] <= 1'b0;
        end else begin
            // the store buffer's write: merged into a line that holds its dword
            if (i_wr && holds(i_wr_addr[31:OB]))
                data_q[w_idx][w_word] <= merge(data_q[w_idx][w_word], i_wr_sel, i_wr_dat);
            // the LSU's own write past the buffer, and a snoop: the line goes
            if (i_inv && holds(i_inv_addr[31:OB]))     valid_q[i_inv_addr[OB+IW-1:OB]]   <= 1'b0;
            if (i_snoop && holds(i_snoop_addr[31:OB])) valid_q[i_snoop_addr[OB+IW-1:OB]] <= 1'b0;

            if (!busy_q) begin
                if (i_fill_req) begin
                    busy_q             <= 1'b1;
                    beat_q             <= 1'b1;
                    kill_q             <= 1'b0;
                    f_line_q           <= i_addr[31:OB];
                    f_word_q           <= i_addr[OB-1:3];
                    f_beat_q           <= '0;
                    valid_q[i_addr[OB+IW-1:OB]] <= 1'b0;      // whatever the index held is rewritten
                    tag_q[i_addr[OB+IW-1:OB]]   <= i_addr[31:OB+IW];
                end
            end else begin
                if (inv_f || snoop_f) kill_q <= 1'b1;
                if (resp) begin
                    data_q[f_idx][f_beat_q] <= i_dat;
                    if (f_beat_q == f_word_q) f_dat_q <= i_dat;
                    if (f_end) begin
                        busy_q <= 1'b0;
                        beat_q <= 1'b0;
                        valid_q[f_idx] <= !i_err && !kill_q && !inv_f && !snoop_f;
                    end else begin
                        f_beat_q <= f_beat_q + 1'b1;     // the next beat, presented from the next cycle
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!rst) begin
        if (i_fill_req && busy_q)
            $error("qv_dc: a refill asked for while one is in progress");
    end
`endif
endmodule: qv_dc
