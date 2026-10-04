/*
 * lockstep_mem.sv -- one side's full memory subsystem.
 *
 * MEMCFG_CACHE=0 (flat SRAM): delay shims on both the fetch and mem
 * master ports, then wb_arbiter2 (fetch=m0, mem=m1, so execute wins
 * ties -- same convention as testbench/core_wb4_sram_harness.sv), then a
 * flat address decode to wb4_sram or lockstep_mmio.
 *
 * MEMCFG_CACHE=1 (cache): mirrors design/soc.sv's own topology -- fetch
 * goes straight to the icache with no delay shim in front of it, mem
 * goes straight to the dcache side of cache_complex, and the single
 * delay shim sits on cache_complex's own downstream mem_* port instead
 * (modeling backing-RAM latency; a cache hit stays fast on both sides).
 */
`include "lockstep_defs.svh"

module lockstep_mem #(
    parameter bit MEMCFG_CACHE      = 1'b0,
    parameter int NUM_WORDS         = `QV_LOCKSTEP_RAM_WORDS,
    parameter int NUM_LINES         = 64,
    parameter int LINE_WORDS        = 4,
    parameter int DELAY_MAX         = 0     // structural: 0 disables both delay-shim FSMs
) (
    input  logic clk,
    input  logic rst,

    input  logic [31:0] delay_seed_fetch_i,  // runtime
    input  logic [31:0] delay_seed_mem_i,    // runtime

    // core-facing fetch port
    input  logic [31:0] fetch_addr_i,
    input  logic        fetch_cyc_i,
    input  logic        fetch_stb_i,
    output logic [63:0] fetch_dat_o,
    output logic        fetch_ack_o,
    output logic        fetch_err_o,

    // core-facing mem port
    input  logic [31:0] mem_addr_i,
    input  logic [63:0] mem_dat_i,
    output logic [63:0] mem_dat_o,
    input  logic [7:0]  mem_sel_i,
    input  logic        mem_we_i,
    input  logic        mem_cyc_i,
    input  logic        mem_stb_i,
    output logic        mem_ack_o,
    output logic        mem_err_o,
    input  logic        mem_lock_i,

    input  logic         icache_flush_i,

    output logic        o_magic_set_we,
    output logic [31:0] o_magic_set_wdata,
    output logic        o_magic_clr_we,
    output logic [31:0] o_magic_clr_wdata,

    output logic        o_wr_valid,
    output logic [31:0] o_wr_addr,
    output logic [7:0]  o_wr_sel,
    output logic [63:0] o_wr_data,

    output logic        o_rd_valid,
    output logic [31:0] o_rd_addr,
    output logic [63:0] o_rd_data
);
    // Downstream single-master port (post arbitration / post cache).
    logic [31:0] dn_addr;
    logic [63:0] dn_dat_m2s, dn_dat_s2m;
    logic [7:0]  dn_sel;
    logic        dn_we, dn_cyc, dn_stb, dn_ack, dn_err;

    // LIVE decode -- used only to gate each slave's own cyc_i/stb_i this
    // cycle (below) and to latch target_q (below), exactly like
    // wb_addr_decoder.sv's own ram_cyc_o/uart_cyc_o (= cyc_i && sel_ram/
    // sel_uart, both live off addr_i). Safe to stay live for THAT use: a
    // slave only ever samples it while a fresh request is actually
    // present this cycle.
    wire is_mmio = (dn_addr >= `QV_LOCKSTEP_MMIO_BASE) &&
                   (dn_addr <  (`QV_LOCKSTEP_MMIO_BASE + `QV_LOCKSTEP_MMIO_SIZE));
    wire is_ram  = (dn_addr < `QV_LOCKSTEP_RAM_BYTES);

    /*
     * Response routing uses a LATCHED target, not a live re-decode of
     * dn_addr -- mirrors wb_addr_decoder.sv's own target_q and its
     * header's "remember which slave" reasoning verbatim: both slaves
     * below are registered (one-cycle-delayed-echo) Wishbone slaves, so
     * by the time ack_i/dat_i need routing back, dn_addr may already
     * reflect something else.
     *
     * This isn't a theoretical convenience, like it is in a lot of
     * designs that could get away with a live re-decode most of the
     * time -- a real, confirmed zero-delay simulation hang happened here
     * without it. ref_core.sv's own wb_mem_addr_o/wb_mem_cyc_o
     * (core.sv:5285-5336) are driven by a combinational
     * `!wb_mem_done`-gated always_comb that reverts BOTH to 0 the same
     * instant it sees a live ack/err -- exactly the "no longer
     * re-derivable from addr_i" case wb_addr_decoder.sv's header warns
     * about, and exactly why that module latches instead. Re-deriving
     * is_mmio/is_ram from dn_addr at response time (this file's original
     * version) closed a real loop: dn_addr reverting to 0 flips
     * is_mmio/is_ram, which flips which registered ack dn_ack reads back,
     * which (being wb_mem_ack_i to the core) flips wb_mem_done live,
     * which flips wb_mem_addr_o/cyc_o again -- forever, in the same time
     * step. Confirmed by a direct run hanging at 100% CPU with simulation
     * time never advancing past the exact cycle the first real MMIO
     * write's (firmware/hello.c's UART TX) ack arrived, and by a
     * delta-cycle tracer catching the live oscillation in the act:
     * dn_addr alternating 0x04008000/0x00000000 and dn_cyc/is_mmio/is_ram
     * flipping in lockstep, all within a single, never-advancing $time.
     * Latching, exactly like the real decoder, breaks it: once latched,
     * the response mux no longer depends on dn_addr at all, so dn_addr's
     * own reversion can never feed back into it.
     */
    typedef enum logic [1:0] { TGT_RAM, TGT_MMIO, TGT_NONE } target_t;
    target_t target_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            target_q <= TGT_RAM;
        end else if (dn_cyc && dn_stb) begin
            if (is_mmio)      target_q <= TGT_MMIO;
            else if (is_ram)  target_q <= TGT_RAM;
            else              target_q <= TGT_NONE;
        end
    end

    // An address that is neither RAM nor MMIO faults -- matches
    // wb4_sram.sv's own "out of range -> err_o" convention, applied one
    // level up here. Registered, like every other ack/err in this file,
    // rather than derived live from dn_cyc/dn_stb (which, unlike the
    // is_mmio/is_ram case above, WOULD still close a loop even with
    // target_q latched: dn_err -> drop_req -> cyc_o/stb_o -> dn_cyc/
    // dn_stb -> dn_err. Not yet reachable by any current corpus entry
    // -- every one stays inside RAM or the one MMIO UART address -- but
    // gen/qvgen.py's generator deliberately emits out-of-range accesses,
    // so a future random-corpus seed could reach it.
    logic none_err_q;
    always_ff @(posedge clk) begin
        if (rst) none_err_q <= 1'b0;
        else     none_err_q <= dn_cyc && dn_stb && !is_mmio && !is_ram;
    end

    logic [63:0] sram_dat, mmio_dat;
    logic        sram_ack, sram_err, mmio_ack, mmio_err;

    always_comb begin
        case (target_q)
            TGT_MMIO: begin dn_dat_s2m = mmio_dat; dn_ack = mmio_ack; dn_err = mmio_err;  end
            TGT_NONE: begin dn_dat_s2m = 64'b0;     dn_ack = 1'b0;    dn_err = none_err_q; end
            default:  begin dn_dat_s2m = sram_dat;  dn_ack = sram_ack; dn_err = sram_err;  end
        endcase
    end

    /* verilator lint_off PINCONNECTEMPTY */
    wb4_sram #(.num_words(NUM_WORDS)) sram0 (
        .clk(clk), .rst(rst),
        .addr_i(dn_addr), .dat_i(dn_dat_m2s), .dat_o(sram_dat), .sel_i(dn_sel),
        .ack_o(sram_ack), .err_o(sram_err),
        .cyc_i(dn_cyc && is_ram), .stb_i(dn_stb && is_ram), .we_i(dn_we)
    );

    lockstep_mmio mmio0 (
        .clk(clk), .rst(rst),
        .addr_i(dn_addr), .dat_i(dn_dat_m2s), .dat_o(mmio_dat), .sel_i(dn_sel),
        .we_i(dn_we), .cyc_i(dn_cyc && is_mmio), .stb_i(dn_stb && is_mmio),
        .ack_o(mmio_ack), .err_o(mmio_err),
        .o_magic_set_we(o_magic_set_we), .o_magic_set_wdata(o_magic_set_wdata),
        .o_magic_clr_we(o_magic_clr_we), .o_magic_clr_wdata(o_magic_clr_wdata),
        .o_rd_valid(o_rd_valid), .o_rd_addr(o_rd_addr), .o_rd_data(o_rd_data)
    );

    // Ordered committed-write log: one pulse per accepted write, taken at
    // the single downstream port so it sees both RAM and MMIO writes.
    assign o_wr_valid = dn_cyc && dn_stb && dn_we && dn_ack;
    assign o_wr_addr  = dn_addr;
    assign o_wr_sel   = dn_sel;
    assign o_wr_data  = dn_dat_m2s;

    generate
        if (!MEMCFG_CACHE) begin : g_sram_cfg
            logic [31:0] df_addr, dm_addr;
            logic [7:0]  df_sel, dm_sel;
            logic        df_we, dm_we, df_cyc, dm_cyc, df_stb, dm_stb;
            logic        df_ack, dm_ack, df_err, dm_err;
            logic        dm_lock;
            logic [63:0] df_dn_dat_i, dm_dn_dat_i;   // per-master read-return from the arbiter
            logic [63:0] dm_wdata;                    // store data forwarded through delay_mem

            lockstep_wb_delay #(.DELAY_MAX(DELAY_MAX)) delay_fetch (
                .clk(clk), .rst(rst), .seed_i(delay_seed_fetch_i),
                .up_addr_i(fetch_addr_i), .up_dat_i(64'b0), .up_dat_o(fetch_dat_o),
                .up_sel_i(8'hFF), .up_we_i(1'b0),
                .up_cyc_i(fetch_cyc_i), .up_stb_i(fetch_stb_i),
                .up_ack_o(fetch_ack_o), .up_err_o(fetch_err_o), .up_lock_i(1'b0),
                .dn_addr_o(df_addr), .dn_dat_o(), .dn_dat_i(df_dn_dat_i),
                .dn_sel_o(), .dn_we_o(), .dn_cyc_o(df_cyc), .dn_stb_o(df_stb),
                .dn_ack_i(df_ack), .dn_err_i(df_err), .dn_lock_o()
            );

            lockstep_wb_delay #(.DELAY_MAX(DELAY_MAX)) delay_mem (
                .clk(clk), .rst(rst), .seed_i(delay_seed_mem_i),
                .up_addr_i(mem_addr_i), .up_dat_i(mem_dat_i), .up_dat_o(mem_dat_o),
                .up_sel_i(mem_sel_i), .up_we_i(mem_we_i),
                .up_cyc_i(mem_cyc_i), .up_stb_i(mem_stb_i),
                .up_ack_o(mem_ack_o), .up_err_o(mem_err_o), .up_lock_i(mem_lock_i),
                .dn_addr_o(dm_addr), .dn_dat_o(dm_wdata), .dn_dat_i(dm_dn_dat_i),
                .dn_sel_o(dm_sel), .dn_we_o(dm_we), .dn_cyc_o(dm_cyc), .dn_stb_o(dm_stb),
                .dn_ack_i(dm_ack), .dn_err_i(dm_err), .dn_lock_o(dm_lock)
            );

            // fetch=m0 (lower priority), mem=m1 (higher priority, wins
            // ties) -- same convention as core_wb4_sram_harness.sv.
            wb_arbiter2 #(.DROP_REQ_ON_RESP(1'b1)) arb0 (
                .clk(clk), .rst(rst),
                .m0_addr_i(df_addr), .m0_dat_i(64'b0), .m0_dat_o(df_dn_dat_i),
                .m0_sel_i(8'hFF), .m0_we_i(1'b0),
                .m0_cyc_i(df_cyc), .m0_stb_i(df_stb),
                .m0_ack_o(df_ack), .m0_err_o(df_err), .m0_lock_i(1'b0),
                .m1_addr_i(dm_addr), .m1_dat_i(dm_wdata), .m1_dat_o(dm_dn_dat_i),
                .m1_sel_i(dm_sel), .m1_we_i(dm_we),
                .m1_cyc_i(dm_cyc), .m1_stb_i(dm_stb),
                .m1_ack_o(dm_ack), .m1_err_o(dm_err), .m1_lock_i(dm_lock),
                .addr_o(dn_addr), .dat_o(dn_dat_m2s), .dat_i(dn_dat_s2m),
                .sel_o(dn_sel), .we_o(dn_we), .cyc_o(dn_cyc), .stb_o(dn_stb),
                .ack_i(dn_ack), .err_i(dn_err), .o_grant()
            );
        end else begin : g_cache_cfg
            // A side B slowed by cache misses runs at a different speed;
            // lockstep_tb.sv's exact stop ends both sides at the same
            // retirement (before it, the faster side could run on past
            // its tohost write, through an EBREAK to mtvec=0 and round
            // the whole program again).
            logic [31:0] cm_addr;
            logic [63:0] cm_dat_m2s, cm_dat_s2m;
            logic [7:0]  cm_sel;
            logic        cm_we, cm_cyc, cm_stb, cm_ack, cm_err;

            // AMO lock is not routed through cache_complex today (no lock
            // port exists on it) -- cache_complex already serializes its
            // own single downstream transaction at a time, so an AMO's
            // read+write phases can't be split by an interleaved fetch
            // refill. Revisit if cache-config AMO lockstep ever surfaces
            // a real interleaving.
            cache_complex #(.num_lines(NUM_LINES), .line_words(LINE_WORDS)) cache0 (
                .clk(clk), .rst(rst),
                .fetch_addr_i(fetch_addr_i), .fetch_cyc_i(fetch_cyc_i), .fetch_stb_i(fetch_stb_i),
                .fetch_dat_o(fetch_dat_o), .fetch_ack_o(fetch_ack_o), .fetch_err_o(fetch_err_o),
                .data_addr_i(mem_addr_i), .data_dat_i(mem_dat_i), .data_dat_o(mem_dat_o),
                .data_sel_i(mem_sel_i), .data_we_i(mem_we_i),
                .data_cyc_i(mem_cyc_i), .data_stb_i(mem_stb_i),
                .data_ack_o(mem_ack_o), .data_err_o(mem_err_o), .flush_i(icache_flush_i),
                .mem_addr_o(cm_addr), .mem_dat_o(cm_dat_m2s), .mem_dat_i(cm_dat_s2m),
                .mem_sel_o(cm_sel), .mem_we_o(cm_we), .mem_cyc_o(cm_cyc), .mem_stb_o(cm_stb),
                .mem_ack_i(cm_ack), .mem_err_i(cm_err)
            );

            lockstep_wb_delay #(.DELAY_MAX(DELAY_MAX)) delay_post_cache (
                .clk(clk), .rst(rst), .seed_i(delay_seed_mem_i),
                .up_addr_i(cm_addr), .up_dat_i(cm_dat_m2s), .up_dat_o(cm_dat_s2m),
                .up_sel_i(cm_sel), .up_we_i(cm_we),
                .up_cyc_i(cm_cyc), .up_stb_i(cm_stb),
                .up_ack_o(cm_ack), .up_err_o(cm_err), .up_lock_i(1'b0),
                .dn_addr_o(dn_addr), .dn_dat_o(dn_dat_m2s), .dn_dat_i(dn_dat_s2m),
                .dn_sel_o(dn_sel), .dn_we_o(dn_we), .dn_cyc_o(dn_cyc), .dn_stb_o(dn_stb),
                .dn_ack_i(dn_ack), .dn_err_i(dn_err), .dn_lock_o()
            );
        end
    endgenerate
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
