// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: icache -- direct-mapped, read-only instruction cache
 *
 * First cache this core has ever had (it was cacheless from the start --
 * see design/defaults/instructions_and_masks.sv's own "single-hart/
 * non-pipelined/single-bus-master/cacheless" comment). Sits between
 * core.sv's fetch path and wb4_sram.sv, presenting a Wishbone SLAVE port
 * to the core (this module's addr_i/cyc_i/stb_i/ack_o/err_o/dat_o) and a
 * Wishbone MASTER port to memory (mem_*) -- read-only, since instruction
 * fetch never writes: no we_i/dat_i/sel_i on the core-facing side at all,
 * documenting the missing write path rather than requiring dead-code
 * reasoning about a we_i=1 case that structurally cannot happen.
 *
 * Direct-mapped, matching design/divider.sv's own precedent for a
 * first-cut module: simplicity and per-state verifiability over
 * hit-rate/cycle-count, with no synthesis flow yet to make a
 * set-associative design's real cost (comparators, LRU state, way-select
 * mux) worth trading against. A PIPT design (physically-indexed,
 * physically-tagged) -- this core has no virtual addressing yet, so
 * there's no VIPT-aliasing concern to design around.
 *
 * wb4_sram.sv has no burst support, so a miss refill is line_words
 * sequential single-dword reads, not a native burst -- see the
 * CACHE_REFILL state below. Fixed fill order (beat 0..line_words-1
 * regardless of which word within the line was actually requested) --
 * deliberately simple; critical-word-first/early-restart is a
 * well-isolated future optimization, not a correctness requirement.
 *
 * Both parameters must be powers of two, >= 2 -- the address-breakdown
 * math below assumes this (matches wb4_sram.sv's own unstated assumption
 * that num_words behaves the same way).
 *
 * Parameters:
 *  num_lines:  Number of cache lines (default 64).
 *  line_words: 64-bit words per line (default 4, i.e. 32-byte lines).
 */
module icache #(
    parameter num_lines  = 64,
    parameter line_words = 4
) (
    input logic clk,
    input logic rst,

    /*
     * Core-facing port -- this module is a Wishbone SLAVE from the
     * core's side. Bits [2:0] of addr_i (the byte offset within a dword)
     * are genuinely unused, same reasoning as wb4_sram.sv's own addr_i:
     * this module only supports dword-granularity fetch addressing.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] dat_o,
    input  logic         cyc_i,
    input  logic         stb_i,
    output logic         ack_o,
    output logic         err_o,

    // Memory-facing port -- this module is a Wishbone MASTER from
    // wb4_sram.sv's side.
    output logic [31:0] mem_addr_o,
    input  logic [63:0] mem_dat_i,
    output logic [7:0]  mem_sel_o,
    output logic        mem_we_o,
    output logic        mem_cyc_o,
    output logic        mem_stb_o,
    input  logic        mem_ack_i,
    input  logic        mem_err_i
);
    /*
     * Address breakdown (byte address, dword-granular):
     *   [31 : 3+OFFSET_WIDTH+INDEX_WIDTH]  tag
     *   [3+OFFSET_WIDTH+INDEX_WIDTH-1 : 3+OFFSET_WIDTH]  index
     *   [3+OFFSET_WIDTH-1 : 3]  word-within-line offset
     *   [2:0]  byte offset within dword (unused)
     */
    localparam OFFSET_WIDTH = $clog2(line_words);
    localparam INDEX_WIDTH  = $clog2(num_lines);
    localparam TAG_WIDTH    = 32 - 3 - OFFSET_WIDTH - INDEX_WIDTH;

    wire [OFFSET_WIDTH-1:0] req_offset = addr_i[3+OFFSET_WIDTH-1:3];
    wire [INDEX_WIDTH-1:0]  req_index  = addr_i[3+OFFSET_WIDTH+INDEX_WIDTH-1:3+OFFSET_WIDTH];
    wire [TAG_WIDTH-1:0]    req_tag    = addr_i[31:3+OFFSET_WIDTH+INDEX_WIDTH];

    reg [63:0]          data_q [0:num_lines-1][0:line_words-1];
    reg [TAG_WIDTH-1:0]  tag_q [0:num_lines-1];
    reg [num_lines-1:0] valid_q;

    /*
     * Simulation-only zero-fill, same reasoning/convention as
     * wb4_sram.sv's own memory[] init: real hardware has no defined
     * power-up state, but zeroing here keeps waveform/$display output
     * readable. valid_q's reset (below, in the clocked block) is the
     * one that's actually correctness-critical -- see that comment.
     */
    integer init_li, init_wi;
    initial begin
        for (init_li = 0; init_li < num_lines; init_li = init_li + 1) begin
            tag_q[init_li] = '0;
            for (init_wi = 0; init_wi < line_words; init_wi = init_wi + 1)
                data_q[init_li][init_wi] = 64'b0;
        end
    end

    typedef enum logic {
        CACHE_IDLE,
        CACHE_REFILL
    } cache_state_t;
    cache_state_t state_q;

    // Latched at miss-detection time -- everything CACHE_REFILL needs to
    // drive the downstream refill and, on completion, serve the
    // originally-requested word back to the core.
    reg [INDEX_WIDTH-1:0]  refill_index_q;
    reg [TAG_WIDTH-1:0]    refill_tag_q;
    reg [OFFSET_WIDTH-1:0] refill_word_q;
    reg [OFFSET_WIDTH-1:0] refill_beat_q;

    wire [31:0] refill_addr = {refill_tag_q, refill_index_q, refill_beat_q, 3'b0};

    /*
     * Memory-facing bus drive: same !mem_ack_i-gated discipline core.sv's
     * own wb_master_drive block uses (core.sv:1554) -- combinational so
     * mem_cyc_o/mem_stb_o drop the instant mem_ack_i arrives, avoiding a
     * double-fire against a slave that would otherwise see cyc&&stb
     * asserted again the following cycle. Also gated on !mem_err_i, not
     * just !mem_ack_i -- mem_ack_i never arrives on an error response
     * (see the CACHE_REFILL case arm's own comment on why ack/err are
     * mutually exclusive here), so without this the request would stay
     * asserted forever after an error instead of dropping.
     */
    always_comb begin: mem_master_drive
        mem_cyc_o  = 1'b0;
        mem_stb_o  = 1'b0;
        mem_we_o   = 1'b0;
        mem_addr_o = 32'b0;
        mem_sel_o  = 8'b0;
        if (state_q == CACHE_REFILL && !mem_ack_i && !mem_err_i) begin
            mem_cyc_o  = 1'b1;
            mem_stb_o  = 1'b1;
            mem_addr_o = refill_addr;
            mem_sel_o  = 8'hFF; // full dword; this module never does partial reads
        end
    end: mem_master_drive

    always_ff @(posedge clk) begin
        if (rst) begin
            ack_o   <= 1'b0;
            err_o   <= 1'b0;
            dat_o   <= 64'b0;
            state_q <= CACHE_IDLE;
            /*
             * Correctness-critical, unlike data_q/tag_q's simulation-only
             * init above: stale valid tags surviving reset would let the
             * cache serve pre-reset garbage as a false hit. Deliberate
             * divergence from wb4_sram.sv's own don't-reset-memory-
             * contents philosophy -- that module's comment explains real
             * hardware has no defined memory power-up state, which is
             * true of data_q/tag_q here too, but valid_q isn't memory
             * contents, it's the cache's own correctness invariant.
             */
            valid_q <= '0;
        end else begin
            case (state_q)
                CACHE_IDLE: begin
                    ack_o <= 1'b0;
                    err_o <= 1'b0;
                    if (cyc_i && stb_i) begin
                        if (valid_q[req_index] && (tag_q[req_index] == req_tag)) begin
                            dat_o <= data_q[req_index][req_offset];
                            ack_o <= 1'b1;
                        end else begin
                            refill_index_q <= req_index;
                            refill_tag_q   <= req_tag;
                            refill_word_q  <= req_offset;
                            refill_beat_q  <= '0;
                            state_q        <= CACHE_REFILL;
                        end
                    end
                end
                CACHE_REFILL: begin
                    /*
                     * mem_ack_i and mem_err_i are mutually exclusive, not
                     * "err qualifies an ack" -- wb4_sram.sv's own error
                     * response (out-of-range address) sets err_o=1 with
                     * ack_o held at 0, matching the Wishbone B4 convention
                     * that ack/err are alternative cycle-termination
                     * signals, never asserted together. The condition
                     * here MUST be the OR, not "err nested inside ack",
                     * or an error response would never be observed at
                     * all (this was a real bug, caught by icache_tb.sv's
                     * out-of-range test hanging instead of failing --
                     * mem_ack_i simply never arrives on an error cycle).
                     */
                    if (mem_ack_i || mem_err_i) begin
                        if (mem_err_i) begin
                            /*
                             * Abort: don't install the line (leaves
                             * valid_q[refill_index_q] exactly as it was
                             * -- either already-0, or a still-good older
                             * line if this replaces a valid one, which is
                             * fine either way since we're reporting an
                             * error for THIS access, not silently
                             * corrupting a future one).
                             */
                            err_o   <= 1'b1;
                            ack_o   <= 1'b1;
                            state_q <= CACHE_IDLE;
                        end else begin
                            data_q[refill_index_q][refill_beat_q] <= mem_dat_i;
                            if (refill_beat_q == OFFSET_WIDTH'(line_words - 1)) begin
                                valid_q[refill_index_q] <= 1'b1;
                                tag_q[refill_index_q]   <= refill_tag_q;
                                /*
                                 * If the just-arrived beat IS the
                                 * originally-requested word, serve
                                 * mem_dat_i directly -- data_q's own
                                 * write above is non-blocking and won't
                                 * be observable via a same-cycle read of
                                 * data_q[refill_index_q][refill_word_q]
                                 * until next cycle.
                                 */
                                dat_o <= (refill_beat_q == refill_word_q)
                                         ? mem_dat_i
                                         : data_q[refill_index_q][refill_word_q];
                                ack_o   <= 1'b1;
                                state_q <= CACHE_IDLE;
                            end else begin
                                refill_beat_q <= refill_beat_q + 1'b1;
                            end
                        end
                    end
                end
            endcase
        end
    end
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
