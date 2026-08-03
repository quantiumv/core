// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Data memory
 *
 * Purpose-built for the single-cycle core, same reasoning as imem.sv:
 * combinational read, no bus protocol. Unlike a Wishbone-attached memory
 * (e.g. design/wb4_sram.sv), this isn't limited to 32-bit beats -- the
 * data port is the full WORD_SIZE (64 bits) wide, so LD/SD complete as
 * ordinary single-cycle accesses instead of needing two beats. Also
 * unlike wb4_sram.sv, this has real byte enables, so SB/SH don't need a
 * read-modify-write cycle to avoid corrupting the bytes around them --
 * core.sv can just fire a single write with the right lanes enabled.
 *
 * i_size is deliberately 2 raw bits, not something ISA-aware like an
 * opcode or funct3 field: it's literally funct3[1:0], which RISC-V
 * encodes identically for every load AND store (00=byte, 01=half,
 * 10=word, 11=doubleword), so core.sv can pass it straight through and
 * this module never needs to `include any instruction-related header.
 *
 * Sign/zero-extension of load data is deliberately NOT this module's
 * job -- LB and LBU read the physically identical byte; whether the
 * result gets sign- or zero-extended is a register-width interpretation
 * core.sv applies afterward, not a memory concern.
 *
 * Known, deliberate simplifications (consistent with everything else
 * deferred out of this milestone -- see the top-level plan): no
 * misaligned-access fault (an access whose byte_offset+size spills past
 * the end of its 8-byte line silently drops the spilling bytes rather
 * than faulting or spanning two lines) and no address-range fault (an
 * out-of-range i_addr aliases via the bit-slice below rather than
 * erroring, unlike wb4_sram.sv's addr_valid check). Testbenches for this
 * milestone stick to naturally-aligned accesses within range.
 *
 * Parameters:
 *  - num_words: number of WORD_SIZE-wide lines (default 4096 = 32 KB).
 *  - l2_num_words: log2(num_words).
 *
 * Input ports:
 *  i_clk: Clock (writes are synchronous; reads are not).
 *  i_addr: Byte address.
 *  i_size: Access width -- 2'b00=byte, 01=half, 10=word, 11=doubleword
 *          (this is exactly funct3[1:0] for every RV64I load/store).
 *  i_write_enable: High to write i_write_data on the next clock edge.
 *  i_write_data: Data to write. The byte/half/word/doubleword being
 *                stored is expected in this value's OWN low bits (i.e.
 *                "the byte to store" in bits [7:0], regardless of where
 *                it ends up landing in memory) -- this module shifts it
 *                into the correct lane itself, core.sv doesn't need to.
 *
 * Output port:
 *  o_read_data: The full WORD_SIZE-wide line containing i_addr,
 *               combinationally, every cycle (regardless of i_size --
 *               core.sv extracts/shifts out the piece it actually wants).
 */
module dmem #(
    parameter num_words    = 4096,
    parameter l2_num_words = 12
) (
    input  logic                       i_clk,
    /*
     * Only bits [l2_num_words+2:0] of i_addr are used (line_addr +
     * byte_offset below) -- deliberate, per the address-range
     * simplification documented above, not an oversight.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [(`WORD_SIZE - 1):0]  i_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]                 i_size,
    input  logic                       i_write_enable,
    input  logic [(`WORD_SIZE - 1):0]  i_write_data,
    output logic [(`WORD_SIZE - 1):0]  o_read_data
);
    logic [(`WORD_SIZE - 1):0] mem [0:(num_words - 1)];

    /* Simulation-only zero-fill -- see imem.sv for why. */
    integer init_i;
    initial begin
        for (init_i = 0; init_i < num_words; init_i = init_i + 1)
            mem[init_i] = '0;
    end

    /*
     * Each line is WORD_SIZE/8 = 8 bytes, so the low 3 address bits
     * select a byte lane WITHIN a line, and everything above that
     * selects the line itself.
     */
    wire [(l2_num_words - 1):0] line_addr   = i_addr[(l2_num_words + 2):3];
    wire [2:0]                  byte_offset = i_addr[2:0];

    assign o_read_data = mem[line_addr];

    /*
     * Byte-enable generation: start with a mask that has the right
     * NUMBER of low bits set for the access size, then barrel-shift it
     * left by byte_offset to slide those bits into the correct lane
     * position. E.g. a halfword access at byte_offset=2 starts as
     * 8'b00000011 and becomes 8'b00001100 -- lanes 2 and 3 enabled.
     */
    logic [7:0] size_mask, byte_enable;
    always_comb begin: byte_enable_gen
        case (i_size)
            2'b00:   size_mask = 8'h01; // byte
            2'b01:   size_mask = 8'h03; // halfword
            2'b10:   size_mask = 8'h0F; // word
            default: size_mask = 8'hFF; // 2'b11: doubleword
        endcase
        byte_enable = size_mask << byte_offset;
    end: byte_enable_gen

    /*
     * Slide the write data into the same lane position byte_enable just
     * computed, so "byte 0 of i_write_data" ends up at the enabled lane
     * regardless of where that lane actually is within the line.
     */
    wire [(`WORD_SIZE - 1):0] shifted_write_data = i_write_data << (byte_offset * 8);

    always_ff @(posedge i_clk) begin: write_port
        if (i_write_enable) begin
            for (int lane = 0; lane < 8; lane = lane + 1) begin
                if (byte_enable[lane])
                    mem[line_addr][(8 * lane) +: 8] <= shifted_write_data[(8 * lane) +: 8];
            end
        end
    end: write_port
endmodule
