// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "defaults/instruction_format.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: Instruction memory
 *
 * Purpose-built for the single-cycle core: combinational read only, no
 * bus protocol at all. This is what makes single-cycle possible in the
 * first place -- fetch, decode, execute, memory access and writeback all
 * have to settle within one clock edge-to-edge cycle, so instruction
 * memory can't have any registered read latency (unlike
 * design/wb4_sram.sv, whose Wishbone ack is a clocked output and takes a
 * minimum of 2 edges -- that's exactly why this core doesn't use it).
 *
 * Test programs are loaded by writing directly into `mem` via a
 * hierarchical reference from the testbench (e.g.
 * dut.imem_inst.mem[0] = 32'h...;) -- no loader task is needed since
 * reads are combinational, so there's nothing to wait on after a write.
 *
 * Parameters:
 *  - num_words: number of 32-bit instruction words (default 4096 = 16 KB).
 *  - l2_num_words: log2(num_words).
 *
 * Input ports:
 *  i_addr: Byte address to fetch from (= PC). Only bits
 *          [l2_num_words+1:2] are used -- bits [1:0] are dropped (fetch
 *          is always 4-byte aligned; there's no C extension yet to make
 *          2-byte-aligned fetch meaningful) and everything above
 *          l2_num_words+1 is dropped too (aliases within this memory's
 *          range rather than faulting -- there's no address-range check,
 *          matching dmem.sv's same simplification).
 *
 * Output port:
 *  o_instruction: The 32-bit instruction at i_addr, combinationally.
 */
module imem #(
    parameter num_words    = 4096,
    parameter l2_num_words = 12
) (
    /*
     * Only bits [l2_num_words+1:2] of i_addr are actually used (see
     * o_instruction's assign below) -- deliberate, per the address-range
     * simplification documented above, not an oversight. Silenced rather
     * than left as a standing lint warning.
     */
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [(`WORD_SIZE - 1):0]  i_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [(`INSTR_SIZE - 1):0] o_instruction
);
    /*
     * INSTR_SIZE here, not WORD_SIZE -- instructions stay 32 bits
     * regardless of XLEN, the one place in this whole design where that
     * distinction actually matters for a signal's width.
     */
    logic [(`INSTR_SIZE - 1):0] mem [0:(num_words - 1)];

    /*
     * Simulation-only zero-fill so an unloaded location reads as 0
     * (which decodes as INVALID, see decoder.sv's default arm) instead
     * of as 'X -- makes "the program ran off the end of what was loaded"
     * behave predictably, and keeps waveform/$display output readable
     * during bring-up. Real hardware has no such guarantee at power-on.
     */
    integer init_i;
    initial begin
        for (init_i = 0; init_i < num_words; init_i = init_i + 1)
            mem[init_i] = '0;
    end

    assign o_instruction = mem[i_addr[(l2_num_words + 1):2]];
endmodule
