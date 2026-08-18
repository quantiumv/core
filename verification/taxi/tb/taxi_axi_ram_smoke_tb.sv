// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: taxi_axi_ram_smoke_tb -- confirms this project's Verilator-based
 * toolchain fork (see verification/taxi/README.md) actually simulates real
 * taxi functional IP correctly, not just elaborates it.
 *
 * taxi's whole AXI4/AXI4-Lite product line is built on SystemVerilog
 * `interface`+`modport` ports (`taxi_axi_if.wr_slv`, etc.) -- confirmed
 * unparseable by this project's Icarus build, isolated down to a
 * taxi-independent 15-line repro. Verilator handles it natively, so any
 * taxi-touching testbench (this one included) MUST be built via
 * run_taxi_tests.sh (verilator --binary --timing), never added to the
 * iverilog-based design/testbench regression file lists -- it will not
 * compile there.
 *
 * A single AXI4 write beat (address 0x10, data 0xDEADBEEF) followed by a
 * single read beat from the same address, driving taxi_axi_if's signals
 * directly rather than through a *_mst modport view (simplest thing that
 * proves the write/read path genuinely round-trips through real handshake
 * logic, not just elaborates).
 */
module taxi_axi_ram_smoke_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    localparam DATA_W = 32;
    localparam ADDR_W = 16;
    localparam STRB_W = DATA_W / 8;
    localparam ID_W = 8;

    taxi_axi_if #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .STRB_W(STRB_W), .ID_W(ID_W)) axi_if();

    /* DATA_W is deliberately NOT passed here -- taxi_axi_ram derives it as a
     * localparam from whichever taxi_axi_if instance is connected
     * (`localparam DATA_W = s_axi_wr.DATA_W;` internally). Passing .DATA_W
     * explicitly is a hard elaboration error ("attempts to override... but
     * it is a local parameter"), not a harmless no-op. */
    taxi_axi_ram #(.ADDR_W(ADDR_W)) dut (
        .clk(clk),
        .rst(rst),
        .s_axi_wr(axi_if.wr_slv),
        .s_axi_rd(axi_if.rd_slv)
    );

    initial begin
        axi_if.awid = '0; axi_if.awaddr = '0; axi_if.awlen = '0; axi_if.awsize = 3'd2;
        axi_if.awburst = 2'b01; axi_if.awlock = 0; axi_if.awcache = '0; axi_if.awprot = '0;
        axi_if.awqos = '0; axi_if.awregion = '0; axi_if.awuser = '0; axi_if.awvalid = 0;
        axi_if.wdata = '0; axi_if.wstrb = '0; axi_if.wlast = 0; axi_if.wuser = '0; axi_if.wvalid = 0;
        axi_if.bready = 1;
        axi_if.arid = '0; axi_if.araddr = '0; axi_if.arlen = '0; axi_if.arsize = 3'd2;
        axi_if.arburst = 2'b01; axi_if.arlock = 0; axi_if.arcache = '0; axi_if.arprot = '0;
        axi_if.arqos = '0; axi_if.arregion = '0; axi_if.aruser = '0; axi_if.arvalid = 0;
        axi_if.rready = 1;

        @(posedge clk); #1; rst = 0;
        @(posedge clk); #1;

        // Single AXI4 write beat.
        axi_if.awaddr = 16'h0010; axi_if.awvalid = 1;
        axi_if.wdata = 32'hDEADBEEF; axi_if.wstrb = 4'hF; axi_if.wlast = 1; axi_if.wvalid = 1;
        do @(posedge clk); while (!(axi_if.awready && axi_if.awvalid));
        #1; axi_if.awvalid = 0;
        do @(posedge clk); while (!(axi_if.wready && axi_if.wvalid));
        #1; axi_if.wvalid = 0;
        do @(posedge clk); while (!axi_if.bvalid);
        #1;
        check("write response bresp == OKAY", {62'b0, axi_if.bresp}, 64'd0);

        // Single AXI4 read beat from the same address.
        @(posedge clk);
        axi_if.araddr = 16'h0010; axi_if.arvalid = 1;
        do @(posedge clk); while (!(axi_if.arready && axi_if.arvalid));
        #1; axi_if.arvalid = 0;
        do @(posedge clk); while (!axi_if.rvalid);
        #1;
        check("taxi_axi_ram write/read round trip", {32'b0, axi_if.rdata}, 64'hDEADBEEF);

        #20;
        $display("");
        $display("taxi_axi_ram_smoke_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("taxi_axi_ram_smoke_tb: FAILURES PRESENT");
        $finish;
    end
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
