// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: dram_model
 *
 * A Wishbone-slave-shaped peripheral (same port contract as design/wb4_sram.sv
 * -- clk/rst, addr_i[31:0]/dat_i[63:0]/dat_o[63:0]/sel_i[7:0], ack_o/err_o,
 * cyc_i/stb_i/we_i) that bridges each WB request to a real, single-beat
 * AXI4 transaction against a genuinely vendored taxi_axi_ram instance, then
 * layers hand-written DRAM-realism timing on top of that otherwise-fixed-
 * latency RAM: a configurable extra ACCESS_LATENCY_CYCLES wait after the AXI
 * response, and a configurable REFRESH_INTERVAL_CYCLES/REFRESH_BUSY_CYCLES
 * pair that periodically blocks STARTING a new transaction (matching real
 * DRAM's periodic refresh unavailability) without ever interrupting one
 * already in flight.
 *
 * This exercises real taxi functional IP as the actual backing store, not a
 * reimplementation of memory-array logic -- taxi_axi_ram.sv (CERN-OHL-S-2.0,
 * see verification/taxi/README.md's License section for the reciprocal
 * implication already accepted for this project) is instantiated directly
 * below and does the real storage/AXI-compliance work; this file's own
 * job is purely the WB<->AXI4 protocol bridge and the timing model on top.
 *
 * Verilator-only, by the same hard constraint as everything else under
 * verification/taxi/: this file instantiates a SystemVerilog `interface`
 * (taxi_axi_if), which this project's Icarus Verilog build cannot parse at
 * all (confirmed via an isolated, taxi-independent repro -- see this
 * directory's own README.md). Deliberately NOT placed under design/, to
 * avoid a future contributor sweeping it into the iverilog regression file
 * lists and breaking the whole build -- build/run it only via
 * verification/taxi/run_taxi_tests.sh.
 *
 * ACCESS_LATENCY_CYCLES/REFRESH_INTERVAL_CYCLES/REFRESH_BUSY_CYCLES defaults
 * are explicitly toy-scale, sim-speed/observability numbers, not literal DDR
 * datasheet timings -- nothing here models per-row/bank state, so a longer,
 * more "realistic" interval would only add idle simulation cycles without
 * exercising more logic. 16/256 is a ~6.25% refresh duty cycle, in the right
 * ballpark of real DRAM refresh overhead without being derived from any
 * specific part's timing table.
 */
module dram_model #(
    parameter ADDR_W                  = 16,   // -> 2**ADDR_W byte address space
    parameter ACCESS_LATENCY_CYCLES   = 4,    // extra cycles after the AXI response, before ack_o
    parameter REFRESH_INTERVAL_CYCLES = 256,  // free-running refresh period
    parameter REFRESH_BUSY_CYCLES     = 16    // cycles per period that block starting a NEW transaction
) (
    input logic clk,
    input logic rst,

    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,

    output logic ack_o,
    output logic err_o,
    input  logic cyc_i,
    input  logic stb_i,
    input  logic we_i
);

    if (REFRESH_BUSY_CYCLES >= REFRESH_INTERVAL_CYCLES)
        $fatal(0, "Error: REFRESH_BUSY_CYCLES must be < REFRESH_INTERVAL_CYCLES (instance %m)");

    /*
     * Refresh timer -- free-running, independent of FSM state. Real DRAM
     * refresh runs on its own physical clock, not gated by controller
     * activity; only ST_IDLE's own next-state logic below ever consults
     * refresh_busy, holding a NEW request off (not advancing) while a
     * refresh window is active. A transaction already past ST_IDLE is never
     * itself interrupted by a refresh window starting mid-flight.
     */
    localparam REFRESH_CNT_W = $clog2(REFRESH_INTERVAL_CYCLES);
    logic [REFRESH_CNT_W-1:0] refresh_cnt;
    always_ff @(posedge clk) begin
        if (rst) refresh_cnt <= '0;
        else if (refresh_cnt == REFRESH_CNT_W'(REFRESH_INTERVAL_CYCLES - 1)) refresh_cnt <= '0;
        else refresh_cnt <= refresh_cnt + 1'b1;
    end
    /* REFRESH_BUSY_CYCLES(0) is a legitimate "disable refresh" configuration
     * (used by the timing-reference test instances that isolate the
     * ACCESS_LATENCY_CYCLES effect alone) -- for that specific
     * parameterization this comparison is constant-false by construction,
     * not a mistake. */
    /* verilator lint_off UNSIGNED */
    wire refresh_busy = (refresh_cnt < REFRESH_CNT_W'(REFRESH_BUSY_CYCLES));
    /* verilator lint_on UNSIGNED */

    // AXI4 interface to the real, vendored taxi_axi_ram backing store.
    taxi_axi_if #(.DATA_W(64), .ADDR_W(ADDR_W)) axi_if ();

    /* DATA_W is deliberately NOT passed to taxi_axi_ram -- it derives that
     * as a localparam from the connected taxi_axi_if instance; passing it
     * explicitly is a hard elaboration error, not a no-op (see this
     * directory's README.md Gotcha section). PIPELINE_OUTPUT(1'b0)
     * explicitly, not just relying on its own default: keeps read and
     * write completion paths the same depth, so this module's own added
     * latency stays symmetric between the two directions. */
    taxi_axi_ram #(.ADDR_W(ADDR_W), .PIPELINE_OUTPUT(1'b0)) ram0 (
        .clk(clk),
        .rst(rst),
        .s_axi_wr(axi_if.wr_slv),
        .s_axi_rd(axi_if.rd_slv)
    );

    // Fields this bridge never varies -- single-outstanding, single-beat,
    // no ID tracking needed (WB itself has no ID/burst concept to translate
    // from).
    assign axi_if.awid     = '0;
    assign axi_if.awlen    = '0;
    assign axi_if.awsize   = 3'd3; // 8 bytes = full bus width; sel_i already carries byte granularity
    assign axi_if.awburst  = 2'b01;
    assign axi_if.awlock   = '0;
    assign axi_if.awcache  = '0;
    assign axi_if.awprot   = '0;
    assign axi_if.awqos    = '0;
    assign axi_if.awregion = '0;
    assign axi_if.awuser   = '0;

    assign axi_if.wlast = 1'b1;
    assign axi_if.wuser = '0;

    assign axi_if.bready = 1'b1; // never issues a new request before consuming the prior response

    assign axi_if.arid     = '0;
    assign axi_if.arlen    = '0;
    assign axi_if.arsize   = 3'd3;
    assign axi_if.arburst  = 2'b01;
    assign axi_if.arlock   = '0;
    assign axi_if.arcache  = '0;
    assign axi_if.arprot   = '0;
    assign axi_if.arqos    = '0;
    assign axi_if.arregion = '0;
    assign axi_if.aruser   = '0;

    assign axi_if.rready = 1'b1;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WR_ADDR,
        ST_WR_RESP,
        ST_RD_ADDR,
        ST_RD_RESP,
        ST_LATENCY,
        ST_ACK
    } state_t;

    state_t state_q, state_d;

    wire addr_valid = (addr_i[31:ADDR_W] == '0);

    // Latched at the IDLE->{WR_ADDR,RD_ADDR} edge -- the WB master (per
    // wb_driver.sv's own wb_cycle convention) holds these stable until
    // ack/err anyway, but latching internally keeps this module correct
    // without depending on that being true of every possible caller.
    logic [31:0] addr_q;
    logic [63:0] wdata_q;
    logic [7:0]  sel_q;
    always_ff @(posedge clk) begin
        if (state_q == ST_IDLE && cyc_i && stb_i && addr_valid && !refresh_busy) begin
            addr_q  <= addr_i;
            wdata_q <= dat_i;
            sel_q   <= sel_i;
        end
    end

    assign axi_if.awaddr = addr_q[ADDR_W-1:0]; // raw byte address, UNSHIFTED --
    assign axi_if.araddr = addr_q[ADDR_W-1:0]; // taxi_axi_ram does its own internal
                                                // >>$clog2(STRB_W) shift; pre-shifting
                                                // here would double-divide and
                                                // misaddress everything.
    assign axi_if.wdata = wdata_q;
    assign axi_if.wstrb = sel_q; // exact width match (STRB_W derives to 8 from DATA_W=64)

    /*
     * AW/W independence -- a real protocol-correctness point, not an
     * assumption: taxi_axi_ram's write FSM accepts AW and W on DIFFERENT
     * cycles in general (awready sits high in steady-state idle, but
     * wready only asserts the cycle AFTER AW is accepted). Two
     * independently-sticky "accepted" bits, each clearing its own
     * channel's valid the cycle its own handshake completes; ST_WR_ADDR is
     * only left once BOTH are done.
     */
    logic aw_done_q, w_done_q;
    always_ff @(posedge clk) begin
        if (rst || state_q != ST_WR_ADDR) begin
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end else begin
            if (axi_if.awvalid && axi_if.awready) aw_done_q <= 1'b1;
            if (axi_if.wvalid && axi_if.wready) w_done_q <= 1'b1;
        end
    end
    assign axi_if.awvalid = (state_q == ST_WR_ADDR) && !aw_done_q;
    assign axi_if.wvalid  = (state_q == ST_WR_ADDR) && !w_done_q;
    wire aw_complete = aw_done_q || (axi_if.awvalid && axi_if.awready);
    wire w_complete  = w_done_q  || (axi_if.wvalid  && axi_if.wready);

    // Read side: a single channel, so simply holding arvalid high for the
    // whole ST_RD_ADDR state (deasserting the cycle after acceptance, via
    // the state transition itself) is already correct -- no sticky bit
    // needed the way the write side's two-channel case requires.
    assign axi_if.arvalid = (state_q == ST_RD_ADDR);

    // Captured on a completed read only -- holds its prior value on writes
    // and errors, same convention design/wb4_sram.sv's own dat_o uses.
    always_ff @(posedge clk) begin
        if (state_q == ST_RD_RESP && axi_if.rvalid) dat_o <= axi_if.rdata;
    end

    /*
     * err_o derivation -- decided by direct inspection of taxi_axi_ram.sv,
     * not assumed: it hardwires bresp/rresp to 2'b00 (OKAY) unconditionally,
     * with no other assignment anywhere in that file -- it structurally
     * cannot produce a non-OKAY response, so there is nothing to gate err_o
     * on there. err_o is sourced exclusively from this WB-side address-
     * range check instead (mirroring wb4_sram.sv's own out-of-range
     * convention); an out-of-range request never starts an AXI transaction
     * at all -- bypasses ACCESS_LATENCY_CYCLES and refresh gating entirely.
     */
    logic err_pending_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            err_pending_q <= 1'b0;
        end else if (state_q == ST_IDLE && cyc_i && stb_i) begin
            err_pending_q <= !addr_valid;
        end
    end

    // Counts cycles spent in ST_LATENCY; reset whenever not in that state,
    // so the first cycle there always reads 0.
    logic [31:0] latency_cnt_q;
    always_ff @(posedge clk) begin
        if (rst || state_q != ST_LATENCY) latency_cnt_q <= '0;
        else latency_cnt_q <= latency_cnt_q + 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) state_q <= ST_IDLE;
        else state_q <= state_d;
    end

    always_comb begin
        state_d = state_q;
        case (state_q)
            ST_IDLE: begin
                if (cyc_i && stb_i) begin
                    if (!addr_valid) state_d = ST_ACK;
                    else if (!refresh_busy) state_d = we_i ? ST_WR_ADDR : ST_RD_ADDR;
                    // else: refresh_busy -- stay ST_IDLE, request held off
                end
            end
            ST_WR_ADDR: if (aw_complete && w_complete) state_d = ST_WR_RESP;
            ST_WR_RESP: if (axi_if.bvalid) state_d = (ACCESS_LATENCY_CYCLES == 0) ? ST_ACK : ST_LATENCY;
            ST_RD_ADDR: if (axi_if.arvalid && axi_if.arready) state_d = ST_RD_RESP;
            ST_RD_RESP: if (axi_if.rvalid) state_d = (ACCESS_LATENCY_CYCLES == 0) ? ST_ACK : ST_LATENCY;
            ST_LATENCY: if (latency_cnt_q == 32'(ACCESS_LATENCY_CYCLES - 1)) state_d = ST_ACK;
            ST_ACK: state_d = ST_IDLE;
            default: state_d = ST_IDLE;
        endcase
    end

    assign ack_o = (state_q == ST_ACK) && !err_pending_q;
    assign err_o = (state_q == ST_ACK) && err_pending_q;

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
