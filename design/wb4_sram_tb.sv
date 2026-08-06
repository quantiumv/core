// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb4_sram (post-widening to 64-bit + sel_i)
 *
 * Drives the Wishbone port directly -- no core.sv involved. Covers a
 * full round-trip write/read and, specifically, that a partial
 * byte-enable write leaves the other lanes of the same line untouched
 * (the actual new behavior this edit added).
 *
 * check() and wb_cycle() come from testbench/check_lib.sv and
 * testbench/wb_driver.sv (see each for its required-signal contract) --
 * resolved via a bare filename plus -I testbench on the iverilog command
 * line, per those files' own headers.
 */
module wb4_sram_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    wb4_sram #(.num_words(64)) dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .ack_o(ack), .err_o(err), .cyc_i(cyc), .stb_i(stb), .we_i(we)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'h00;
        @(posedge clk); #1;
        rst = 0;

        // Full-word write/read round trip.
        wb_cycle(32'h0, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
        #1;
        check("full-word round trip", dat_o, 64'hDEADBEEF_CAFEF00D);

        // Partial byte-enable write: only lanes 0-1 (sel=8'h03) get the
        // new value; lanes 2-7 (already DE AD BE EF CA FE from above)
        // must stay untouched.
        wb_cycle(32'h0, 64'h00000000_0000A5A5, 8'h03, 1'b1);
        wb_cycle(32'h0, 64'h0, 8'h00, 1'b0);
        #1;
        check("byte-enable write only touches enabled lanes", dat_o, 64'hDEADBEEF_CAFEA5A5);

        // A different line entirely stays at its power-on-zero value --
        // proves word_addr's bit-slice isn't accidentally aliasing lines.
        wb_cycle(32'h8, 64'h0, 8'h00, 1'b0);
        #1;
        check("adjacent line unaffected", dat_o, 64'h0);

        // Out-of-range address (num_words=64 -> valid range is 0x000-0x1FF)
        // must assert err_o, not silently succeed. Safe as a plain
        // wb_cycle call now that the shared task waits on !ack && !err
        // instead of !ack only.
        wb_cycle(32'h1000, 64'h0, 8'h00, 1'b0);
        check("out-of-range address asserts err_o", {63'b0, err}, 64'd1);

        $display("");
        $display("wb4_sram_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb4_sram_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
