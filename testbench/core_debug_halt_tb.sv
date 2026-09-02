// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, the Milestone 4 halt/resume/step FSM and the
 * EBREAK->Debug-entry redirect.
 *
 * Six independent scenarios, one harness instance each (matching this
 * project's own established multi-DUT-per-file precedent, e.g.
 * testbench/core_interrupt_tb.sv):
 *
 *   dut_halt        -- an external i_debug_halt_req halts at the
 *                       retirement boundary immediately following an
 *                       in-flight LOAD's own completion (not mid-load),
 *                       dpc/dcsr.cause capture correctly, and resuming
 *                       continues execution from dpc -- including a
 *                       real, ordinary EBREAK (dcsr.ebreakm left at its
 *                       reset value 0) still trapping normally
 *                       afterward, proving Milestone 1's own
 *                       EBREAK-as-real-trap behavior is untouched when
 *                       the debug-entry feature isn't engaged.
 *   dut_step        -- single-stepping executes exactly one instruction
 *                       past a resume, then automatically re-halts
 *                       before the next one -- including a SECOND
 *                       consecutive resume with dcsr.step left set,
 *                       proving the sticky per-resume re-arm (not just
 *                       a one-shot) genuinely holds across more than
 *                       one step.
 *   dut_ebreakm     -- EBREAK itself redirects into Debug Mode (instead
 *                       of its ordinary synchronous trap) when
 *                       dcsr.ebreakm is set, repeatably across two
 *                       separate EBREAKs.
 *   dut_race        -- an external halt request and a pending, enabled
 *                       timer interrupt become eligible on the exact
 *                       same commit_now_q-timed boundary; proves
 *                       interrupt_taken's own new debug-halt exclusion
 *                       guard actually wins the tie (Debug Mode entry,
 *                       not an interrupt trap through mtvec).
 *   dut_div_race    -- a halt request arrives mid-divide (div_stall
 *                       held); proves debug_halt_req_entry can't land
 *                       until the divide's own commit_now actually
 *                       fires (its regfile write lands first), the same
 *                       timing guarantee already proven for
 *                       interrupt_taken in core_interrupt_tb.sv's own
 *                       Case 3, now proven for debug-halt too.
 *   dut_smode_ebreak -- EBREAK-to-debug from S-mode (not M), proving
 *                       ebreak_to_debug's current_priv-keyed mux
 *                       actually reads dcsr.ebreaks (bit 13) -- not
 *                       just dcsr.ebreakm -- and dcsr.prv correctly
 *                       captures PRIV_S on entry.
 *
 * dcsr.step/ebreakm/ebreaks are poked directly via a hierarchical backdoor
 * (dut_X.core0.csr_file0.dcsr_q), not set through a real CSR
 * instruction: no Debug Module or Program Buffer exists yet (later
 * milestones), so there is currently no real mechanism -- and, per this
 * module's own debug_csr_violation check, no LEGAL one from ordinary
 * code -- for software to write dcsr at all. This mirrors the project's
 * own established "poke DUT-internal state directly for test setup"
 * convention (e.g. hand-packing dut.sram0.memory[] for instructions),
 * generalized to a CSR register. Poked only at quiet points (before
 * reset deasserts, or while genuinely parked in S_DEBUG_HALTED with no
 * clocked write in flight), so there's no race with dcsr_q's own
 * always_ff.
 */
module core_debug_halt_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"
    // halt_wait.sv's own wait_halted_or_timeout task references a
    // caller-declared `halted` by name even when unused -- this file
    // uses its own per-DUT fork/wait/timeout blocks directly instead
    // (three independent harness instances, not one), so this is a
    // dummy satisfying that reference only, never itself driven.
    logic halted = 1'b0;
    `include "halt_wait.sv"

    /* ------------------------------------------------------------- *
     * dut_halt: external halt request, not-mid-load, dpc/cause
     * capture, resume-continues-from-dpc, ordinary EBREAK still traps
     * ------------------------------------------------------------- */

    logic rst_halt = 1;
    logic halt_req_drv = 1'b0;
    logic resume_req_drv = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_halt (
        .clk(clk), .rst(rst_halt),
        .i_debug_halt_req(halt_req_drv), .i_debug_resume_req(resume_req_drv)
    );

    // Asserts halt_req_drv once 3 instructions (the two addi's and the
    // sw) have retired -- i.e. while the 4th (the lw) is itself still
    // in flight, deliberately mid-instruction, to prove the halt can't
    // land before that load finishes. halt_armed makes this a one-shot
    // latch -- without it, this block would permanently re-force
    // halt_req_drv back to 1 every single cycle for the rest of the
    // simulation, fighting the initial block's own later deassertion
    // (a real bug caught empirically: it silently re-triggered a SECOND
    // halt right after the post-resume addi, before the EBREAK that was
    // supposed to run normally ever got a chance to).
    int halt_commit_count = 0;
    logic halt_armed = 1'b0;
    always @(posedge clk) begin
        if (dut_halt.core0.commit_now) halt_commit_count <= halt_commit_count + 1;
        if (halt_commit_count >= 3 && !halt_armed) begin
            halt_req_drv <= 1'b1;
            halt_armed   <= 1'b1;
        end
    end

    logic dut_halt_ebreak = 1'b0;
    always @(posedge clk)
        if (dut_halt.core0.trap_taken && dut_halt.core0.is_ebreak) dut_halt_ebreak <= 1'b1;

    /* ------------------------------------------------------------- *
     * dut_step: single-step executes exactly one instruction
     * ------------------------------------------------------------- */

    logic rst_step = 1;
    logic step_halt_req_drv = 1'b0;
    logic step_resume_req_drv = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_step (
        .clk(clk), .rst(rst_step),
        .i_debug_halt_req(step_halt_req_drv), .i_debug_resume_req(step_resume_req_drv)
    );

    logic dut_step_ebreak = 1'b0;
    always @(posedge clk)
        if (dut_step.core0.trap_taken && dut_step.core0.is_ebreak) dut_step_ebreak <= 1'b1;

    /* ------------------------------------------------------------- *
     * dut_ebreakm: EBREAK itself redirects to Debug Mode, repeatably,
     * when dcsr.ebreakm is set
     * ------------------------------------------------------------- */

    logic rst_ebreakm = 1;
    logic ebreakm_resume_req_drv = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_ebreakm (
        .clk(clk), .rst(rst_ebreakm),
        .i_debug_halt_req(1'b0), .i_debug_resume_req(ebreakm_resume_req_drv)
    );

    /* ------------------------------------------------------------- *
     * dut_race: external halt request races a pending, enabled timer
     * interrupt on the same commit_now_q-timed boundary -- debug-halt
     * must win (interrupt_taken's own new exclusion guard)
     * ------------------------------------------------------------- */

    logic rst_race = 1;
    logic race_halt_req_drv = 1'b0;
    logic i_mtip_race = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_race (
        .clk(clk), .rst(rst_race),
        .i_mtip(i_mtip_race),
        .i_debug_halt_req(race_halt_req_drv), .i_debug_resume_req(1'b0)
    );

    // Both driven non-blocking on the SAME commit edge (the marker's own
    // retirement at pc==0x18), mirroring core_interrupt_tb.sv's own
    // trigger-on-pc idiom -- both read 1 starting the very next cycle,
    // exactly when commit_now_q (hence both interrupt_taken and
    // debug_halt_req_entry) is evaluated, creating a genuine same-cycle
    // race between the two.
    always @(posedge clk) begin
        if (dut_race.core0.commit_now && dut_race.core0.pc == 64'h18) begin
            race_halt_req_drv <= 1'b1;
            i_mtip_race       <= 1'b1;
        end
    end

    /* ------------------------------------------------------------- *
     * dut_div_race: a halt request arrives mid-divide -- must wait for
     * the divide's own commit_now before landing, not preempt it
     * ------------------------------------------------------------- */

    logic rst_div_race = 1;
    logic div_race_halt_req_drv = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_div_race (
        .clk(clk), .rst(rst_div_race),
        .i_debug_halt_req(div_race_halt_req_drv), .i_debug_resume_req(1'b0)
    );

    // Fires the instant div_stall first goes high (genuinely mid-divide),
    // mirroring core_interrupt_tb.sv's own Case 3 exactly -- proves
    // int_pending_and_enabled-style eligibility becoming true DURING the
    // stall doesn't matter, since commit_now (hence commit_now_q, hence
    // debug_halt_req_entry) structurally can't fire until div_stall
    // clears.
    always @(posedge clk) begin
        if (dut_div_race.core0.div_stall) div_race_halt_req_drv <= 1'b1;
    end
    // White-box proof debug_halt_req_entry never asserts before the
    // divide's own commit -- no purely-architectural observable exists
    // for "held off during the stall" (a wrong x6 alone wouldn't
    // distinguish "correctly deferred" from "landed one cycle early but
    // the divide happened to still finish in time").
    logic div_race_committed = 1'b0;
    logic div_race_bad_early_halt = 1'b0;
    always @(posedge clk) begin
        if (dut_div_race.core0.commit_now && dut_div_race.core0.is_div_family)
            div_race_committed <= 1'b1;
        if (!div_race_committed && dut_div_race.core0.debug_halt_req_entry)
            div_race_bad_early_halt <= 1'b1;
    end

    /* ------------------------------------------------------------- *
     * dut_smode_ebreak: EBREAK-to-debug from S-mode -- proves
     * ebreak_to_debug's current_priv-keyed mux reads dcsr.ebreaks (bit
     * 13), not just dcsr.ebreakm, and dcsr.prv captures PRIV_S
     * ------------------------------------------------------------- */

    logic rst_smode = 1;
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_smode_ebreak (
        .clk(clk), .rst(rst_smode),
        .i_debug_halt_req(1'b0), .i_debug_resume_req(1'b0)
    );

    initial begin
        #1;

        /* ----------------------------------------------------------- *
         * dut_halt
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  addi x1,x0,77
         *  0x04  addi x2,x0,0x100
         *  0x08  sw   x1,0(x2)            mem[0x100] = 77 (3rd commit)
         *  0x0C  lw   x3,0(x2)            x3 <- 77 (4th commit -- halt_req
         *                                 held through this entire
         *                                 instruction's own S_MEM phase)
         *  0x10  addi x4,x0,999           must NOT execute before halt
         *  0x14  ebreak                   ordinary trap (ebreakm=0) --
         *                                 only reached after resume
         */
        dut_halt.sram0.memory[0] = {encode_i(32'sh100, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                     encode_i(32'sd77, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_halt.sram0.memory[1] = {encode_i(32'sd0, 5'd2, 3'b010, 5'd3, `OPC_LOAD),
                                     encode_s(32'sd0, 5'd1, 5'd2, 3'b010, `OPC_STORE)};
        dut_halt.sram0.memory[2] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                     encode_i(32'sd999, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_halt = 0;

        fork
            wait (dut_halt.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_halt never entered Debug Mode");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_halt: x3 == 77 -- the in-flight load completed normally, not aborted mid-instruction",
            dut_halt.core0.regfile0.gp_registers[3], 64'd77);
        check("dut_halt: x4 == 0 -- addi at 0x10 never executed, halt landed right after the load",
            dut_halt.core0.regfile0.gp_registers[4], 64'd0);
        check("dut_halt: o_debug_mode == 1", {63'b0, dut_halt.o_debug_mode}, 64'd1);
        check("dut_halt: dpc == 0x10 (the resume address, right after the load)",
            dut_halt.core0.dpc_w, 64'h10);
        check("dut_halt: dcsr.cause == 3 (haltreq)",
            {61'b0, dut_halt.core0.dcsr_w[8:6]}, 64'd3);

        // Deassert the halt request and resume -- execution should
        // continue from dpc (0x10) and run to a real, ordinary EBREAK.
        halt_req_drv = 1'b0;
        @(negedge clk);
        resume_req_drv = 1'b1;
        @(posedge clk); #1;
        resume_req_drv = 1'b0;

        fork
            wait (dut_halt_ebreak === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_halt never reached its post-resume EBREAK");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_halt: x4 == 999 -- execution resumed correctly from dpc",
            dut_halt.core0.regfile0.gp_registers[4], 64'd999);
        check("dut_halt: post-resume EBREAK traps normally (ebreakm=0), Milestone 1 untouched",
            {63'b0, dut_halt_ebreak}, 64'd1);
        check("dut_halt: o_debug_mode stays 0 -- the post-resume EBREAK is a real trap, not Debug re-entry",
            {63'b0, dut_halt.o_debug_mode}, 64'd0);

        /* ----------------------------------------------------------- *
         * dut_step
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  addi x1,x0,1
         *  0x04  addi x2,x0,2             the 1st stepped instruction
         *  0x08  addi x3,x0,3             the 2nd stepped instruction --
         *                                 proves the sticky re-arm holds
         *                                 across a SECOND consecutive
         *                                 resume with dcsr.step still 1
         *  0x0C  ebreak                   ordinary trap -- reached only
         *                                 after dcsr.step is cleared and
         *                                 a 3rd resume issued
         */
        step_halt_req_drv = 1'b1; // held from before reset -- halts after the very first instruction
        dut_step.sram0.memory[0] = {encode_i(32'sd2, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                     encode_i(32'sd1, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_step.sram0.memory[1] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                     encode_i(32'sd3, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_step = 0;

        fork
            wait (dut_step.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_step never entered Debug Mode (initial halt)");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_step: x1 == 1 -- the first instruction retired before halting",
            dut_step.core0.regfile0.gp_registers[1], 64'd1);
        check("dut_step: x2 == 0 -- halted before the second instruction",
            dut_step.core0.regfile0.gp_registers[2], 64'd0);

        // Arm single-step (dcsr.step, bit 2) and drop the plain halt
        // request so only stepping drives the next re-entry.
        step_halt_req_drv = 1'b0;
        dut_step.core0.csr_file0.dcsr_q[2] = 1'b1;
        @(negedge clk);
        step_resume_req_drv = 1'b1;
        @(posedge clk); #1;
        step_resume_req_drv = 1'b0;

        fork
            wait (dut_step.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_step never re-entered Debug Mode after stepping");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_step: x2 == 2 -- exactly the one stepped instruction executed",
            dut_step.core0.regfile0.gp_registers[2], 64'd2);
        check("dut_step: x3 == 0 -- re-halted before the instruction after the stepped one",
            dut_step.core0.regfile0.gp_registers[3], 64'd0);
        check("dut_step: dcsr.cause == 4 (step) on the re-entry",
            {61'b0, dut_step.core0.dcsr_w[8:6]}, 64'd4);

        // dcsr.step is left SET (not cleared) across this second resume
        // -- proves the re-arm in stepping_q's always_ff is a genuine
        // sticky, every-resume re-read of dcsr.step, not a one-shot that
        // only ever worked once.
        @(negedge clk);
        step_resume_req_drv = 1'b1;
        @(posedge clk); #1;
        step_resume_req_drv = 1'b0;

        fork
            wait (dut_step.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_step never re-entered Debug Mode after the 2nd consecutive step");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_step: x3 == 3 -- the sticky re-arm stepped a 2nd instruction across a 2nd resume",
            dut_step.core0.regfile0.gp_registers[3], 64'd3);
        check("dut_step: dcsr.cause == 4 (step) on the 2nd consecutive step re-entry",
            {61'b0, dut_step.core0.dcsr_w[8:6]}, 64'd4);

        // Clear dcsr.step (a real, sticky, software-controlled bit --
        // it would otherwise correctly keep re-arming single-stepping
        // on every resume, per spec) and resume once more. Execution
        // should continue normally (not step again) all the way to
        // EBREAK.
        dut_step.core0.csr_file0.dcsr_q[2] = 1'b0;
        @(negedge clk);
        step_resume_req_drv = 1'b1;
        @(posedge clk); #1;
        step_resume_req_drv = 1'b0;

        fork
            wait (dut_step_ebreak === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_step never reached its final EBREAK");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_step: final EBREAK traps normally", {63'b0, dut_step_ebreak}, 64'd1);

        /* ----------------------------------------------------------- *
         * dut_ebreakm
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  ebreak                   ebreakm=1 -> Debug Mode entry #1,
         *                                 dpc == 0x00 (the ebreak's own
         *                                 address, same as mepc would be
         *                                 for a synchronous trap)
         *  0x04  addi x1,x0,55            reached only after resume -- the
         *                                 test bumps dpc past the ebreak
         *                                 first, mirroring how a real
         *                                 debugger steps over a software
         *                                 breakpoint (resuming with dpc
         *                                 unchanged would just re-execute
         *                                 the same ebreak forever)
         *  0x08  ebreak                   ebreakm=1 -> Debug Mode entry #2,
         *                                 dpc == 0x08
         *  0x0C  addi x2,x0,66            never reached -- no 2nd resume
         */
        dut_ebreakm.sram0.memory[0] = {encode_i(32'sd55, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                        {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};
        dut_ebreakm.sram0.memory[1] = {encode_i(32'sd66, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                        {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        @(posedge clk); #1;
        rst_ebreakm = 0;
        // ebreakm, poked right as reset drops -- csr_file0's own reset
        // arm would otherwise wipe an earlier poke on the same edge it
        // deasserts (the exact same hazard the Debug CSR milestone's
        // own testbenches already learned from).
        dut_ebreakm.core0.csr_file0.dcsr_q[15] = 1'b1;

        fork
            wait (dut_ebreakm.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_ebreakm never entered Debug Mode on the first EBREAK");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_ebreakm: x1 == 0 -- redirected to Debug Mode at the very first EBREAK, nothing after it ran",
            dut_ebreakm.core0.regfile0.gp_registers[1], 64'd0);
        check("dut_ebreakm: dpc == 0x00 (the ebreak's own address)",
            dut_ebreakm.core0.dpc_w, 64'h00);
        check("dut_ebreakm: dcsr.cause == 1 (ebreak)",
            {61'b0, dut_ebreakm.core0.dcsr_w[8:6]}, 64'd1);

        // bump dpc past the ebreak before resuming, mirroring how a real
        // debugger steps over a software breakpoint (dpc is spec-legal
        // software-writable storage -- poked directly here since no CSR
        // access path exists yet; Program Buffer/Access Register are
        // later Debug Module milestones).
        dut_ebreakm.core0.csr_file0.dpc_q = 64'h04;

        @(negedge clk);
        ebreakm_resume_req_drv = 1'b1;
        @(posedge clk); #1;
        ebreakm_resume_req_drv = 1'b0;

        fork
            wait (dut_ebreakm.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_ebreakm never re-entered Debug Mode on the second EBREAK");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_ebreakm: x1 == 55 -- execution resumed and ran the instruction before the 2nd EBREAK",
            dut_ebreakm.core0.regfile0.gp_registers[1], 64'd55);
        check("dut_ebreakm: x2 == 0 -- redirected again at the 2nd EBREAK, the mechanism repeats",
            dut_ebreakm.core0.regfile0.gp_registers[2], 64'd0);
        check("dut_ebreakm: dpc == 0x08 (the 2nd ebreak's own address)",
            dut_ebreakm.core0.dpc_w, 64'h08);

        /* ----------------------------------------------------------- *
         * dut_race
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  addi x28,x0,128
         *  0x04  csrrw mtvec,x28          mtvec = 0x80 (never actually
         *                                 reached if the guard works)
         *  0x08  addi x28,x0,128
         *  0x0C  csrrw mie,x28            mie.MTIE = 1
         *  0x10  addi x28,x0,8
         *  0x14  csrrw mstatus,x28        mstatus.MIE = 1
         *  0x18  addi x1,x0,55            marker -- halt_req/i_mtip both
         *                                 asserted on THIS commit
         *  0x1C  addi x2,x0,66            must NOT execute if debug-halt
         *                                 wins the race (interrupt_taken
         *                                 would otherwise redirect here
         *                                 first)
         */
        dut_race.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_race.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_race.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_race.sram0.memory[3] = {encode_i(32'sd66, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                     encode_i(32'sd55, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};

        @(posedge clk); #1;
        rst_race = 0;

        fork
            wait (dut_race.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_race never entered Debug Mode");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_race: x1 == 55 -- the marker instruction retired before the race was decided",
            dut_race.core0.regfile0.gp_registers[1], 64'd55);
        check("dut_race: x2 == 0 -- the instruction after the marker never ran",
            dut_race.core0.regfile0.gp_registers[2], 64'd0);
        check("dut_race: dcsr.cause == 3 (haltreq) -- debug-halt won, not an interrupt",
            {61'b0, dut_race.core0.dcsr_w[8:6]}, 64'd3);
        check("dut_race: dpc == 0x1C -- the ordinary resume address, NOT mtvec (0x80)",
            dut_race.core0.dpc_w, 64'h1C);

        /* ----------------------------------------------------------- *
         * dut_div_race
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  addi x21,x0,7
         *  0x04  addi x20,x0,100
         *  0x08  div  x6,x20,x21          multi-cycle -- halt_req_drv
         *                                 asserted the instant div_stall
         *                                 first goes high, mid-divide
         *  0x0C  addi x9,x0,999           must NOT execute -- halt must
         *                                 land right after the divide's
         *                                 own commit, not run past it
         */
        dut_div_race.sram0.memory[0] = {encode_i(32'sd100, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM),
                                         encode_i(32'sd7, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM)};
        dut_div_race.sram0.memory[1] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM),
                                         encode_r(7'b0000001, 5'd21, 5'd20, 3'b100, 5'd6, `OPC_OP)};

        @(posedge clk); #1;
        rst_div_race = 0;

        fork
            wait (dut_div_race.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_div_race never entered Debug Mode");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_div_race: x6 == 14 -- the divide committed and wrote back before halting",
            dut_div_race.core0.regfile0.gp_registers[6], 64'd14);
        check("dut_div_race: x9 == 0 -- the instruction after the divide never ran",
            dut_div_race.core0.regfile0.gp_registers[9], 64'd0);
        check("dut_div_race: dcsr.cause == 3 (haltreq)",
            {61'b0, dut_div_race.core0.dcsr_w[8:6]}, 64'd3);
        check("dut_div_race: debug_halt_req_entry never asserted before the divide's own commit",
            {63'b0, div_race_bad_early_halt}, 64'd0);

        /* ----------------------------------------------------------- *
         * dut_smode_ebreak
         * ----------------------------------------------------------- */

        /*
         * addr  instr                     notes
         *  0x00  addi x28,x0,1
         *  0x04  slli x28,x28,11          x28 = mstatus.MPP field (S)
         *  0x08  csrrw mstatus,x28
         *  0x0C  addi x28,x0,0x18
         *  0x10  csrrw mepc,x28
         *  0x14  mret                     current_priv <- S, pc <- 0x18
         *  0x18  ebreak                   executed from S-mode; redirects
         *                                 to Debug Mode via dcsr.ebreaks
         *                                 (bit 13), not dcsr.ebreakm
         */
        dut_smode_ebreak.sram0.memory[0] = {encode_shift64(6'b0, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM),
                                             encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_ebreak.sram0.memory[1] = {encode_i(32'sh18, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),
                                             encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut_smode_ebreak.sram0.memory[2] = {`INSTR_HEX_MRET,
                                             encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut_smode_ebreak.sram0.memory[3] = {32'h0,
                                             {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        @(posedge clk); #1;
        rst_smode = 0;
        // ebreaks (bit 13), poked right as reset drops -- same
        // poke-after-reset hazard already learned from dut_ebreakm above.
        dut_smode_ebreak.core0.csr_file0.dcsr_q[13] = 1'b1;

        fork
            wait (dut_smode_ebreak.o_debug_mode === 1'b1);
            begin
                repeat (`TIMEOUT_CYCLES_SMALL) @(posedge clk);
                $display("TIMEOUT: dut_smode_ebreak never entered Debug Mode");
                $finish;
            end
        join_any
        disable fork; // kill the orphaned timeout branch -- join_any doesn't do this automatically
        #1;

        check("dut_smode_ebreak: dcsr.cause == 1 (ebreak) -- redirected via dcsr.ebreaks, not ebreakm",
            {61'b0, dut_smode_ebreak.core0.dcsr_w[8:6]}, 64'd1);
        check("dut_smode_ebreak: dcsr.prv == 01 (S) -- captured the actual privilege at entry",
            {62'b0, dut_smode_ebreak.core0.dcsr_w[1:0]}, 64'h1);
        check("dut_smode_ebreak: dpc == 0x18 (the ebreak's own address)",
            dut_smode_ebreak.core0.dpc_w, 64'h18);

        $display("");
        $display("core_debug_halt_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_debug_halt_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
