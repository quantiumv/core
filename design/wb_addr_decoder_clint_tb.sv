// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_addr_decoder + real clint0 (bus-level integration)
 *
 * design/wb_addr_decoder_tb.sv proves the decoder's OWN routing/latching
 * logic in isolation, using fake slaves with fixed canned responses. This
 * testbench instead proves the decoder wired to REAL slaves -- especially
 * a real design/clint.sv -- works correctly end-to-end through the actual
 * port wiring soc.sv now uses, via testbench/decoder_clint_harness.sv
 * (real wb_addr_decoder + real wb4_sram + real uart_tx + real clint, no
 * core.sv). This is bus-level, not firmware/instruction-level: raw
 * Wishbone cycles are driven directly at the decoder's CPU-facing port
 * with testbench/wb_driver.sv's wb_cycle() task, the same way
 * design/wb4_sram_tb.sv and design/wb_addr_decoder_tb.sv already do --
 * no real RISC-V instructions are assembled or run through core.sv here.
 *
 * mtime is a real, free-running counter in this test (not a fixed fake
 * response) -- so "sane" is checked via two reads separated by real
 * elapsed cycles and confirming the second is strictly greater than the
 * first, rather than via an exact-value check() the way the fake-slave
 * testbench can afford to.
 *
 * Deliberately does NOT test interrupt-taking (mtip_o has no consumer
 * anywhere in this milestone's fabric -- see clint0's own instantiation
 * in decoder_clint_harness.sv) -- that's Milestone 6's concern. This test
 * isolates address-decode-and-wiring correctness only.
 */
module wb_addr_decoder_clint_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    decoder_clint_harness dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    localparam logic [31:0] CLINT_MTIME    = 32'h0001_0000;
    localparam logic [31:0] CLINT_MTIMECMP = 32'h0001_0008;

    logic [63:0] mtime_first, mtime_second;

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'hFF;
        @(posedge clk); #1;
        rst = 0;

        /*
         * RAM round trip through the real fabric, BEFORE any CLINT
         * traffic -- baseline proof that routing to RAM still works with
         * CLINT now sharing the same decoder.
         */
        wb_cycle(32'h0000_0100, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0100, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (pre-CLINT traffic)", dat_o, 64'hDEADBEEF_CAFEF00D);

        /*
         * UART round trip through the real fabric -- TX_DATA write then
         * TX_STATUS poll, same pattern design/uart_tx_tb.sv itself uses.
         */
        wb_cycle(32'h0000_8000, 64'h48, 8'h01, 1'b1); // 'H'
        check("UART: one character captured", {55'b0, dut.uart0.tx_history_count}, 64'd1);
        check("UART: history[0] == 'H'", {56'b0, dut.uart0.tx_history[0]}, 64'h48);
        wb_cycle(32'h0000_8008, 64'h0, 8'h00, 1'b0);
        check("UART: TX_STATUS reads ready", dat_o, 64'h1);

        /*
         * CLINT mtime: a real, sane free-running counter, not a fixed
         * value -- two reads separated by real elapsed cycles must show
         * a strict increase.
         */
        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_first = dat_o;

        repeat (20) @(posedge clk);

        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_second = dat_o;
        check("CLINT mtime: second read strictly greater than first",
              {63'b0, (mtime_second > mtime_first)}, 64'd1);

        /*
         * CLINT mtimecmp: SD-equivalent write of a real 64-bit deadline,
         * then a read-back confirming it stuck.
         */
        wb_cycle(CLINT_MTIMECMP, 64'h0000_0000_0012_3456, 8'hFF, 1'b1);
        wb_cycle(CLINT_MTIMECMP, 64'h0, 8'hFF, 1'b0);
        check("CLINT mtimecmp: write then read-back sticks", dat_o, 64'h0000_0000_0012_3456);

        /*
         * RAM/UART routing unaffected by CLINT now sharing the decoder --
         * a plain RAM read/write round trip AFTER CLINT traffic, at a
         * different address than the earlier RAM check, still works.
         */
        wb_cycle(32'h0000_0200, 64'h1122_3344_5566_7788, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0200, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (post-CLINT traffic, unaffected)", dat_o, 64'h1122_3344_5566_7788);

        wb_cycle(32'h0000_8000, 64'h69, 8'h01, 1'b1); // 'i'
        check("UART: second character captured (post-CLINT traffic, unaffected)",
              {55'b0, dut.uart0.tx_history_count}, 64'd2);

        $display("");
        $display("wb_addr_decoder_clint_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb_addr_decoder_clint_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
