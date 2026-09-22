// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"


/* ------------------------------------------------------------------------- */


/*
 * Module: cache_complex -- I$/D$ pair, one shared memory-facing port
 *
 * Thin wrapper: instantiates icache.sv and dcache.sv, routes core.sv's
 * single time-multiplexed Wishbone master port to whichever one applies
 * (ifetch_i high -> icache0, low -> dcache0 -- see core.sv's own
 * wb_ifetch_o port comment for why this side-band signal exists at all),
 * and ARBITRATES both sub-caches' independent downstream refill/write
 * traffic onto ONE shared memory-facing Wishbone master port.
 *
 * Pipelining P2 prerequisite (real dual-outstanding arbiter, replacing
 * the old plain-select design): the old version's header stated, as a
 * design INVARIANT rather than a mux convenience, that "core.sv's FSM is
 * single-issue: fetch and mem/AMO access never overlap, so icache0 and
 * dcache0 can never both have outstanding downstream traffic at the same
 * time" -- true as of the fstate machine shipped in P2 steps 1-3a (the
 * top-level state register is still single-issue: S_MEM blocks on
 * wb_done before a new S_FETCH request can start), but P2's own end goal
 * (step 3b, not yet implemented) is real fetch/execute overlap: letting
 * instruction N+1's own fetch start while instruction N is still
 * draining a LOAD/STORE in dcache0. Both icache.sv's CACHE_REFILL and
 * dcache.sv's CACHE_REFILL/CACHE_WRITE run to completion once started
 * (sampled cyc_i&&stb_i while CACHE_IDLE), driven purely by their own
 * mem_ack_i/mem_err_i from that point on, with NO abort path and no
 * further dependence on their own core-facing cyc_i/stb_i staying
 * asserted (confirmed directly: icache.sv's own CACHE_IDLE arm only
 * consults cyc_i/stb_i for the exact one cycle it decides hit vs. miss).
 * That autonomy is exactly what makes real overlap possible at the
 * core.sv level (a single shared core-facing port can safely hand off
 * to a different requester the cycle after a request was SAMPLED,
 * without needing to keep holding it) -- but it is ALSO exactly what
 * breaks the OLD single active_ifetch_q latch here: once real overlap
 * lands, each sub-cache can independently be idle, waiting to issue a
 * downstream request, or already mid-downstream-transaction, at any
 * moment, regardless of the OTHER sub-cache's own state. The old latch
 * ("whichever core-facing request came LAST wins ALL future downstream
 * responses, unconditionally") would silently steal a mid-flight
 * sub-cache's own eventual mem_ack_i/mem_err_i the instant the other
 * sub-cache's request appeared -- a genuine lost-response/deadlock bug,
 * not a mere latency inefficiency, once that scenario becomes reachable.
 *
 * Landed AHEAD of step 3b itself (core.sv doesn't issue overlapping
 * core-facing requests yet, so the arbiter below is exercised on every
 * real request but never actually contended in today's build) --
 * deliberately, matching this project's own staged-milestone discipline:
 * a strict superset of the old routing for every single-issue scenario
 * the old code already got right (see this file's own regression
 * argument, unchanged for that case), landed and independently verified
 * before the change that will actually put it under real contention.
 *
 * wb4_sram.sv (the sole downstream slave) is a single cyc_i/stb_i/
 * addr_i/dat_i/sel_i/we_i in, ack_o/err_o/dat_o out, NO-BURST,
 * single-outstanding slave -- the SHARED downstream bus itself can only
 * ever carry one request at a time, by construction of a single
 * Wishbone master port. "Dual-outstanding" here means each sub-cache
 * independently HOLDS its own pending/in-flight request without losing
 * it or having it corrupted by the other -- not that both appear on the
 * wire literally simultaneously (physically impossible for one port).
 *
 * Arbitration policy: dcache0 (execute) has FIXED PRIORITY over icache0
 * (fetch-ahead) whenever both want the shared downstream port on the
 * same cycle -- the same "execute always wins the shared bus; fetch-
 * ahead is pure latency-hiding and must never delay actual retirement"
 * intent step 3b's own core.sv-side priority mux will apply at the
 * core-facing level too. A dcache0 request belongs to the CURRENTLY
 * RETIRING instruction (delaying it delays commit_now, hence every
 * later instruction, fetch-ahead included); an icache0 request, once
 * real overlap lands, is for a SPECULATIVELY pre-fetched future
 * instruction that may be flushed before it's ever used -- delaying it
 * costs at most some latency-hiding benefit, never correctness.
 *
 * Starvation: this priority is re-evaluated COMBINATIONALLY every cycle
 * (nothing latches "locked to dcache0 until its whole transfer
 * finishes") -- icache0 is granted the very next cycle dcache0 doesn't
 * want the bus, not the cycle after dcache0's entire transaction
 * completes. Genuine indefinite starvation would need dcache0 wanting
 * the bus on literally every cycle forever, which this core cannot
 * produce while lookahead stays bounded to one instruction (P1/P2 step
 * 1's own SLOT_COUNT=2 scheme): the NEXT dcache0 request can't even be
 * reached without ITS OWN instruction's fetch completing first, which
 * needs an icache0 grant. Re-check this argument if lookahead depth
 * ever grows past one instruction.
 *
 * No change needed to icache.sv/dcache.sv: both already hold their own
 * mem_cyc_o/mem_stb_o combinationally asserted (Wishbone classic
 * "master holds cyc/stb until ack" discipline) for as long as they want
 * a downstream beat, re-evaluated every cycle rather than pulsed once --
 * exactly the contract this arbiter needs. A sub-cache denied the bus
 * this cycle simply keeps re-asserting its request next cycle; the
 * sub-cache's own state IS the pending-request queue, so no separate
 * queueing structure is needed here.
 *
 * Core-facing routing (active_ifetch_q, below) stays UNCHANGED from the
 * old design -- core.sv still only ever issues one core-facing request
 * at a time today (step 3b's own job, not this file's), so that latch
 * is still exactly correct there; it was the OLD DOWNSTREAM latch that
 * was wrong once dual-outstanding downstream traffic becomes possible,
 * and that is what the new arbiter below replaces.
 */
module cache_complex #(
    parameter num_lines  = 64,
    parameter line_words = 4
) (
    input logic clk,
    input logic rst,

    // Core-facing port -- this module is a Wishbone SLAVE from core.sv's
    // side. ifetch_i is not part of the Wishbone protocol itself -- see
    // core.sv's wb_ifetch_o port comment.
    input  logic [31:0] addr_i,
    input  logic [63:0] dat_i,
    output logic [63:0] dat_o,
    input  logic [7:0]  sel_i,
    input  logic        we_i,
    input  logic        ifetch_i,
    input  logic        cyc_i,
    input  logic        stb_i,
    output logic        ack_o,
    output logic        err_o,

    /*
     * Zifencei: passed straight through to icache0.flush_i UNCONDITIONALLY
     * -- load-bearing to get right, not a style choice. ifetch_i is LOW
     * throughout S_EXEC (FENCE.I's own commit cycle, where core.sv pulses
     * icache_flush_o -- see that port's own comment), so gating this on
     * ifetch_i the way cyc_i/stb_i are routed above would silently make
     * FENCE.I a permanent no-op: the exact class of bug this signal exists
     * to prevent, not just an edge case. D$ has no equivalent flush path
     * (or need for one) -- write-through already keeps a store hit's
     * cached copy and SRAM in lockstep.
     */
    input  logic        flush_i,

    // Memory-facing port -- this module is a Wishbone MASTER from
    // wb4_sram.sv's side. Shared by both sub-caches; see this module's
    // own header for why no arbitration is needed.
    output logic [31:0] mem_addr_o,
    output logic [63:0] mem_dat_o,
    input  logic [63:0] mem_dat_i,
    output logic [7:0]  mem_sel_o,
    output logic        mem_we_o,
    output logic        mem_cyc_o,
    output logic        mem_stb_o,
    input  logic        mem_ack_i,
    input  logic        mem_err_i
);
    // icache0's own ports.
    logic [63:0] ic_dat_o;
    logic        ic_ack, ic_err;
    logic [31:0] ic_mem_addr;
    logic [63:0] ic_mem_dat_i;
    logic [7:0]  ic_mem_sel;
    /* verilator lint_off UNUSEDSIGNAL */
    // ic_mem_we: icache0 never writes (read-only cache -- see icache.sv's
    // own header), so the arbiter below hardwires mem_we_o to 0 whenever
    // icache0 is granted rather than ever consulting this port.
    // ic_mem_stb: icache.sv (like dcache.sv) always drives mem_cyc_o==
    // mem_stb_o, so the arbiter's own want_ic reads mem_cyc_o alone --
    // the CYC/STB pair really is one signal here, not two independent
    // ones, and reading both would be redundant, not more correct.
    logic        ic_mem_we, ic_mem_stb;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        ic_mem_cyc, ic_mem_ack, ic_mem_err;

    icache #(.num_lines(num_lines), .line_words(line_words)) icache0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_o(ic_dat_o), .cyc_i(cyc_i && ifetch_i), .stb_i(stb_i && ifetch_i),
        .ack_o(ic_ack), .err_o(ic_err), .flush_i(flush_i),
        .mem_addr_o(ic_mem_addr), .mem_dat_i(ic_mem_dat_i), .mem_sel_o(ic_mem_sel),
        .mem_we_o(ic_mem_we), .mem_cyc_o(ic_mem_cyc), .mem_stb_o(ic_mem_stb),
        .mem_ack_i(ic_mem_ack), .mem_err_i(ic_mem_err)
    );

    // dcache0's own ports.
    logic [63:0] dc_dat_o;
    logic        dc_ack, dc_err;
    logic [31:0] dc_mem_addr;
    logic [63:0] dc_mem_dat_o, dc_mem_dat_i;
    logic [7:0]  dc_mem_sel;
    // dc_mem_stb: see ic_mem_stb's own comment above -- same reasoning,
    // dcache.sv also always drives mem_cyc_o==mem_stb_o.
    /* verilator lint_off UNUSEDSIGNAL */
    logic        dc_mem_stb;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        dc_mem_we, dc_mem_cyc, dc_mem_ack, dc_mem_err;

    dcache #(.num_lines(num_lines), .line_words(line_words)) dcache0 (
        .clk(clk), .rst(rst),
        .addr_i(addr_i), .dat_i(dat_i), .dat_o(dc_dat_o), .sel_i(sel_i),
        .we_i(we_i), .cyc_i(cyc_i && !ifetch_i), .stb_i(stb_i && !ifetch_i),
        .ack_o(dc_ack), .err_o(dc_err),
        .mem_addr_o(dc_mem_addr), .mem_dat_o(dc_mem_dat_o), .mem_dat_i(dc_mem_dat_i),
        .mem_sel_o(dc_mem_sel), .mem_we_o(dc_mem_we), .mem_cyc_o(dc_mem_cyc), .mem_stb_o(dc_mem_stb),
        .mem_ack_i(dc_mem_ack), .mem_err_i(dc_mem_err)
    );

    /*
     * Latched at request-issue time -- see this module's own header for
     * why this can't race the sub-caches' own state transitions, and
     * design/wb_addr_decoder.sv's identical sel_uart_q for the same
     * underlying "remember which target an outstanding transaction
     * belongs to" reasoning.
     */
    logic active_ifetch_q;
    always_ff @(posedge clk) begin
        if (rst)
            active_ifetch_q <= 1'b0;
        else if (cyc_i && stb_i)
            active_ifetch_q <= ifetch_i;
    end

    assign ack_o = active_ifetch_q ? ic_ack   : dc_ack;
    assign err_o = active_ifetch_q ? ic_err   : dc_err;
    assign dat_o = active_ifetch_q ? ic_dat_o : dc_dat_o;

    /*
     * Downstream arbiter -- see this module's own header for the full
     * design (policy, starvation argument, why no change is needed in
     * icache.sv/dcache.sv).
     *
     * want_ic/want_dc read straight off each sub-cache's own
     * combinational mem_cyc_o (icache.sv/dcache.sv always drive
     * mem_cyc_o==mem_stb_o, so either alone is a complete "I want a
     * fresh downstream beat issued THIS cycle" signal). A cache denied
     * the grant simply presents want_* again next cycle -- its own
     * internal state is the pending-request queue, nothing else is
     * needed here.
     */
    wire want_ic = ic_mem_cyc;
    wire want_dc = dc_mem_cyc;

    // Fixed priority: dcache0 (the retiring instruction) wins ties.
    wire grant_dc = want_dc;
    wire grant_ic = want_ic && !want_dc;

    assign mem_addr_o = grant_dc ? dc_mem_addr : (grant_ic ? ic_mem_addr : 32'b0);
    assign mem_dat_o  = grant_dc ? dc_mem_dat_o : 64'b0; // icache0 never writes
    assign mem_sel_o  = grant_dc ? dc_mem_sel  : (grant_ic ? ic_mem_sel  : 8'b0);
    assign mem_we_o   = grant_dc ? dc_mem_we   : 1'b0;   // icache0 never writes
    assign mem_cyc_o  = grant_dc || grant_ic;
    assign mem_stb_o  = grant_dc || grant_ic;

    /*
     * mem_owner_ic_q: which sub-cache's request was actually FORWARDED
     * downstream on the immediately preceding cycle -- i.e. whose
     * response the next mem_ack_i/mem_err_i (wb4_sram.sv's own
     * one-cycle-latency response) belongs to. Updates on the exact same
     * edge a grant is made, mirroring active_ifetch_q's own "latches on
     * the same edge the routed traffic first appears" timing proof --
     * re-derived here for the DOWNSTREAM grant decision instead of the
     * core-facing request, since once dual-outstanding traffic is
     * possible those two are no longer the same event. Holds its value
     * on any cycle neither is granted -- harmless: on such a cycle
     * mem_cyc_o/mem_stb_o are already low, so wb4_sram.sv's own
     * registered ack_o/err_o for the following cycle is 0 regardless of
     * what mem_owner_ic_q says, the same "a stale latch value never
     * observably matters" property the old code already relied on.
     */
    logic mem_owner_ic_q;
    always_ff @(posedge clk) begin
        if (rst)
            mem_owner_ic_q <= 1'b0;
        else if (grant_ic || grant_dc)
            mem_owner_ic_q <= grant_ic;
    end

    // Each sub-cache only ever sees a real mem_ack_i/mem_err_i while it
    // was the one actually granted the downstream request that response
    // answers -- the other one's own downstream port is forced idle-
    // response (0), same "a gated-off master's response inputs don't
    // matter" convention the old code used, just re-keyed off
    // mem_owner_ic_q (the GRANT winner) instead of active_ifetch_q (the
    // CORE-FACING request winner) -- the two are no longer always the
    // same signal once dual-outstanding traffic is possible.
    assign ic_mem_ack   = mem_owner_ic_q ? mem_ack_i : 1'b0;
    assign ic_mem_err   = mem_owner_ic_q ? mem_err_i : 1'b0;
    assign ic_mem_dat_i = mem_dat_i;

    assign dc_mem_ack   = mem_owner_ic_q ? 1'b0 : mem_ack_i;
    assign dc_mem_err   = mem_owner_ic_q ? 1'b0 : mem_err_i;
    assign dc_mem_dat_i = mem_dat_i;
endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
