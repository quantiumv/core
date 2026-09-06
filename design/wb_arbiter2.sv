// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Module: wb_arbiter2
 *
 * A small, fixed-priority 2-master Wishbone arbiter (Milestone 8 of the
 * EBREAK/JTAG staged plan -- see [[dm-progbuf-milestone]] for Milestone 7).
 * Presents ONE arbitrated master-facing port downstream (to
 * design/wb_addr_decoder.sv, which needs no changes at all -- it only
 * ever sees a single master port regardless of how many real masters
 * exist upstream of it) and accepts two independent master ports
 * upstream: m0 (this project's own usage: core.sv's ordinary fetch/load/
 * store traffic) and m1 (this project's own usage: dm.sv's new System
 * Bus Access port, design/dm.sv's own o_sba_.../i_sba_... group).
 *
 * m1 has fixed priority over m0 -- justified because System Bus Access
 * is rare and debugger-invoked (a human or a debug script explicitly
 * requesting a memory peek/poke), while m0's ordinary CPU traffic is
 * frequent and latency-sensitive only in aggregate, not on any single
 * access; letting a rare, deliberate debug request jump ahead keeps the
 * debugger responsive at a negligible cost to overall throughput. This
 * is a policy choice specific to how THIS module is used in soc.sv, not
 * an inherent property of the module itself -- a different pairing of
 * masters might reasonably want the opposite priority, which is why the
 * ports are named m0/m1 (generic) rather than core/dm.
 *
 * A REAL, DATA-CORRUPTING BUG was found (and, in its first fix attempt,
 * only PARTLY fixed) during this module's own bring-up -- worth
 * understanding in full before touching this file again, since the
 * first, incomplete fix looked correct under standalone testing and
 * only failed under the real multi-instruction integration scenario:
 *
 * design/wb4_sram.sv (the real downstream slave, and the pattern every
 * slave in this project follows) computes `ack_o`/`err_o` as a PLAIN,
 * REGISTERED, ONE-CYCLE-DELAYED ECHO of `cyc_i && stb_i` -- it does no
 * edge-detection at all, so it re-asserts ack_o EVERY SINGLE CYCLE
 * cyc_i&&stb_i stays high, using whatever address is CURRENTLY on the
 * bus that cycle. A single ordinary master (core.sv with no arbiter)
 * relies on exactly this for its own back-to-back transactions to run
 * at 1-wait-state latency with zero gap. The subtler consequence: dm.sv's
 * SBA state machine holds cyc_i/stb_i asserted THROUGH the same cycle it
 * observes its own ack, only dropping them the cycle AFTER -- standard,
 * correct Wishbone master behavior (core.sv itself, notably, does NOT
 * follow this exact pattern -- see the fix's own comment below for why
 * that doesn't matter). Combined with wb4_sram's own re-ack behavior,
 * this means a master that holds cyc_i through its own ack cycle
 * ALWAYS produces a second, "ghost" ack one cycle after the real one --
 * not just when masters switch. In the single-master case this is
 * harmless: by the time the ghost arrives, that master has already
 * moved on to a different state and isn't consulting wb_ack_i anymore.
 * But an arbiter sitting between two masters has to actively decide who
 * a response belongs to, and an earlier version of this module decided
 * that using only `ack_i`'s own arrival to end a transaction
 * (`in_flight_q` clearing the instant ack_i/err_i was seen, with an
 * explicit one-cycle "turnaround" bubble forced on top whenever the
 * about-to-be-granted master differed from the last one) -- which
 * fixed the FIRST-order case (switching addresses with literally zero
 * idle cycle) but not this one: the GHOST ack arrives one cycle after
 * in_flight_q had ALREADY cleared and control had ALREADY passed to
 * whichever master `grant` defaults to when idle (m0), even if nobody
 * was actually requesting yet -- so core0 could receive a second
 * master's own stale, one-cycle-late response despite the turnaround
 * fix, and (once again) execute it as a bogus fetched instruction.
 * Confirmed by direct simulation trace showing mem_ack high with
 * mem_cyc already low and neither master's own cyc_i asserted that
 * cycle -- not just reasoned about.
 *
 * The real, sufficient fix: `in_flight_q` must stay set until the
 * GRANTED MASTER'S OWN cyc_i actually drops -- not merely until its
 * ack/err arrives. This is correct regardless of WHEN a given master
 * happens to drop cyc_i relative to its own ack (the same cycle, like
 * core.sv, or the cycle after, like dm.sv's SBA state machine) --
 * either way, `in_flight_q` simply tracks that master's own real
 * cyc_i, so it naturally stays set for exactly as long as that master
 * is still asserting anything at all, absorbing wb4_sram's own
 * guaranteed ghost response whenever one occurs, and clearing the
 * instant it doesn't. As a direct consequence, this ALSO gives any
 * newly-requesting different master the genuine cyc_i-low cycle it
 * needs before its own (different) address ever reaches the real
 * slave. This single fix subsumes the earlier, separate "turnaround on
 * switch" mechanism entirely -- that machinery (a `switching` wire and
 * a prev_switching_q register) has been removed, not left alongside
 * it; a from-scratch re-derivation showed it added complexity without
 * covering anything this fix doesn't already handle.
 *
 * A SEPARATE bug, found by adversarial review rather than simulation,
 * and fixed alongside the above: fixed-priority tie-breaking on an
 * idle cycle is exactly right for two INDEPENDENT masters, but core.sv's
 * own read-modify-write AMOs are not one bus transaction -- they are
 * TWO (S_MEM's read, then S_AMO_WRITE's write), glued together only by
 * core.sv's own FSM, with exactly one genuinely idle bus cycle in
 * between (wb_cyc_o drops the SAME cycle the read's ack arrives, since
 * it's gated by !wb_done; `state` only becomes S_AMO_WRITE the
 * following edge, and THAT state's own fresh wb_cyc_o=1 request appears
 * immediately, the same cycle). Right on that boundary cycle,
 * in_flight_q has already cleared (core0's own cyc_i was already low
 * the prior cycle) at the exact moment core0's OWN new write request
 * reappears -- a genuine tie against m1, which fixed priority resolves
 * in m1's favor, letting a debugger's own SBA access land physically
 * between an AMO's read and write and silently break the atomicity
 * RISC-V requires against every other bus agent. Fixed with a real
 * Wishbone B4 LOCK signal (m0_lock_i below) core.sv now drives across
 * exactly that two-phase span -- see core.sv's own wb_lock_o port
 * comment for the full derivation. m1 (SBA) has no equivalent concept
 * this milestone and simply ties m1_lock_i to its own ANSI default.
 *
 * Same-master back-to-back transactions (core.sv talking to itself,
 * dm0 idle -- the frequent, ordinary case) still incur ZERO added
 * latency: `in_flight_q` simply never has a reason to clear while the
 * SAME master keeps asserting cyc_i continuously (there being no other
 * master to switch to, `grant` never needs to move), exactly matching
 * the proven, existing non-arbitrated behavior. The cost of this fix
 * is paid only on an actual master handoff, which is rare precisely
 * because m1 (System Bus Access) itself is rare -- and even then, no
 * EXTRA cycle beyond what wb4_sram's own ghost response already forces
 * is spent; the fix simply stops mis-attributing that unavoidable
 * extra cycle to the wrong master.
 *
 * Two-part state, mirroring wb_addr_decoder.sv's own request/response
 * split:
 *   - `grant` (combinational): decides, EVERY cycle, which master's
 *     request to forward right now. While a transaction is latched in
 *     flight (in_flight_q), it holds onto whichever master in_flight_q
 *     says owns it, ignoring the other master's cyc_i entirely -- this
 *     is what makes "never switch masters mid-transaction" hold, and
 *     (per the fix above) extends automatically through the ghost-ack
 *     cycle too. While idle, it picks FRESH, this same cycle: m0_lock_i
 *     forces m0 (the AMO-atomicity fix above), else m1_lock_i forces m1
 *     (symmetric, unused by this project's own current wiring), else m1
 *     wins if requesting, else m0 -- zero added latency in the ordinary
 *     (unlocked) case, exactly like wb_addr_decoder.sv's own
 *     sel_ram/sel_uart/etc being a live, combinational function of
 *     addr_i, not a registered echo of it.
 *   - `in_flight_q`/`grant_q` (registered): latched the cycle a request
 *     actually starts (cyc_o&&stb_o while not already in flight), held
 *     until the GRANTED master's own cyc_i drops (not merely until
 *     ack_i/err_i arrives -- see above) -- lets `grant` know "am I
 *     mid-transaction, and with whom," the same role target_q plays
 *     for wb_addr_decoder.sv's own response routing.
 *
 * No starvation-avoidance logic (round-robin, priority aging, etc.) is
 * implemented, and none is needed for this project's own usage: m0
 * (core.sv) does not hold cyc_i asserted forever -- most instructions
 * spend at least one real cycle bus-idle (S_EXEC) between consecutive
 * fetches, confirmed by inspection -- so m1 is never permanently locked
 * out even under fixed priority.
 */
module wb_arbiter2 (
    input logic clk,
    input logic rst,

    // Master 0 -- lower priority (this project's own usage: core.sv).
    input  logic [31:0] m0_addr_i,
    input  logic [63:0] m0_dat_i,
    output logic [63:0] m0_dat_o,
    input  logic [7:0]  m0_sel_i,
    input  logic        m0_we_i,
    input  logic        m0_cyc_i,
    input  logic        m0_stb_i,
    output logic        m0_ack_o,
    output logic        m0_err_o,
    /*
     * m0_lock_i: a real Wishbone B4 LOCK signal (the spec's own optional
     * mechanism for exactly this) -- while high, an IDLE-cycle
     * arbitration decision must grant m0 unconditionally, even if m1 is
     * also requesting, overriding m1's own normal fixed-priority win.
     * See the module header's AMO-atomicity fix for why this exists and
     * core.sv's own wb_lock_o port comment for exactly when it's
     * asserted. Defaults to 1'b0 so a caller with no lock concept (any
     * hypothetical master besides core.sv) stays compile-clean without
     * wiring it, same precedent this project's own i_mtip/
     * i_debug_halt_req-style ports already established.
     */
    input  logic        m0_lock_i = 1'b0,

    // Master 1 -- higher priority (this project's own usage: dm.sv's
    // System Bus Access port).
    input  logic [31:0] m1_addr_i,
    input  logic [63:0] m1_dat_i,
    output logic [63:0] m1_dat_o,
    input  logic [7:0]  m1_sel_i,
    input  logic        m1_we_i,
    input  logic        m1_cyc_i,
    input  logic        m1_stb_i,
    output logic        m1_ack_o,
    output logic        m1_err_o,
    // m1_lock_i: symmetric to m0_lock_i above -- forces m1 to win an
    // idle-cycle arbitration decision unconditionally. Unused by this
    // project's own current wiring (dm.sv's SBA has no analogous
    // multi-phase-atomicity concept this milestone), kept for the same
    // generic-module reasoning m0/m1 naming itself already follows.
    input  logic        m1_lock_i = 1'b0,

    // Arbitrated (downstream) master port -- to wb_addr_decoder.sv.
    output logic [31:0] addr_o,
    output logic [63:0] dat_o,
    input  logic [63:0] dat_i,
    output logic [7:0]  sel_o,
    output logic        we_o,
    output logic        cyc_o,
    output logic        stb_o,
    input  logic        ack_i,
    input  logic        err_i,

    /*
     * o_grant: which master THIS cycle's live request-forwarding
     * decision (`grant` below) currently points at (0=m0, 1=m1) --
     * exposed so a consumer with its own out-of-band, per-transaction
     * side signal keyed to a SPECIFIC master (soc.sv's own wb_ifetch,
     * which is only ever meaningful for core.sv/m0's own traffic, never
     * for a System Bus Access) can gate that signal correctly instead
     * of reading whatever m0 happens to be driving regardless of which
     * master is actually being forwarded this cycle -- see soc.sv's own
     * comment at the point this output is consumed for the full
     * reasoning. Deliberately the COMBINATIONAL `grant`, not a
     * registered echo of it -- o_grant must be correct for the SAME
     * cycle cyc_o/addr_o carry a fresh request, not one cycle behind.
     */
    output logic o_grant
);
    /*
     * in_flight_q/grant_q: registered response-routing state, see the
     * module header for the exact clearing condition and why it must be
     * the granted master's own cyc_i dropping, not ack_i/err_i arriving.
     */
    logic in_flight_q;
    logic grant_q;

    // idle_grant: the fresh, this-cycle arbitration decision used only
    // when nothing is currently in flight. m0_lock_i overrides m1's own
    // normal tie-breaking priority -- see the module header's
    // AMO-atomicity fix -- m1_lock_i is the unused-by-this-project
    // symmetric case.
    wire idle_grant = m0_lock_i ? 1'b0 : (m1_lock_i ? 1'b1 : (m1_cyc_i ? 1'b1 : 1'b0));
    wire grant = in_flight_q ? grant_q : idle_grant;
    wire granted_cyc_i = grant ? m1_cyc_i : m0_cyc_i;

    assign cyc_o  = grant ? m1_cyc_i : m0_cyc_i;
    assign stb_o  = grant ? m1_stb_i : m0_stb_i;
    assign addr_o = grant ? m1_addr_i : m0_addr_i;
    assign dat_o  = grant ? m1_dat_i  : m0_dat_i;
    assign sel_o  = grant ? m1_sel_i  : m0_sel_i;
    assign we_o   = grant ? m1_we_i   : m0_we_i;

    assign o_grant = grant;

    always_ff @(posedge clk) begin
        if (rst) begin
            in_flight_q <= 1'b0;
            grant_q     <= 1'b0;
        end else if (in_flight_q) begin
            // Stay latched onto the SAME master until its own cyc_i
            // actually drops -- one cycle after its ack/err, per every
            // master's own established convention in this project --
            // not merely until ack_i/err_i first arrives. This is what
            // absorbs wb4_sram's own guaranteed one-cycle-late "ghost"
            // re-ack (see the module header) instead of misattributing
            // it to whichever master `grant` would otherwise default to.
            if (!granted_cyc_i) in_flight_q <= 1'b0;
        end else if (cyc_o && stb_o) begin
            in_flight_q <= 1'b1;
            grant_q     <= grant;
        end
    end

    // Response fan-out: both masters see dat_i unconditionally (harmless
    // for the non-granted one, which isn't watching for a response
    // anyway), but ack_o/err_o are gated so only the GRANTED master ever
    // sees a response meant for it. Uses the live `grant`, not grant_q --
    // the two are provably identical for the entire in-flight window
    // (grant collapses to grant_q exactly whenever in_flight_q is set,
    // by construction above), so this holds regardless of how many wait
    // states the downstream slave has, including a hypothetical
    // zero-wait-state one.
    assign m0_dat_o = dat_i;
    assign m1_dat_o = dat_i;
    assign m0_ack_o = !grant && ack_i;
    assign m1_ack_o =  grant && ack_i;
    assign m0_err_o = !grant && err_i;
    assign m1_err_o =  grant && err_i;
endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
