// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_addr_decoder
 *
 * The decoder is tested in isolation -- no real wb4_sram/uart_tx/clint
 * instances. Instead this testbench models three trivial fake slaves
 * directly (each a 1-wait-state ack with a fixed, distinct response
 * value), so a wrong routing/latching decision is unambiguous: RAM's
 * fake value is 0xAAAA..., UART's is 0xBBBB..., CLINT's is 0xCCCC...,
 * and nothing else could produce any of the three.
 */
module wb_addr_decoder_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    logic [31:0] ram_addr_o, uart_addr_o, clint_addr_o, dram_addr_o;
    logic [63:0] ram_dat_o, uart_dat_o, clint_dat_o, dram_dat_o;
    logic [7:0]  ram_sel_o, uart_sel_o, clint_sel_o, dram_sel_o;
    logic        ram_we_o, ram_cyc_o, ram_stb_o, uart_we_o, uart_cyc_o, uart_stb_o;
    logic        clint_we_o, clint_cyc_o, clint_stb_o;
    logic        dram_we_o, dram_cyc_o, dram_stb_o;
    logic [63:0] ram_dat_i, uart_dat_i, clint_dat_i, dram_dat_i;
    logic        ram_ack_i, ram_err_i, uart_ack_i, uart_err_i, clint_ack_i, clint_err_i;
    logic        dram_ack_i, dram_err_i;

    wb_addr_decoder dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .ram_addr_o(ram_addr_o), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel_o), .ram_we_o(ram_we_o), .ram_cyc_o(ram_cyc_o),
        .ram_stb_o(ram_stb_o), .ram_ack_i(ram_ack_i), .ram_err_i(ram_err_i),
        .uart_addr_o(uart_addr_o), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel_o), .uart_we_o(uart_we_o), .uart_cyc_o(uart_cyc_o),
        .uart_stb_o(uart_stb_o), .uart_ack_i(uart_ack_i), .uart_err_i(uart_err_i),
        .clint_addr_o(clint_addr_o), .clint_dat_o(clint_dat_o), .clint_dat_i(clint_dat_i),
        .clint_sel_o(clint_sel_o), .clint_we_o(clint_we_o), .clint_cyc_o(clint_cyc_o),
        .clint_stb_o(clint_stb_o), .clint_ack_i(clint_ack_i), .clint_err_i(clint_err_i),
        .dram_addr_o(dram_addr_o), .dram_dat_o(dram_dat_o), .dram_dat_i(dram_dat_i),
        .dram_sel_o(dram_sel_o), .dram_we_o(dram_we_o), .dram_cyc_o(dram_cyc_o),
        .dram_stb_o(dram_stb_o), .dram_ack_i(dram_ack_i), .dram_err_i(dram_err_i)
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

    // Fake CLINT: same shape, third distinguishable response.
    always @(posedge clk) begin
        if (rst) begin
            clint_ack_i <= 0; clint_err_i <= 0; clint_dat_i <= 0;
        end else if (clint_cyc_o && clint_stb_o) begin
            clint_ack_i <= 1'b1; clint_dat_i <= 64'hCCCCCCCC_CCCCCCCC;
        end else begin
            clint_ack_i <= 1'b0;
        end
    end

    // Fake DRAM: same shape, fourth distinguishable response.
    always @(posedge clk) begin
        if (rst) begin
            dram_ack_i <= 0; dram_err_i <= 0; dram_dat_i <= 0;
        end else if (dram_cyc_o && dram_stb_o) begin
            dram_ack_i <= 1'b1; dram_dat_i <= 64'hDDDDDDDD_DDDDDDDD;
        end else begin
            dram_ack_i <= 1'b0;
        end
    end

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

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
        check("RAM address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        check("RAM address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // UART-range address: only uart_cyc_o should assert.
        @(negedge clk);
        addr = 32'h0000_8000; cyc = 1; stb = 1;
        #1;
        check("UART address: uart_cyc_o asserted", {63'b0, uart_cyc_o}, 64'd1);
        check("UART address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("UART address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        check("UART address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // CLINT-range address: only clint_cyc_o should assert.
        @(negedge clk);
        addr = 32'h0001_0000; cyc = 1; stb = 1;
        #1;
        check("CLINT address: clint_cyc_o asserted", {63'b0, clint_cyc_o}, 64'd1);
        check("CLINT address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("CLINT address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        check("CLINT address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // DRAM-range address: only dram_cyc_o should assert. This address
        // (addr_i[16]==1, addr_i[15]==1) used to alias into CLINT's old
        // 64KB window (bit 16 alone decided CLINT, regardless of bit 15);
        // under the current 4-way map, bit 15 is a real, tested select
        // bit, and 0x1_8000 is DRAM's own base.
        @(negedge clk);
        addr = 32'h0001_8000; cyc = 1; stb = 1;
        #1;
        check("DRAM address (formerly CLINT's over-wide window): dram_cyc_o asserted", {63'b0, dram_cyc_o}, 64'd1);
        check("DRAM address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        check("DRAM address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("DRAM address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // Boundary edge cases: the top address of each window. The decode
        // is a raw bit test, not a magnitude comparator, so these can't
        // actually catch an off-by-one the way they would against a real
        // range compare -- but they're cheap, and a future rewrite to a
        // comparator-based decode would be exactly the kind of change
        // these should catch a regression in.
        @(negedge clk);
        addr = 32'h0000_7FFF; cyc = 1; stb = 1;  // top of RAM's window
        #1;
        check("RAM top-of-window address: ram_cyc_o asserted", {63'b0, ram_cyc_o}, 64'd1);
        check("RAM top-of-window address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        check("RAM top-of-window address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        check("RAM top-of-window address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        @(negedge clk);
        addr = 32'h0000_FFFF; cyc = 1; stb = 1;  // top of UART's window
        #1;
        check("UART top-of-window address: uart_cyc_o asserted", {63'b0, uart_cyc_o}, 64'd1);
        check("UART top-of-window address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("UART top-of-window address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        check("UART top-of-window address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        @(negedge clk);
        addr = 32'h0001_7FFF; cyc = 1; stb = 1;  // top of CLINT's narrowed window
        #1;
        check("CLINT top-of-window address: clint_cyc_o asserted", {63'b0, clint_cyc_o}, 64'd1);
        check("CLINT top-of-window address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("CLINT top-of-window address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        check("CLINT top-of-window address: dram_cyc_o stays low", {63'b0, dram_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        @(negedge clk);
        addr = 32'h0001_FFFF; cyc = 1; stb = 1;  // top of DRAM's window
        #1;
        check("DRAM top-of-window address: dram_cyc_o asserted", {63'b0, dram_cyc_o}, 64'd1);
        check("DRAM top-of-window address: ram_cyc_o stays low", {63'b0, ram_cyc_o}, 64'd0);
        check("DRAM top-of-window address: uart_cyc_o stays low", {63'b0, uart_cyc_o}, 64'd0);
        check("DRAM top-of-window address: clint_cyc_o stays low", {63'b0, clint_cyc_o}, 64'd0);
        cyc = 0; stb = 0;
        @(negedge clk);

        // Full round trip, RAM then UART back-to-back -- exercises
        // sel_uart_q actually updating between two different-slave
        // transactions, not just holding whatever it started as.
        wb_cycle(32'h0000_0200, 64'h0, 8'hFF, 1'b0);
        check("response routed from RAM", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        wb_cycle(32'h0000_8008, 64'h0, 8'hFF, 1'b0);
        check("response routed from UART (latch updated, not stuck on RAM)", dat_o, 64'hBBBBBBBB_BBBBBBBB);

        wb_cycle(32'h0000_0300, 64'h0, 8'hFF, 1'b0);
        check("response routed back to RAM (latch updates both directions)", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        // 3-way round trip: RAM -> UART -> CLINT -> RAM, proving the
        // now-2-bit target_q latch correctly updates across all three
        // targets in sequence, not just the original 2.
        wb_cycle(32'h0000_0400, 64'h0, 8'hFF, 1'b0);
        check("3-way: response routed from RAM", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        wb_cycle(32'h0000_8010, 64'h0, 8'hFF, 1'b0);
        check("3-way: response routed from UART", dat_o, 64'hBBBBBBBB_BBBBBBBB);

        wb_cycle(32'h0001_0008, 64'h0, 8'hFF, 1'b0);
        check("3-way: response routed from CLINT", dat_o, 64'hCCCCCCCC_CCCCCCCC);

        wb_cycle(32'h0000_0500, 64'h0, 8'hFF, 1'b0);
        check("3-way: response routed back to RAM", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        // Close the loop: the sequence above never exercises RAM -> CLINT
        // or CLINT -> UART directly (only CLINT -> RAM and UART -> CLINT
        // were hit). All 6 ordered target-pair transitions are now covered.
        wb_cycle(32'h0001_0010, 64'h0, 8'hFF, 1'b0);
        check("closing the loop: response routed RAM -> CLINT", dat_o, 64'hCCCCCCCC_CCCCCCCC);

        wb_cycle(32'h0000_8018, 64'h0, 8'hFF, 1'b0);
        check("closing the loop: response routed CLINT -> UART", dat_o, 64'hBBBBBBBB_BBBBBBBB);

        // DRAM is the 4th target -- extend "closing the loop" to cover
        // every pair involving it. target_q's own update (line ~161:
        // `else if (cyc_i && stb_i) target_q <= target;`) is a flat,
        // unconditional overwrite with no branch on the prior value, so
        // there's no code path that could behave differently for one
        // ordered pair versus another sharing the same destination --
        // only "does this destination get correctly latched" matters, a
        // property of the destination alone. The 6 pairs above (among
        // RAM/UART/CLINT) already fully prove the latch mechanism for
        // those three; DRAM needs exactly 6 new pairs (3 partners x 2
        // directions each), continuing as a single walk from the
        // previous section's end state (UART) so every DRAM-involving
        // pair is hit exactly once, giving full 12/12 ordered-pair
        // coverage across the file.
        wb_cycle(32'h0001_8010, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed UART -> DRAM", dat_o, 64'hDDDDDDDD_DDDDDDDD);

        wb_cycle(32'h0000_0600, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed DRAM -> RAM", dat_o, 64'hAAAAAAAA_AAAAAAAA);

        wb_cycle(32'h0001_8018, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed RAM -> DRAM", dat_o, 64'hDDDDDDDD_DDDDDDDD);

        wb_cycle(32'h0001_0018, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed DRAM -> CLINT", dat_o, 64'hCCCCCCCC_CCCCCCCC);

        wb_cycle(32'h0001_8020, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed CLINT -> DRAM", dat_o, 64'hDDDDDDDD_DDDDDDDD);

        wb_cycle(32'h0000_8020, 64'h0, 8'hFF, 1'b0);
        check("DRAM pairs: response routed DRAM -> UART", dat_o, 64'hBBBBBBBB_BBBBBBBB);

        $display("");
        $display("wb_addr_decoder_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb_addr_decoder_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
