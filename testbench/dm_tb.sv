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

        $display("");
        $display("dm_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("dm_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
