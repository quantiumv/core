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
    logic [31:0] reg_rdata_progbuf;
    dm_core_harness #(.NUM_WORDS(32)) dut_progbuf (
        .clk(clk), .rst(rst_progbuf),
        .i_reg_addr(reg_addr_progbuf), .i_reg_wdata(reg_wdata_progbuf),
        .i_reg_we(reg_we_progbuf), .o_reg_rdata(reg_rdata_progbuf)
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

        // abstractauto -- storage-only, no functional effect (see dm.sv's
        // own header), but its plain DMI write/read round trip still
        // deserves proof: a hidden address-decode bug here (e.g. aliasing
        // ADDR_COMMAND or ADDR_PROGBUF_LO) would otherwise ship silently.
        basic_dmi_write(DMI_ABSTRACTAUTO, 32'hCAFE_0001);
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_ABSTRACTAUTO, rd);
            check("dut_basic: abstractauto round trips through a plain DMI write/read",
                rd, 32'hCAFE_0001);
        end

        // sbcs's access-width mask: write all five sbaccess8/16/32/64/128
        // bits (the real spec position, [4:0] -- confirmed against
        // riscv-debug-spec's own xml/dm_registers.xml) plus some
        // unrelated bits elsewhere in the word, then confirm the masked
        // read reports NO access width supported (those 5 bits read 0)
        // -- proving SBCS_ACCESS_MASK actually clears the real capability
        // bits, not System Bus Access itself (still out of scope, M8).
        basic_dmi_write(DMI_SBCS, 32'h0000_101F);
        begin
            logic [31:0] rd;
            basic_dmi_read(DMI_SBCS, rd);
            check("dut_basic: sbcs reports no System Bus Access width supported",
                {59'b0, rd[4:0]}, 64'd0);
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

        $display("");
        $display("dm_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("dm_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
