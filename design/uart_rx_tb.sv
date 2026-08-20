// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: uart_rx
 *
 * Drives the Wishbone port directly, using push_byte (the backdoor
 * hierarchical task uart_rx.sv exposes) to inject bytes as if they had
 * arrived over the wire, then checking the real bus-facing read path
 * (RX_DATA/RX_STATUS) pops them back out in order -- the mirror image
 * of uart_tx_tb.sv's own write-then-check-tx_history shape, just with
 * the injection and observation points swapped (backdoor writes here,
 * bus reads there; bus writes there, backdoor reads here).
 */
module uart_rx_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    uart_rx dut (
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

        // RX_STATUS reads not-ready before anything has been pushed.
        wb_cycle(32'h8018, 64'h0, 8'h00, 1'b0);
        check("RX_STATUS reads not-ready (0) when empty", dat_o, 64'h0);

        // RX_DATA reads 0 (not stale, not X) when empty.
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("RX_DATA reads 0 when empty", dat_o, 64'h0);

        // Push "ABC" via the backdoor -- the mirror image of uart_tx_tb.sv's
        // wb_cycle writes, just injected directly rather than over the bus.
        dut.push_byte(8'h41); // 'A'
        dut.push_byte(8'h42); // 'B'
        dut.push_byte(8'h43); // 'C'

        wb_cycle(32'h8018, 64'h0, 8'h00, 1'b0);
        check("RX_STATUS reads ready (1) after push", dat_o, 64'h1);

        // Pop all three back out over the real bus, in order (FIFO).
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("RX_DATA pop 1 == 'A'", dat_o, 64'h41);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("RX_DATA pop 2 == 'B'", dat_o, 64'h42);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("RX_DATA pop 3 == 'C'", dat_o, 64'h43);

        // Drained -- back to not-ready, and a further read returns 0
        // without underflowing.
        wb_cycle(32'h8018, 64'h0, 8'h00, 1'b0);
        check("RX_STATUS reads not-ready (0) after drain", dat_o, 64'h0);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("RX_DATA reads 0 after drain (no underflow)", dat_o, 64'h0);

        // A bus WRITE to RX_DATA must be a pure no-op -- doesn't pop, doesn't
        // corrupt the queue for the next real read.
        dut.push_byte(8'h99);
        wb_cycle(32'h8010, 64'hFF, 8'h01, 1'b1); // write attempt, should be ignored
        check("write to RX_DATA doesn't pop the queue", {55'b0, dut.rx_count}, 64'd1);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("queue survives the write attempt intact", dat_o, 64'h99);

        // A bus WRITE to RX_STATUS must likewise be a pure no-op --
        // mirrors the RX_DATA write-no-op case above (RX_STATUS is
        // read-only too).
        dut.push_byte(8'h77);
        wb_cycle(32'h8018, 64'hFF, 8'h01, 1'b1); // write attempt, should be ignored
        check("write to RX_STATUS doesn't corrupt the queue", {55'b0, dut.rx_count}, 64'd1);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
        check("queue survives the RX_STATUS write attempt intact", dat_o, 64'h77);

        // A read whose sel_i doesn't include byte lane 0 must not pop --
        // this is the sel_i[0] gate design/uart_rx.sv's own header
        // documents: an ungated pop here would silently discard a real
        // received byte on e.g. a sub-word load at a nonzero offset
        // within this register's own bus window.
        dut.push_byte(8'hAA);
        wb_cycle(32'h8010, 64'h0, 8'h02, 1'b0); // read, but sel[0]=0 (lane 1 only)
        check("read without sel[0] doesn't pop the queue", {55'b0, dut.rx_count}, 64'd1);
        wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0); // real read, sel[0]=1
        check("byte survives the lane-mismatched probe intact", dat_o, 64'hAA);

        /*
         * FIFO overflow: push RX_QUEUE_DEPTH+1 (257) bytes via the
         * backdoor. This also exercises the rx_head/rx_tail wraparound
         * at the 256-entry boundary as a side effect of legitimately
         * filling the queue -- byte value i's low 8 bits double as its
         * own expected FIFO-order payload, so the drain loop below can
         * check every single entry without a separate expected-value
         * table.
         */
        for (int i = 0; i < 257; i++) begin
            dut.push_byte(i[7:0]);
        end
        check("queue caps at 256 entries, 257th byte silently dropped",
            {55'b0, dut.rx_count}, 64'd256);

        // Drain all 256 back out over the real bus and confirm FIFO
        // order. quiet_on_pass suppresses per-byte PASS spam; any real
        // mismatch still prints (check_lib.sv always displays on FAIL
        // regardless of quiet_on_pass).
        quiet_on_pass = 1'b1;
        for (int i = 0; i < 256; i++) begin
            wb_cycle(32'h8010, 64'h0, 8'h01, 1'b0);
            check($sformatf("overflow drain byte %0d in FIFO order", i), dat_o, {56'b0, i[7:0]});
        end
        quiet_on_pass = 1'b0;
        check("queue fully drained after overflow test", {55'b0, dut.rx_count}, 64'd0);

        $display("");
        $display("uart_rx_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("uart_rx_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
