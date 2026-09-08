// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_addr_decoder + real plic0 (bus-level integration)
 *
 * design/wb_addr_decoder_clint_tb.sv (this file's own direct template)
 * proves the decoder wired to real RAM/UART/CLINT slaves works
 * end-to-end. This testbench extends that same proof to the new fifth
 * slave (PMP+PLIC plan Milestone 5's own addr_i[22] split), via
 * testbench/decoder_plic_harness.sv. Bus-level, not firmware/
 * instruction-level -- same discipline as every sibling in this file.
 *
 * Deliberately does NOT re-prove plic.sv's own internal gateway/claim/
 * complete semantics (design/plic_tb.sv already covers that in full) --
 * this test isolates address-decode-and-wiring correctness only: does
 * the real addr_i[22] bit route to PLIC, does the real byte offset
 * within PLIC's own window land correctly, and do RAM/UART/CLINT stay
 * unaffected by PLIC now sharing the same decoder.
 */
module wb_addr_decoder_plic_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    decoder_plic_harness dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .i_uart_rx_irq(1'b0)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    localparam logic [31:0] CLINT_MTIME    = 32'h0401_0000;
    localparam logic [31:0] CLINT_MTIMECMP = 32'h0401_0008;

    // Real PLIC spec byte offsets (independently transcribed, matching
    // plic.sv's own internal localparams, not read from that file's
    // internals) plus the new PLIC_BASE this milestone's own addr_i[22]
    // split assigns (shifted up by 0x0400_0000 from 0x0040_0000, along
    // with every other peripheral, by the Linux-boot-readiness RAM-growth
    // change's new addr_i[26]/sel_periph outer gate).
    localparam logic [31:0] PLIC_BASE      = 32'h0440_0000;
    localparam logic [31:0] PLIC_PRIORITY  = PLIC_BASE + 32'h00_0000; // source1's field: HIGH 32 bits
    localparam logic [31:0] PLIC_THRESH0   = PLIC_BASE + 32'h20_0000; // threshold: LOW 32 bits

    logic [63:0] mtime_first, mtime_second;

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'hFF;
        @(posedge clk); #1;
        rst = 0;

        /* RAM round trip, BEFORE any PLIC traffic. */
        wb_cycle(32'h0000_0100, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0100, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (pre-PLIC traffic)", dat_o, 64'hDEADBEEF_CAFEF00D);

        /* UART round trip. */
        wb_cycle(32'h0400_8000, 64'h48, 8'h01, 1'b1); // 'H'
        check("UART: one character captured", {55'b0, dut.uart0.tx_history_count}, 64'd1);
        wb_cycle(32'h0400_8008, 64'h0, 8'h00, 1'b0);
        check("UART: TX_STATUS reads ready", dat_o, 64'h1);

        /* CLINT: mtime sane (real free-running counter), mtimecmp round trip. */
        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_first = dat_o;
        repeat (20) @(posedge clk);
        wb_cycle(CLINT_MTIME, 64'h0, 8'hFF, 1'b0);
        mtime_second = dat_o;
        check("CLINT mtime: second read strictly greater than first",
              {63'b0, (mtime_second > mtime_first)}, 64'd1);
        wb_cycle(CLINT_MTIMECMP, 64'h0000_0000_0012_3456, 8'hFF, 1'b1);
        wb_cycle(CLINT_MTIMECMP, 64'h0, 8'hFF, 1'b0);
        check("CLINT mtimecmp: write then read-back sticks", dat_o, 64'h0000_0000_0012_3456);

        /*
         * PLIC priority round trip through the REAL decoder, at the real
         * 0x0040_0000 window -- the direct proof addr_i[22]=1 genuinely
         * routes here (a decoder bug leaving the old 3-way-only decode in
         * place would instead route this to RAM/UART, aliasing this
         * write onto whatever real register lives at the low 22 bits of
         * this address in that OTHER slave, which would either silently
         * "succeed" with a wrong value or read back something else
         * entirely -- not just time out, so an exact-value check here is
         * a real, discriminating proof, not a formality).
         */
        wb_cycle(PLIC_PRIORITY, {29'b0, 3'd5, 32'b0}, 8'hF0, 1'b1);
        wb_cycle(PLIC_PRIORITY, 64'h0, 8'hF0, 1'b0);
        check("PLIC priority round trip through the real decoder (addr_i[22] routing)",
              dat_o[34:32], 64'(3'd5));

        /*
         * A second PLIC address, a different real offset within the same
         * window (+0x200000, not +0x0) -- confirms the addr_i[21:0]
         * mapping into plic.sv isn't off by a shift/rebase the first
         * check alone couldn't catch (e.g. plic_addr_o accidentally
         * rebased the way dram_addr_o deliberately IS, which would make
         * every PLIC offset alias onto offset 0).
         */
        wb_cycle(PLIC_THRESH0, {32'b0, 29'b0, 3'd2}, 8'h0F, 1'b1);
        wb_cycle(PLIC_THRESH0, 64'h0, 8'h0F, 1'b0);
        check("PLIC threshold round trip at a distinct offset (+0x200000, not aliased to +0x0)",
              dat_o[2:0], 64'(3'd2));

        /* RAM/UART/CLINT routing unaffected by PLIC now sharing the decoder. */
        wb_cycle(32'h0000_0200, 64'h1122_3344_5566_7788, 8'hFF, 1'b1);
        wb_cycle(32'h0000_0200, 64'h0, 8'hFF, 1'b0);
        check("RAM round trip (post-PLIC traffic, unaffected)", dat_o, 64'h1122_3344_5566_7788);

        wb_cycle(32'h0400_8000, 64'h69, 8'h01, 1'b1); // 'i'
        check("UART: second character captured (post-PLIC traffic, unaffected)",
              {55'b0, dut.uart0.tx_history_count}, 64'd2);

        wb_cycle(CLINT_MTIMECMP, 64'h0, 8'hFF, 1'b0);
        check("CLINT mtimecmp still reads back correctly (post-PLIC traffic, unaffected)",
              dat_o, 64'h0000_0000_0012_3456);

        $display("");
        $display("wb_addr_decoder_plic_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb_addr_decoder_plic_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
