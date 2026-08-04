// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_addr_decoder
 *
 * The decoder is tested in isolation -- no real wb4_sram/uart_tx
 * instances. Instead this testbench models two trivial fake slaves
 * directly (each a 1-wait-state ack with a fixed, distinct response
 * value), so a wrong routing/latching decision is unambiguous: RAM's
 * fake value is 0xAAAA..., UART's is 0xBBBB..., and nothing else could
 * produce either.
 */
module wb_addr_decoder_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    logic [31:0] ram_addr_o, uart_addr_o;
    logic [63:0] ram_dat_o, uart_dat_o;
    logic [7:0]  ram_sel_o, uart_sel_o;
    logic        ram_we_o, ram_cyc_o, ram_stb_o, uart_we_o, uart_cyc_o, uart_stb_o;
    logic [63:0] ram_dat_i, uart_dat_i;
    logic        ram_ack_i, ram_err_i, uart_ack_i, uart_err_i;

    wb_addr_decoder dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .ram_addr_o(ram_addr_o), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel_o), .ram_we_o(ram_we_o), .ram_cyc_o(ram_cyc_o),
        .ram_stb_o(ram_stb_o), .ram_ack_i(ram_ack_i), .ram_err_i(ram_err_i),
        .uart_addr_o(uart_addr_o), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel_o), .uart_we_o(uart_we_o), .uart_cyc_o(uart_cyc_o),
        .uart_stb_o(uart_stb_o), .uart_ack_i(uart_ack_i), .uart_err_i(uart_err_i)
    );

    // Fake RAM: 1-wait-state ack, fixed distinguishable response.
    always @(posedge clk) begin
        if (rst) begin
            ram_ack_i <= 0; ram_err_i <= 0; ram_dat_i <= 0;
        end else if (ram_cyc_o && ram_stb_o) begin
            ram_ack_i <= 1'b1; ram_dat_i <= 64'hAAAAAAAA_AAAAAAAA;
        end else begin
            ram_ack_i <= 1'b0;
        end
    end

    // Fake UART: same shape, different fixed response.
    always @(posedge clk) begin
        if (rst) begin
            uart_ack_i <= 0; uart_err_i <= 0; uart_dat_i <= 0;
        end else if (uart_cyc_o && uart_stb_o) begin
            uart_ack_i <= 1'b1; uart_dat_i <= 64'hBBBBBBBB_BBBBBBBB;
        end else begin
            uart_ack_i <= 1'b0;
        end
    end

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

    // Same #1-after-@(posedge clk) discipline established in
    // wb4_sram_tb.sv/uart_tx_tb.sv -- see those files for why.
    task automatic wb_cycle(logic [31:0] a);
        @(negedge clk);
        addr = a; dat_i = 0; sel = 8'hFF; we = 0; cyc = 1; stb = 1;
        @(posedge clk); #1;
        while (!ack) begin
            @(posedge clk); #1;
        end
        cyc = 0; stb = 0;
    endtask

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'hFF;
        @(posedge clk); #1;
        rst = 0;

        // RAM-range address: only ram_cyc_o should assert.
        @(negedge clk);
        addr = 32'h0000_0100; cyc = 1; stb = 1;
        #1;
        check("RAM address: ram_cyc_o asserted", {63'b0, ram_cyc_o}, 64'd1);
        check("RAM address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // UART-range address: only uart_cyc_o should assert.
        @(negedge clk);
        addr = 32'h0000_8000; cyc = 1; stb = 1;
        #1;
        check("UART address: uart_cyc_o asserted", {63'b0, uart_cyc_o}, 64'd1);
        check("UART address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // Full round trip, RAM then UART back-to-back -- exercises
        // sel_uart_q actually updating between two different-slave
        // transactions, not just holding whatever it started as.
        wb_cycle(32'h0000_0200);
        check("response routed from RAM", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        wb_cycle(32'h0000_8008);
        check("response routed from UART (latch updated, not stuck on RAM)", dat_o, 64'hBBBBBBBB_BBBBBBBB);

        wb_cycle(32'h0000_0300);
        check("response routed back to RAM (latch updates both directions)", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        $display("");
        $display("wb_addr_decoder_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb_addr_decoder_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
