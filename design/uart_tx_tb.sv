// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: uart_tx
 *
 * Drives the Wishbone port directly. Console output ("Hi" appearing
 * literally in the run's stdout) is a visual sanity check, not what's
 * asserted on -- the checked behavior is tx_history[]/tx_history_count,
 * which is exactly what that capture mechanism exists for.
 */
module uart_tx_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        ack, err, cyc, stb, we;

    uart_tx dut (
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

        // Write "Hi" -- prints live to console.
        wb_cycle(32'h8000, 64'h48, 8'h01, 1'b1); // 'H'
        wb_cycle(32'h8000, 64'h69, 8'h01, 1'b1); // 'i'
        check("two characters captured", {55'b0, dut.tx_history_count}, 64'd2);
        check("history[0] == 'H'", {56'b0, dut.tx_history[0]}, 64'h48);
        check("history[1] == 'i'", {56'b0, dut.tx_history[1]}, 64'h69);

        // Write with byte-enable OFF (sel[0]=0) -- must not capture.
        wb_cycle(32'h8000, 64'hFF, 8'h00, 1'b1);
        check("write without sel[0] is ignored", {55'b0, dut.tx_history_count}, 64'd2);

        // TX_STATUS always reads ready.
        wb_cycle(32'h8008, 64'h0, 8'h00, 1'b0);
        check("TX_STATUS reads ready (1)", dat_o, 64'h1);

        // TX_DATA reads back 0.
        wb_cycle(32'h8000, 64'h0, 8'h00, 1'b0);
        check("TX_DATA reads 0", dat_o, 64'h0);

        $display("");
        $display("uart_tx_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("uart_tx_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
