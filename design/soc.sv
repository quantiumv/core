// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: soc
 *
 * Top-level integration: core (Wishbone master) <-> wb_addr_decoder <->
 * {cache_complex -> wb4_sram, uart_tx, clint0}. Exactly the wiring already
 * proven in testbench/core_wb_tb.sv (for core<->decoder<->{ram,uart}),
 * testbench/core_cache_harness.sv (for core<->cache_complex<->sram), and
 * testbench/decoder_clint_harness.sv (for decoder<->{ram,uart,clint} at
 * the bus level, see that harness's own header for exactly what it does
 * and doesn't cover) -- this file adds no new logic of its own, only the
 * connections between already-independently-verified pieces.
 *
 * clint0 (design/clint.sv, Milestone 3, already independently verified)
 * hangs off the decoder's third slave port exactly like uart0 hangs off
 * its second -- see wb_addr_decoder.sv's own header for the 3-way
 * address map this now routes. clint0's mtip_o has NO consumer yet in
 * this milestone: core.sv gains no CLINT-facing input port until
 * Milestone 6 of this same plan, so clint_mtip below is genuinely
 * unconsumed for now (deliberate, not an oversight).
 *
 * cache_complex sits AFTER wb_addr_decoder, between it and wb4_sram --
 * not before the decoder. This is deliberate, not incidental ordering:
 * uart_tx.sv is a real side-effecting MMIO peripheral (TX_DATA triggers a
 * genuine $write on every store; TX_STATUS is a poll register explicitly
 * structured to grow real serial timing later), and placing the cache
 * downstream of the decoder makes UART traffic structurally uncacheable
 * -- cache_complex's ports simply never see it -- rather than requiring
 * the cache to duplicate the decoder's own addr_i[15] test internally,
 * with the real risk of getting it wrong (e.g. a cached TX_STATUS poll
 * silently breaking once real timing lands there). See the cache
 * hierarchy's own design notes (project memory: cache-hierarchy-plan) for
 * the full reasoning.
 *
 * clint0 sits outside cache_complex for the SAME structural reason, not
 * a separate one worth re-deriving: mtime free-runs every cycle and the
 * CPU never writes it, so a cached read would freeze at whatever value
 * it first saw, with nothing to ever invalidate it -- permanently
 * breaking any `while (mtime < deadline);` poll loop. Placing clint0
 * downstream of the decoder, alongside uart0, makes it structurally
 * uncacheable the same way -- not an incidental side effect of where it
 * happened to get wired, and NOT something a future refactor should
 * "simplify" by routing it through cache_complex alongside RAM.
 *
 * wb4_sram is instantiated at its default num_words (4096, 32KB) --
 * unlike core_wb_tb.sv's deliberately small test instance, this is the
 * real memory map wb_addr_decoder.sv's address split (addr_i[15]) is
 * derived from; see that module's own header comment for why the two
 * aren't independent. cache_complex's own cache size defaults (64 lines x
 * 4 words = 2KB per cache, 4KB combined) are likewise this module's
 * choice to keep, not something wb_addr_decoder.sv or wb4_sram.sv need to
 * know about -- the cache is fully transparent to both.
 *
 * I$/D$ coherence for self-modifying code (Zifencei, FENCE.I): closed
 * 2026-08-17, no longer a gap. core0.icache_flush_o (pulses one cycle on
 * FENCE.I's own retirement) wires straight to cache0.flush_i, which
 * cache_complex.sv passes through unconditionally to icache0 -- software
 * that stores new instruction bytes then executes FENCE.I before jumping
 * to them gets a correctly-invalidated I$, matching the RISC-V spec's
 * own Zifencei contract. D$ never needed an equivalent flush path --
 * write-through already keeps a store hit's cached copy and SRAM in
 * lockstep. See design/core.sv's icache_flush_o port comment and
 * design/icache.sv's flush_i port comment for the full timing proof.
 *
 * No UART pin exists at this level (or anywhere in this design) -- see
 * uart_tx.sv's header for why: this milestone's UART "transmits" via
 * $write in simulation, not real serial timing, so there is nothing for
 * a top-level pin to carry. clk/rst are this module's only ports.
 */
module soc (
    input logic clk,
    input logic rst
);

    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;
    logic        wb_ifetch;
    logic        icache_flush;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(wb_addr), .wb_dat_o(wb_dat_m2s), .wb_dat_i(wb_dat_s2m),
        .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb),
        .wb_ack_i(wb_ack), .wb_err_i(wb_err), .wb_ifetch_o(wb_ifetch),
        .icache_flush_o(icache_flush)
    );

    logic [31:0] ram_addr, uart_addr, clint_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i, clint_dat_o, clint_dat_i;
    logic [7:0]  ram_sel, uart_sel, clint_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;
    logic        clint_we, clint_cyc, clint_stb, clint_ack, clint_err;

    wb_addr_decoder decoder0 (
        .clk(clk), .rst(rst),
        .addr_i(wb_addr), .dat_i(wb_dat_m2s), .dat_o(wb_dat_s2m), .sel_i(wb_sel),
        .we_i(wb_we), .cyc_i(wb_cyc), .stb_i(wb_stb), .ack_o(wb_ack), .err_o(wb_err),
        .ram_addr_o(ram_addr), .ram_dat_o(ram_dat_o), .ram_dat_i(ram_dat_i),
        .ram_sel_o(ram_sel), .ram_we_o(ram_we), .ram_cyc_o(ram_cyc),
        .ram_stb_o(ram_stb), .ram_ack_i(ram_ack), .ram_err_i(ram_err),
        .uart_addr_o(uart_addr), .uart_dat_o(uart_dat_o), .uart_dat_i(uart_dat_i),
        .uart_sel_o(uart_sel), .uart_we_o(uart_we), .uart_cyc_o(uart_cyc),
        .uart_stb_o(uart_stb), .uart_ack_i(uart_ack), .uart_err_i(uart_err),
        .clint_addr_o(clint_addr), .clint_dat_o(clint_dat_o), .clint_dat_i(clint_dat_i),
        .clint_sel_o(clint_sel), .clint_we_o(clint_we), .clint_cyc_o(clint_cyc),
        .clint_stb_o(clint_stb), .clint_ack_i(clint_ack), .clint_err_i(clint_err)
    );

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    cache_complex cache0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .we_i(ram_we), .ifetch_i(wb_ifetch), .cyc_i(ram_cyc), .stb_i(ram_stb),
        .ack_o(ram_ack), .err_o(ram_err), .flush_i(icache_flush),
        .mem_addr_o(mem_addr), .mem_dat_o(mem_dat_m2s), .mem_dat_i(mem_dat_s2m),
        .mem_sel_o(mem_sel), .mem_we_o(mem_we), .mem_cyc_o(mem_cyc), .mem_stb_o(mem_stb),
        .mem_ack_i(mem_ack), .mem_err_i(mem_err)
    );

    wb4_sram sram0 (
        .clk(clk), .rst(rst),
        .addr_i(mem_addr), .dat_i(mem_dat_m2s), .dat_o(mem_dat_s2m), .sel_i(mem_sel),
        .ack_o(mem_ack), .err_o(mem_err), .cyc_i(mem_cyc), .stb_i(mem_stb), .we_i(mem_we)
    );

    uart_tx uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_dat_i), .sel_i(uart_sel),
        .ack_o(uart_ack), .err_o(uart_err), .cyc_i(uart_cyc), .stb_i(uart_stb), .we_i(uart_we)
    );

    // mtip_o has no consumer yet -- Milestone 6 wires this to core0.i_mtip.
    /* verilator lint_off UNUSEDSIGNAL */
    logic clint_mtip;
    /* verilator lint_on UNUSEDSIGNAL */

    clint clint0 (
        .clk(clk), .rst(rst),
        .addr_i(clint_addr), .dat_i(clint_dat_o), .dat_o(clint_dat_i), .sel_i(clint_sel),
        .ack_o(clint_ack), .err_o(clint_err), .cyc_i(clint_cyc), .stb_i(clint_stb), .we_i(clint_we),
        .mtip_o(clint_mtip)
    );

endmodule
