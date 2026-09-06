// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: soc
 *
 * Top-level integration: {core, dm0} (two Wishbone masters, Milestone 8)
 * <-> wb_arbiter2 <-> wb_addr_decoder <-> {cache_complex -> wb4_sram,
 * uart_tx, uart_rx, clint0}. Exactly the wiring already proven in
 * testbench/core_wb_tb.sv (for core<->decoder<->{ram,uart}),
 * testbench/core_cache_harness.sv (for core<->cache_complex<->sram), and
 * testbench/decoder_clint_harness.sv (for decoder<->{ram,uart,clint} at
 * the bus level, see that harness's own header for exactly what it does
 * and doesn't cover) -- this file adds no new logic of its own, only the
 * connections between already-independently-verified pieces (arb0's own
 * cache_ifetch gating, right where cache0 is instantiated below, is the
 * one piece of real reasoning THIS file itself contributes, not just a
 * connection between pieces already proven elsewhere).
 *
 * clint0 (design/clint.sv, Milestone 3, already independently verified)
 * hangs off the decoder's third slave port exactly like uart0 hangs off
 * its second -- see wb_addr_decoder.sv's own header for the 3-way
 * address map this now routes. clint0's mtip_o (this milestone) wires
 * directly to core0.i_mtip -- see clint_mtip below -- feeding core.sv's
 * machine-timer-interrupt-taking logic (design/core.sv's own Interrupts
 * section, near csr_file0's instantiation).
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
 * uart_rx0 (design/uart_rx.sv, Milestone 2 of the EBREAK/JTAG staged
 * plan) is a new sibling to uart0, NOT a new decoder port -- the two
 * share the decoder's existing single uart_* port group, split by a new
 * addr_i[4] sub-decode introduced in THIS file (0 routes to uart0/TX, 1
 * routes to uart_rx0/RX). This is the first address-decode logic soc.sv
 * itself has ever contained -- every other split (RAM/UART/CLINT/DRAM)
 * lives one level down in wb_addr_decoder.sv, which still only ever
 * sees one opaque "uart" target and has no reason to know it's now
 * backed by two physical instances. See the detailed rationale right
 * where that split is wired, next to the uart0/uart_rx0 instantiations
 * below.
 *
 * No UART pin exists at this level (or anywhere in this design) -- see
 * uart_tx.sv's header for why: this milestone's UART "transmits" via
 * $write in simulation, not real serial timing, so there is nothing for
 * a top-level pin to carry.
 *
 * jtag_tck/jtag_tms/jtag_tdi/jtag_tdo/jtag_trst_n (Milestone 6 of the
 * EBREAK/JTAG staged plan) are this project's first-ever real top-level
 * pins -- everything else so far (UART, the debug ports below) has been
 * simulation-only or internal. jtag_tap0 (design/jtag_tap.sv) is a real
 * IEEE 1149.1 TAP FSM clocked on jtag_tck, genuinely asynchronous to
 * clk; it instantiates dm_dmi0 (design/dm_dmi.sv) internally, which owns
 * the DMI transport's own busy/sticky-error protocol and the clock
 * domain crossing back into dm0's plain register interface -- see both
 * files' own headers for the full CDC design. dm0 (design/dm.sv,
 * Milestone 5) is instantiated here for the first time; its Access
 * Register ports, previously left deliberately, explicitly unconnected
 * on core0 (no Debug Module instance existed at this level yet), are now
 * wired for real.
 */
module soc (
    input logic clk,
    input logic rst,

    /*
     * ANSI defaults matter here, not just as a formality: ~10 existing
     * testbenches instantiate `soc dut (.clk(clk), .rst(rst));` with no
     * idea these pins exist. jtag_trst_n defaults to 1'b0 (ASSERTED --
     * jtag_tap0 stays cleanly, deterministically held in
     * Test-Logic-Reset, never X) specifically so those testbenches stay
     * compile/simulation-clean with no JTAG probe connected at all --
     * same reasoning this project already established for i_mtip/
     * i_debug_halt_req/etc.'s own ANSI defaults. jtag_tck defaults to
     * 1'b0 (idle low, never toggles without an explicit driver, so
     * jtag_tap0's FSM never advances past reset regardless). jtag_tms
     * defaults to 1'b1 (the safe idle level per JTAG convention -- if
     * TCK ever DID spuriously toggle, TMS=1 drives toward
     * Test-Logic-Reset, not deeper into a live scan). jtag_tdi's default
     * is arbitrary (1'b0) since it's only sampled while shifting, which
     * requires TCK to toggle in the first place.
     */
    input  logic jtag_tck = 1'b0,
    input  logic jtag_tms = 1'b1,
    input  logic jtag_tdi = 1'b0,
    output logic jtag_tdo,
    input  logic jtag_trst_n = 1'b0
);

    logic [31:0] core_wb_addr;
    logic [63:0] core_wb_dat_m2s, core_wb_dat_s2m;
    logic [7:0]  core_wb_sel;
    logic        core_wb_we, core_wb_cyc, core_wb_stb, core_wb_ack, core_wb_err;
    logic [31:0] wb_addr;
    logic [63:0] wb_dat_m2s, wb_dat_s2m;
    logic [7:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack, wb_err;
    logic        wb_ifetch;
    logic        wb_lock;
    logic        icache_flush;
    logic        clint_mtip;
    logic        arb_grant;

    /*
     * Debug Module wiring (Milestone 6) -- dm0's Access Register ports
     * are declared here, ahead of core0's own instantiation, since
     * core0 is the FIRST thing this file instantiates but dm0/jtag_tap0
     * (further down) are what actually drive/consume these wires.
     */
    logic debug_mode;
    logic debug_halt_req, debug_resume_req;
    logic dm_gpr_we, dm_csr_we;
    logic [4:0]  dm_gpr_sel;
    logic [11:0] dm_csr_addr;
    logic [63:0] dm_gpr_wdata, dm_csr_wdata, dm_gpr_rdata, dm_csr_rdata;
    logic        progbuf_start, progbuf_done, progbuf_abort;
    logic [3:0]  progbuf_pc;
    logic [31:0] progbuf_data;
    logic [31:0] sba_addr;
    logic [63:0] sba_dat_m2s, sba_dat_s2m;
    logic [7:0]  sba_sel;
    logic        sba_we, sba_cyc, sba_stb, sba_ack, sba_err;

    core core0 (
        .clk(clk), .rst(rst),
        .wb_addr_o(core_wb_addr), .wb_dat_o(core_wb_dat_m2s), .wb_dat_i(core_wb_dat_s2m),
        .wb_sel_o(core_wb_sel), .wb_we_o(core_wb_we), .wb_cyc_o(core_wb_cyc), .wb_stb_o(core_wb_stb),
        .wb_ack_i(core_wb_ack), .wb_err_i(core_wb_err), .wb_ifetch_o(wb_ifetch),
        .wb_lock_o(wb_lock),
        .icache_flush_o(icache_flush), .i_mtip(clint_mtip),

        /*
         * Milestone 4 (core.sv halt/resume FSM) added real
         * i_debug_halt_req/i_debug_resume_req/o_debug_mode ports;
         * Milestone 5 (design/dm.sv) added the Access Register
         * i_dm_.../o_dm_... ports. Both were left deliberately
         * unconnected through Milestone 5 (no Debug Module instance
         * existed at this level yet) -- Milestone 6 is that
         * instantiation, real for the first time: dm0 (further down)
         * drives every one of these. Milestone 7 adds the Program
         * Buffer ports, wired the same way.
         */
        .o_debug_mode(debug_mode),
        .i_debug_halt_req(debug_halt_req), .i_debug_resume_req(debug_resume_req),
        .i_dm_gpr_we(dm_gpr_we), .i_dm_gpr_sel(dm_gpr_sel),
        .i_dm_gpr_wdata(dm_gpr_wdata), .o_dm_gpr_rdata(dm_gpr_rdata),
        .i_dm_csr_we(dm_csr_we), .i_dm_csr_addr(dm_csr_addr),
        .i_dm_csr_wdata(dm_csr_wdata), .o_dm_csr_rdata(dm_csr_rdata),
        .i_progbuf_start(progbuf_start), .o_progbuf_pc(progbuf_pc),
        .i_progbuf_data(progbuf_data), .o_progbuf_done(progbuf_done),
        .o_progbuf_abort(progbuf_abort)
    );

    /*
     * Milestone 8 (System Bus Access): arbitrates core0's own ordinary
     * bus traffic (m0, lower priority) against dm0's new SBA master port
     * (m1, higher priority -- see design/wb_arbiter2.sv's own header for
     * the policy) before either ever reaches decoder0, which needs no
     * changes at all -- it only ever sees ONE arbitrated master port
     * regardless of how many real masters sit upstream of it.
     */
    wb_arbiter2 arb0 (
        .clk(clk), .rst(rst),
        .m0_addr_i(core_wb_addr), .m0_dat_i(core_wb_dat_m2s), .m0_dat_o(core_wb_dat_s2m),
        .m0_sel_i(core_wb_sel), .m0_we_i(core_wb_we), .m0_cyc_i(core_wb_cyc), .m0_stb_i(core_wb_stb),
        .m0_ack_o(core_wb_ack), .m0_err_o(core_wb_err), .m0_lock_i(wb_lock),
        .m1_addr_i(sba_addr), .m1_dat_i(sba_dat_m2s), .m1_dat_o(sba_dat_s2m),
        .m1_sel_i(sba_sel), .m1_we_i(sba_we), .m1_cyc_i(sba_cyc), .m1_stb_i(sba_stb),
        .m1_ack_o(sba_ack), .m1_err_o(sba_err), .m1_lock_i(1'b0),
        .addr_o(wb_addr), .dat_o(wb_dat_m2s), .dat_i(wb_dat_s2m),
        .sel_o(wb_sel), .we_o(wb_we), .cyc_o(wb_cyc), .stb_o(wb_stb),
        .ack_i(wb_ack), .err_i(wb_err),
        .o_grant(arb_grant)
    );

    logic [31:0] ram_addr, uart_addr, clint_addr;
    logic [63:0] ram_dat_o, ram_dat_i, uart_dat_o, uart_dat_i, clint_dat_o, clint_dat_i;
    logic [7:0]  ram_sel, uart_sel, clint_sel;
    logic        ram_we, ram_cyc, ram_stb, ram_ack, ram_err;
    logic        uart_we, uart_cyc, uart_stb, uart_ack, uart_err;
    logic        clint_we, clint_cyc, clint_stb, clint_ack, clint_err;

    // See decoder0's own dram_* port comment below for the full reasoning.
    // Declared ahead of decoder0's instantiation -- Icarus requires a
    // plain net used in a port connection to already be declared, unlike
    // module-level ordering in general.
    logic dram_stub_cyc, dram_stub_stb;
    logic dram_stub_err_q;

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
        .clint_stb_o(clint_stb), .clint_ack_i(clint_ack), .clint_err_i(clint_err),

        /*
         * dram_addr_o/dram_dat_o/dram_sel_o/dram_we_o left explicitly,
         * deliberately unconnected -- design/wb_addr_decoder.sv's DRAM
         * slave (verification/taxi/rtl/dram_model.sv) instantiates a
         * SystemVerilog `interface` internally, so it can only be built
         * via Verilator, never iverilog (see verification/taxi/README.md).
         * This file must stay 100% iverilog-compatible -- it's compiled by
         * testbench/soc_tb.sv, testbench/soc_interrupt_tb.sv,
         * testbench/soc_c_regression_tb.sv, and others -- so it can never
         * instantiate dram_model.sv directly. Empty parens rather than
         * omitting the lines, so lint tools see this as deliberate, not a
         * forgotten connection -- same precedent core0's own
         * .o_instruction_address() already uses in design/core.sv.
         *
         * dram_cyc_o/dram_stb_o/dram_dat_i/dram_ack_i/dram_err_i, by
         * contrast, are wired to a tiny real stub below (dram_stub_err_q),
         * NOT left floating and NOT tied to bare constants -- a Milestone 8
         * review-fix, in two parts:
         *
         * (1) A floating dram_ack_i/dram_err_i reads as X in simulation,
         * and an `if (i_sba_ack || i_sba_err)` condition on an X operand
         * evaluates as false per IEEE 1800 -- so dm.sv's own SBA busy FSM
         * would NEVER see its access complete, hanging sba_busy_q forever.
         * Before System Bus Access existed, this window was reachable only
         * by software deliberately constructing such an address, which no
         * real firmware/testbench ever did -- an accepted gap. A debugger
         * driving SBA can target ANY address, including this one, making
         * the gap newly, involuntarily reachable.
         *
         * (2) The first fix attempt tied dram_err_i to a bare constant
         * 1'b1 -- WRONG, caught by jtag_dmi_e2e_tb.sv's own new SBA test
         * (see below) failing the very next resume: wb_addr_decoder.sv's
         * target_q latches which slave's ack/err to route ONE CYCLE AFTER
         * a request starts, so on the FIRST cycle of a brand new request,
         * err_o still reflects the PREVIOUS target's response. Every real
         * slave's err_i naturally decays back to 0 once idle (a registered
         * echo of its own cyc_i&&stb_i), so this staleness window is
         * harmless for RAM/UART/CLINT -- but a bare constant 1'b1 NEVER
         * decays, so the cycle right after an SBA-to-DRAM access, target_q
         * is still stale (==TARGET_DRAM) for one cycle while core0's own
         * unrelated fresh request lands, and that request spuriously
         * inherits a DRAM bus error it never asked for (concretely: a
         * post-resume instruction fetch got spuriously fault-trapped to
         * mtvec, PC landing at 0 instead of the real fetch address).
         * dram_stub_err_q fixes this by being a REAL registered echo of
         * cyc_i&&stb_i, mirroring wb4_sram.sv's own out-of-range
         * convention exactly (`if (cyc_i&&stb_i) err_o<=1; else
         * err_o<=0;`) -- it decays to 0 the very next idle cycle, just
         * like every other slave here, so it cannot leak into a later,
         * unrelated transaction the way the bare constant did.
         *
         * A real consumer exists only under
         * verification/taxi/rtl/decoder_dram_harness.sv; wiring
         * dram_model.sv into THIS file for real would need a separate
         * Verilator-only top-level, not a change here -- see
         * verification/taxi/README.md's Status section.
         */
        /* verilator lint_off PINCONNECTEMPTY */
        .dram_addr_o(), .dram_dat_o(), .dram_sel_o(), .dram_we_o(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dram_cyc_o(dram_stub_cyc), .dram_stb_o(dram_stub_stb),
        .dram_dat_i('0), .dram_ack_i(1'b0), .dram_err_i(dram_stub_err_q)
    );

    always_ff @(posedge clk) begin
        if (rst) dram_stub_err_q <= 1'b0;
        else     dram_stub_err_q <= dram_stub_cyc && dram_stub_stb;
    end

    logic [31:0] mem_addr;
    logic [63:0] mem_dat_m2s, mem_dat_s2m;
    logic [7:0]  mem_sel;
    logic        mem_we, mem_cyc, mem_stb, mem_ack, mem_err;

    /*
     * cache_ifetch (Milestone 8): wb_ifetch is core0's OWN "this bus
     * request is an instruction fetch" hint -- meaningful only for
     * core0's own traffic, since dm0's System Bus Access never fetches
     * instructions. Before arb0 existed, cache0 sat directly behind
     * core0's own port, so wb_ifetch was always trustworthy as-is; now
     * that arb0 can forward a SBA request (a real RAM-address read/write
     * that flows through this same cache0 instance) while core0's own
     * wb_ifetch output is left driving whatever it was last doing
     * (unrelated to the request actually in flight), gating it by
     * arb_grant is required, not optional -- without this, a System Bus
     * Access to a RAM address could get silently misclassified against
     * the wrong cache (I$ instead of D$, or vice versa) depending on
     * what core0 happened to be doing the same cycle. arb_grant==0 means
     * core0 (m0) currently holds the arbitrated port, the only case
     * wb_ifetch is ever real.
     */
    wire cache_ifetch = wb_ifetch && !arb_grant;

    cache_complex cache0 (
        .clk(clk), .rst(rst),
        .addr_i(ram_addr), .dat_i(ram_dat_o), .dat_o(ram_dat_i), .sel_i(ram_sel),
        .we_i(ram_we), .ifetch_i(cache_ifetch), .cyc_i(ram_cyc), .stb_i(ram_stb),
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

    /*
     * uart_addr[4] sub-decode: soc.sv's own addr_i[4] split of the
     * decoder's single uart_* port group between uart0 (TX, addr_i[4]=0)
     * and uart_rx0 (RX, addr_i[4]=1) -- see design/uart_rx.sv's own
     * header for the register map this produces (0x8000/0x8008 TX,
     * 0x8010/0x8018 RX).
     *
     * uart_cyc/uart_stb are gated combinationally by uart_sel_rx (itself
     * a plain combinational read of uart_addr[4], which the decoder
     * holds stable for the full duration of a transaction) BEFORE they
     * ever reach either instance, so exactly one of the two ever sees a
     * live request on a given cycle -- the other's own `cyc_i && stb_i`
     * reads false and it correctly holds its own ack_o/err_o low that
     * cycle (see uart_tx.sv/uart_rx.sv's own always block: the else
     * branch drives both low). Since at most one instance is ever
     * asserting ack_o on any given cycle, the two local ack/err/dat_o
     * triples can simply be OR'd/muxed back together below with no
     * arbitration needed -- not a coincidence, a direct consequence of
     * the mutually-exclusive gating above. A future refactor must not
     * "simplify" this by feeding both instances the same ungated
     * uart_cyc/uart_stb -- that would make both instances respond to
     * every UART access, corrupting whichever one wasn't the real
     * target.
     */
    wire uart_sel_rx = uart_addr[4];

    wire uart_tx_cyc = uart_cyc && !uart_sel_rx;
    wire uart_tx_stb = uart_stb && !uart_sel_rx;
    wire uart_rx_cyc = uart_cyc && uart_sel_rx;
    wire uart_rx_stb = uart_stb && uart_sel_rx;

    logic [63:0] uart_tx_dat_o, uart_rx_dat_o;
    logic        uart_tx_ack, uart_tx_err, uart_rx_ack, uart_rx_err;

    assign uart_ack   = uart_tx_ack | uart_rx_ack;
    assign uart_err   = uart_tx_err | uart_rx_err;
    assign uart_dat_i = uart_tx_ack ? uart_tx_dat_o : uart_rx_dat_o;

    uart_tx uart0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_tx_dat_o), .sel_i(uart_sel),
        .ack_o(uart_tx_ack), .err_o(uart_tx_err), .cyc_i(uart_tx_cyc), .stb_i(uart_tx_stb), .we_i(uart_we)
    );

    uart_rx uart_rx0 (
        .clk(clk), .rst(rst),
        .addr_i(uart_addr), .dat_i(uart_dat_o), .dat_o(uart_rx_dat_o), .sel_i(uart_sel),
        .ack_o(uart_rx_ack), .err_o(uart_rx_err), .cyc_i(uart_rx_cyc), .stb_i(uart_rx_stb), .we_i(uart_we)
    );

    clint clint0 (
        .clk(clk), .rst(rst),
        .addr_i(clint_addr), .dat_i(clint_dat_o), .dat_o(clint_dat_i), .sel_i(clint_sel),
        .ack_o(clint_ack), .err_o(clint_err), .cyc_i(clint_cyc), .stb_i(clint_stb), .we_i(clint_we),
        .mtip_o(clint_mtip)
    );

    /*
     * Debug Module (Milestone 6): jtag_tap0's own plain register
     * interface output (o_reg_addr/o_reg_wdata/o_reg_we/i_reg_rdata,
     * see design/jtag_tap.sv's header) is wired directly to dm0's
     * matching input side -- this is a plain, same-clock-domain
     * register bus (jtag_tap0 already did the TCK->clk CDC bridging
     * internally via its own dm_dmi0 instance), not a new bus master on
     * the Wishbone fabric above.
     */
    logic [6:0]  dmi_reg_addr;
    logic [31:0] dmi_reg_wdata;
    logic        dmi_reg_we;
    logic [31:0] dmi_reg_rdata;

    jtag_tap jtag_tap0 (
        .tck(jtag_tck), .tms(jtag_tms), .tdi(jtag_tdi), .tdo(jtag_tdo), .trst_n(jtag_trst_n),
        .clk(clk), .rst(rst),
        .o_reg_addr(dmi_reg_addr), .o_reg_wdata(dmi_reg_wdata), .o_reg_we(dmi_reg_we),
        .i_reg_rdata(dmi_reg_rdata)
    );

    dm dm0 (
        .clk(clk), .rst(rst),
        .i_reg_addr(dmi_reg_addr), .i_reg_wdata(dmi_reg_wdata), .i_reg_we(dmi_reg_we),
        .o_reg_rdata(dmi_reg_rdata),
        .i_hart_halted(debug_mode),
        .o_debug_halt_req(debug_halt_req), .o_debug_resume_req(debug_resume_req),
        .o_dm_gpr_we(dm_gpr_we), .o_dm_gpr_sel(dm_gpr_sel),
        .o_dm_gpr_wdata(dm_gpr_wdata), .i_dm_gpr_rdata(dm_gpr_rdata),
        .o_dm_csr_we(dm_csr_we), .o_dm_csr_addr(dm_csr_addr),
        .o_dm_csr_wdata(dm_csr_wdata), .i_dm_csr_rdata(dm_csr_rdata),
        .o_progbuf_start(progbuf_start), .i_progbuf_pc(progbuf_pc),
        .o_progbuf_data(progbuf_data), .i_progbuf_done(progbuf_done),
        .i_progbuf_abort(progbuf_abort),
        .o_sba_addr(sba_addr), .o_sba_dat(sba_dat_m2s), .i_sba_dat(sba_dat_s2m),
        .o_sba_sel(sba_sel), .o_sba_we(sba_we), .o_sba_cyc(sba_cyc), .o_sba_stb(sba_stb),
        .i_sba_ack(sba_ack), .i_sba_err(sba_err)
    );

endmodule
