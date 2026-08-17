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
 * general-purpose memory at all -- it's split into exactly two behaviors
 * gated on wb_ifetch_o (the same side-band signal cache_complex.sv
 * already uses for I$/D$ routing):
 *   - Instruction fetches: served from a real, small backing array,
 *     same convention as wb4_sram.sv (so a real program can actually run).
 *   - Any data access (S_MEM/S_AMO_WRITE, ifetch low): reads always
 *     succeed with a fixed known value; writes always fault. There is
 *     only ever one AMO under test in the testbenches that use this
 *     harness, so no address-matching logic is needed for the data path.
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

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err, wb_ifetch;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err), .wb_ifetch_o(wb_ifetch)
    );

    reg [63:0] memory [0:(NUM_WORDS - 1)];
    localparam ADDR_WIDTH = $clog2(NUM_WORDS);
    wire [ADDR_WIDTH-1:0] word_addr = wb_addr[ADDR_WIDTH+2:3];
    wire addr_valid = (wb_addr[31:ADDR_WIDTH+3] == 0);

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

    always @(posedge clk) begin
        if (rst) begin
            wb_ack     <= 1'b0;
            wb_err     <= 1'b0;
            wb_dat_s2m <= 64'b0;
        end else if (wb_cyc && wb_stb) begin
            if (wb_ifetch) begin
                if (addr_valid) begin
                    wb_dat_s2m <= memory[word_addr];
                    wb_ack     <= 1'b1;
                    wb_err     <= 1'b0;
                end else begin
                    wb_ack <= 1'b0;
                    wb_err <= 1'b1;
                end
            end else begin
                if (wb_we) begin
                    wb_ack <= 1'b0;
                    wb_err <= 1'b1;
                end else begin
                    wb_dat_s2m <= AMO_OLD_VALUE;
                    wb_ack     <= 1'b1;
                    wb_err     <= 1'b0;
                end
            end
        end else begin
            wb_ack <= 1'b0;
            wb_err <= 1'b0;
        end
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
