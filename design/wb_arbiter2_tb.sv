// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


/*
 * Testbench: wb_arbiter2
 *
 * The fake slave here deliberately mirrors design/wb4_sram.sv's own
 * exact ack timing -- a plain, unconditional "ack_o <= cyc_i && stb_i"
 * every cycle, with NO edge-detection and NO gating on ack_o's own
 * prior value. Its own response data is DERIVED FROM THE ADDRESS it
 * received (`{32'hFEED_0000, addr_o}`), not a fixed per-master
 * constant, so a master receiving a response that doesn't match its
 * OWN just-issued address is directly, unambiguously detectable.
 *
 * Just as important: every place below that drives a master's request
 * HOLDS cyc/stb for one FULL extra cycle after observing its own
 * ack/err before dropping them -- matching every real master in this
 * project (core.sv, design/dm.sv's SBA state machine), which drop
 * cyc_i/stb_i via a REGISTERED FSM transition one cycle after the edge
 * their own ack arrived on, never sooner. An earlier version of this
 * testbench dropped cyc/stb via a plain blocking assignment immediately
 * upon observing the ack (no extra clock edge consumed at all) -- which
 * meant the fake slave here NEVER actually saw cyc_i&&stb_i held across
 * two consecutive edges, so it could never produce the second, "ghost"
 * ack wb4_sram's own real (unconditional, no-edge-detection) design
 * always produces for a genuine hardware master. That discrepancy is
 * exactly why this testbench's own earlier 33/33-passing run never
 * caught the real bug this module shipped with even after its first
 * (incomplete) fix -- see wb_arbiter2.sv's own header for the full
 * story of what that bug was and what actually fixes it. Getting
 * master timing right here isn't a style nicety: it's the difference
 * between a test that can catch this bug and one that structurally
 * cannot.
 */
module wb_arbiter2_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic [31:0] m0_addr, m1_addr;
    logic [63:0] m0_dat_i, m1_dat_i, m0_dat_o, m1_dat_o;
    logic [7:0]  m0_sel, m1_sel;
    logic        m0_we, m1_we, m0_cyc, m1_cyc, m0_stb, m1_stb;
    logic        m0_ack, m1_ack, m0_err, m1_err;
    logic        m0_lock, m1_lock;

    logic [31:0] addr_o;
    logic [63:0] dat_i, dat_o;
    logic [7:0]  sel_o;
    logic        we_o, cyc_o, stb_o, ack_i, err_i, grant;

    wb_arbiter2 dut (
        .clk(clk), .rst(rst),
        .m0_addr_i(m0_addr), .m0_dat_i(m0_dat_i), .m0_dat_o(m0_dat_o),
        .m0_sel_i(m0_sel), .m0_we_i(m0_we), .m0_cyc_i(m0_cyc), .m0_stb_i(m0_stb),
        .m0_ack_o(m0_ack), .m0_err_o(m0_err), .m0_lock_i(m0_lock),
        .m1_addr_i(m1_addr), .m1_dat_i(m1_dat_i), .m1_dat_o(m1_dat_o),
        .m1_sel_i(m1_sel), .m1_we_i(m1_we), .m1_cyc_i(m1_cyc), .m1_stb_i(m1_stb),
        .m1_ack_o(m1_ack), .m1_err_o(m1_err), .m1_lock_i(m1_lock),
        .addr_o(addr_o), .dat_o(dat_o), .dat_i(dat_i), .sel_o(sel_o), .we_o(we_o),
        .cyc_o(cyc_o), .stb_o(stb_o), .ack_i(ack_i), .err_i(err_i),
        .o_grant(grant)
    );

    // Fake slave: wb4_sram.sv-faithful 1-wait-state, unconditional
    // re-ack (see the module header for why this fidelity matters),
    // address-derived response data, plus a one-shot err mode a task
    // below can arm for the err-routing test.
    logic force_err;
    always @(posedge clk) begin
        if (rst) begin
            ack_i <= 1'b0; err_i <= 1'b0; dat_i <= 64'b0;
        end else if (cyc_o && stb_o) begin
            if (force_err) begin
                ack_i <= 1'b0;
                err_i <= 1'b1;
            end else begin
                ack_i <= 1'b1;
                err_i <= 1'b0;
                dat_i <= {32'hFEED_0000, addr_o};
            end
        end else begin
            ack_i <= 1'b0;
            err_i <= 1'b0;
        end
    end

    // Small backing memory for the write-path tests (Finding #8): a real
    // write must land the WRITING master's own data at the WRITING
    // master's own address, not get misattributed to the other master
    // mid-arbitration -- every prior test here only ever exercised
    // READS. Indexed directly by addr_o[31:28] -- every test address in
    // this file (both the pre-existing read-only ones and the new
    // write-path ones below) has a distinct top nibble, so this never
    // aliases two tests onto the same entry.
    logic [63:0] slave_mem [0:15];
    always @(posedge clk) begin
        if (cyc_o && stb_o && we_o && !force_err) begin
            slave_mem[addr_o[31:28]] <= dat_o;
        end
    end

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    initial begin
        m0_addr = 0; m0_dat_i = 0; m0_sel = 8'hFF; m0_we = 0; m0_cyc = 0; m0_stb = 0;
        m1_addr = 0; m1_dat_i = 0; m1_sel = 8'hFF; m1_we = 0; m1_cyc = 0; m1_stb = 0;
        m0_lock = 1'b0; m1_lock = 1'b0;
        force_err = 1'b0;
        @(posedge clk); #1;
        rst = 0;

        // Test 1: m0 alone -- zero-latency passthrough, m1 sees nothing,
        // and the response data genuinely matches m0's own address.
        @(negedge clk);
        m0_addr = 32'h1000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        #1;
        check("m0 alone: addr_o mirrors m0 immediately (zero latency)", {32'b0, addr_o}, {32'b0, 32'h1000_0000});
        check("m0 alone: cyc_o asserted immediately", {63'b0, cyc_o}, 64'd1);
        check("m0 alone: o_grant == 0 (m0)", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("m0 alone: m0_ack fires, m1_ack stays low", {63'b0, m0_ack, m1_ack}, 64'b10);
        check("m0 alone: m0_dat_o reflects m0's OWN address", m0_dat_o, {32'hFEED_0000, 32'h1000_0000});
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(negedge clk);

        // Test 2: m1 alone -- same shape, opposite master.
        @(negedge clk);
        m1_addr = 32'h2000_0000; m1_dat_i = 64'hB1B1B1B1_B1B1B1B1; m1_sel = 8'hFF; m1_we = 1'b0;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        #1;
        check("m1 alone: addr_o mirrors m1 immediately (zero latency)", {32'b0, addr_o}, {32'b0, 32'h2000_0000});
        check("m1 alone: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
        end
        check("m1 alone: m1_ack fires, m0_ack stays low", {63'b0, m1_ack, m0_ack}, 64'b10);
        check("m1 alone: m1_dat_o reflects m1's OWN address", m1_dat_o, {32'hFEED_0000, 32'h2000_0000});
        @(posedge clk); #1;
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(negedge clk);

        // Test 3: genuine tie -- both assert on the exact same idle
        // cycle. m1 must win, m0 must see NEITHER its addr forwarded nor
        // any ack, until m1's own transaction (INCLUDING the one extra
        // cycle it holds cyc/stb after its own ack, exactly like a real
        // master) has fully vacated the bus -- this is the direct
        // regression test for the real bug found here: without
        // in_flight_q correctly waiting for m1's own cyc_i to drop
        // (not just for ack_i to arrive), m0 would receive wb4_sram's
        // own guaranteed one-cycle-late "ghost" re-ack of m1's already-
        // completed transaction, misattributed to m0's own, different,
        // just-started request.
        @(negedge clk);
        m0_addr = 32'h3000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m1_addr = 32'h4000_0000; m1_dat_i = 64'hB1B1B1B1_B1B1B1B1; m1_sel = 8'hFF; m1_we = 1'b0;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        #1;
        check("tie-break: m1 wins -- addr_o is m1's address", {32'b0, addr_o}, {32'b0, 32'h4000_0000});
        check("tie-break: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
            // m0 must never see an ack of its own while m1's tied
            // transaction is still resolving.
            check("tie-break: m0_ack stays low throughout m1's transaction", {63'b0, m0_ack}, 64'd0);
        end
        check("tie-break: m1_dat_o reflects m1's OWN address, not m0's", m1_dat_o, {32'hFEED_0000, 32'h4000_0000});
        // m1's own ack has arrived -- it now holds cyc/stb for ONE MORE
        // cycle (matching real master timing) before dropping. THIS is
        // exactly the cycle wb4_sram's own ghost re-ack fires -- m0
        // must still see nothing.
        @(posedge clk); #1;
        check("tie-break: on m1's own ghost-ack cycle, m0_ack still stays low", {63'b0, m0_ack}, 64'd0);
        check("tie-break: addr_o still reflects m1 (grant hasn't moved yet)",
            {32'b0, addr_o}, {32'b0, 32'h4000_0000});
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(posedge clk); #1;
        // NOW m1 has genuinely vacated (cyc_i low). m0's own request
        // (still asserted the whole time) is granted immediately, with
        // its own genuinely fresh ack/data -- not m1's stale one.
        check("tie-break: once m1 truly vacates, m0 is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'h3000_0000});
        check("tie-break: o_grant == 0 (m0)", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("tie-break: m0_dat_o correctly reflects m0's OWN address, not m1's stale response",
            m0_dat_o, {32'hFEED_0000, 32'h3000_0000});
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(negedge clk);

        // Test 4: grant-holds-until-idle -- m0 starts alone; m1 shows up
        // wanting the bus WHILE m0's own transaction (including its own
        // post-ack holding cycle) is still resolving. The arbiter must
        // not switch to m1 until m0 has genuinely vacated (cyc_i low),
        // and m1 must then see its own correct data, not m0's stale
        // ghost response.
        @(negedge clk);
        m0_addr = 32'h5000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        #1;
        check("grant-holds: m0 granted immediately", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("grant-holds: m0_dat_o correctly reflects m0's OWN address", m0_dat_o, {32'hFEED_0000, 32'h5000_0000});
        // m1 shows up right as m0's own ack fires -- m0 still holds
        // cyc/stb for one more (ghost-ack) cycle.
        m1_addr = 32'h6000_0000; m1_dat_i = 64'hB1B1B1B1_B1B1B1B1; m1_sel = 8'hFF; m1_we = 1'b0;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        check("grant-holds: still m0 despite m1 now also asserting", {63'b0, grant}, 64'd0);
        @(posedge clk); #1;
        check("grant-holds: on m0's own ghost-ack cycle, m1_ack still stays low", {63'b0, m1_ack}, 64'd0);
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(posedge clk); #1;
        // m0 has genuinely vacated -- m1 (waiting the whole time) is
        // granted immediately, with zero further delay.
        check("grant-holds: once m0 truly vacates, m1 (waiting) is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'h6000_0000});
        check("grant-holds: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
        end
        check("grant-holds: m1_dat_o correctly reflects m1's OWN address, not m0's stale response",
            m1_dat_o, {32'hFEED_0000, 32'h6000_0000});
        @(posedge clk); #1;
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(negedge clk);

        // Test 5: same-master back-to-back transactions incur ZERO
        // added latency -- m0 issues a second, different-address
        // request with cyc/stb held continuously high (no drop at all
        // in between, exactly core.sv's own established convention),
        // and it must be serviced immediately, proving the fix didn't
        // regress the ordinary, frequent, single-master case into
        // paying an unnecessary bubble on every transaction.
        @(negedge clk);
        m0_addr = 32'h5100_0000; m0_cyc = 1'b1; m0_stb = 1'b1;
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        // Same master's own very next request, issued the same cycle
        // its prior ack fired, cyc/stb never dropped in between.
        m0_addr = 32'h5200_0000;
        @(posedge clk); #1;
        check("same-master back-to-back: no delay -- granted immediately",
            {32'b0, addr_o}, {32'b0, 32'h5200_0000});
        check("same-master back-to-back: o_grant stays 0 (m0), zero added latency", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("same-master back-to-back: m0_dat_o reflects the SECOND address",
            m0_dat_o, {32'hFEED_0000, 32'h5200_0000});
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(negedge clk);

        // Test 6: err routing -- the granted master's OWN err_o must
        // fire, its ack_o must not, and the other master must see
        // neither.
        force_err = 1'b1;
        @(negedge clk);
        m0_addr = 32'h7000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("err routing: m0_err fires", {63'b0, m0_err}, 64'd1);
        check("err routing: m0_ack stays low on an error response", {63'b0, m0_ack}, 64'd0);
        check("err routing: m1_err/m1_ack both stay low (not the granted master)",
            {62'b0, m1_err, m1_ack}, 64'b00);
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        force_err = 1'b0;
        // One more settle edge: m0_cyc/stb are still 1 going INTO the
        // edge above (the fake slave's own "ghost" re-err cycle), so
        // m0_err is still stale-true right after it. Without this extra
        // edge (where cyc_o&&stb_o genuinely reads 0), Test 7's own
        // `while (!m0_ack && !m0_err)` below would see m0_err already
        // true and exit before ever waiting for its OWN fresh response.
        @(posedge clk); #1;

        // Test 7: m0_lock_i -- the AMO-atomicity fix's own mechanism
        // (design/wb_arbiter2.sv's module header, and design/core.sv's
        // own wb_lock_o port comment, describe the real bug this closes:
        // a debugger's SBA request winning the exact idle cycle between
        // an AMO's read phase and its write phase). Direct arbiter-level
        // proof, independent of the whole-core dut_amo_sba integration
        // test in testbench/dm_tb.sv: with m0_lock_i asserted, m1 must
        // NOT win even though it's requesting on the very same idle
        // cycle m0 also starts -- the opposite of Test 3's own tie-break
        // result, proving the lock genuinely overrides m1's normal
        // fixed-priority win, not merely coinciding with it.
        @(negedge clk);
        m0_addr = 32'h8000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m1_addr = 32'h9000_0000; m1_dat_i = 64'hB1B1B1B1_B1B1B1B1; m1_sel = 8'hFF; m1_we = 1'b0;
        m0_lock = 1'b1;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        #1;
        check("m0_lock: m0 wins the tie despite m1 also requesting", {32'b0, addr_o}, {32'b0, 32'h8000_0000});
        check("m0_lock: o_grant == 0 (m0)", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
            // m1 must never see an ack of its own while m0's locked
            // transaction is still resolving -- the direct proof m1
            // didn't sneak in mid-lock.
            check("m0_lock: m1_ack stays low throughout m0's locked transaction", {63'b0, m1_ack}, 64'd0);
        end
        check("m0_lock: m0_dat_o reflects m0's OWN address, not m1's", m0_dat_o, {32'hFEED_0000, 32'h8000_0000});
        @(posedge clk); #1;  // m0's own ghost-ack cycle -- still locked, m1 still shut out.
        check("m0_lock: on m0's own ghost-ack cycle, m1_ack still stays low", {63'b0, m1_ack}, 64'd0);
        m0_cyc = 1'b0; m0_stb = 1'b0;
        m0_lock = 1'b0;  // the AMO's own two-phase span has ended -- release the lock.
        @(posedge clk); #1;
        // m0 has genuinely vacated AND released the lock -- m1 (waiting
        // the whole time) is granted immediately, same as an ordinary
        // (unlocked) grant-holds handoff.
        check("m0_lock: once released and m0 vacates, m1 (waiting) is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'h9000_0000});
        check("m0_lock: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
        end
        check("m0_lock: m1_dat_o correctly reflects m1's OWN address, not m0's stale response",
            m1_dat_o, {32'hFEED_0000, 32'h9000_0000});
        @(posedge clk); #1;
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(negedge clk);

        // Test 8: m1_lock_i -- the symmetric case (unused by this
        // project's own current wiring, but part of the module's own
        // generic contract -- see wb_arbiter2.sv's own m1_lock_i port
        // comment). m0 would normally win an UNLOCKED idle cycle when
        // m1 is NOT requesting at all, but here m1 asserts its own lock
        // one cycle before either master's cyc/stb goes live, so the
        // very first idle-cycle decision must still favor m1 the moment
        // it does start requesting, even against m0's normal (lower
        // priority in the unlocked case, but irrelevant once THIS lock
        // is live) request.
        @(negedge clk);
        m1_lock = 1'b1;
        m0_addr = 32'hA000_0000; m0_dat_i = 64'hA0A0A0A0_A0A0A0A0; m0_sel = 8'hFF; m0_we = 1'b0;
        m1_addr = 32'hB000_0000; m1_dat_i = 64'hB1B1B1B1_B1B1B1B1; m1_sel = 8'hFF; m1_we = 1'b0;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        #1;
        check("m1_lock: m1 wins the tie (m1_lock_i forces it)", {32'b0, addr_o}, {32'b0, 32'hB000_0000});
        check("m1_lock: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
            check("m1_lock: m0_ack stays low throughout m1's locked transaction", {63'b0, m0_ack}, 64'd0);
        end
        check("m1_lock: m1_dat_o reflects m1's OWN address, not m0's", m1_dat_o, {32'hFEED_0000, 32'hB000_0000});
        m1_cyc = 1'b0; m1_stb = 1'b0;
        m1_lock = 1'b0;
        @(posedge clk); #1;
        check("m1_lock: once released and m1 vacates, m0 (waiting) is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'hA000_0000});
        check("m1_lock: o_grant == 0 (m0)", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("m1_lock: m0_dat_o correctly reflects m0's OWN address, not m1's stale response",
            m0_dat_o, {32'hFEED_0000, 32'hA000_0000});
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(negedge clk);

        // Test 9: write-path tie-break (Finding #8) -- mirrors Test 3's
        // own read-based tie-break exactly, but with we_i=1 and DISTINCT
        // write data per master, checking the fake slave's own backing
        // memory (slave_mem, keyed by address) to directly prove the
        // WINNING master's own write data landed at the WINNING master's
        // own address -- not silently misattributed to the other master
        // mid-arbitration, the same class of bug the read-path tie-break
        // test already proves for reads. Every prior test in this file
        // only ever exercised reads.
        @(negedge clk);
        m0_addr = 32'hC000_0000; m0_dat_i = 64'hC0C0C0C0_C0C0C0C0; m0_sel = 8'hFF; m0_we = 1'b1;
        m1_addr = 32'hD000_0000; m1_dat_i = 64'hD1D1D1D1_D1D1D1D1; m1_sel = 8'hFF; m1_we = 1'b1;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        #1;
        check("write tie-break: m1 wins -- addr_o is m1's address", {32'b0, addr_o}, {32'b0, 32'hD000_0000});
        check("write tie-break: o_grant == 1 (m1)", {63'b0, grant}, 64'd1);
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
            check("write tie-break: m0_ack stays low throughout m1's transaction", {63'b0, m0_ack}, 64'd0);
        end
        check("write tie-break: m1's OWN write landed at m1's OWN address", slave_mem[4'hD], 64'hD1D1D1D1_D1D1D1D1);
        // m1's own ack has arrived -- it now holds cyc/stb for ONE MORE
        // cycle (matching real master timing, and Test 3's own read-path
        // precedent) before dropping. THIS is exactly the cycle
        // wb4_sram's own ghost re-ack fires -- m0 must still see nothing.
        @(posedge clk); #1;
        check("write tie-break: on m1's own ghost-ack cycle, m0_ack still stays low", {63'b0, m0_ack}, 64'd0);
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(posedge clk); #1;
        check("write tie-break: once m1 vacates, m0 is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'hC000_0000});
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("write tie-break: m0's OWN write landed at m0's OWN address, not overwriting m1's",
            slave_mem[4'hC], 64'hC0C0C0C0_C0C0C0C0);
        check("write tie-break: m1's earlier write is still intact, undisturbed by m0's later one",
            slave_mem[4'hD], 64'hD1D1D1D1_D1D1D1D1);
        @(posedge clk); #1;
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(negedge clk);

        // Test 10: write-path grant-holds (Finding #8) -- mirrors Test
        // 4's own grant-holds-until-idle scenario, but with writes: m0
        // starts a write alone, m1 shows up wanting the bus mid-
        // transaction, the arbiter must not switch until m0 has
        // genuinely vacated, and m1's own subsequent write must land at
        // ITS OWN address without corrupting m0's just-completed one.
        @(negedge clk);
        m0_addr = 32'hE000_0000; m0_dat_i = 64'hE2E2E2E2_E2E2E2E2; m0_sel = 8'hFF; m0_we = 1'b1;
        m0_cyc = 1'b1; m0_stb = 1'b1;
        #1;
        check("write grant-holds: m0 granted immediately", {63'b0, grant}, 64'd0);
        while (!m0_ack && !m0_err) begin
            @(posedge clk); #1;
        end
        check("write grant-holds: m0's OWN write lands at m0's OWN address", slave_mem[4'hE], 64'hE2E2E2E2_E2E2E2E2);
        m1_addr = 32'hF000_0000; m1_dat_i = 64'hF3F3F3F3_F3F3F3F3; m1_sel = 8'hFF; m1_we = 1'b1;
        m1_cyc = 1'b1; m1_stb = 1'b1;
        check("write grant-holds: still m0 despite m1 now also asserting", {63'b0, grant}, 64'd0);
        @(posedge clk); #1;
        check("write grant-holds: on m0's own ghost-ack cycle, m1_ack still stays low", {63'b0, m1_ack}, 64'd0);
        m0_cyc = 1'b0; m0_stb = 1'b0;
        @(posedge clk); #1;
        check("write grant-holds: once m0 vacates, m1 (waiting) is granted immediately",
            {32'b0, addr_o}, {32'b0, 32'hF000_0000});
        while (!m1_ack && !m1_err) begin
            @(posedge clk); #1;
        end
        check("write grant-holds: m1's OWN write lands at m1's OWN address",
            slave_mem[4'hF], 64'hF3F3F3F3_F3F3F3F3);
        check("write grant-holds: m0's earlier write is still intact, undisturbed by m1's later one",
            slave_mem[4'hE], 64'hE2E2E2E2_E2E2E2E2);
        @(posedge clk); #1;
        m1_cyc = 1'b0; m1_stb = 1'b0;
        @(negedge clk);

        $display("");
        $display("wb_arbiter2_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("wb_arbiter2_tb: FAILURES PRESENT");
        $finish;
    end

endmodule


/* ------------------------------------------------------------------------- */


/* End of file. */
