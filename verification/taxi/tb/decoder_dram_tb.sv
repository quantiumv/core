// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_addr_decoder + real dram0 (bus-level integration)
 *
 * Mirrors design/wb_addr_decoder_clint_tb.sv exactly, extended to the 4th
 * real slave -- via verification/taxi/rtl/decoder_dram_harness.sv (real
 * wb_addr_decoder + real wb4_sram + real uart_tx + real clint + real
 * dram_model, no core.sv). Bus-level, not firmware/instruction-level: raw
 * Wishbone cycles driven directly at the decoder's CPU-facing port with
 * wb_cycle(), same idiom as every other decoder-level testbench.
 *
 * dram0 is instantiated with its REAL default timing parameters
 * (ACCESS_LATENCY_CYCLES=4, REFRESH_INTERVAL_CYCLES=256,
 * REFRESH_BUSY_CYCLES=16, see decoder_dram_harness.sv) -- this test's job
 * is routing correctness, not timing correctness (already separately
 * proven by verification/taxi/tb/dram_model_tb.sv's own cycle-delta
 * method). wb_cycle()'s wait loop already tolerates arbitrary wait
 * states, so occasionally landing a request inside a refresh-busy window
 * just costs a few extra simulated cycles, at zero correctness risk.
 *
 * Deliberately does NOT run real firmware through core.sv -- that's a
 * separate, later step if ever wanted (and, unlike CLINT's own later
 * firmware-through-soc.sv proof, cannot ever be "just wire dram_model.sv
 * into soc.sv" -- see verification/taxi/README.md's Status section for
 * why). This test isolates address-decode-and-wiring correctness only,
 * matching wb_addr_decoder_clint_tb.sv's own explicit scoping.
 */
module decoder_dram_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    decoder_dram_harness dut (
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
    localparam logic [31:0] CLINT_TOP      = 32'h0001_7FFF; // top of CLINT's narrowed window
    localparam logic [31:0] DRAM_BASE      = 32'h0001_8000;
    localparam logic [31:0] DRAM_SECOND    = 32'h0001_8100;

    logic [63:0] mtime_first, mtime_second;

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'hFF;
        @(posedge clk); #1;
        rst = 0;

        /* RAM round trip through the real fabric, BEFORE any DRAM traffic. */
        wb_cycle(32'h0000_0100, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0100, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (pre-DRAM traffic)", dat_o, 64'hDEADBEEF_CAFEF00D);

        /* UART round trip. */
        wb_cycle(32'h0000_8000, 64'h48, 8'h01, 1'b1); // 'H'
        check("UART: one character captured", {55'b0, dut.uart0.tx_history_count}, 64'd1);
        check("UART: history[0] == 'H'", {56'b0, dut.uart0.tx_history[0]}, 64'h48);
        wb_cycle(32'h0000_8008, 64'h0, 8'h00, 1'b0);
        check("UART: TX_STATUS reads ready", dat_o, 64'h1);

        /* CLINT mtime: real free-running counter, strict-increase check. */
        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_first = dat_o;
        repeat (20) @(posedge clk);
        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_second = dat_o;
        check("CLINT mtime: second read strictly greater than first",
              {63'b0, (mtime_second > mtime_first)}, 64'd1);

        /* CLINT mtimecmp write/read-back. */
        wb_cycle(CLINT_MTIMECMP, 64'h0000_0000_0012_3456, 8'hFF, 1'b1);
        wb_cycle(CLINT_MTIMECMP, 64'h0, 8'hFF, 1'b0);
        check("CLINT mtimecmp: write then read-back sticks", dat_o, 64'h0000_0000_0012_3456);

        /* Top of CLINT's narrowed window -- proves the decoder's new
         * boundary, not just clint.sv's own permissive address aliasing
         * (clint.sv would ack almost anything routed to it regardless). */
        wb_cycle(CLINT_TOP, 64'h0, 8'hFF, 1'b0);
        check("CLINT top-of-narrowed-window: ack_o (routes to CLINT, not err)", {63'b0, ack}, 64'd1);
        check("CLINT top-of-narrowed-window: no err_o", {63'b0, err}, 64'd0);

        /* The critical DRAM round trip -- fails loudly with err_o instead
         * of a data mismatch if wb_addr_decoder.sv's dram_addr_o rebase
         * is missing or wrong. */
        wb_cycle(DRAM_BASE, 64'hFEED_FACE_BEEF_CAFE, 8'hFF, 1'b1);
        wb_cycle(DRAM_BASE, 64'h0, 8'hFF, 1'b0);
        check("DRAM round trip (bottom of window)", dat_o, 64'hFEED_FACE_BEEF_CAFE);
        check("DRAM round trip: ack_o, not err_o", {63'b0, ack}, 64'd1);

        /* Second DRAM address -- confirms the addr_i[14:0] rebase isn't
         * off-by-a-shift (a shift error would alias this back onto the
         * first address or onto a completely different byte). */
        wb_cycle(DRAM_SECOND, 64'h1357_9BDF_2468_ACE0, 8'hFF, 1'b1);
        wb_cycle(DRAM_SECOND, 64'h0, 8'hFF, 1'b0);
        check("DRAM round trip (second address)", dat_o, 64'h1357_9BDF_2468_ACE0);
        wb_cycle(DRAM_BASE, 64'h0, 8'hFF, 1'b0);
        check("DRAM: first address unchanged by second address's write", dat_o, 64'hFEED_FACE_BEEF_CAFE);

        /* RAM/UART/CLINT routing unaffected by DRAM now sharing the decoder. */
        wb_cycle(32'h0000_0200, 64'h1122_3344_5566_7788, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0200, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (post-DRAM traffic, unaffected)", dat_o, 64'h1122_3344_5566_7788);

        wb_cycle(32'h0000_8000, 64'h69, 8'h01, 1'b1); // 'i'
        check("UART: second character captured (post-DRAM traffic, unaffected)",
              {55'b0, dut.uart0.tx_history_count}, 64'd2);

        wb_cycle(CLINT_MTIMECMP, 64'h0, 8'hFF, 1'b0);
        check("CLINT mtimecmp: still reads back correctly (post-DRAM traffic, unaffected)",
              dat_o, 64'h0000_0000_0012_3456);

        $display("");
        $display("decoder_dram_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("decoder_dram_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
