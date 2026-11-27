// SPDX-License-Identifier: MIT

/*
 * qv_sb -- the store buffer: stores to RAM that have retired and are still on their way to memory.
 *
 * A plain store to RAM does not touch the bus at the ROB head: the LSU runs its checks, completes it
 * with the bus fields in its result, and commit pushes {dword address, byte select, shifted data}
 * here in the cycle the store retires (never earlier, so a store an interrupt or a halt takes the slot
 * of never reaches the buffer). The buffer then writes the stores to the memory port in order, one
 * beat at a time, long after the instruction has left the pipeline. A flush does not touch it: its
 * entries have retired.
 *
 * It is the third master of the memory port, next to the LSU and the page-table walker, and keeps
 * their discipline: a beat in flight is never abandoned or interrupted, cyc and stb drop in the
 * response cycle (combinationally, as the LSU's do, so a slave that re-samples requests never sees
 * one twice), a beat is registered (beat_q) and driven from the next cycle on, and an ack or err is
 * only taken as its own while beat_q is set.
 *
 * A beat starts only when nobody else is on the port: not the walker (i_ptw_beat), not an LSU access
 * in flight (i_lsu_inflight). The drain yields to a load that sits in the LSU slot among the oldest ROB
 * entries (i_load_near): with the blocking write-through D$ a beat holds the D$ until memory has taken the
 * store (the D$ passes it straight through), and a load that follows the store would otherwise wait out the
 * very beat the store used to hold the ROB head for, which gains nothing. It yields for at most YIELD_MAX
 * cycles, and never when the buffer is full (o_start_now then also tells the LSU not to start in the same
 * cycle). With YIELD_READY (P9d's rule) it also yields to any LSU access that is ready to start
 * (i_lsu_busy), however far from the head; without it (O4f, the core's default) a beat goes before such a load,
 * whose start is not yet what the head waits for: yielding to a stream of them leaves the last stores in
 * the buffer until a younger load that reads one of their dwords has to wait out the drain anyway.
 *
 * o_match says that an entry holds a store to the dword a load at the ROB head is about to read.
 * The load waits until it is gone (the drain is in order); the whole raw bus word is what RVFI reports
 * and the lockstep comparator checks, so data is never taken from an entry.
 *
 * A bus error cannot happen inside the PMA window the stores are posted for: the entry is dropped (the
 * drain must not hang) and an assertion fires in simulation.
 *
 * (W3a) PIPE: a beat decided in the previous one's response cycle goes out in that very cycle -- cyc stays high,
 * now carrying the next entry -- so back-to-back beats come one a cycle instead of one every two. That is the one
 * exception to "cyc drops in the response cycle": the request held through the ack is a new one, never the answered
 * one again, and the bus between the core and memory must take a request in an ack cycle (soc.sv's arbiter forwards
 * it: wb_arbiter2's PIPE_M0). The beat answered in a cycle is the oldest entry: o_resp_* are its fields (the D$ takes
 * a store's data from there), o_addr/o_dat/o_sel the request on the bus.
 */
module qv_sb #(
    parameter int DEPTH     = 4,      // entries, >= 1
    parameter int YIELD_MAX = 16,     // cycles the drain may yield to a load before it goes anyway
    parameter bit YIELD_READY = 1'b1, // also yield to any LSU access ready to start (P9d's rule; the core passes 0)
    parameter bit PIPE      = 1'b0    // (W3a) the next beat in the current one's response cycle: a beat a cycle
) (
    input  logic        clk,
    input  logic        rst,

    // push, at commit
    input  logic        i_push,
    input  logic [31:3] i_push_addr,
    input  logic [7:0]  i_push_sel,
    input  logic [63:0] i_push_data,
    output logic        o_ready,       // a push is accepted (not full; from the registered count)
    output logic        o_empty,

    // a load at the ROB head asks whether a store to its dword is still buffered
    input  logic [31:3] i_match_addr,
    output logic        o_match,

    // the memory port
    input  logic        i_lsu_busy,    // an LSU access is on the bus or ready to start this cycle (YIELD_READY)
    input  logic        i_lsu_inflight,// ... is on the bus
    input  logic        i_ptw_beat,    // the walker's beat is in flight
    input  logic        i_load_near,   // a load that does not wait for this buffer is among the oldest ROB entries
    output logic        o_start_now,   // a beat is decided this cycle: the LSU must not start in it
    output logic        o_start_idle,  // ... the part of it with no beat in flight (no i_ack/i_err in it): what the LSU takes
    output logic        o_beat,        // a beat is in flight, its response cycle included
    output logic        o_cyc,
    output logic [31:0] o_addr,
    output logic [63:0] o_dat,
    output logic [7:0]  o_sel,
    input  logic        i_ack,
    input  logic        i_err,
    output logic [31:3] o_resp_addr,   // the beat an i_ack/i_err answers: the oldest entry (with PIPE the bus may
    output logic [7:0]  o_resp_sel,    // already carry the next one)
    output logic [63:0] o_resp_dat
);
    localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int CNT_W = $clog2(DEPTH + 1);

    logic [31:3] addr_q [0:DEPTH-1];
    logic [7:0]  sel_q  [0:DEPTH-1];
    logic [63:0] dat_q  [0:DEPTH-1];
    logic        v_q    [0:DEPTH-1];
    logic [PTR_W-1:0] rd_q, wr_q;
    logic [CNT_W-1:0] cnt_q;
    logic             beat_q;
    logic [7:0]       held_q;

    function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] p);
        ptr_inc = (p == PTR_W'(DEPTH - 1)) ? '0 : p + 1'b1;
    endfunction

    wire full  = (cnt_q == CNT_W'(DEPTH));
    assign o_ready = !full;
    assign o_empty = (cnt_q == '0);

    always_comb begin
        o_match = 1'b0;
        for (int i = 0; i < DEPTH; i++)
            if (v_q[i] && addr_q[i] == i_match_addr) o_match = 1'b1;
    end

    // ---------------- the drain ----------------
    wire resp     = beat_q && (i_ack || i_err);
    wire urgent   = full || (held_q >= 8'(YIELD_MAX));
    // with the entry that is leaving gone there is something left to start
    wire has_next = (cnt_q > (resp ? CNT_W'(1) : CNT_W'(0)));
    // a beat can be decided in the response cycle of the previous one: it goes out one cycle later, so the gap
    // between two beats is a single cycle
    wire go       = (!beat_q || resp) && has_next && !i_lsu_inflight && !i_ptw_beat
                    && (urgent || (!(YIELD_READY && i_lsu_busy) && !i_load_near));

    assign o_start_now = go;
    // With a beat in flight the LSU is held off by o_beat anyway, so it only needs the decision of an idle drain.
    // That one is independent of the response: the LSU's start, and so its lock, would otherwise be a function of
    // ack (arbiter grant -> ack -> start -> lock -> grant), a loop in the netlist even though no ack can arrive
    // when the grant is open.
    assign o_start_idle = !beat_q && (cnt_q != '0) && !i_lsu_inflight && !i_ptw_beat
                          && (urgent || (!(YIELD_READY && i_lsu_busy) && !i_load_near));
    // (W3a) with PIPE, a beat decided in a response cycle is on the bus in it: the next entry, behind the answered one
    wire nxt = PIPE && resp && go;
    wire [PTR_W-1:0] cur = nxt ? ptr_inc(rd_q) : rd_q;
    assign o_beat      = beat_q;
    assign o_cyc       = beat_q && (!(i_ack || i_err) || nxt);
    assign o_addr      = {addr_q[cur], 3'b000};
    assign o_dat       = dat_q[cur];
    assign o_sel       = sel_q[cur];
    assign o_resp_addr = addr_q[rd_q];
    assign o_resp_sel  = sel_q[rd_q];
    assign o_resp_dat  = dat_q[rd_q];

    wire push = i_push && o_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_q   <= '0;
            wr_q   <= '0;
            cnt_q  <= '0;
            beat_q <= 1'b0;
            held_q <= '0;
            for (int i = 0; i < DEPTH; i++) v_q[i] <= 1'b0;
        end else begin
            if (push) begin
                addr_q[wr_q] <= i_push_addr;
                sel_q[wr_q]  <= i_push_sel;
                dat_q[wr_q]  <= i_push_data;
                v_q[wr_q]    <= 1'b1;
                wr_q         <= ptr_inc(wr_q);
            end
            if (resp) begin
                v_q[rd_q] <= 1'b0;
                rd_q      <= ptr_inc(rd_q);
            end
            cnt_q <= cnt_q + CNT_W'(push) - CNT_W'(resp);

            if (go)        beat_q <= 1'b1;
            else if (resp) beat_q <= 1'b0;

            // cycles the drain has had something to write and was kept off by a load
            if (go || o_empty)                                held_q <= '0;
            else if (!beat_q && !(i_lsu_inflight || i_ptw_beat) && held_q != 8'hFF) held_q <= held_q + 8'd1;
        end
    end

`ifdef RISCV_FORMAL
    // inside the PMA window the memory cannot answer with an error
    always @(posedge clk) if (!rst) assert (!(resp && i_err));
`endif
endmodule
