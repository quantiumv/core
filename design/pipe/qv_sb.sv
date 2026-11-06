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
 * in flight (i_lsu_inflight), and, unless the buffer is full, not an LSU access that is ready to start
 * in this very cycle (i_lsu_busy: a load goes before a store that has already retired). The drain also
 * yields to a load that sits in the LSU slot among the oldest ROB entries (i_load_near): with the
 * blocking write-through D$ a beat takes the D$ for 3 cycles, and a load that follows the store would
 * otherwise wait out the very beat the store used to hold the ROB head for, which gains nothing. It
 * yields for at most YIELD_MAX cycles, and never when the buffer is full (o_start_now then also tells
 * the LSU not to start in the same cycle).
 *
 * o_match says that an entry holds a store to the dword a load at the ROB head is about to read.
 * The load waits until it is gone (the drain is in order); the whole raw bus word is what RVFI reports
 * and the lockstep comparator checks, so data is never taken from an entry.
 *
 * A bus error cannot happen inside the PMA window the stores are posted for: the entry is dropped (the
 * drain must not hang) and an assertion fires in simulation.
 */
module qv_sb #(
    parameter int DEPTH     = 4,      // entries, >= 1
    parameter int YIELD_MAX = 16      // cycles the drain may yield to a load before it goes anyway
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
    input  logic        i_lsu_busy,    // an LSU access is on the bus or ready to start this cycle
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
    input  logic        i_err
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
                    && (urgent || (!i_lsu_busy && !i_load_near));

    assign o_start_now = go;
    // With a beat in flight the LSU is held off by o_beat anyway, so it only needs the decision of an idle drain.
    // That one is independent of the response: the LSU's start, and so its lock, would otherwise be a function of
    // ack (arbiter grant -> ack -> start -> lock -> grant), a loop in the netlist even though no ack can arrive
    // when the grant is open.
    assign o_start_idle = !beat_q && (cnt_q != '0) && !i_lsu_inflight && !i_ptw_beat
                          && (urgent || (!i_lsu_busy && !i_load_near));
    assign o_beat      = beat_q;
    assign o_cyc       = beat_q && !(i_ack || i_err);
    assign o_addr      = {addr_q[rd_q], 3'b000};
    assign o_dat       = dat_q[rd_q];
    assign o_sel       = sel_q[rd_q];

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
