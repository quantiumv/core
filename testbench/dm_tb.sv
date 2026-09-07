// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: dm, driven entirely through its own plain register
 * interface (i_reg_addr/i_reg_wdata/i_reg_we/o_reg_rdata) via
 * dm_core_harness.sv -- the DMI backdoor this Milestone 5 gate calls
 * for, bypassing the real 41-bit DMI transport FSM entirely (a separate,
 * later Milestone 6 concern, design/dm_dmi.sv).
 *
 * Register addresses below mirror design/dm.sv's own localparam map
 * exactly (duplicated here rather than referenced hierarchically, to
 * keep this file's own intent legible without cross-referencing the DUT
 * source for every constant).
 *
 * Program (all 3 DUTs share this layout):
 *  0x00  addi x1,x0,10
 *  0x04  addi x2,x0,20
 *  0x08  addi x3,x0,30            halt lands here (dpc==0x08) -- exactly
 *                                  2 commits, so x1/x2 are both already
 *                                  set but x3 isn't yet
 *  0x0C  addi x4,x2,0             uses x2 -- proves a DM-mutated x2 is
 *                                  visible to code that runs AFTER resume
 *  0x10  ebreak                   ordinary trap, marks the end
 *
 * dut_basic proves: haltreq (via a real DMI write to dmcontrol) halts at
 * the expected boundary; dmstatus.allhalted/anyhalted/allrunning/
 * anyrunning track o_debug_mode correctly; an Access Register READ of
 * x1 returns 10 via data0/data1; an Access Register WRITE of x2=99 is
 * visible to x4 after a real resumereq-driven resume (proving the whole
 * DMI-write -> command -> register-mux -> resume chain works end to
 * end, not just that dm.sv's own storage bits move); an Access Register
 * CSR transfer (dscratch0, chosen since it has no side effects to
 * account for) round-trips a written value back out through a READ
 * command; abstractcs.busy is observed to pulse for exactly the cycle
 * after a legal command.
 *
 * dut_err proves: issuing a command while the hart is still RUNNING
 * (not halted) sets abstractcs.cmderr=4 (halt/resume) and performs no
 * transfer, and that writing 1 to cmderr's own field clears it (W1C).
 */
module dm_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    // halt_wait.sv's own wait_halted_or_timeout task references a
    // caller-declared `halted` by name even when unused -- this file
    // uses its own per-DUT fork/wait/timeout blocks directly instead,
    // matching core_debug_halt_tb.sv's own precedent (see that file for
    // the fuller rationale).
    logic halted = 1'b0;
    `include "halt_wait.sv"

    localparam [6:0] DMI_DATA0        = 7'h04;
    localparam [6:0] DMI_DATA1        = 7'h05;
    localparam [6:0] DMI_DMCONTROL    = 7'h10;
    localparam [6:0] DMI_DMSTATUS     = 7'h11;
    localparam [6:0] DMI_ABSTRACTCS   = 7'h16;
    localparam [6:0] DMI_COMMAND      = 7'h17;
    localparam [6:0] DMI_ABSTRACTAUTO = 7'h18;
    localparam [6:0] DMI_SBCS         = 7'h38;
    localparam [6:0] DMI_SBADDRESS0   = 7'h39;
    localparam [6:0] DMI_SBDATA0      = 7'h3C;
    localparam [6:0] DMI_SBDATA1      = 7'h3D;

    localparam [11:0] CSR_DSCRATCH0 = 12'h7B2;

    /* ------------------------------------------------------------- *
     * dut_basic
     * ------------------------------------------------------------- */

    logic rst_basic = 1;
    logic [6:0]  reg_addr_basic;
    logic [31:0] reg_wdata_basic;
    logic        reg_we_basic = 1'b0;
    logic [31:0] reg_rdata_basic;
    dm_core_harness #(.NUM_WORDS(32)) dut_basic (
        .clk(clk), .rst(rst_basic),
        .i_reg_addr(reg_addr_basic), .i_reg_wdata(reg_wdata_basic),
        .i_reg_we(reg_we_basic), .o_reg_rdata(reg_rdata_basic)
    );

    task automatic basic_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_basic  = addr;
        reg_wdata_basic = wdata;
        reg_we_basic    = 1'b1;
        @(posedge clk); #1;
        reg_we_basic    = 1'b0;
    endtask

    task automatic basic_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_basic = addr;
        #1;
        rdata = reg_rdata_basic;
    endtask

    // A dedicated always block, not inline polling in the initial block --
    // commit_now is combinational off `state`, so an inline
    // `@(posedge clk); if (commit_now) ...` in the initial block would
    // race the same edge's own NBA state update (this exact class of
    // race is why core_debug_halt_tb.sv's own dut_halt uses the same
    // always-block idiom instead of inline polling).
    int basic_commit_count = 0;
    always @(posedge clk) begin
        if (dut_basic.core0.commit_now) basic_commit_count <= basic_commit_count + 1;
    end

    /* ------------------------------------------------------------- *
     * dut_err
     * ------------------------------------------------------------- */

    logic rst_err = 1;
    logic [6:0]  reg_addr_err;
    logic [31:0] reg_wdata_err;
    logic        reg_we_err = 1'b0;
    logic [31:0] reg_rdata_err;
    dm_core_harness #(.NUM_WORDS(32)) dut_err (
        .clk(clk), .rst(rst_err),
        .i_reg_addr(reg_addr_err), .i_reg_wdata(reg_wdata_err),
        .i_reg_we(reg_we_err), .o_reg_rdata(reg_rdata_err)
    );

    task automatic err_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_err  = addr;
        reg_wdata_err = wdata;
        reg_we_err    = 1'b1;
        @(posedge clk); #1;
        reg_we_err    = 1'b0;
    endtask

    task automatic err_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_err = addr;
        #1;
        rdata = reg_rdata_err;
    endtask

    /* ------------------------------------------------------------- *
     * dut_progbuf -- Milestone 7's own Program Buffer execution,
     * proven via the same backdoor DMI interface as dut_basic/dut_err
     * (a real bit-banged run through the JTAG/DMI transport is
     * jtag_dmi_e2e_tb.sv's own job, mirroring how dut_basic's own
     * Access Register scenario already has that split).
     * ------------------------------------------------------------- */

    logic rst_progbuf = 1;
    logic [6:0]  reg_addr_progbuf;
    logic [31:0] reg_wdata_progbuf;
    logic        reg_we_progbuf = 1'b0;
    logic        reg_re_progbuf = 1'b0;  // Milestone 10a -- real read-strobe backdoor
    logic [31:0] reg_rdata_progbuf;
    dm_core_harness #(.NUM_WORDS(32)) dut_progbuf (
        .clk(clk), .rst(rst_progbuf),
        .i_reg_addr(reg_addr_progbuf), .i_reg_wdata(reg_wdata_progbuf),
        .i_reg_we(reg_we_progbuf), .i_reg_re(reg_re_progbuf), .o_reg_rdata(reg_rdata_progbuf)
    );

    task automatic progbuf_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_progbuf  = addr;
        reg_wdata_progbuf = wdata;
        reg_we_progbuf    = 1'b1;
        @(posedge clk); #1;
        reg_we_progbuf    = 1'b0;
    endtask

    task automatic progbuf_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_progbuf = addr;
        #1;
        rdata = reg_rdata_progbuf;
    endtask

    // Milestone 10a -- mirrors sba_dmi_read_re's own shape exactly (see
    // that task's comment for the real-transport timing this emulates).
    task automatic progbuf_dmi_read_re(input [6:0] addr, output [31:0] rdata);
        reg_addr_progbuf = addr;
        #1;
        rdata = reg_rdata_progbuf;
        reg_re_progbuf = 1'b1;
        @(posedge clk); #1;
        reg_re_progbuf = 1'b0;
    endtask

    localparam int PROGBUF_BUSY_RETRY_LIMIT = 100;

    // Polls abstractcs.busy (bit 12) until it clears -- a real Program
    // Buffer run takes many clk cycles (unlike an ordinary Access
    // Register transfer's own single-edge resolution), so this can't be
    // a single dmi_read the way dut_basic's own busy checks are.
    task automatic progbuf_wait_done();
        logic [31:0] rd;
        int tries;
        tries = 0;
        rd = 32'h0000_1000;  // seed with busy=1 so the loop runs at least once
        while (rd[12]) begin
            if (tries >= PROGBUF_BUSY_RETRY_LIMIT) begin
                $display("TIMEOUT: dut_progbuf busy never cleared");
                $finish;
            end
            @(posedge clk); #1;
            progbuf_dmi_read(DMI_ABSTRACTCS, rd);
            tries++;
        end
    endtask

    localparam [6:0] DMI_PROGBUF0 = 7'h20;
    localparam [6:0] DMI_PROGBUF1 = 7'h21;
    localparam [11:0] CSR_DPC_PB  = 12'h7B1;

    /* ------------------------------------------------------------- *
     * dut_sba -- Milestone 8's own System Bus Access, proven via the
     * same backdoor DMI interface as every other dut_* scenario above.
     * The one property none of dm_tb.sv's earlier scenarios needed to
     * prove -- a debugger accessing real memory has NOTHING to do with
     * whether the hart is halted -- is the whole point of this feature,
     * so this DUT is deliberately never halted at all: it just runs its
     * own program (a 200-iteration counting loop) from reset to its own
     * EBREAK while a sequence of SBA reads/writes lands concurrently.
     * ------------------------------------------------------------- */

    logic rst_sba = 1;
    logic [6:0]  reg_addr_sba;
    logic [31:0] reg_wdata_sba;
    logic        reg_we_sba = 1'b0;
    logic        reg_re_sba = 1'b0;  // Milestone 10a -- real read-strobe backdoor
    logic [31:0] reg_rdata_sba;
    dm_core_harness #(.NUM_WORDS(64)) dut_sba (
        .clk(clk), .rst(rst_sba),
        .i_reg_addr(reg_addr_sba), .i_reg_wdata(reg_wdata_sba),
        .i_reg_we(reg_we_sba), .i_reg_re(reg_re_sba), .o_reg_rdata(reg_rdata_sba)
    );

    // Mirrors basic_commit_count above -- used to catch x1's value at
    // EXACTLY its 50th update (see Test G below), deliberately NOT via
    // wait(trap_taken && is_ebreak): dut_sba's program never arms
    // dcsr.ebreakm, so its trailing EBREAK takes a REAL synchronous trap
    // (mtvec resets to 0), sending core0 right back into the SAME
    // counting loop instead of stopping -- a wait() on that pulse can
    // land on any lap, not just the first. Counting real commits is
    // race-free and doesn't care what happens after the 50th.
    int sba_commit_count = 0;
    always @(posedge clk) begin
        if (dut_sba.core0.commit_now) sba_commit_count <= sba_commit_count + 1;
    end

    task automatic sba_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_sba  = addr;
        reg_wdata_sba = wdata;
        reg_we_sba    = 1'b1;
        @(posedge clk); #1;
        reg_we_sba    = 1'b0;
    endtask

    task automatic sba_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_sba = addr;
        #1;
        rdata = reg_rdata_sba;
    endtask

    // Milestone 10a: a real read-strobe, mirroring design/dm_dmi.sv's own
    // o_reg_re timing (address held stable, then i_reg_re presented for
    // exactly one clock edge). Returns the PRE-retrigger value (matching
    // real hardware: o_reg_rdata for the read itself is combinational off
    // the value BEFORE this edge's own retrigger effect, if any, lands).
    task automatic sba_dmi_read_re(input [6:0] addr, output [31:0] rdata);
        reg_addr_sba = addr;
        #1;
        rdata = reg_rdata_sba;
        reg_re_sba = 1'b1;
        @(posedge clk); #1;
        reg_re_sba = 1'b0;
    endtask

    localparam int SBA_BUSY_RETRY_LIMIT = 100;

    // Mirrors progbuf_wait_done() -- a real SBA bus transaction is
    // multi-cycle, so polling sbcs.sbbusy (bit 21) in a loop is the only
    // correct way to wait for one to land.
    task automatic sba_wait_done();
        logic [31:0] rd;
        int tries;
        tries = 0;
        rd = 32'h0020_0000;  // seed with sbbusy=1 so the loop runs at least once
        while (rd[21]) begin
            if (tries >= SBA_BUSY_RETRY_LIMIT) begin
                $display("TIMEOUT: dut_sba sbcs.sbbusy never cleared");
                $finish;
            end
            @(posedge clk); #1;
            sba_dmi_read(DMI_SBCS, rd);
            tries++;
        end
    endtask

    // sbcs field packing helper -- {sbreadonaddr, sbaccess[2:0],
    // sbautoincrement, sbreadondata} at their real bit positions
    // ([20], [19:17], [16], [15]), everything else 0. Matches this
    // file's own established "build the exact bit layout at the call
    // site" idiom (e.g. the Access Register command word above) rather
    // than hiding the field positions behind named arguments.
    function automatic logic [31:0] sba_cfg(
        input logic readonaddr, input logic [2:0] access,
        input logic autoincrement, input logic readondata
    );
        return {11'b0, readonaddr, access, autoincrement, readondata, 15'b0};
    endfunction

    /* ------------------------------------------------------------- *
     * dut_amo_sba -- Milestone 8 review-fix regression: a real RMW AMO
     * (amoadd.d) is not one bus transaction -- it's two (S_MEM's read,
     * then S_AMO_WRITE's write), with one genuinely idle bus cycle in
     * between (wb_cyc_o drops the SAME cycle the read's own ack
     * arrives, since it's gated by !wb_done, but `state` only becomes
     * S_AMO_WRITE the FOLLOWING edge). Without core.sv's own wb_lock_o
     * (a real Wishbone B4 LOCK signal) holding the arbiter's grant
     * through that gap, a pending SBA transaction can win the fixed-
     * priority tie that arises right as the write's own fresh request
     * reappears, physically interleaving a debugger's own access
     * between the AMO's read and write -- silently breaking the
     * atomicity RISC-V requires against every other bus agent. See
     * design/wb_arbiter2.sv's own header and design/core.sv's
     * wb_lock_o port comment for the full derivation.
     *
     * Test design: the SBA write is deliberately staged (sbcs/
     * sbaddress0/sbdata1 written ahead of time) and its OWN triggering
     * write (sbdata0) is issued the instant dut_amo_sba.core0.wb_lock_o
     * is FIRST observed high -- i.e. the earliest possible cycle the
     * AMO's own read has started -- guaranteeing the SBA request is
     * genuinely pending during the AMO's entire locked window, not
     * racing to land before or after it by chance. Since the SBA
     * request can only start once wb_lock_o is already 1, the AMO's
     * own read is GUARANTEED to see the pre-existing value regardless
     * of whether the fix works (x6 == V0 either way) -- the real,
     * discriminating check is the FINAL memory value: with the fix
     * working, the SBA's own write is held off until the AMO fully
     * completes and so becomes the last writer (memory == W); with the
     * bug present, the SBA's write would land between the AMO's read
     * and write and then be silently overwritten by the AMO's own
     * (now-stale) computed sum (memory == V0+K instead).
     * ------------------------------------------------------------- */

    logic rst_amo_sba = 1;
    logic [6:0]  reg_addr_amo_sba;
    logic [31:0] reg_wdata_amo_sba;
    logic        reg_we_amo_sba = 1'b0;
    logic [31:0] reg_rdata_amo_sba;
    dm_core_harness #(.NUM_WORDS(64)) dut_amo_sba (
        .clk(clk), .rst(rst_amo_sba),
        .i_reg_addr(reg_addr_amo_sba), .i_reg_wdata(reg_wdata_amo_sba),
        .i_reg_we(reg_we_amo_sba), .o_reg_rdata(reg_rdata_amo_sba)
    );

    task automatic amo_sba_dmi_write(input [6:0] addr, input [31:0] wdata);
        reg_addr_amo_sba  = addr;
        reg_wdata_amo_sba = wdata;
        reg_we_amo_sba    = 1'b1;
        @(posedge clk); #1;
        reg_we_amo_sba    = 1'b0;
    endtask

    task automatic amo_sba_dmi_read(input [6:0] addr, output [31:0] rdata);
        reg_addr_amo_sba = addr;
        #1;
        rdata = reg_rdata_amo_sba;
    endtask

    task automatic amo_sba_wait_done();
        logic [31:0] rd;
        int tries;
        tries = 0;
        rd = 32'h0020_0000;
        while (rd[21]) begin
            if (tries >= SBA_BUSY_RETRY_LIMIT) begin
                $display("TIMEOUT: dut_amo_sba sbcs.sbbusy never cleared");
                $finish;
            end
            @(posedge clk); #1;
            amo_sba_dmi_read(DMI_SBCS, rd);
            tries++;
        end
    endtask

    localparam int AMO_SBA_T  = 32'h0000_01A0;  // target address (fits a 12-bit signed immediate)
    localparam int AMO_SBA_K  = 100;            // the AMOADD's own operand
    localparam int AMO_SBA_V0 = 500;            // pre-loaded original value at T
    localparam int AMO_SBA_W  = 12345;          // the SBA's own concurrent write value

    initial begin
        #1;

        /* ----------------------------------------------------------- *
         * dut_basic
         * ----------------------------------------------------------- */

        dut_basic.sram0.memory[0] = {encode_i(32'sd20, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                      encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_basic.sram0.memory[1] = {encode_i(32'sd0, 5'd2, 3'b000, 5'd4, `OPC_OP_IMM),
                                      encode_i(32'sd30, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut_basic.sram0.memory[2] = {32'h0,
                                      {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        @(posedge clk); #1;
        rst_basic = 0;

        // dmstatus before anything happens: running, not halted.
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_DMSTATUS, rd);
            check("dut_basic: dmstatus.anyrunning == 1 before any halt request", {63'b0, rd[10]}, 64'd1);
            check("dut_basic: dmstatus.anyhalted == 0 before any halt request", {63'b0, rd[8]}, 64'd0);
            check("dut_basic: dmstatus.authenticated == 1", {63'b0, rd[7]}, 64'd1);
            check("dut_basic: dmstatus.version == 2 (0.13/1.0)", {60'b0, rd[3:0]}, 64'd2);
            check("dut_basic: dmstatus.anynonexistent == 0 (single-hart, hart 0 exists)",
                {63'b0, rd[14]}, 64'd0);
        end

        // "Activate" the DM (real-debugger hygiene -- see dm.sv's own
        // header note on dmactive not yet gating anything functionally
        // this milestone) -- and read it back, proving dmcontrol_q's own
        // storage/read-mux arm actually works (every other dmcontrol
        // write in this file is only verified indirectly, through
        // downstream behavior like o_debug_mode/resume).
        basic_dmi_write(DMI_DMCONTROL, 32'h0000_0001);
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_DMCONTROL, rd);
            check("dut_basic: dmcontrol.dmactive == 1 after a plain DMI write", rd, 32'h0000_0001);
        end

        // abstractauto's own plain DMI write/read round trip still
        // deserves proof independent of its Milestone 10a functional bits
        // (a hidden address-decode bug here, e.g. aliasing ADDR_COMMAND or
        // ADDR_PROGBUF_LO, would otherwise ship silently): 0xCAFE_0000, not
        // 0xCAFE_0001 -- bits [1:0] (autoexecdata for data0/data1) are now
        // REAL (Milestone 10a), and dut_basic's own later Access Register
        // WRITE/CSR-round-trip tests below stage values through data0/
        // data1 too -- leaving bit 0 armed here would spuriously retrigger
        // this cycle's OWN stale command_q on every one of those later,
        // functionally-unrelated data0 accesses. The dedicated autoexecdata
        // functional tests (see the new section below) exercise bits [1:0]
        // deliberately, in isolation, then explicitly disarm them again.
        basic_dmi_write(DMI_ABSTRACTAUTO, 32'hCAFE_0000);
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTAUTO, rd);
            check("dut_basic: abstractauto round trips through a plain DMI write/read",
                rd, 32'hCAFE_0000);
        end

        // sbcs's access-width capability bits (real spec position,
        // [4:0] -- confirmed against riscv-debug-spec's own
        // xml/dm_registers.xml AND pulp-platform/riscv-dbg's own sbcs_t
        // struct, cross-checked when Milestone 8 gave System Bus Access
        // its real implementation): sbaccess8/16/32/64 are hardwired 1
        // (this core's 64-bit-wide Wishbone bus genuinely supports all
        // four), sbaccess128 is hardwired 0 (no natural 128-bit path).
        // Write all five bits plus an unrelated bit (bit 12, part of the
        // W1C sberror field) to confirm these capability bits are
        // fixed-function OUTPUTS, not real storage -- a debugger's own
        // write has no effect on them either way, and the unrelated bit
        // doesn't interfere with reading them back correctly.
        basic_dmi_write(DMI_SBCS, 32'h0000_101F);
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_SBCS, rd);
            check("dut_basic: sbcs reports sbaccess8/16/32/64 supported, sbaccess128 not",
                {59'b0, rd[4:0]}, 64'd15);
        end

        // Wait for the 1st real commit (addi x1,10), then request a halt
        // -- deliberately NOT timed to wait for commit #2 first.
        // basic_dmi_write's own DMI write takes a full clock edge to
        // land in dmcontrol_q; waiting until commit #2 had *already*
        // happened left no margin against core0's own commit_now_q
        // check for instruction #2's own retirement boundary
        // (empirically: it missed that boundary and landed one commit
        // later than intended, at instruction #3's). Requesting the
        // halt right after commit #1 instead gives the DMI write a full
        // instruction's worth of fetch latency as margin -- haltreq is
        // a LEVEL, so once dmcontrol_q captures it (long before
        // instruction #2 even starts fetching), it's still set by the
        // time instruction #2 actually commits, correctly catching
        // THAT boundary -- lands with dpc==0x08, x3 not yet run, same
        // as originally intended.
        while (basic_commit_count < 1) begin
            @(posedge clk); #1;
        end
        basic_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1

        fork
            wait (dut_basic.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_basic never halted");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_basic: x3 == 0 -- halted before the 3rd instruction",
            dut_basic.core0.regfile0.gp_registers[3], 64'd0);
        check("dut_basic: dpc == 0x08", dut_basic.core0.dpc_w, 64'h08);

        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_DMSTATUS, rd);
            check("dut_basic: dmstatus.allhalted == 1 while halted", {63'b0, rd[9]}, 64'd1);
            check("dut_basic: dmstatus.anyhalted == 1 while halted", {63'b0, rd[8]}, 64'd1);
            check("dut_basic: dmstatus.allrunning == 0 while halted", {63'b0, rd[11]}, 64'd0);
            check("dut_basic: dmstatus.anyrunning == 0 while halted", {63'b0, rd[10]}, 64'd0);
            check("dut_basic: dmstatus.allresumeack == 0 while halted", {63'b0, rd[17]}, 64'd0);
        end

        // cmderr == 2 (not supported): a command with aarsize=2 (32-bit)
        // while genuinely halted -- design/dm.sv only ever accepts
        // aarsize==3 (64-bit is the only width this core's GPRs/CSRs
        // support end to end), so this is guaranteed rejected.
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd2, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        #1;
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_basic: cmderr == 2 (not supported) -- aarsize=2 while halted",
                {61'b0, rd[10:8]}, 64'd2);
        end
        basic_dmi_write(DMI_ABSTRACTCS, {3'b0, 5'b0, 11'b0, 1'b0, 1'b0, 3'd2, 4'b0, 4'b0});  // W1C clear
        #1;
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_basic: cmderr == 0 after clearing the not-supported error",
                {61'b0, rd[10:8]}, 64'd0);
        end

        // cmderr == 1 (busy): two Access Register READ x1 commands issued
        // on CONSECUTIVE clock edges -- basic_dmi_write itself consumes
        // exactly one edge, so calling it twice in a row lands the 2nd
        // command write on the very edge busy_q (set by the 1st,
        // legal command) still reads 1, hitting dm.sv's busy_q branch
        // (cmderr_q<=3'd1) before cmd_legal's own !busy_q term would
        // otherwise let a 2nd, well-formed command through.
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        #1;
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_basic: cmderr == 1 (busy) -- 2nd command landed while the 1st was still busy",
                {61'b0, rd[10:8]}, 64'd1);
        end
        basic_dmi_write(DMI_ABSTRACTCS, {3'b0, 5'b0, 11'b0, 1'b0, 1'b0, 3'd1, 4'b0, 4'b0});  // W1C clear
        #1;
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_basic: cmderr == 0 after clearing the busy error",
                {61'b0, rd[10:8]}, 64'd0);
        end

        // Access Register READ x1 (regno 0x1001) -- aarsize=3 (64-bit),
        // transfer=1, write=0. Field layout (32 bits, matching design/
        // dm.sv's own decode exactly): {cmdtype[8], rsvd[1], aarsize[3],
        // aarpostincrement[1], postexec[1], transfer[1], write[1], regno[16]}.
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        #1;
        begin
            logic [31:0] rd;
            logic [31:0] busy_rd;
            basic_dmi_read(DMI_ABSTRACTCS, busy_rd);
            check("dut_basic: abstractcs.busy == 1 the cycle right after a legal command",
                {63'b0, busy_rd[12]}, 64'd1);
            basic_dmi_read(DMI_DATA0, rd);
            check("dut_basic: Access Register READ x1 -> data0 == 10", {32'b0, rd}, 64'd10);
            basic_dmi_read(DMI_DATA1, rd);
            check("dut_basic: Access Register READ x1 -> data1 == 0 (high half)", {32'b0, rd}, 64'd0);
            // basic_dmi_read is purely combinational (no clock edge) --
            // a real edge must elapse for busy_q to actually clear.
            @(posedge clk); #1;
            basic_dmi_read(DMI_ABSTRACTCS, busy_rd);
            check("dut_basic: abstractcs.busy == 0 one cycle later", {63'b0, busy_rd[12]}, 64'd0);
            check("dut_basic: abstractcs.cmderr == 0 (no error so far)", {61'b0, busy_rd[10:8]}, 64'd0);
        end

        // Access Register WRITE x2 = 99 (regno 0x1002) -- stage data0/1
        // first, then issue the command.
        basic_dmi_write(DMI_DATA0, 32'd99);
        basic_dmi_write(DMI_DATA1, 32'd0);
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b1, 16'h1002});
        #1;

        check("dut_basic: Access Register WRITE landed -- x2 == 99 (white-box)",
            dut_basic.core0.regfile0.gp_registers[2], 64'd99);

        // Access Register WRITE dscratch0 = 0xABCD (a CSR with no side
        // effects), then READ it back to prove the CSR path round-trips
        // independently of the GPR path just exercised above.
        basic_dmi_write(DMI_DATA0, 32'h0000_ABCD);
        basic_dmi_write(DMI_DATA1, 32'h0000_0000);
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b1,
                                       4'b0, CSR_DSCRATCH0});
        #1;
        basic_dmi_write(DMI_DATA0, 32'd0);  // clobber, so the next read can't coast on a stale value
        basic_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0,
                                       4'b0, CSR_DSCRATCH0});
        #1;
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_DATA0, rd);
            check("dut_basic: Access Register CSR round trip -- dscratch0 == 0xABCD",
                {32'b0, rd}, 64'h0000_ABCD);
        end

        // Resume -- execution continues from dpc (0x08): addi x3,30 then
        // addi x4,x2,0, which must see the MUTATED x2 (99), proving the
        // DM write is visible to code that runs after resume, not just
        // to a white-box peek taken while still halted.
        basic_dmi_write(DMI_DMCONTROL, 32'h4000_0001);  // resumereq=1, dmactive=1

        fork
            wait (dut_basic.core0.trap_taken && dut_basic.core0.is_ebreak);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_basic never reached its final EBREAK after resume");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_basic: x3 == 30 -- resumed and ran the instruction after the halt point",
            dut_basic.core0.regfile0.gp_registers[3], 64'd30);
        check("dut_basic: x4 == 99 -- sees the DM-mutated x2, not the original 20",
            dut_basic.core0.regfile0.gp_registers[4], 64'd99);

        /* ----------------------------------------------------------- *
         * dut_err: a command issued while running sets cmderr=4
         * ----------------------------------------------------------- */

        dut_err.sram0.memory[0] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),
                                    encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_err.sram0.memory[1] = {32'h0,
                                    {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        @(posedge clk); #1;
        rst_err = 0;

        // No haltreq ever asserted -- the hart is (and stays) running.
        // Issue a READ x1 command immediately.
        err_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1001});
        #1;
        begin
            logic [31:0] rd;
            err_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_err: cmderr == 4 (halt/resume) -- command issued while running",
                {61'b0, rd[10:8]}, 64'd4);
        end

        // Clear cmderr (W1C: write 1 to the field) and confirm it drops
        // back to 0.
        // abstractcs field layout (32 bits, matching design/dm.sv's own
        // spec-cross-checked layout): {rsvd[3], progbufsize[5], rsvd[11],
        // busy[1], relaxedpriv[1], cmderr[3], rsvd[4], datacount[4]} --
        // writing any nonzero value into the cmderr field clears it (W1C,
        // per spec).
        err_dmi_write(DMI_ABSTRACTCS, {3'b0, 5'b0, 11'b0, 1'b0, 1'b0, 3'd4, 4'b0, 4'b0});
        #1;
        begin
            logic [31:0] rd;
            err_dmi_read(DMI_ABSTRACTCS, rd);
            check("dut_err: cmderr == 0 after a W1C write", {61'b0, rd[10:8]}, 64'd0);
        end

        /* ----------------------------------------------------------- *
         * dut_progbuf
         * ----------------------------------------------------------- */

        /*
         * Program:
         *  0x00  addi x1,x0,10
         *  0x04  ebreak                   halt lands here (dpc==0x04) --
         *                                  1 commit's worth of margin,
         *                                  same reasoning as dut_basic
         */
        dut_progbuf.sram0.memory[0] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                        encode_i(32'sd10, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_progbuf = 0;

        // haltreq asserted IMMEDIATELY -- deliberately NOT delayed behind
        // a commit-count wait the way dut_basic's own halt request is.
        // debug_halt_req_entry structurally can't fire before the first
        // real commit_now anyway (it requires commit_now_q, itself a
        // one-cycle-deferred echo of a real commit_now pulse), so this
        // still lands the halt boundary right after instruction #0
        // retires (dpc==0x04) -- it does NOT fire one cycle earlier.
        // Waiting for a commit first (dut_basic's own pattern) would push
        // the boundary to land after commit #2 instead (the DMI write's
        // own latency margin, see dut_basic's comment above) -- but
        // commit #2 HERE is the program's own trailing ebreak itself,
        // which would then retire as a REAL synchronous trap (dcsr.ebreakm
        // defaults to 0) and redirect pc to mtvec (0) before
        // debug_halt_req_entry ever captures dpc -- exactly the dpc==0
        // bug this ordering avoids.
        progbuf_dmi_write(DMI_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1

        fork
            wait (dut_progbuf.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_progbuf never halted");
                $finish;
            end
        join_any
        disable fork;
        #1;

        check("dut_progbuf: dpc == 0x04 after the initial halt",
            dut_progbuf.core0.dpc_w, 64'h04);

        // Test A: postexec-only (transfer=0) -- run progbuf0/1 directly,
        // no register transfer involved.
        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd42, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM));  // addi x5,x0,42
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                   // ebreak
        // {cmdtype[8]=0, rsvd[1], aarsize[3]=3, aarpostincrement[1]=0,
        //  postexec[1]=1, transfer[1]=0, write[1]=0, regno[16]=0}
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        check("dut_progbuf: Test A -- x5 == 42 after a postexec-only run",
            dut_progbuf.core0.regfile0.gp_registers[5], 64'd42);
        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test A -- cmderr == 0 (success)", {61'b0, acs[10:8]}, 64'd0);
            // abstractcs.progbufsize (bits [28:24]) is real now (16 words,
            // not a stub) -- prove a debugger probing capabilities via DMI
            // actually sees that, not just that dm.sv's internal array
            // happens to be sized right (Test I below exercises the array
            // itself, all 16 slots).
            check("dut_progbuf: abstractcs.progbufsize == 16", {59'b0, acs[28:24]}, 64'd16);
        end
        check("dut_progbuf: Test A -- o_debug_mode stays 1 (never resumed)",
            {63'b0, dut_progbuf.o_debug_mode}, 64'd1);
        check("dut_progbuf: Test A -- dpc unchanged (still 0x04)",
            dut_progbuf.core0.dpc_w, 64'h04);

        // Test B: a GPR WRITE transfer combined with postexec -- the
        // transfer must land BEFORE the Program Buffer starts running.
        progbuf_dmi_write(DMI_DATA0, 32'd5);
        progbuf_dmi_write(DMI_DATA1, 32'd0);
        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd10, 5'd1, 3'b000, 5'd1, `OPC_OP_IMM));  // addi x1,x1,10
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                   // ebreak
        // transfer=1, write=1, postexec=1, regno=0x1001 (x1)
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b1, 1'b1, 16'h1001});
        progbuf_wait_done();

        check("dut_progbuf: Test B -- x1 == 15 (WRITE x1=5, then progbuf adds 10)",
            dut_progbuf.core0.regfile0.gp_registers[1], 64'd15);

        // Test C: a deliberate fault (illegal instruction) -- must abort
        // with cmderr=3, NOT a real trap, and mcause/mepc/dpc must stay
        // provably untouched.
        progbuf_dmi_write(DMI_PROGBUF0, 32'hFFFF_FFFF);  // guaranteed-illegal encoding
        // postexec=1, transfer=0 -- no trailing ebreak needed, it aborts
        // on this very instruction.
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test C -- cmderr == 3 (exception)", {61'b0, acs[10:8]}, 64'd3);
        end
        check("dut_progbuf: Test C -- o_debug_mode stays 1 (aborted back to Debug Mode, not a real trap)",
            {63'b0, dut_progbuf.o_debug_mode}, 64'd1);
        check("dut_progbuf: Test C -- dpc still unchanged (still 0x04)",
            dut_progbuf.core0.dpc_w, 64'h04);

        // Test C (continued): while cmderr is STILL 3 (not yet W1C-cleared),
        // prove cmd_legal's own (cmderr_q == 0) gate really blocks a brand
        // new postexec command, not just an ordinary Access Register
        // transfer (dut_err's own cmderr==4 scenario predates Milestone 7
        // and never exercises postexec at all). Reuses Test A's own
        // program, but targets x8 (untouched by every earlier test) so a
        // stray successful run would be unambiguous, not masked by a
        // register some other test already set to the same value.
        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd42, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM));  // addi x8,x0,42
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                   // ebreak
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        #1;
        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test C -- a new postexec command is rejected while cmderr==3 is still pending (busy stays 0)",
                {63'b0, acs[12]}, 64'd0);
            check("dut_progbuf: Test C -- cmderr stays 3 (the ORIGINAL error, not overwritten)",
                {61'b0, acs[10:8]}, 64'd3);
        end
        check("dut_progbuf: Test C -- x8 == 0 (the rejected command's own progbuf never actually ran)",
            dut_progbuf.core0.regfile0.gp_registers[8], 64'd0);

        // W1C-clear cmderr=3 before issuing any further command.
        progbuf_dmi_write(DMI_ABSTRACTCS, {3'b0, 5'b0, 11'b0, 1'b0, 1'b0, 3'd3, 4'b0, 4'b0});

        // Read mcause/mepc back via a normal Access Register CSR
        // transfer -- both must still read their reset value (0),
        // proving the abort never routed through the real trap path.
        begin
            logic [31:0] rd;
            // READ mcause (0x342)
            progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 4'b0, `CSR_MCAUSE});
            #1;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test C -- mcause == 0 (untouched by the abort)", {32'b0, rd}, 64'd0);
            // One extra edge before the next command write -- busy_q is
            // still 1 immediately after the mcause command above (it only
            // clears the cycle AFTER acceptance, same "busy for exactly
            // one cycle" precedent dut_basic's own busy check establishes
            // above), and issuing this write's own DMI edge too soon would
            // land it on that still-busy cycle, spuriously rejecting the
            // mepc read with cmderr=1 -- which would otherwise silently
            // carry into Test D's own command (dm.sv's cmderr is sticky
            // until explicitly W1C-cleared).
            @(posedge clk); #1;
            // READ mepc (0x341)
            progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b0, 4'b0, `CSR_MEPC});
            #1;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test C -- mepc == 0 (untouched by the abort)", {32'b0, rd}, 64'd0);
        end

        // Test D: a real CSR instruction (csrr x6,dpc) executed FROM the
        // Program Buffer -- closes the Milestone 3/4-deferred "inside-
        // Debug-Mode-legal dcsr/dpc/dscratch* access" test gap, which
        // needed exactly this (a real instruction stream, not a white-box
        // peek) and had no way to exist before this milestone.
        progbuf_dmi_write(DMI_PROGBUF0, encode_csr(CSR_DPC_PB, 5'd0, `FUNCT3_CSRRS, 5'd6, `OPC_SYSTEM));
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});  // ebreak
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test D -- cmderr == 0 (dpc CSR access is legal in Debug Mode)",
                {61'b0, acs[10:8]}, 64'd0);
        end
        check("dut_progbuf: Test D -- x6 == dpc's real value (0x04), read via a real CSR instruction",
            dut_progbuf.core0.regfile0.gp_registers[6], 64'h04);

        // Test E: a fault reached via S_MEM (a real LD past dut_progbuf's
        // own 32-word/256-byte sram range), not the S_EXEC-only
        // illegal-instruction path Test C already covers -- design/core.sv
        // added its OWN progbuf_abort arm to both the S_MEM and
        // S_AMO_WRITE branches of the state-transition always_ff
        // (distinct from S_EXEC's), so this proves that arm specifically:
        // a bug isolated to it would either hang progbuf_wait_done() below
        // (busy never clears) or silently fall through to S_FETCH and
        // corrupt dpc on the very next real fetch -- neither is caught by
        // Test C alone. No trailing ebreak needed -- it aborts on this one
        // instruction, once wb_err_i returns during S_MEM.
        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd256, 5'd0, 3'b011, 5'd7, `OPC_LOAD));  // ld x7,256(x0)
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test E -- cmderr == 3 (exception, reached via S_MEM not S_EXEC)",
                {61'b0, acs[10:8]}, 64'd3);
        end
        check("dut_progbuf: Test E -- o_debug_mode stays 1 (aborted back to Debug Mode)",
            {63'b0, dut_progbuf.o_debug_mode}, 64'd1);
        check("dut_progbuf: Test E -- dpc still unchanged (still 0x04)",
            dut_progbuf.core0.dpc_w, 64'h04);
        check("dut_progbuf: Test E -- x7 == 0 (the faulting load's own destination was never written)",
            dut_progbuf.core0.regfile0.gp_registers[7], 64'd0);
        progbuf_dmi_write(DMI_ABSTRACTCS, {3'b0, 5'b0, 11'b0, 1'b0, 1'b0, 3'd3, 4'b0, 4'b0});  // W1C clear

        // Test F: a register READ transfer combined with postexec (Test B
        // only ever exercised WRITE+postexec) -- the read must capture the
        // register's value from BEFORE the Program Buffer runs, not after.
        // Seed x2 with a known value via a plain postexec-only run first
        // (mirrors Test A's own pattern), then run a SECOND buffer that
        // mutates x2 while simultaneously reading its PRE-run value via
        // transfer=1/write=0.
        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd99, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM));  // addi x2,x0,99
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                   // ebreak
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd1, 5'd2, 3'b000, 5'd2, `OPC_OP_IMM));  // addi x2,x2,1
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                  // ebreak
        // transfer=1, write=0 (READ), postexec=1, regno=0x1002 (x2)
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b1, 1'b0, 16'h1002});
        progbuf_wait_done();

        begin
            logic [31:0] rd;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test F -- data0 == 99 (the READ captured x2's value BEFORE the run, not after)",
                {32'b0, rd}, 64'd99);
        end
        check("dut_progbuf: Test F -- x2 == 100 (the progbuf's own addi still ran, mutating the live register)",
            dut_progbuf.core0.regfile0.gp_registers[2], 64'd100);

        // Test I: fill all 16 progbuf words (progbuf0-14 = addi x9,x9,1,
        // progbuf15 = ebreak) -- every earlier test only ever used
        // progbuf0/1, leaving progbufsize's real value of 16 (see the
        // check next to Test A above) functionally unproven at the high
        // end of the range. x9 is untouched by every earlier test, so a
        // final value of exactly 15 proves all 15 addi words -- including
        // the one at progbuf14, right at the edge of the array -- actually
        // executed, and that progbuf_pc_q/the DM's own address decode both
        // genuinely reach index 15 (an off-by-one or truncated progbuf_q
        // declaration would either hang progbuf_wait_done() below or leave
        // x9 short of 15).
        for (int i = 0; i < 15; i++) begin
            progbuf_dmi_write(7'(DMI_PROGBUF0 + i[6:0]),
                encode_i(32'sd1, 5'd9, 3'b000, 5'd9, `OPC_OP_IMM));  // addi x9,x9,1
        end
        progbuf_dmi_write(7'(DMI_PROGBUF0 + 7'd15), {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});  // progbuf15 = ebreak
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        progbuf_wait_done();

        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test I -- cmderr == 0 (a full 16-word buffer ran cleanly)",
                {61'b0, acs[10:8]}, 64'd0);
        end
        check("dut_progbuf: Test I -- x9 == 15 (all 15 addi words, through progbuf14, actually executed)",
            dut_progbuf.core0.regfile0.gp_registers[9], 64'd15);

        /* ----------------------------------------------------------- *
         * Test J (Milestone 10a): abstractauto.autoexecdata bulk GPR
         * read -- a real per-access re-execution of the last command,
         * not just a storage bit. x20 (untouched by every earlier test
         * in this file) starts at 200; progbuf0/1 (overwriting Test I's
         * own content, safely -- nothing reads it again) hold
         * `addi x20,x20,1` + a trailing ebreak; the command combines a
         * READ transfer of x20 with postexec. Test F above already
         * proved a combined READ+postexec command captures the PRE-run
         * value into data0, so successive retriggers of THIS command
         * must read back a strictly increasing sequence (200, 201, 202)
         * if and only if each plain data0 read genuinely re-executes the
         * whole command again, not just re-reads stale storage.
         * ----------------------------------------------------------- */
        progbuf_dmi_write(DMI_DATA0, 32'd200);
        progbuf_dmi_write(DMI_DATA1, 32'd0);
        // transfer=1, write=1, postexec=0, regno=0x1014 (x20)
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1, 1'b1, 16'h1014});
        progbuf_wait_done();

        progbuf_dmi_write(DMI_PROGBUF0, encode_i(32'sd1, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM));  // addi x20,x20,1
        progbuf_dmi_write(DMI_PROGBUF1, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});                    // ebreak
        progbuf_dmi_write(DMI_ABSTRACTAUTO, 32'h0000_0001);  // arm autoexecdata for data0

        // transfer=1, write=0 (READ), postexec=1, regno=0x1014 (x20) --
        // issued once explicitly; every subsequent data0 read below
        // retriggers this exact same command_q again.
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b1, 1'b0, 16'h1014});
        progbuf_wait_done();
        begin
            logic [31:0] rd, unused;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test J -- autoexecdata read #1 == 200 (pre-run snapshot)", {32'b0, rd}, 64'd200);
            progbuf_dmi_read_re(DMI_DATA0, unused);  // this READ retriggers the command again
        end
        progbuf_wait_done();
        begin
            logic [31:0] rd, unused;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test J -- autoexecdata read #2 == 201 (reflects x20 mutated by the 1st retrigger)",
                {32'b0, rd}, 64'd201);
            progbuf_dmi_read_re(DMI_DATA0, unused);  // a SECOND, independent retrigger -- not a one-shot
        end
        progbuf_wait_done();
        begin
            logic [31:0] rd;
            progbuf_dmi_read(DMI_DATA0, rd);
            check("dut_progbuf: Test J -- autoexecdata read #3 == 202 (reflects the 2nd retrigger)",
                {32'b0, rd}, 64'd202);
        end
        check("dut_progbuf: Test J -- x20 == 203 (3 total command executions: 1 explicit + 2 retriggers)",
            dut_progbuf.core0.regfile0.gp_registers[20], 64'd203);

        /* ----------------------------------------------------------- *
         * Test K (Milestone 10a): a retrigger landing while a PRIOR
         * postexec run is still in flight must be refused exactly like
         * an ordinary command write would be (cmderr=1, busy) --
         * proving cmd_trigger_now shares cmd_legal's/cmderr_q's gate
         * uniformly, not a separate, unguarded path. Reprograms
         * progbuf0-8 with 9 straight-line addi's (instead of Test J's
         * single instruction) specifically to widen the busy window --
         * a postexec run can't finish in fewer clk cycles than it has
         * instructions to retire, giving the retrigger below a
         * deterministic (not raced) window to land in.
         * ----------------------------------------------------------- */
        for (int i = 0; i < 9; i++) begin
            progbuf_dmi_write(7'(DMI_PROGBUF0 + i[6:0]),
                encode_i(32'sd1, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM));  // addi x20,x20,1
        end
        progbuf_dmi_write(7'(DMI_PROGBUF0 + 7'd9), {11'b0, 1'b1, 13'b0, `OPC_SYSTEM});  // progbuf9 = ebreak
        // transfer=0 (no register transfer this time -- isolates the
        // busy-collision check from any transfer-related side effect),
        // postexec=1 -- starts a real, ~9-instruction-long run.
        progbuf_dmi_write(DMI_COMMAND, {8'h00, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 1'b0, 16'h0000});
        // Do NOT wait for it to finish -- read data0 (a retrigger, since
        // abstractauto is still armed from Test J) WHILE busy_q is
        // guaranteed still 1 (the run needs >= 9 more commit_now edges).
        begin
            logic [31:0] unused;
            progbuf_dmi_read_re(DMI_DATA0, unused);
        end
        // cmd_auto_retrigger_q's own effect on cmd_trigger_now (hence
        // cmderr_q/busy_q) is visible starting the CYCLE AFTER the read
        // strobe, not the same edge (standard NBA-update timing -- the
        // always_ff driving cmd_auto_retrigger_q and the one driving
        // cmderr_q both evaluate off cmd_auto_retrigger_q's OLD value at
        // the strobe's own edge). One extra edge here gives that a
        // chance to settle before checking -- still comfortably inside
        // the busy window established above.
        @(posedge clk); #1;
        begin
            logic [31:0] acs;
            progbuf_dmi_read(DMI_ABSTRACTCS, acs);
            check("dut_progbuf: Test K -- cmderr == 1 (busy) -- a retrigger while a prior run is still in flight is refused",
                {61'b0, acs[10:8]}, 64'd1);
        end
        progbuf_wait_done();  // let the original (non-retriggered) run finish
        progbuf_dmi_write(DMI_ABSTRACTCS, 32'h0000_0100);  // W1C-clear cmderr
        progbuf_dmi_write(DMI_ABSTRACTAUTO, 32'h0000_0000);  // disarm -- required hygiene, see dm_tb.sv's own dut_basic note

        /* ----------------------------------------------------------- *
         * dut_sba
         * ----------------------------------------------------------- */

        /*
         * Program: 50 straight-line `addi x1,x1,1` instructions (a
         * deliberately branch-free counting sequence -- no encode_b
         * needed, no backward-branch-timing subtlety to get right)
         * followed by a trailing EBREAK. Gives ~150-200+ real clk
         * cycles of "core0 is genuinely running" window to interleave
         * the SBA sequence below into, and an unambiguous final check
         * (x1 == 50) that core0's own execution wasn't corrupted or
         * stalled by any of that concurrent bus traffic.
         */
        for (int w = 0; w < 25; w++) begin  // 25 words = 50 addi instructions, 2 per 64-bit word
            dut_sba.sram0.memory[w] = {encode_i(32'sd1, 5'd1, 3'b000, 5'd1, `OPC_OP_IMM),
                                        encode_i(32'sd1, 5'd1, 3'b000, 5'd1, `OPC_OP_IMM)};
        end
        dut_sba.sram0.memory[25] = {32'h0, {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};  // ebreak, right after the loop

        @(posedge clk); #1;
        rst_sba = 0;
        // No haltreq anywhere in this scenario -- core0 runs freely from
        // reset to its own EBREAK. System Bus Access works precisely
        // BECAUSE it doesn't need the hart halted at all; that's the one
        // property no earlier dut_* scenario in this file could prove.

        // Test SBA-A: a 64-bit WRITE (sbaccess=3, using both sbdata0 and
        // sbdata1) to scratch address 0x180 -- comfortably beyond the
        // running program (which only occupies 0x000-0x0C7) and its
        // own trailing EBREAK (0x0C8), well within dut_sba's
        // NUM_WORDS=64 (0-511 byte) range. sbautoincrement=1 proves the
        // address-advance side of the feature in the same step.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b0, 3'd3, 1'b1, 1'b0));  // readonaddr=0, access=64-bit, autoincrement=1
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0180);              // plain address stage (readonaddr=0 -- no auto-read)
        sba_dmi_write(DMI_SBDATA1, 32'hCAFEBABE);                  // high half staged FIRST, per spec (see dm.sv's own header)
        sba_dmi_write(DMI_SBDATA0, 32'hDEADBEEF);                  // low half write -- THIS triggers the real bus write
        sba_wait_done();

        check("dut_sba: Test A -- memory[0x180] == the 64-bit value just written (white-box)",
            dut_sba.sram0.memory[32'h0000_0180 / 8], 64'hCAFEBABE_DEADBEEF);
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test A -- sberror == 0 (success)", {61'b0, rd[14:12]}, 64'd0);
            sba_dmi_read(DMI_SBADDRESS0, rd);
            check("dut_sba: Test A -- sbaddress0 auto-incremented by 8 (64-bit access width)",
                {32'b0, rd}, 64'h0000_0188);
        end

        // Test SBA-B: read the same location back over SBA (not just a
        // white-box memory peek) -- sbreadonaddr=1 so writing sbaddress0
        // itself triggers the read.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd3, 1'b0, 1'b0));  // readonaddr=1, access=64-bit, autoincrement=0
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0180);              // triggers the read
        sba_wait_done();

        begin
            logic [31:0] rd0, rd1;
            sba_dmi_read(DMI_SBDATA0, rd0);
            sba_dmi_read(DMI_SBDATA1, rd1);
            check("dut_sba: Test B -- sbdata0 == the low half read back over SBA", {32'b0, rd0}, 64'hDEADBEEF);
            check("dut_sba: Test B -- sbdata1 == the high half read back over SBA", {32'b0, rd1}, 64'hCAFEBABE);
        end

        // Test SBA-C: misalignment is rejected instantly, never
        // attempted on the bus -- access=32-bit (4-byte aligned
        // required), address 0x181 (misaligned by 1 byte).
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0181);
        begin
            logic [31:0] rd;
            #1;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test C -- sberror == 3 (misaligned), rejected instantly (sbbusy never even pulses)",
                {61'b0, rd[14:12]}, 64'd3);
        end
        sba_dmi_write(DMI_SBCS, 32'h0000_3000);  // W1C-clear sberror (bits [14:12])

        // Test SBA-D: an unsupported access width (128-bit, sbaccess=4)
        // is rejected with sberror=4, even at an otherwise-aligned
        // address.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd4, 1'b0, 1'b0));  // readonaddr=1, access=128-bit (unsupported)
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0180);
        begin
            logic [31:0] rd;
            #1;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test D -- sberror == 4 (not supported)", {61'b0, rd[14:12]}, 64'd4);
        end
        sba_dmi_write(DMI_SBCS, 32'h0000_3000);  // W1C-clear sberror

        // Test SBA-E: a genuine bus error -- address 0x1000 is well
        // beyond dut_sba's NUM_WORDS=64 (512-byte) range, so wb4_sram
        // itself returns err_o. Unlike Tests C/D (rejected instantly,
        // pre-bus), this DOES start a real transaction -- sba_wait_done()
        // must see sbbusy correctly clear once the error lands, not hang.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit, aligned
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_1000);
        sba_wait_done();
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test E -- sberror == 2 (bad address, a real bus error)", {61'b0, rd[14:12]}, 64'd2);
        end
        sba_dmi_write(DMI_SBCS, 32'h0000_3000);  // W1C-clear sberror

        // Test SBA-F: busy-collision -- two sbaddress0 writes issued on
        // consecutive edges (same idiom dut_basic's own cmderr==1 busy
        // test uses for Access Register commands above), the second
        // landing while the first's own read is still in flight.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0180);  // triggers the 1st read
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0184);  // 2nd write lands while the 1st is still busy
        begin
            logic [31:0] rd;
            #1;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test F -- sbbusyerror == 1 (2nd write collided with the 1st still in flight)",
                {63'b0, rd[22]}, 64'd1);
        end
        sba_wait_done();  // let the 1st (legitimate) op actually finish
        sba_dmi_write(DMI_SBCS, 32'h0040_0000);  // W1C-clear sbbusyerror (bit 22)

        // Test SBA-H (review-fix regression, closes a real coverage gap):
        // an sbaddress0 write while busy with sbreadonaddr==0 is a plain
        // address-staging write, not a trigger -- sba_new_op_requested
        // never sees it, so Test F's own coverage (which relies on
        // sbreadonaddr==1 to make the SECOND sbaddress0 write itself the
        // trigger sba_reject_as_busy_collision keys off) does NOT exercise
        // this path at all. Before the fix, this write-while-busy went
        // completely unflagged.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b0, 3'd2, 1'b0, 1'b0));  // readonaddr=0, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0188);  // stage the address (does NOT trigger)
        sba_dmi_write(DMI_SBDATA0, 32'hDEAD_BEEF);     // triggers the real write
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_018C);  // lands while the write above is still busy
        begin
            logic [31:0] rd;
            #1;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test H -- sbbusyerror == 1 (sbaddress0 write while busy, sbreadonaddr==0)",
                {63'b0, rd[22]}, 64'd1);
        end
        sba_wait_done();
        sba_dmi_write(DMI_SBCS, 32'h0040_0000);  // W1C-clear sbbusyerror
        check("dut_sba: Test H -- memory[0x188] == the write's own value (2nd sbaddress0 write was dropped, not applied)",
            dut_sba.sram0.memory[32'h188 / 8][31:0], 64'hDEAD_BEEF);

        // Test SBA-I (review-fix regression): sbcs/sbdata1 writes while
        // busy were already flagged by sba_other_write_while_busy before
        // this review round, but had no dedicated test distinguishing
        // this path from Test F's own sbaddress0-while-busy coverage.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_0190);  // triggers the read
        sba_dmi_write(DMI_SBDATA1, 32'hFFFF_FFFF);     // lands while busy -- dropped, flags sbbusyerror
        begin
            logic [31:0] rd;
            #1;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test I -- sbbusyerror == 1 (sbdata1 write while busy)",
                {63'b0, rd[22]}, 64'd1);
        end
        sba_wait_done();
        sba_dmi_write(DMI_SBCS, 32'h0040_0000);  // W1C-clear sbbusyerror

        // Test SBA-J (review-fix regression, closes a real coverage gap):
        // a non-zero-byte-offset SBA access -- every OTHER test in this
        // scenario uses byte offset 0 within its own 8-byte line, so none
        // of them can catch an off-by-shift-amount bug in the byte-lane
        // math (sba_effective_addr_low3/o_sba_sel/o_sba_dat's own <<
        // shift, sba_rdata_shifted's own >> shift). Proves an 8-bit
        // access at offset 2 touches ONLY its own byte, in both
        // directions.
        dut_sba.sram0.memory[32'h1A0 / 8] = 64'h1122334455667788;
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b0, 3'd0, 1'b0, 1'b0));  // readonaddr=0, access=8-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01A2);  // byte offset 2 within the line
        sba_dmi_write(DMI_SBDATA0, 32'h0000_00AB);     // triggers the write
        sba_wait_done();
        check("dut_sba: Test J -- non-zero-byte-offset SBA write only touches its own byte",
            dut_sba.sram0.memory[32'h1A0 / 8], 64'h1122334455AB7788);

        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd0, 1'b0, 1'b0));  // readonaddr=1, access=8-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01A2);  // triggers the read
        sba_wait_done();
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBDATA0, rd);
            check("dut_sba: Test J -- read-back at the same non-zero offset returns exactly that byte",
                {56'b0, rd[7:0]}, 64'hAB);
        end

        // Test SBA-K (review-fix regression, Finding #4): the
        // sbbusyerror_q W1C-clear priority race. A SINGLE sbcs write
        // landing WHILE an op is busy, whose OWN wdata ALSO has bit 22
        // set (a W1C-clear-sbbusyerror intent), must be interpreted as
        // the NEW busy-collision it itself causes, not silently
        // swallowed by its own coincidental clear bit -- see dm.sv's
        // sbbusyerror_q always_ff (hardware-set checked BEFORE the
        // software clear, mirroring cmderr_q's own precedent). Before
        // that fix (software-clear checked first), this exact write
        // would have left sbbusyerror at 0, hiding the very collision it
        // just caused. No filler edge needed: sba_busy_q is already 1
        // starting the cycle right after the trigger write lands, so the
        // very next DMI write (this one) samples it mid-transaction.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01B0);  // triggers a real read (busy window opens next edge)
        sba_dmi_write(DMI_SBCS, 32'h0040_0000);        // lands WHILE busy, own wdata[22]=1 -- the race itself
        sba_wait_done();
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test K -- sbbusyerror == 1 (the race's own hardware-set beats its own same-write clear bit)",
                {63'b0, rd[22]}, 64'd1);
        end
        sba_dmi_write(DMI_SBCS, 32'h0040_0000);  // W1C-clear sbbusyerror, tidy up

        // Test SBA-L (review-fix regression, Finding #4): sberror_q's
        // own version of the same race -- a REAL bus error landing on
        // the EXACT same edge a W1C-clear write to sbcs lands, proving
        // the hardware-set (a genuinely NEW error) wins over a same-
        // cycle software clear, distinct from Test K's simpler same-
        // write race. Timing derived from wb4_sram's own 1-wait-state
        // convention: the trigger write lands at edge N; sba_busy_q (and
        // o_sba_cyc) first read 1 starting N+1; the slave's own err_o
        // registers at edge N+1, becoming visible (and sberror_q's own
        // hardware-set firing) at edge N+2. One filler edge after the
        // trigger lands this write's own sampling on that exact edge.
        //
        // A precondition check (review-caught): the final sberror==2
        // result alone can't distinguish a GENUINE race from a mistimed
        // one that happens to look the same -- a clear-write landing ONE
        // EDGE TOO EARLY (before the real error has even registered)
        // would ALSO leave sberror==2 at the end, but for a completely
        // mundane, non-racing reason (the clear is a no-op against an
        // already-0 sberror_q, and the real error then latches, un-raced,
        // on the very next edge). Directly sampling i_sba_err right after
        // the filler edge -- i.e. the SAME cycle the race write is about
        // to land -- proves the race is genuinely live at this exact
        // moment, not one cycle off; a future change elsewhere that
        // shifts this timing by a cycle would fail THIS check loudly,
        // instead of silently downgrading the final check into an
        // accidental, non-discriminating pass.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd2, 1'b0, 1'b0));  // readonaddr=1, access=32-bit
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_1000);  // trigger -- out of range, a real bus error (edge N)
        @(posedge clk); #1;                             // filler (edge N+1)
        check("dut_sba: Test L -- precondition: i_sba_err is genuinely live the same cycle the race write is about to land",
            {63'b0, dut_sba.dm0.i_sba_err}, 64'd1);
        sba_dmi_write(DMI_SBCS, 32'h0000_3000);         // races the hardware-set at edge N+2
        sba_wait_done();
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBCS, rd);
            check("dut_sba: Test L -- sberror == 2 (the race's own hardware-set beats the same-cycle clear write)",
                {61'b0, rd[14:12]}, 64'd2);
        end
        // W1C-clear sberror AND sbbusyerror -- tidy up. The race write
        // above is itself an sbcs write landing while sba_busy_q is still
        // 1, so it also incidentally trips sba_other_write_while_busy,
        // setting sbbusyerror_q=1 as a side effect (review-caught,
        // harmless -- nothing else in this file reads dut_sba's sbcs
        // again -- but cleaned up here rather than left dangling).
        sba_dmi_write(DMI_SBCS, 32'h0040_3000);

        /* ----------------------------------------------------------- *
         * Test M/N (Milestone 10a): sbreadondata -- a real auto-
         * triggered read on every plain sbdata0 READ, not just a
         * storage/readback bit. 3 fresh dwords (0x1C0/0x1C8/0x1D0 --
         * every earlier dut_sba test above tops out at 0x1B0) so there's
         * no risk of colliding with earlier test state.
         * ----------------------------------------------------------- */
        // Address staged FIRST, then data1, then data0 (which triggers)
        // -- matches Test A's own established order exactly. Getting
        // this backwards (data0 before the address) would trigger the
        // write against whatever STALE address happened to be in
        // sbaddress0_q already, not the intended one.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b0, 3'd3, 1'b0, 1'b0));  // plain address stage, 64-bit, no auto-read
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01C0);
        sba_dmi_write(DMI_SBDATA1, 32'h0000_0000);
        sba_dmi_write(DMI_SBDATA0, 32'h1111_1111);  // triggers the write
        sba_wait_done();
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01C8);
        sba_dmi_write(DMI_SBDATA1, 32'h0000_0000);
        sba_dmi_write(DMI_SBDATA0, 32'h2222_2222);
        sba_wait_done();
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01D0);
        sba_dmi_write(DMI_SBDATA1, 32'h0000_0000);
        sba_dmi_write(DMI_SBDATA0, 32'h3333_3333);
        sba_wait_done();

        // Test M: sbreadonaddr=1, sbautoincrement=1, sbreadondata=1,
        // 64-bit -- one sbaddress0 write triggers word 0's read; 2 plain
        // sbdata0 READS (via the new real read-strobe) pull words 1 and
        // 2 with NO explicit re-trigger in between -- the direct proof
        // multi-word SBA reads now work.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd3, 1'b1, 1'b1));
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01C0);  // triggers word 0's read
        sba_wait_done();
        begin
            logic [31:0] rd, unused;
            sba_dmi_read(DMI_SBDATA0, rd);
            check("dut_sba: Test M -- sbreadondata word 0 == 0x11111111", {32'b0, rd}, 64'h1111_1111);
            sba_dmi_read_re(DMI_SBDATA0, unused);  // the read ITSELF triggers word 1's fetch
        end
        sba_wait_done();
        begin
            logic [31:0] rd, unused;
            sba_dmi_read(DMI_SBDATA0, rd);
            check("dut_sba: Test M -- sbreadondata auto-advanced to word 1 == 0x22222222 after one plain read",
                {32'b0, rd}, 64'h2222_2222);
            sba_dmi_read_re(DMI_SBDATA0, unused);
        end
        sba_wait_done();
        begin
            logic [31:0] rd;
            sba_dmi_read(DMI_SBDATA0, rd);
            check("dut_sba: Test M -- sbreadondata auto-advanced to word 2 == 0x33333333 after a second plain read",
                {32'b0, rd}, 64'h3333_3333);
        end

        // Test N (regression): sbreadondata==0 -- a plain sbdata0 read
        // (still through the real i_reg_re strobe, proving the strobe
        // itself is harmless when the gate is off, not just that the
        // feature works when it's on) must NOT auto-advance.
        sba_dmi_write(DMI_SBCS, sba_cfg(1'b1, 3'd3, 1'b1, 1'b0));  // sbreadondata=0 now
        sba_dmi_write(DMI_SBADDRESS0, 32'h0000_01C0);  // re-trigger word 0's read
        sba_wait_done();
        begin
            logic [31:0] rd, unused;
            sba_dmi_read_re(DMI_SBDATA0, unused);
            sba_dmi_read(DMI_SBDATA0, rd);
            check("dut_sba: Test N -- sbreadondata==0 -- a plain sbdata0 read does not auto-advance",
                {32'b0, rd}, 64'h1111_1111);
        end

        // Test SBA-G (the milestone's own core gate): confirm core0
        // reached its own, correct final state -- x1 == 50, exactly its
        // 50th update -- completely unaffected by every SBA operation
        // above, ALL of which landed while core0 was actively executing
        // its own counting loop, never halted. Waits on sba_commit_count
        // (see its own comment above for why, not a bare
        // wait(trap_taken && is_ebreak) on the trailing EBREAK itself --
        // dcsr.ebreakm is never armed in this scenario, so that EBREAK
        // takes a real trap back to the same loop rather than stopping,
        // and a level wait on it could land on any lap).
        // A plain polling loop (mirroring basic_commit_count's own usage
        // above), NOT a bare wait() -- a bare wait(sba_commit_count>=50)
        // can resume the instant the counter's own NBA update becomes
        // true, with no guarantee that regfile0's OWN sibling NBA update
        // (x1's actual write, scheduled by a DIFFERENT always block off
        // the SAME commit_now edge) has already settled -- the identical
        // class of "checking a signal one edge too early" hazard
        // testbench/wb_driver.sv's own header documents in detail for
        // ack_o. @(posedge clk); #1; after the condition is already true
        // guarantees a full settle past that edge first.
        while (sba_commit_count < 50) begin
            @(posedge clk); #1;
        end

        check("dut_sba: Test G -- x1 == 50 -- core0's own loop finished correctly, undisturbed by concurrent SBA traffic",
            dut_sba.core0.regfile0.gp_registers[1], 64'd50);

        /* ----------------------------------------------------------- *
         * dut_amo_sba
         * ----------------------------------------------------------- */

        // Program: 8x "addi x1,x1,1" padding (gives the testbench room to
        // stage the SBA's own config via DMI *after* reset deasserts --
        // dm0 shares dut_amo_sba's single rst input with core0, so any DMI
        // write issued before deassertion has no lasting effect), then the
        // real sequence: addi x7,x0,T ; addi x5,x0,K ; amoadd.d x6,x5,(x7) ; ebreak
        for (int i = 0; i < 4; i++) begin
            dut_amo_sba.sram0.memory[i] = {encode_i(32'sd1, 5'd1, 3'b000, 5'd1, `OPC_OP_IMM),
                                            encode_i(32'sd1, 5'd1, 3'b000, 5'd1, `OPC_OP_IMM)};
        end
        dut_amo_sba.sram0.memory[4] = {encode_i(AMO_SBA_K, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                        encode_i(AMO_SBA_T, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM)};
        dut_amo_sba.sram0.memory[5] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                        encode_amo(`FUNCT5_AMOADD, 1'b0, 1'b0, 5'd5, 5'd7,
                                                    `FUNCT3_AMO_D, 5'd6, `OPC_AMO)};
        dut_amo_sba.sram0.memory[AMO_SBA_T / 8] = 64'(AMO_SBA_V0);

        @(posedge clk); #1;
        rst_amo_sba = 0;

        // Stage the SBA write's own config/address/high-data now that dm0
        // is out of reset -- the 8 padding instructions above guarantee
        // core0 is nowhere near the AMO yet (it's still working through
        // the filler), so this always lands well before wb_lock_o rises.
        amo_sba_dmi_write(DMI_SBCS, sba_cfg(1'b0, 3'd3, 1'b0, 1'b0));  // readonaddr=0, access=64-bit
        amo_sba_dmi_write(DMI_SBADDRESS0, AMO_SBA_T);
        amo_sba_dmi_write(DMI_SBDATA1, 32'h0);

        while (!dut_amo_sba.core0.wb_lock_o) begin
            @(posedge clk); #1;
        end
        amo_sba_dmi_write(DMI_SBDATA0, AMO_SBA_W);  // triggers the real SBA write
        amo_sba_wait_done();
        @(posedge clk); #1;

        check("dut_amo_sba: x6 == V0 -- the AMO's own read saw the pre-existing value (500)",
            dut_amo_sba.core0.regfile0.gp_registers[6], 64'd500);
        check("dut_amo_sba: memory[T] == W -- the SBA's own write landed AFTER the AMO fully completed, not lost between its read and write",
            dut_amo_sba.sram0.memory[AMO_SBA_T / 8], 64'd12345);

        $display("");
        $display("dm_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("dm_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
