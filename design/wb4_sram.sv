// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


//TODO: Will need to redo defaults.
// `include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Internal SRAM With Wishbone BUS
 *
 * Widened to 64-bit data (was 32) so LD/SD complete as single-beat
 * accesses over the SoC's Wishbone bus -- see design/core.sv's header
 * comment for why the bus is 64-bit here. Byte-granularity writes now
 * need an explicit sel_i (SB/SH/SW write less than the full 8-byte line);
 * core.sv computes the mask/shift and this module just does the
 * lane-gated write.
 *
 * Parameters:
 *  num_words: Number of 64-bit words in the memory (default = 4096, 32KB).
 *
 */
module wb4_sram #(
    parameter num_words = 4096
) (
    input logic clk,
    input logic rst,

    // Wishbone signals
    /*
     * Bits [2:0] (the byte offset within an 8-byte word) are genuinely
     * unused -- this module only supports word-granularity addressing;
     * per-byte write granularity comes from sel_i, not from low address
     * bits. Deliberately narrowed, not an oversight.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,

    output logic ack_o,
    output logic err_o,
    input logic cyc_i,
    input logic stb_i,
    input logic we_i
);
    reg [63:0] memory [0:(num_words - 1)];

    // For address calculation. Each word is now 8 bytes (3 byte-offset
    // bits), not 4 (2 bits) -- word_addr/addr_valid's slices shift by one
    // bit accordingly versus the 32-bit version this replaced.
    localparam ADDR_WIDTH = $clog2(num_words);
    wire [ADDR_WIDTH-1:0] word_addr;
    wire addr_valid;

    /*
     * Simulation-only zero-fill, same reasoning and same convention as
     * register_file.sv: real hardware has no defined power-up memory
     * state, but zeroing here keeps waveform/$display
     * output readable, and matters more here than for those modules --
     * this is the memory real firmware actually loads into via
     * $readmemh below, and $readmemh only writes the addresses the hex
     * file actually specifies, leaving everything else at whatever the
     * array started as. Applied before $readmemh so a real firmware
     * load still overwrites the addresses it covers.
     */
    integer init_i;
    initial begin
        for (init_i = 0; init_i < num_words; init_i = init_i + 1)
            memory[init_i] = '0;
        $readmemh("../firmware/crt0.hex", memory);
    end

    assign word_addr = addr_i[ADDR_WIDTH+2:3]; // Byte to 8-byte-word address
    assign addr_valid = (addr_i[31:ADDR_WIDTH+3] == 0); // Check upper bits are 0

    always @(posedge clk) begin
        if (rst)
        begin
            ack_o <= 1'b0;
            err_o <= 1'b0;
            dat_o <= 64'b0;
        end
        else
        begin
            if (cyc_i && stb_i) begin
                if (addr_valid) begin
                    if (we_i)
                    begin
                        /*
                         * Lane-gated write, one bit of sel_i per byte.
                         * Variable-indexed +: part-select, not a constant
                         * bit-select -- Icarus doesn't fully support
                         * constant selects inside always_* processes,
                         * and this form sidesteps that entirely rather
                         * than working around it.
                         */
                        for (int lane = 0; lane < 8; lane = lane + 1) begin
                            if (sel_i[lane])
                                memory[word_addr][(8*lane) +: 8] <= dat_i[(8*lane) +: 8];
                        end
                    end
                    else
                    begin
                        dat_o <= memory[word_addr];
                    end
                    ack_o <= 1'b1;
                    err_o <= 1'b0;
                end
                else
                begin
                    ack_o <= 1'b0;
                    err_o <= 1'b1;
                end
            end
            else
            begin
                ack_o <= 1'b0;
                err_o <= 1'b0;
            end
        end
    end
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
