// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: dcache -- direct-mapped, write-through, no-write-allocate data
 * cache
 *
 * Sibling to design/icache.sv -- same direct-mapped, PIPT organization,
 * same multi-beat sequential refill discipline for reads (wb4_sram.sv has
 * no burst support), same reasoning for why (see icache.sv's own header
 * for the full derivation; not repeated here).
 *
 * Full Wishbone slave port both sides (unlike icache.sv's read-only
 * core-facing port): loads AND stores both flow through this module.
 *
 * Write policy -- write-through, no-write-allocate:
 *  - A store is ALWAYS forwarded to SRAM as a single downstream beat,
 *    hit or miss -- writes are never slower than the cacheless baseline.
 *  - A store HIT also updates the cached copy in place, using the same
 *    sel-qualified byte-lane merge wb4_sram.sv's own write path already
 *    does -- keeps the cache and SRAM in lockstep without ever needing a
 *    dirty bit or a write-back-on-evict path.
 *  - A store MISS does NOT allocate a line -- the cache stays exactly as
 *    it was; only a later READ to that address would install it. This
 *    sidesteps having to refill a whole line just to service one write.
 *
 * AMO/LR/SC need no special handling here at all: this core's reservation
 * register (design/core.sv's reservation_valid_q/reservation_addr_q) is a
 * bare address compare, fully independent of cache state, and an AMO's
 * read phase and write phase are captured against the bit-identical
 * address (design/core.sv's amo_addr_q, latched once), so a direct-mapped
 * index/tag guarantees both phases hit the same line -- the write phase
 * is provably always a cache hit, never its own refill. LR is an ordinary
 * read through this module; SC is an ordinary (conditional) write.
 */
module dcache #(
    parameter num_lines  = 64,
    parameter line_words = 4
) (
    input logic clk,
    input logic rst,

    /*
     * Core-facing port -- this module is a Wishbone SLAVE from the
     * core's side. Bits [2:0] of addr_i (the byte offset within a dword)
     * are genuinely unused, same reasoning as wb4_sram.sv's own addr_i.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    // Memory-facing port -- this module is a Wishbone MASTER from
    // wb4_sram.sv's side.
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
    // Address breakdown -- identical scheme to icache.sv, see that
    // module's own comment for the exact bit layout.
    localparam OFFSET_WIDTH = $clog2(line_words);
    localparam INDEX_WIDTH  = $clog2(num_lines);
    localparam TAG_WIDTH    = 32 - 3 - OFFSET_WIDTH - INDEX_WIDTH;

    wire [OFFSET_WIDTH-1:0] req_offset = addr_i[3+OFFSET_WIDTH-1:3];
    wire [INDEX_WIDTH-1:0]  req_index  = addr_i[3+OFFSET_WIDTH+INDEX_WIDTH-1:3+OFFSET_WIDTH];
    wire [TAG_WIDTH-1:0]    req_tag    = addr_i[31:3+OFFSET_WIDTH+INDEX_WIDTH];

    reg [63:0]          data_q [0:num_lines-1][0:line_words-1];
    reg [TAG_WIDTH-1:0]  tag_q [0:num_lines-1];
    reg [num_lines-1:0] valid_q;

    wire req_hit = valid_q[req_index] && (tag_q[req_index] == req_tag);

    // Simulation-only zero-fill -- see icache.sv's identical comment.
    integer init_li, init_wi;
    initial begin
        for (init_li = 0; init_li < num_lines; init_li = init_li + 1) begin
            tag_q[init_li] = '0;
            for (init_wi = 0; init_wi < line_words; init_wi = init_wi + 1)
                data_q[init_li][init_wi] = 64'b0;
        end
    end

    typedef enum logic [1:0] {
        CACHE_IDLE,
        CACHE_REFILL,
        CACHE_WRITE
    } cache_state_t;
    cache_state_t state_q;

    // CACHE_REFILL's own latched state -- identical role to icache.sv.
    reg [INDEX_WIDTH-1:0]  refill_index_q;
    reg [TAG_WIDTH-1:0]    refill_tag_q;
    reg [OFFSET_WIDTH-1:0] refill_word_q;
    reg [OFFSET_WIDTH-1:0] refill_beat_q;

    // CACHE_WRITE's own latched state -- everything needed to drive the
    // single downstream write beat and, on completion, update the cached
    // copy IF this was a hit (no-write-allocate: a miss updates nothing).
    reg [31:0]              write_addr_q;
    reg [63:0]               write_dat_q;
    reg [7:0]                write_sel_q;
    reg                      write_hit_q;
    reg [INDEX_WIDTH-1:0]  write_index_q;
    reg [OFFSET_WIDTH-1:0] write_offset_q;

    wire [31:0] refill_addr = {refill_tag_q, refill_index_q, refill_beat_q, 3'b0};

    /*
     * Memory-facing bus drive: same !mem_ack_i/!mem_err_i-gated
     * discipline icache.sv's own mem_master_drive uses (see that
     * module's comment for the full reasoning) -- extended with a second
     * arm for CACHE_WRITE's single downstream beat.
     */
    always_comb begin: mem_master_drive
        mem_cyc_o  = 1'b0;
        mem_stb_o  = 1'b0;
        mem_we_o   = 1'b0;
        mem_addr_o = 32'b0;
        mem_dat_o  = 64'b0;
        mem_sel_o  = 8'b0;
        if (state_q == CACHE_REFILL && !mem_ack_i && !mem_err_i) begin
            mem_cyc_o  = 1'b1;
            mem_stb_o  = 1'b1;
            mem_addr_o = refill_addr;
            mem_sel_o  = 8'hFF; // full dword; refill always reads a whole line
        end else if (state_q == CACHE_WRITE && !mem_ack_i && !mem_err_i) begin
            mem_cyc_o  = 1'b1;
            mem_stb_o  = 1'b1;
            mem_we_o   = 1'b1;
            mem_addr_o = write_addr_q;
            mem_dat_o  = write_dat_q;
            mem_sel_o  = write_sel_q;
        end
    end: mem_master_drive

    always_ff @(posedge clk) begin
        if (rst) begin
            ack_o   <= 1'b0;
            err_o   <= 1'b0;
            dat_o   <= 64'b0;
            state_q <= CACHE_IDLE;
            // Correctness-critical -- see icache.sv's identical comment
            // on why this diverges from wb4_sram.sv's own reset
            // philosophy.
            valid_q <= '0;
        end else begin
            case (state_q)
                CACHE_IDLE: begin
                    ack_o <= 1'b0;
                    err_o <= 1'b0;
                    if (cyc_i && stb_i) begin
                        if (we_i) begin
                            // Write: always forwarded downstream as a
                            // single beat (no-write-allocate), regardless
                            // of hit/miss -- see this module's own header
                            // for why.
                            write_addr_q   <= addr_i;
                            write_dat_q    <= dat_i;
                            write_sel_q    <= sel_i;
                            write_hit_q    <= req_hit;
                            write_index_q  <= req_index;
                            write_offset_q <= req_offset;
                            state_q        <= CACHE_WRITE;
                        end else begin
                            // Read: identical hit/miss handling to
                            // icache.sv.
                            if (req_hit) begin
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
                end
                CACHE_REFILL: begin
                    // Identical to icache.sv's own CACHE_REFILL arm --
                    // see that module's comments for the full reasoning
                    // (mem_ack_i/mem_err_i mutual exclusivity, fixed fill
                    // order, the same-cycle-arrival dat_o special case).
                    if (mem_ack_i || mem_err_i) begin
                        if (mem_err_i) begin
                            err_o   <= 1'b1;
                            ack_o   <= 1'b1;
                            state_q <= CACHE_IDLE;
                        end else begin
                            data_q[refill_index_q][refill_beat_q] <= mem_dat_i;
                            if (refill_beat_q == OFFSET_WIDTH'(line_words - 1)) begin
                                valid_q[refill_index_q] <= 1'b1;
                                tag_q[refill_index_q]   <= refill_tag_q;
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
                CACHE_WRITE: begin
                    if (mem_ack_i || mem_err_i) begin
                        if (mem_err_i) begin
                            // Downstream write failed -- don't touch the
                            // cached copy even if write_hit_q, since the
                            // write never actually reached SRAM (would
                            // desync the cache from memory otherwise).
                            err_o   <= 1'b1;
                            ack_o   <= 1'b1;
                            state_q <= CACHE_IDLE;
                        end else begin
                            if (write_hit_q) begin
                                /*
                                 * Sel-qualified byte-lane merge into the
                                 * cached copy -- same idiom wb4_sram.sv's
                                 * own write path uses (design/wb4_sram.sv,
                                 * the variable-indexed +: part-select
                                 * form, not a constant bit-select, for
                                 * the same Icarus constant-select
                                 * limitation reason given there).
                                 */
                                for (int lane = 0; lane < 8; lane = lane + 1) begin
                                    if (write_sel_q[lane])
                                        data_q[write_index_q][write_offset_q][(8*lane) +: 8] <= write_dat_q[(8*lane) +: 8];
                                end
                            end
                            ack_o   <= 1'b1;
                            state_q <= CACHE_IDLE;
                        end
                    end
                end
                default: begin
                    // Unreachable in practice (cache_state_t only ever
                    // assigns the 3 named values above) -- present only
                    // because a 2-bit state var has a 4th encoding
                    // (2'b11) with no defined meaning. Recover to a known
                    // good state rather than leaving behavior undefined.
                    state_q <= CACHE_IDLE;
                end
            endcase
        end
    end
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
