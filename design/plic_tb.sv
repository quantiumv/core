// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: plic
 *
 * Drives the Wishbone port directly -- no core.sv involved, same idiom
 * as design/clint_tb.sv (this file's own direct template). i_uart_rx_irq
 * is driven directly by this testbench too, standing in for a real
 * uart_rx.sv instance (not wired up until Milestone 6).
 */
module plic_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;
    logic        uart_rx_irq;
    logic        meip, seip;

    plic dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .we_i(we), .cyc_i(cyc), .stb_i(stb), .ack_o(ack), .err_o(err),
        .i_uart_rx_irq(uart_rx_irq), .o_meip(meip), .o_seip(seip)
    );

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    `include "wb_driver.sv"

    localparam PRIORITY_ADDR  = 32'h000000;  // source1's own field lives in the HIGH 32 bits
    localparam PENDING_ADDR   = 32'h001000;  // source1's own bit lives in the LOW 32 bits
    localparam ENABLE0_ADDR   = 32'h002000;
    localparam ENABLE1_ADDR   = 32'h002080;
    localparam THRESH0_ADDR   = 32'h200000;  // threshold=LOW 32 bits, claim/complete=HIGH 32 bits
    localparam THRESH1_ADDR   = 32'h201000;

    task automatic set_priority1(input [2:0] p);
        wb_cycle(PRIORITY_ADDR, {29'b0, p, 32'b0}, 8'hF0, 1'b1);
    endtask
    task automatic set_enable0(input v);
        wb_cycle(ENABLE0_ADDR, {62'b0, v, 1'b0}, 8'h0F, 1'b1);
    endtask
    task automatic set_enable1(input v);
        wb_cycle(ENABLE1_ADDR, {62'b0, v, 1'b0}, 8'h0F, 1'b1);
    endtask
    task automatic set_threshold0(input [2:0] t);
        wb_cycle(THRESH0_ADDR, {32'b0, 29'b0, t}, 8'h0F, 1'b1);
    endtask
    task automatic set_threshold1(input [2:0] t);
        wb_cycle(THRESH1_ADDR, {32'b0, 29'b0, t}, 8'h0F, 1'b1);
    endtask
    task automatic claim0(output [31:0] id);
        wb_cycle(THRESH0_ADDR, 64'b0, 8'hF0, 1'b0);
        id = dat_o[63:32];
    endtask
    task automatic claim1(output [31:0] id);
        wb_cycle(THRESH1_ADDR, 64'b0, 8'hF0, 1'b0);
        id = dat_o[63:32];
    endtask
    task automatic complete0(input [31:0] id);
        wb_cycle(THRESH0_ADDR, {id, 32'b0}, 8'hF0, 1'b1);
    endtask
    task automatic complete1(input [31:0] id);
        wb_cycle(THRESH1_ADDR, {id, 32'b0}, 8'hF0, 1'b1);
    endtask

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'h00; uart_rx_irq = 0;
        @(posedge clk); #1;
        rst = 0;

        // -- 1. priority WARL round-trip --
        set_priority1(3'd5);
        wb_cycle(PRIORITY_ADDR, 64'b0, 8'hF0, 1'b0);
        check("priority1 round-trips (3 bits)", dat_o[34:32], 64'(3'd5));
        set_priority1(3'd0);

        // -- 2. EIP stays 0 until both enable AND priority>threshold hold --
        set_enable0(1'b0);
        set_threshold0(3'd0);
        set_priority1(3'd0);
        uart_rx_irq = 1'b1;
        @(posedge clk); #1;
        check("EIP stays 0: disabled, priority=0, level asserted", {63'b0, meip}, 64'd0);

        set_enable0(1'b1);
        @(posedge clk); #1;
        check("EIP stays 0: enabled but priority(0) not > threshold(0)", {63'b0, meip}, 64'd0);

        set_priority1(3'd1);
        @(posedge clk); #1;
        check("EIP asserts once enabled AND priority(1) > threshold(0)", {63'b0, meip}, 64'd1);

        // -- 3. pending persists even if the level drops before service --
        uart_rx_irq = 1'b0;
        @(posedge clk); #1;
        check("EIP stays asserted after the level drops (pending already latched)", {63'b0, meip}, 64'd1);

        // -- 4. claim returns the real ID when eligible, atomically clears
        //    pending (EIP drops immediately) --
        begin
            logic [31:0] claimed_id;
            claim0(claimed_id);
            check("claim0 returns source 1's real ID", claimed_id, 32'd1);
            @(posedge clk); #1;
            check("EIP drops immediately after claim (pending cleared)", {63'b0, meip}, 64'd0);
        end

        // -- 5. a still-asserted level does NOT create a new pending while
        //    served (level was already dropped above, but reassert it now
        //    to prove the gateway stays quiet despite a fresh rising edge
        //    right after claim, until completion) --
        uart_rx_irq = 1'b1;
        @(posedge clk); #1;
        check("EIP stays 0 while served, even with the level freshly reasserted", {63'b0, meip}, 64'd0);

        // -- 6. a claim while NOT eligible returns ID 0, consumes nothing --
        begin
            logic [31:0] claimed_id;
            claim0(claimed_id);
            check("a claim while already served (not eligible) returns ID 0", claimed_id, 32'd0);
        end

        // -- 7. completion with the WRONG id is silently ignored (served
        //    stays set, so a real completion afterward still works) --
        complete0(32'd2);
        begin
            logic [31:0] claimed_id;
            claim0(claimed_id);
            check("a claim right after a wrong-ID completion still returns 0 (served untouched)",
                claimed_id, 32'd0);
        end

        // -- 8. real completion clears served; since the level is still
        //    asserted, the very next cycle re-latches pending and
        //    re-asserts EIP -- a real, one-cycle-later re-arm. --
        complete0(32'd1);
        check("EIP still 0 the same edge completion lands (re-arm is NOT same-cycle)",
            {63'b0, meip}, 64'd0);
        @(posedge clk); #1;
        check("EIP re-asserts one cycle after completion, level still high", {63'b0, meip}, 64'd1);

        // Clean up: claim + complete once more, drop the level, confirm quiescent.
        begin
            logic [31:0] claimed_id;
            claim0(claimed_id);
            complete0(claimed_id);
        end
        uart_rx_irq = 1'b0;
        @(posedge clk); #1;
        check("quiescent after final claim+complete+level-drop", {63'b0, meip}, 64'd0);

        // -- 9. dual-context multicast: both contexts enabled+above-
        //    threshold assert together off the SAME shared pending latch;
        //    whichever claims first clears pending for both. --
        set_enable1(1'b1);
        set_threshold1(3'd0);
        uart_rx_irq = 1'b1;
        @(posedge clk); #1;
        check("dual-context: o_meip asserts", {63'b0, meip}, 64'd1);
        check("dual-context: o_seip asserts (same shared pending latch)", {63'b0, seip}, 64'd1);
        begin
            logic [31:0] claimed_id;
            claim1(claimed_id);  // context 1 claims first
            check("dual-context: ctx1's own claim returns the real ID", claimed_id, 32'd1);
            @(posedge clk); #1;
            check("dual-context: o_meip also drops (shared pending, not per-context)", {63'b0, meip}, 64'd0);
            check("dual-context: o_seip drops too", {63'b0, seip}, 64'd0);
            complete1(claimed_id);
        end
        uart_rx_irq = 1'b0;

        // -- 10. err_o never asserts, for any address/access pattern tried
        //    above (already implicit in wb_cycle()'s own !ack&&!err wait
        //    loop never hanging) -- one explicit spot-check per register. --
        wb_cycle(PRIORITY_ADDR, 64'b0, 8'hF0, 1'b0);
        check("err_o never asserts (priority read)", {63'b0, err}, 64'd0);
        wb_cycle(PENDING_ADDR, 64'b0, 8'h0F, 1'b0);
        check("err_o never asserts (pending read)", {63'b0, err}, 64'd0);
        wb_cycle(32'h003000, 64'b0, 8'hFF, 1'b0);  // an address matching no real register
        check("err_o never asserts (unmapped address in-window aliases, doesn't fault)", {63'b0, err}, 64'd0);

        $display("");
        $display("plic_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("plic_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
