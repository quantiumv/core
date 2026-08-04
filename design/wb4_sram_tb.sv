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
    task automatic check(string name, logic [63:0] actual, logic [63:0] expected);
        if (actual === expected) begin
            pass_count++;
            $display("PASS: %s", name);
        end else begin
            fail_count++;
            $display("FAIL: %s -- expected %h, got %h", name, expected, actual);
        end
    endtask

    /*
     * Issue one WB transaction and wait for ack, mirroring core.sv's own
     * "hold the request, advance on ack" convention. The #1 after each
     * @(posedge clk) before checking ack is required: ack_o updates via
     * <= in the DUT's clocked block, only visible in the NBA region
     * after this edge's active region finishes -- checking immediately
     * on resuming from @(posedge clk) would read ack one edge stale,
     * leaving cyc/stb asserted for an extra edge and causing a second,
     * spurious transaction (silently harmless here since a repeated
     * identical read/write is idempotent, but the same task shape
     * caused a real duplicate-write bug in uart_tx_tb.sv, where it
     * isn't -- fixed in both places).
     */
    task automatic wb_cycle(logic [31:0] a, logic [63:0] d, logic [7:0] s, logic w);
        @(negedge clk);
        addr = a; dat_i = d; sel = s; we = w; cyc = 1; stb = 1;
        @(posedge clk); #1;
        while (!ack) begin
            @(posedge clk); #1;
        end
        cyc = 0; stb = 0;
    endtask

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
        // must assert err_o, not silently succeed.
        @(negedge clk);
        addr = 32'h1000; dat_i = 64'h0; sel = 8'h00; we = 0; cyc = 1; stb = 1;
        @(posedge clk); #1;
        while (!ack && !err) begin
            @(posedge clk); #1;
        end
        check("out-of-range address asserts err_o", {63'b0, err}, 64'd1);
        cyc = 0; stb = 0;

        $display("");
        $display("wb4_sram_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb4_sram_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
