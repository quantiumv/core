// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: core_amo_write_fault_harness
 *
 * Purpose-built for exactly one scenario: an AMO whose READ phase
 * succeeds but whose WRITE phase (to the SAME address) faults. No real
 * Wishbone slave in this project can produce that -- wb4_sram.sv's
 * addr_valid check is symmetric for read vs. write at a fixed address,
 * so "read succeeds, write faults" is structurally impossible to
 * construct through it (or any real cache/decoder path sitting on top
 * of it) alone. This mock slave sidesteps that by not being a real,
 * general-purpose memory at all -- it's two independent mock slaves, one
 * per core.sv master port (no merge needed: they never shared an
 * address space):
 *   - Fetch port: served from a real, small backing array, same
 *     convention as wb4_sram.sv (so a real program can actually run).
 *   - Mem port (S_MEM/S_AMO_WRITE/S_PTW): reads always succeed with a
 *     fixed known value; writes always fault. There is only ever one
 *     AMO under test in the testbenches that use this harness, so no
 *     address-matching logic is needed for the data path.
 *
 * Use core_wb4_sram_harness (or core_cache_harness for the cached path)
 * for every other testbench -- this one exists solely to make the AMO
 * write-phase fault case constructible at all.
 */
module core_amo_write_fault_harness #(
    parameter NUM_WORDS = 64
) (
    input logic clk,
    input logic rst
);

    // core.sv's fetch-side (read-only) master port.
    logic [31:0] wbf_addr;
    logic [63:0] wbf_dat_s2m;
    logic        wbf_cyc, wbf_stb, wbf_ack, wbf_err;

    // core.sv's mem-side master port. wbm_addr/wbm_dat_m2s/wbm_sel are
    // never consulted (see the mock's own always block below).
    logic [31:0] wbm_addr;
    logic [63:0] wbm_dat_m2s, wbm_dat_s2m;
    logic [7:0]  wbm_sel;
    logic        wbm_we, wbm_cyc, wbm_stb, wbm_ack, wbm_err;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_fetch_addr_o(wbf_addr), .wb_fetch_cyc_o(wbf_cyc), .wb_fetch_stb_o(wbf_stb),
        .wb_fetch_dat_i(wbf_dat_s2m), .wb_fetch_ack_i(wbf_ack), .wb_fetch_err_i(wbf_err),
        .wb_mem_addr_o(wbm_addr), .wb_mem_dat_o(wbm_dat_m2s), .wb_mem_dat_i(wbm_dat_s2m),
        .wb_mem_sel_o(wbm_sel), .wb_mem_we_o(wbm_we), .wb_mem_cyc_o(wbm_cyc), .wb_mem_stb_o(wbm_stb),
        .wb_mem_ack_i(wbm_ack), .wb_mem_err_i(wbm_err)
    );

    reg [63:0] memory [0:(NUM_WORDS - 1)];
    localparam ADDR_WIDTH = $clog2(NUM_WORDS);
    wire [ADDR_WIDTH-1:0] word_addr = wbf_addr[ADDR_WIDTH+2:3];
    wire addr_valid = (wbf_addr[31:ADDR_WIDTH+3] == 0);

    /*
     * AMO_OLD_VALUE: what a read on the data path always returns --
     * the AMO's "old value" operand, chosen (along with the caller's
     * own rs2) so a mem_paddr-instead-of-amo_addr_q bug in core.sv's
     * trap_val is trivially distinguishable from the correct address:
     * see the testbench using this harness for the exact numbers.
     */
    localparam logic [63:0] AMO_OLD_VALUE = 64'd100;

    integer init_i;
    initial begin
        for (init_i = 0; init_i < NUM_WORDS; init_i = init_i + 1)
            memory[init_i] = '0;
    end

    // Fetch-port mock: same registered one-cycle ack/err echo as wb4_sram.sv.
    always @(posedge clk) begin
        if (rst) begin
            wbf_ack     <= 1'b0;
            wbf_err     <= 1'b0;
            wbf_dat_s2m <= 64'b0;
        end else if (wbf_cyc && wbf_stb) begin
            if (addr_valid) begin
                wbf_dat_s2m <= memory[word_addr];
                wbf_ack     <= 1'b1;
                wbf_err     <= 1'b0;
            end else begin
                wbf_ack <= 1'b0;
                wbf_err <= 1'b1;
            end
        end else begin
            wbf_ack <= 1'b0;
            wbf_err <= 1'b0;
        end
    end

    // Mem-port mock: reads always return AMO_OLD_VALUE, writes always fault.
    always @(posedge clk) begin
        if (rst) begin
            wbm_ack     <= 1'b0;
            wbm_err     <= 1'b0;
            wbm_dat_s2m <= 64'b0;
        end else if (wbm_cyc && wbm_stb) begin
            if (wbm_we) begin
                wbm_ack <= 1'b0;
                wbm_err <= 1'b1;
            end else begin
                wbm_dat_s2m <= AMO_OLD_VALUE;
                wbm_ack     <= 1'b1;
                wbm_err     <= 1'b0;
            end
        end else begin
            wbm_ack <= 1'b0;
            wbm_err <= 1'b0;
        end
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
