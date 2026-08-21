// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: dram_model
 *
 * Correctness (on `dut`, ACCESS_LATENCY_CYCLES=2, refresh disabled) mirrors
 * design/wb4_sram_tb.sv's own coverage: full-word round trip, byte-enable
 * write, a second-address round trip, and an out-of-range address asserting
 * err_o -- via `` `include "wb_driver.sv" ``'s wb_cycle() task, same idiom
 * every WB-slave testbench in this project already uses.
 *
 * Latency/refresh timing is proven via CYCLE-COUNT DELTAS against a shared
 * zero-latency/refresh-disabled baseline (dut_ref0), not a hardcoded
 * absolute cycle count -- hand-tracing taxi_axi_ram's exact registered
 * timing by inspection is error-prone (this exact derivation caught a real
 * off-by-one during planning: 4 cycles first, corrected to 3 on a closer
 * recheck), but the DELTA a knob induces is invariant to any error in that
 * base number. Three more `dram_model` instances (dut_ref0/dut_lat5/
 * dut_refresh) are driven by a local `timed_request` task using real `ref`
 * arguments -- viable here specifically because this file compiles
 * exclusively through Verilator (verification/taxi/run_taxi_tests.sh),
 * unlike every iverilog testbench in this project, which is stuck avoiding
 * `ref` args per testbench/wb_driver.sv's own documented Icarus limitation
 * ("sorry: Reference ports not supported yet.").
 *
 * dut_refresh's single request is issued immediately after its own reset
 * deasserts, landing deterministically at refresh_cnt==0 -- the very first
 * cycle of a refresh-busy window -- with no phase-alignment arithmetic
 * needed (0 is unambiguous).
 */
module dram_model_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    /* ----------------------------------------------------------------- *
     * Correctness suite -- `dut`.
     * ----------------------------------------------------------------- */
    logic [31:0] addr;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel;
    logic        we, cyc, stb, ack, err;

    dram_model #(.ACCESS_LATENCY_CYCLES(2), .REFRESH_BUSY_CYCLES(0)) dut (
        .clk(clk), .rst(rst),
        .addr_i(addr), .dat_i(dat_i), .dat_o(dat_o), .sel_i(sel),
        .ack_o(ack), .err_o(err), .cyc_i(cyc), .stb_i(stb), .we_i(we)
    );

    `include "wb_driver.sv"

    /* ----------------------------------------------------------------- *
     * Timing-reference instances -- dut_ref0 (baseline), dut_lat5 (latency
     * delta), dut_refresh (refresh-stall delta). Each needs its own
     * independent WB signal set, since wb_driver.sv's wb_cycle() can only
     * bind to one fixed name set per including module.
     * ----------------------------------------------------------------- */
    logic rst_ref0 = 1;
    logic [31:0] addr_ref0; logic [63:0] dat_i_ref0, dat_o_ref0; logic [7:0] sel_ref0;
    logic we_ref0, cyc_ref0, stb_ref0, ack_ref0, err_ref0;
    dram_model #(.ACCESS_LATENCY_CYCLES(0), .REFRESH_BUSY_CYCLES(0)) dut_ref0 (
        .clk(clk), .rst(rst_ref0),
        .addr_i(addr_ref0), .dat_i(dat_i_ref0), .dat_o(dat_o_ref0), .sel_i(sel_ref0),
        .ack_o(ack_ref0), .err_o(err_ref0), .cyc_i(cyc_ref0), .stb_i(stb_ref0), .we_i(we_ref0)
    );

    logic rst_lat5 = 1;
    logic [31:0] addr_lat5; logic [63:0] dat_i_lat5, dat_o_lat5; logic [7:0] sel_lat5;
    logic we_lat5, cyc_lat5, stb_lat5, ack_lat5, err_lat5;
    dram_model #(.ACCESS_LATENCY_CYCLES(5), .REFRESH_BUSY_CYCLES(0)) dut_lat5 (
        .clk(clk), .rst(rst_lat5),
        .addr_i(addr_lat5), .dat_i(dat_i_lat5), .dat_o(dat_o_lat5), .sel_i(sel_lat5),
        .ack_o(ack_lat5), .err_o(err_lat5), .cyc_i(cyc_lat5), .stb_i(stb_lat5), .we_i(we_lat5)
    );

    logic rst_refresh = 1;
    logic [31:0] addr_refresh; logic [63:0] dat_i_refresh, dat_o_refresh; logic [7:0] sel_refresh;
    logic we_refresh, cyc_refresh, stb_refresh, ack_refresh, err_refresh;
    dram_model #(.ACCESS_LATENCY_CYCLES(0), .REFRESH_INTERVAL_CYCLES(20), .REFRESH_BUSY_CYCLES(6)) dut_refresh (
        .clk(clk), .rst(rst_refresh),
        .addr_i(addr_refresh), .dat_i(dat_i_refresh), .dat_o(dat_o_refresh), .sel_i(sel_refresh),
        .ack_o(ack_refresh), .err_o(err_refresh), .cyc_i(cyc_refresh), .stb_i(stb_refresh), .we_i(we_refresh)
    );

    task automatic timed_request(
        ref logic rst_r,
        ref logic [31:0] addr_r,
        ref logic [63:0] dat_i_r,
        ref logic [7:0]  sel_r,
        ref logic we_r,
        ref logic cyc_r,
        ref logic stb_r,
        ref logic ack_r,
        ref logic err_r,
        output int cyc_count
    );
        rst_r = 1'b1;
        cyc_r = 1'b0; stb_r = 1'b0; we_r = 1'b0; addr_r = 32'h0; dat_i_r = 64'h0; sel_r = 8'hFF;
        @(posedge clk); #1;
        rst_r = 1'b0;

        // Issue immediately -- lands the first ST_IDLE sample at
        // refresh_cnt==0, the deterministic start of a busy window.
        @(negedge clk);
        addr_r = 32'h0; dat_i_r = 64'hA5A5_A5A5_A5A5_A5A5; sel_r = 8'hFF; we_r = 1'b1;
        cyc_r = 1'b1; stb_r = 1'b1;
        cyc_count = 0;
        @(posedge clk); #1;
        while (!ack_r && !err_r) begin
            cyc_count = cyc_count + 1;
            @(posedge clk); #1;
        end
        cyc_r = 1'b0; stb_r = 1'b0;
    endtask

    int cyc_count_ref0, cyc_count_lat5, cyc_count_refresh;
    int oor_cyc_count;

    initial begin
        cyc = 0; stb = 0; we = 0; addr = 0; dat_i = 0; sel = 8'hFF;
        @(posedge clk); #1;
        rst = 0;

        /* ---- (a) full-word round trip ---- */
        wb_cycle(32'h0, 64'hDEADBEEF_CAFEF00D, 8'hFF, 1'b1);
        wb_cycle(32'h0, 64'h0, 8'hFF, 1'b0);
        check("full-word round trip", dat_o, 64'hDEADBEEF_CAFEF00D);

        /* ---- (b) byte-enable write only touches enabled lanes ---- */
        wb_cycle(32'h0, 64'h0000_0000_0000_A5A5, 8'h03, 1'b1);
        wb_cycle(32'h0, 64'h0, 8'hFF, 1'b0);
        check("byte-enable write only touches enabled lanes", dat_o, 64'hDEADBEEF_CAFEA5A5);

        /* ---- (c) second-address round trip ---- */
        wb_cycle(32'h8, 64'h5A5A5A5A_5A5A5A5A, 8'hFF, 1'b1);
        wb_cycle(32'h8, 64'h0, 8'hFF, 1'b0);
        check("second-address round trip", dat_o, 64'h5A5A5A5A_5A5A5A5A);

        /* ---- (d) out-of-range address asserts err_o, bypassing the AXI
         * FSM (and therefore ACCESS_LATENCY_CYCLES(2)) entirely -- proven
         * below as a comparative check against cyc_count_ref0 (a real,
         * successful transaction's own cycle count on a ZERO-latency
         * instance), not a bare hardcoded number: the error path must
         * resolve in fewer cycles than even the fastest possible
         * successful transaction, since it never touches ST_WR_ADDR/
         * ST_WR_RESP/ST_LATENCY at all. ---- */
        @(negedge clk);
        addr = 32'h0001_0000; dat_i = 64'h0; sel = 8'hFF; we = 1'b0; cyc = 1; stb = 1;
        oor_cyc_count = 0;
        @(posedge clk); #1;
        while (!ack && !err) begin
            oor_cyc_count = oor_cyc_count + 1;
            @(posedge clk); #1;
        end
        check("out-of-range: err_o asserted", {63'b0, err}, 64'd1);
        check("out-of-range: ack_o stays low", {63'b0, ack}, 64'd0);
        cyc = 0; stb = 0;

        /* ---- latency/refresh deltas ---- */
        timed_request(rst_ref0, addr_ref0, dat_i_ref0, sel_ref0, we_ref0,
                       cyc_ref0, stb_ref0, ack_ref0, err_ref0, cyc_count_ref0);
        timed_request(rst_lat5, addr_lat5, dat_i_lat5, sel_lat5, we_lat5,
                       cyc_lat5, stb_lat5, ack_lat5, err_lat5, cyc_count_lat5);
        timed_request(rst_refresh, addr_refresh, dat_i_refresh, sel_refresh, we_refresh,
                       cyc_refresh, stb_refresh, ack_refresh, err_refresh, cyc_count_refresh);

        check("access latency delta == ACCESS_LATENCY_CYCLES (5)",
              64'(cyc_count_lat5 - cyc_count_ref0), 64'd5);
        check("refresh stall delta == REFRESH_BUSY_CYCLES (6)",
              64'(cyc_count_refresh - cyc_count_ref0), 64'd6);
        check("out-of-range resolves strictly faster than any successful transaction (bypasses the AXI FSM)",
              {63'b0, (oor_cyc_count < cyc_count_ref0)}, 64'd1);
        $display("INFO: baseline cyc_count_ref0 = %0d, out-of-range oor_cyc_count = %0d (bring-up reference only, not separately asserted)",
                 cyc_count_ref0, oor_cyc_count);

        $display("");
        $display("dram_model_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("dram_model_tb: FAILURES PRESENT");
        $finish;
    end
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
