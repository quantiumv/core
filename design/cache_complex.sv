// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: cache_complex -- I$/D$ pair, one shared memory-facing port
 *
 * Thin wrapper: instantiates icache.sv and dcache.sv, routes core.sv's
 * single time-multiplexed Wishbone master port to whichever one applies
 * (ifetch_i high -> icache0, low -> dcache0 -- see core.sv's own
 * wb_ifetch_o port comment for why this side-band signal exists at all),
 * and multiplexes both sub-caches' independent downstream refill/write
 * traffic onto ONE shared memory-facing Wishbone master port.
 *
 * No arbiter logic anywhere in this file -- deliberately, not an
 * oversight. core.sv's FSM is single-issue: fetch (S_FETCH/S_FETCH_HI)
 * and mem/AMO access (S_MEM/S_AMO_WRITE) never overlap, so icache0 and
 * dcache0 can never both have outstanding downstream traffic at the same
 * time either. The routing below is therefore a plain select, the same
 * "gate cyc/stb per target, broadcast everything else, latch which one
 * gets which response" idiom design/wb_addr_decoder.sv already
 * establishes for its own (structurally different, but same-shaped)
 * one-master-many-slaves problem -- see that module's own header for the
 * "remember which slave" reasoning this mirrors.
 *
 * Timing note (confirmed by tracing through, not assumed): active_ifetch_q
 * latches on the SAME clock edge a sub-cache's own state_q first leaves
 * CACHE_IDLE, since both updates are triggered by the identical
 * cyc_i&&stb_i condition on core.sv's request-issue cycle -- so by the
 * time either sub-cache's downstream traffic first appears, the routing
 * mux is already pointed at the right one. No race window exists.
 */
module cache_complex #(
    parameter num_lines  = 64,
    parameter line_words = 4
) (
    input logic clk,
    input logic rst,

    // Core-facing port -- this module is a Wishbone SLAVE from core.sv's
    // side. ifetch_i is not part of the Wishbone protocol itself -- see
    // core.sv's wb_ifetch_o port comment.
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        ifetch_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    /*
     * Zifencei: passed straight through to icache0.flush_i UNCONDITIONALLY
     * -- load-bearing to get right, not a style choice. ifetch_i is LOW
     * throughout S_EXEC (FENCE.I's own commit cycle, where core.sv pulses
     * icache_flush_o -- see that port's own comment), so gating this on
     * ifetch_i the way cyc_i/stb_i are routed above would silently make
     * FENCE.I a permanent no-op: the exact class of bug this signal exists
     * to prevent, not just an edge case. D$ has no equivalent flush path
     * (or need for one) -- write-through already keeps a store hit's
     * cached copy and SRAM in lockstep.
     */
    input  logic        flush_i,

    // Memory-facing port -- this module is a Wishbone MASTER from
    // wb4_sram.sv's side. Shared by both sub-caches; see this module's
    // own header for why no arbitration is needed.
    output logic [31:0] mem_addr_o,
    output logic [63:0] mem_dat_o,
    input  logic [63:0] mem_dat_i,
    output logic [7:0]  mem_sel_o,
    output logic        mem_we_o,
    output logic        mem_cyc_o,
    output logic        mem_stb_o,
    input  logic        mem_ack_i,
    input  logic        mem_err_i
);
    // icache0's own ports.
    logic [63:0] ic_dat_o;
    logic        ic_ack, ic_err;
    logic [31:0] ic_mem_addr;
    logic [63:0] ic_mem_dat_i;
    logic [7:0]  ic_mem_sel;
    logic        ic_mem_we, ic_mem_cyc, ic_mem_stb, ic_mem_ack, ic_mem_err;

    icache #(.num_lines(num_lines), .line_words(line_words)) icache0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_o(ic_dat_o), .cyc_i(cyc_i && ifetch_i), .stb_i(stb_i && ifetch_i),
        .ack_o(ic_ack), .err_o(ic_err), .flush_i(flush_i),
        .mem_addr_o(ic_mem_addr), .mem_dat_i(ic_mem_dat_i), .mem_sel_o(ic_mem_sel),
        .mem_we_o(ic_mem_we), .mem_cyc_o(ic_mem_cyc), .mem_stb_o(ic_mem_stb),
        .mem_ack_i(ic_mem_ack), .mem_err_i(ic_mem_err)
    );

    // dcache0's own ports.
    logic [63:0] dc_dat_o;
    logic        dc_ack, dc_err;
    logic [31:0] dc_mem_addr;
    logic [63:0] dc_mem_dat_o, dc_mem_dat_i;
    logic [7:0]  dc_mem_sel;
    logic        dc_mem_we, dc_mem_cyc, dc_mem_stb, dc_mem_ack, dc_mem_err;

    dcache #(.num_lines(num_lines), .line_words(line_words)) dcache0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_i(dat_i), .dat_o(dc_dat_o), .sel_i(sel_i),
        .we_i(we_i), .cyc_i(cyc_i && !ifetch_i), .stb_i(stb_i && !ifetch_i),
        .ack_o(dc_ack), .err_o(dc_err),
        .mem_addr_o(dc_mem_addr), .mem_dat_o(dc_mem_dat_o), .mem_dat_i(dc_mem_dat_i),
        .mem_sel_o(dc_mem_sel), .mem_we_o(dc_mem_we), .mem_cyc_o(dc_mem_cyc), .mem_stb_o(dc_mem_stb),
        .mem_ack_i(dc_mem_ack), .mem_err_i(dc_mem_err)
    );

    /*
     * Latched at request-issue time -- see this module's own header for
     * why this can't race the sub-caches' own state transitions, and
     * design/wb_addr_decoder.sv's identical sel_uart_q for the same
     * underlying "remember which target an outstanding transaction
     * belongs to" reasoning.
     */
    logic active_ifetch_q;
    always_ff @(posedge clk) begin
        if (rst)
            active_ifetch_q <= 1'b0;
        else if (cyc_i && stb_i)
            active_ifetch_q <= ifetch_i;
    end

    assign ack_o = active_ifetch_q ? ic_ack   : dc_ack;
    assign err_o = active_ifetch_q ? ic_err   : dc_err;
    assign dat_o = active_ifetch_q ? ic_dat_o : dc_dat_o;

    // Each sub-cache only ever sees a real mem_ack_i/mem_err_i while it's
    // the one actually driving mem_cyc_o/mem_stb_o -- the inactive one's
    // own downstream port is forced idle-response (0), matching the "a
    // gated-off master's response inputs don't matter" convention
    // wb_addr_decoder.sv's slave-side gating already establishes, mirrored
    // here on the master side.
    assign ic_mem_ack   = active_ifetch_q ? mem_ack_i : 1'b0;
    assign ic_mem_err   = active_ifetch_q ? mem_err_i : 1'b0;
    assign ic_mem_dat_i = mem_dat_i;

    assign dc_mem_ack   = active_ifetch_q ? 1'b0 : mem_ack_i;
    assign dc_mem_err   = active_ifetch_q ? 1'b0 : mem_err_i;
    assign dc_mem_dat_i = mem_dat_i;

    assign mem_addr_o = active_ifetch_q ? ic_mem_addr : dc_mem_addr;
    assign mem_dat_o  = active_ifetch_q ? 64'b0        : dc_mem_dat_o; // icache0 never writes
    assign mem_sel_o  = active_ifetch_q ? ic_mem_sel  : dc_mem_sel;
    assign mem_we_o   = active_ifetch_q ? ic_mem_we   : dc_mem_we;
    assign mem_cyc_o  = active_ifetch_q ? ic_mem_cyc  : dc_mem_cyc;
    assign mem_stb_o  = active_ifetch_q ? ic_mem_stb  : dc_mem_stb;
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
