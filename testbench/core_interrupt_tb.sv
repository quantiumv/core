// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's machine-timer-interrupt-taking logic (Milestone 6),
 * hand-packed instructions via core_wb4_sram_harness -- same idiom as
 * core_priv_tb.sv, extended with `i_mtip` passthrough (see that harness's
 * own header for why a real port was added instead of a hierarchical
 * force/release).
 *
 * Nine independent DUT instances, one per required case -- NOT nine
 * phases of one continuous program. Every case needs its own precise
 * relationship between "when mie.MTIE/mstatus.MIE become enabled" and
 * "when i_mtip actually asserts", and since i_mtip is driven directly by
 * this testbench (not by any instruction the DUT executes), the two are
 * fully decoupled -- letting the SAME enable state serve two different
 * cases (e.g. masked vs. not) would require re-arming CSRs between
 * phases anyway, so nine small, independently-reasoned-about programs are
 * simpler and safer to get right than one long choreographed one.
 *
 * Common technique used by every "trigger"-shaped case (mepc x4, S-mode
 * routing): i_mtip starts at 0 (so mie/mstatus can be safely enabled
 * during setup with zero risk of a premature redirect), then a small
 * `always @(posedge clk)` block asserts i_mtip the instant
 * `core0.commit_now && core0.pc == TRIGGER_PC` -- i.e. on the exact edge
 * the chosen trigger instruction retires. Because that assignment is
 * non-blocking, i_mtip reads 1 starting the very next cycle -- exactly
 * the cycle interrupt_taken's own deferred check runs (see core.sv's
 * Interrupts section) -- with zero risk of firing one instruction early
 * (during setup) or one instruction late. Every case places a "poison"
 * marker instruction at the address the redirect must preempt, and every
 * case's handler reads the architectural mepc/mcause CSRs back into a
 * scratch register so the check below stays black-box (reading DUT
 * *architectural* state through the ISA, not just internal FSM wires) --
 * the DIV case additionally needs one small white-box monitor (see its
 * own comment) since "held off during a multi-cycle stall" has no
 * purely-architectural observable.
 *
 * mie.MTIE = bit 7 (128), mstatus.MIE = bit 3 (8), mstatus.MPIE = bit 7
 * (128 -- same numeric value as mie's MTIE bit, different CSR, no
 * relation), mstatus.MPP = bits[12:11] (2048 = S), mstatus.SIE = bit 1 (2).
 *
 * Case 5's own mtval_q check and Case 7 (mideleg[7]=1 delegation) both
 * close a real, review-confirmed gap: nothing originally exercised
 * either i_trap_val's mux-to-0-on-a-pure-interrupt (core.sv's resolved
 * "trap_val for a pure interrupt" design decision) or mti_to_s/
 * interrupt_to_s's =1 branch at all (mideleg was never written by any
 * test), so a real bug in either -- confirmed via mutation during
 * review, e.g. swapping mstatus_sie_w for mstatus_mie_w in mti_enabled's
 * delegated branch -- would have shipped completely undetected.
 */
module core_interrupt_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    localparam int TIMEOUT_CYCLES = 500;

    /* ----------------------------------------------------------------- *
     * Case 1: pending but masked via mie.MTIE=0 (mstatus.MIE=1, i_mtip=1
     * throughout) -- no redirect; program runs straight to its own
     * EBREAK, the "would-be handler" (at mtvec) never runs.
     * ----------------------------------------------------------------- */
    logic i_mtip_mask_mie = 1'b1;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mask_mie (.clk(clk), .rst(rst), .i_mtip(i_mtip_mask_mie));
    // Completion keyed on the program's own marker write (pc==0x10), NOT on
    // its trailing ebreak: since EBREAK now really traps, that ebreak would
    // bounce into mtvec (armed at 0x80, needed for the OTHER cases' real
    // interrupt redirects) and corrupt/loop -- see this milestone's own
    // core.sv changes and Case 6's own comment below for the full story.
    // A broken mask (interrupt fires anyway) means pc==0x10 is never
    // reached at all -- caught by the shared timeout below, not a hang.
    logic mask_mie_halted = 1'b0;
    always @(posedge clk) if (dut_mask_mie.core0.commit_now && dut_mask_mie.core0.pc == 64'h10) mask_mie_halted <= 1'b1;

    /* ----------------------------------------------------------------- *
     * Case 2: pending but masked via mstatus.MIE=0 (mie.MTIE=1, i_mtip=1
     * throughout) -- same shape, opposite mask bit.
     * ----------------------------------------------------------------- */
    logic i_mtip_mask_mstatus = 1'b1;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mask_mstatus (.clk(clk), .rst(rst), .i_mtip(i_mtip_mask_mstatus));
    // Same reasoning as mask_mie_halted above -- key on the marker write
    // (pc==0x10), not the trailing ebreak.
    logic mask_mstatus_halted = 1'b0;
    always @(posedge clk) if (dut_mask_mstatus.core0.commit_now && dut_mask_mstatus.core0.pc == 64'h10) mask_mstatus_halted <= 1'b1;

    /* ----------------------------------------------------------------- *
     * Case 3: multi-cycle DIV. mie.MTIE/mstatus.MIE enabled during setup
     * (i_mtip still 0, so nothing fires yet); i_mtip asserts the moment
     * div_stall first goes high (genuinely mid-divide, not at its
     * boundary) -- proves int_pending_and_enabled becoming true DURING
     * the stall doesn't matter, since commit_now (hence commit_now_q,
     * hence interrupt_taken) structurally can't fire until div_stall
     * clears. div_committed/bad_early_interrupt is the one white-box
     * monitor this file needs (no purely-architectural way to observe
     * "interrupt_taken never asserted before this specific commit").
     * ----------------------------------------------------------------- */
    logic i_mtip_div = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_div (.clk(clk), .rst(rst), .i_mtip(i_mtip_div));
    // Completion keyed on the handler's own marker write (pc==0x84, `addi
    // x11,1`), strictly before its own trailing ebreak at 0x88 -- see
    // Case 6's own comment below for why an ebreak-based signal is wrong
    // here now that EBREAK really traps (it would bounce back into mtvec
    // and re-execute this same handler, corrupting mepc/mcause).
    logic div_halted = 1'b0;
    // Point-in-time snapshot of x10 (mepc, read by the handler's own csrr
    // at pc==0x80, the instruction immediately before this marker) -- NOT
    // a live read at check() time, which would race a runaway bounce-back
    // loop through this same handler (see Case 6's own comment below for
    // the full story). Captured on the SAME edge as the completion latch.
    logic [63:0] div_x10_snap;
    always @(posedge clk) if (!div_halted && dut_div.core0.commit_now && dut_div.core0.pc == 64'h84) begin
        div_halted <= 1'b1;
        div_x10_snap <= dut_div.core0.regfile0.gp_registers[10];
    end
    always @(posedge clk) begin
        if (dut_div.core0.div_stall) i_mtip_div <= 1'b1;
    end
    logic div_committed = 1'b0;
    logic bad_early_interrupt = 1'b0;
    always @(posedge clk) begin
        if (dut_div.core0.commit_now && dut_div.core0.is_div_family) div_committed <= 1'b1;
        if (!div_committed && dut_div.core0.interrupt_taken) bad_early_interrupt <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 4a: mepc correctness -- ordinary ALU op as the just-retired
     * instruction. Expected mepc == TRIGGER_PC + 4 (pc_plus_len).
     * ----------------------------------------------------------------- */
    logic i_mtip_mepc_alu = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mepc_alu (.clk(clk), .rst(rst), .i_mtip(i_mtip_mepc_alu));
    // Keyed on the handler's own marker write (pc==0x84), not its trailing
    // ebreak -- see Case 6's own comment below for why.
    logic mepc_alu_halted = 1'b0;
    // Point-in-time snapshot of x10 (mepc) -- see Case 6's own comment
    // below for why a live read at check() time isn't safe.
    logic [63:0] mepc_alu_x10_snap;
    always @(posedge clk) if (!mepc_alu_halted && dut_mepc_alu.core0.commit_now && dut_mepc_alu.core0.pc == 64'h84) begin
        mepc_alu_halted <= 1'b1;
        mepc_alu_x10_snap <= dut_mepc_alu.core0.regfile0.gp_registers[10];
    end
    always @(posedge clk) begin
        if (dut_mepc_alu.core0.commit_now && dut_mepc_alu.core0.pc == 64'h18) i_mtip_mepc_alu <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 4b: mepc correctness -- JAL as the just-retired instruction.
     * Expected mepc == the JAL's own jump target (pc_rel_target), not
     * pc_plus_len.
     * ----------------------------------------------------------------- */
    logic i_mtip_mepc_jal = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mepc_jal (.clk(clk), .rst(rst), .i_mtip(i_mtip_mepc_jal));
    // Keyed on the handler's own marker write (pc==0x84), not its trailing
    // ebreak -- see Case 6's own comment below for why.
    logic mepc_jal_halted = 1'b0;
    // Point-in-time snapshot of x10 (mepc) -- see Case 6's own comment
    // below for why a live read at check() time isn't safe.
    logic [63:0] mepc_jal_x10_snap;
    always @(posedge clk) if (!mepc_jal_halted && dut_mepc_jal.core0.commit_now && dut_mepc_jal.core0.pc == 64'h84) begin
        mepc_jal_halted <= 1'b1;
        mepc_jal_x10_snap <= dut_mepc_jal.core0.regfile0.gp_registers[10];
    end
    always @(posedge clk) begin
        if (dut_mepc_jal.core0.commit_now && dut_mepc_jal.core0.pc == 64'h18) i_mtip_mepc_jal <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 4c: mepc correctness -- taken branch (BEQ x0,x0, always true)
     * as the just-retired instruction. Same shape as JAL: mepc ==
     * pc_rel_target.
     * ----------------------------------------------------------------- */
    logic i_mtip_mepc_branch = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mepc_branch (.clk(clk), .rst(rst), .i_mtip(i_mtip_mepc_branch));
    // Keyed on the handler's own marker write (pc==0x84), not its trailing
    // ebreak -- see Case 6's own comment below for why.
    logic mepc_branch_halted = 1'b0;
    // Point-in-time snapshot of x10 (mepc) -- see Case 6's own comment
    // below for why a live read at check() time isn't safe.
    logic [63:0] mepc_branch_x10_snap;
    always @(posedge clk) if (!mepc_branch_halted && dut_mepc_branch.core0.commit_now && dut_mepc_branch.core0.pc == 64'h84) begin
        mepc_branch_halted <= 1'b1;
        mepc_branch_x10_snap <= dut_mepc_branch.core0.regfile0.gp_registers[10];
    end
    always @(posedge clk) begin
        if (dut_mepc_branch.core0.commit_now && dut_mepc_branch.core0.pc == 64'h18) i_mtip_mepc_branch <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 4d: mepc correctness -- MRET as the just-retired instruction.
     * THE regression test for the systematic bug the whole one-cycle-
     * deferred design exists to avoid: mstatus is pre-armed MPIE=1/MIE=0
     * (so MIE only becomes visible AS MRET's own commit restores it --
     * exactly the "every MRET would fail to let an already-pending
     * interrupt preempt the very first instruction it returns to" defect
     * the deferred design's own header describes), mepc is pre-armed to
     * point at a poison marker, and i_mtip asserts on MRET's own commit
     * edge. The poison marker at MRET's return address must NEVER
     * execute (checked via its own distinctive register value staying
     * 0) -- proving genuine preemption, not "eventually taken".
     * ----------------------------------------------------------------- */
    logic i_mtip_mepc_mret = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mepc_mret (.clk(clk), .rst(rst), .i_mtip(i_mtip_mepc_mret));
    // Keyed on the handler's own marker write (pc==0x88, `addi x12,1`),
    // strictly before its own trailing ebreak at 0x8C -- see Case 6's own
    // comment below for why.
    logic mepc_mret_halted = 1'b0;
    // Point-in-time snapshot of x10 (mepc) and x11 (mcause) -- see Case 6's
    // own comment below for why a live read at check() time isn't safe.
    logic [63:0] mepc_mret_x10_snap, mepc_mret_x11_snap;
    always @(posedge clk) if (!mepc_mret_halted && dut_mepc_mret.core0.commit_now && dut_mepc_mret.core0.pc == 64'h88) begin
        mepc_mret_halted <= 1'b1;
        mepc_mret_x10_snap <= dut_mepc_mret.core0.regfile0.gp_registers[10];
        mepc_mret_x11_snap <= dut_mepc_mret.core0.regfile0.gp_registers[11];
    end
    always @(posedge clk) begin
        if (dut_mepc_mret.core0.commit_now && dut_mepc_mret.core0.pc == 64'h20) i_mtip_mepc_mret <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 5: interrupt taken from S-mode with mideleg[7]=0 (left at its
     * post-reset default -- never written) routes to M (mcause, not
     * scause; current_priv ends M), confirming mti_to_s's real
     * (not-hardwired-0) handling on the common, undelegated path. A
     * marker retires genuinely in S-mode first (mideleg bit 7 has no
     * bearing on WHEN the interrupt becomes visible -- an undelegated
     * higher-privilege interrupt is unconditionally enabled below M
     * regardless of the lower level's own mstatus bits, see
     * core.sv's mti_enabled), then i_mtip asserts on that marker's own
     * commit edge, same technique as every mepc case above.
     * ----------------------------------------------------------------- */
    logic i_mtip_smode = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_smode (.clk(clk), .rst(rst), .i_mtip(i_mtip_smode));
    // Keyed on the handler's own marker write (pc==0x84), not its trailing
    // ebreak -- see Case 6's own comment below for why.
    logic smode_halted = 1'b0;
    // Point-in-time snapshot of x10 (mcause) -- see Case 6's own comment
    // below for why a live read at check() time isn't safe.
    logic [63:0] smode_x10_snap;
    always @(posedge clk) if (!smode_halted && dut_smode.core0.commit_now && dut_smode.core0.pc == 64'h84) begin
        smode_halted <= 1'b1;
        smode_x10_snap <= dut_smode.core0.regfile0.gp_registers[10];
    end
    always @(posedge clk) begin
        if (dut_smode.core0.commit_now && dut_smode.core0.pc == 64'h28) i_mtip_smode <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 7: interrupt taken from S-mode with mideleg[7]=1 (delegated),
     * mstatus.SIE=1 -- routes to S (scause/sepc, not mcause/mepc;
     * current_priv stays/becomes S), exercising interrupt_to_s's =1
     * branch and mti_enabled's mti_to_s-delegated arm for the first time
     * anywhere in this milestone. mstatus's S-side fields (SIE/SPIE/SPP)
     * are untouched by MRET (confirmed by csr_file.sv's own mstatus_q
     * writer), so SIE must be armed BEFORE the MRET that enters S-mode,
     * in the same write as MPP=S (a plain CSR write fully replaces every
     * writable bit, not a merge -- same discipline core_priv_tb.sv/
     * priv_test.s already established for this exact field).
     * ----------------------------------------------------------------- */
    logic i_mtip_smode_deleg = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_smode_deleg (.clk(clk), .rst(rst), .i_mtip(i_mtip_smode_deleg));
    // Keyed on the S-mode handler's own marker write (pc==0xC8), not its
    // trailing ebreak -- see Case 6's own comment below for why.
    logic smode_deleg_halted = 1'b0;
    // Point-in-time snapshots -- see Case 6's own comment below for why a
    // live read at check() time isn't safe. EBREAK isn't delegated here
    // (medeleg is never programmed in this case, only mideleg), so this
    // handler's own trailing ebreak bounces to the UNWRITTEN mtvec=0x80
    // window once it fires -- snapshot everything the checks below read,
    // not just the obviously-CSR-sourced values, since what exactly that
    // stray fetch decodes to isn't worth relying on.
    logic [63:0] smode_deleg_x13_snap, smode_deleg_x14_snap;
    logic [1:0]  smode_deleg_priv_snap;
    logic [63:0] smode_deleg_mcauseq_snap, smode_deleg_stvalq_snap;
    always @(posedge clk) if (!smode_deleg_halted && dut_smode_deleg.core0.commit_now && dut_smode_deleg.core0.pc == 64'hC8) begin
        smode_deleg_halted <= 1'b1;
        smode_deleg_x13_snap  <= dut_smode_deleg.core0.regfile0.gp_registers[13];
        smode_deleg_x14_snap  <= dut_smode_deleg.core0.regfile0.gp_registers[14];
        // x15 (the marker THIS instruction itself writes) is deliberately
        // NOT snapshotted here -- it would read regfile0's pre-edge value
        // (a same-cycle race, since this instruction's own write and this
        // read happen on the identical posedge). Read live at check()
        // time instead, same as every other case's own idempotent marker
        // (x11/x12 elsewhere) -- safe since a constant write stays correct
        // regardless of how many extra loop passes re-execute it.
        smode_deleg_priv_snap <= dut_smode_deleg.core0.current_priv;
        smode_deleg_mcauseq_snap <= dut_smode_deleg.core0.csr_file0.mcause_q;
        smode_deleg_stvalq_snap  <= dut_smode_deleg.core0.csr_file0.stval_q;
    end
    // x15 snapshot, deliberately a cycle later than the block above (keyed
    // on pc==0xCC, the handler's own trailing ebreak, one instruction
    // after the marker at 0xC8) -- x15's own write only lands the cycle
    // AFTER it commits, so capturing it on the SAME edge as the marker's
    // own commit would read the stale pre-write value (confirmed: this
    // handler's own mtvec window (0x80) is never populated by this case
    // -- it falls through to real crt0.hex boot-stub content left over in
    // that memory, not zero -- so once the bounce-back loop starts
    // executing THAT unrelated code, x15 is genuinely at risk if not
    // captured before it starts).
    logic smode_deleg_x15_done = 1'b0;
    logic [63:0] smode_deleg_x15_snap;
    always @(posedge clk) if (!smode_deleg_x15_done && dut_smode_deleg.core0.commit_now && dut_smode_deleg.core0.pc == 64'hCC) begin
        smode_deleg_x15_done <= 1'b1;
        smode_deleg_x15_snap <= dut_smode_deleg.core0.regfile0.gp_registers[15];
    end
    always @(posedge clk) begin
        if (dut_smode_deleg.core0.commit_now && dut_smode_deleg.core0.pc == 64'h3C) i_mtip_smode_deleg <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 6: a timer interrupt pending exactly as EBREAK's OWN trap-entry
     * retires must not spuriously double-fire on the very next (deferred)
     * interrupt-eligibility check. Since EBREAK is now a real trap (see
     * this milestone's core.sv changes), this no longer depends on any
     * EBREAK-specific guard -- the old `halted`/`!halted` mechanism this
     * case originally exercised no longer exists. It falls out instead
     * from the ORDINARY M-mode trap-entry mechanism: EBREAK's own
     * trap-entry clears mstatus.MIE (csr_file.sv's mstatus_q writer),
     * exactly like any other M-mode trap, so a still-pending interrupt
     * correctly can't preempt on the immediately following cycle. This
     * case proves that holds, AND that EBREAK's own trap fires for real
     * (mcause==3, mepc==TRIGGER's own address) with genuine forward
     * progress into a real handler -- not that nothing happens at all.
     *
     * i_mtip asserts on TRIGGER's own commit edge (an ebreak, same as
     * every other case's own trigger technique -- just that here the
     * triggering instruction IS the thing under test).
     *
     * EVERY completion signal in this file (not just this one) is keyed
     * on a handler's own marker/CSR-readback WRITE instruction, never on
     * any ebreak -- a real, milestone-wide gotcha found the hard way:
     * since EBREAK is a real trap now, a "terminal" ebreak placed inside
     * a handler while mtvec is still armed does NOT terminate anything --
     * it bounces straight back into that SAME handler (mtvec still
     * points there), re-executing it and overwriting mepc/mcause with
     * the LOOPING ebreak's own values before this testbench's fork/
     * wait_all ever gets around to checking them (the 10 DUTs run fully
     * concurrently; a fast DUT keeps looping for many extra cycles while
     * the fork waits on a slower one). A completion signal keyed on the
     * marker write instead fires on this handler's guaranteed-first pass
     * (a non-pipelined core can't have looped back yet at that point),
     * capturing state before any bounce-back has a chance to corrupt it.
     * dut_halted's own handler has no separate marker distinct from its
     * CSR reads, so it's keyed on the last of those (csrr x11,mcause,
     * pc==0x84) instead.
     * ----------------------------------------------------------------- */
    logic i_mtip_halted = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_halted (.clk(clk), .rst(rst), .i_mtip(i_mtip_halted));
    always @(posedge clk) begin
        if (dut_halted.core0.commit_now && dut_halted.core0.pc == 64'h18) i_mtip_halted <= 1'b1;
    end
    logic bad_interrupt_racing_ebreak = 1'b0;
    always @(posedge clk) begin
        if (dut_halted.core0.interrupt_taken) bad_interrupt_racing_ebreak <= 1'b1;
    end
    logic case6_done = 1'b0;
    // x10 (mepc, written by the EARLIER csrr at 0x80) genuinely changes
    // across loop passes -- see the big comment above -- so it needs a
    // point-in-time snapshot, gated to fire only once (a plain, ungated
    // assignment would keep re-firing and overwriting itself on every
    // subsequent loop pass, ending up with the LAST value, not the
    // first -- the actual bug this whole redesign chased down). x11
    // (mcause) is deliberately read LIVE at check() time instead, not
    // snapshotted: it's written by THIS SAME instruction (a same-cycle
    // read-before-write race against a snapshot), but every trap in this
    // specific loop is the same repeating ebreak (always cause 3), so
    // its value never actually changes across passes -- safe as a live
    // read either way.
    logic [63:0] case6_x10_snap;
    always @(posedge clk) begin
        if (!case6_done && dut_halted.core0.commit_now && dut_halted.core0.pc == 64'h84) begin
            case6_done <= 1'b1;
            case6_x10_snap <= dut_halted.core0.regfile0.gp_registers[10];
        end
    end

    initial begin
        #1; // run after every wb4_sram sub-instance's own time-0 crt0.hex init

        /* ---- Case 1: mask via mie.MTIE=0 ---- */
        dut_mask_mie.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mask_mie.sram0.memory[1] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mask_mie.sram0.memory[2] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                        // ebreak
                                          encode_i(32'sd111, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};    // addi x1,x0,111
        dut_mask_mie.sram0.memory[16] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                        // ebreak (0x84)
                                           encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};   // addi x2,x0,999 (poison, 0x80)

        /* ---- Case 2: mask via mstatus.MIE=0 ---- */
        dut_mask_mstatus.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                              encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mask_mstatus.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                              encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mask_mstatus.sram0.memory[2] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                              encode_i(32'sd222, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut_mask_mstatus.sram0.memory[16] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                               encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};

        /* ---- Case 3: multi-cycle DIV hold-off ---- */
        dut_div.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_div.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_div.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                     encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_div.sram0.memory[3] = {encode_i(32'sd7, 5'd0, 3'b000, 5'd21, `OPC_OP_IMM),             // addi x21,x0,7
                                     encode_i(32'sd100, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};         // addi x20,x0,100
        dut_div.sram0.memory[4] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),            // addi x2,x0,999 (poison, 0x24)
                                     encode_r(7'b0000001, 5'd21, 5'd20, 3'b100, 5'd6, `OPC_OP)};    // div x6,x20,x21 (0x20)
        dut_div.sram0.memory[5] = {32'h0,
                                     {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                            // ebreak (0x28)
        dut_div.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),            // addi x11,x0,1 (0x84)
                                      encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)}; // csrr x10,mepc (0x80)
        dut_div.sram0.memory[17] = {32'h0,
                                      {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                           // ebreak (0x88)

        /* ---- Case 4a: mepc after an ordinary ALU op ---- */
        dut_mepc_alu.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_alu.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_alu.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_alu.sram0.memory[3] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),       // addi x2,x0,999 (poison, 0x1C)
                                          encode_i(32'h55, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};       // addi x1,x0,0x55 (TRIGGER, 0x18)
        dut_mepc_alu.sram0.memory[4] = {32'h0,
                                          {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                       // ebreak (0x20)
        dut_mepc_alu.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),
                                           encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};
        dut_mepc_alu.sram0.memory[17] = {32'h0,
                                           {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        /* ---- Case 4b: mepc after a JAL ---- */
        dut_mepc_jal.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_jal.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_jal.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                          encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_jal.sram0.memory[3] = {encode_i(32'sd888, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM),       // addi x4,x0,888 (decoy, 0x1C -- skipped by JAL)
                                          encode_j(32'sd8, 5'd3, `OPC_JAL)};                        // jal x3,+8 (TRIGGER, 0x18 -> target 0x20)
        dut_mepc_jal.sram0.memory[4] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                          // ebreak (0x24, safety net)
                                          encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};     // addi x2,x0,999 (poison, 0x20)
        dut_mepc_jal.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),
                                           encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};
        dut_mepc_jal.sram0.memory[17] = {32'h0,
                                           {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        /* ---- Case 4c: mepc after a taken branch ---- */
        dut_mepc_branch.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                             encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_branch.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                             encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_branch.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                             encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_branch.sram0.memory[3] = {encode_i(32'sd888, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM),    // addi x4,x0,888 (decoy, 0x1C)
                                             encode_b(32'sd8, 5'd0, 5'd0, 3'b000, `OPC_BRANCH)};    // beq x0,x0,+8 (TRIGGER, 0x18 -> target 0x20)
        dut_mepc_branch.sram0.memory[4] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                       // ebreak (0x24, safety net)
                                             encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};  // addi x2,x0,999 (poison, 0x20)
        dut_mepc_branch.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),
                                              encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};
        dut_mepc_branch.sram0.memory[17] = {32'h0,
                                              {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};

        /* ---- Case 4d: mepc after MRET (the systematic-bug regression) ---- */
        dut_mepc_mret.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                           encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_mret.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                           encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_mret.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM), // mstatus: MPIE=1,MIE=0
                                           encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_mret.sram0.memory[3] = {encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),    // mepc = 0x28 (poison addr)
                                           encode_i(32'h28, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_mepc_mret.sram0.memory[4] = {encode_i(32'sd777, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),      // addi x5,x0,777 (decoy, 0x24 -- skipped by MRET)
                                           `INSTR_HEX_MRET};                                        // mret (TRIGGER, 0x20)
        dut_mepc_mret.sram0.memory[5] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                        // ebreak (0x2C, safety net)
                                           encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};    // addi x2,x0,999 (poison, 0x28)
        dut_mepc_mret.sram0.memory[16] = {encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM),  // csrr x11,mcause (0x84)
                                            encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)}; // csrr x10,mepc (0x80)
        dut_mepc_mret.sram0.memory[17] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                       // ebreak (0x8C)
                                            encode_i(32'sd1, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM)};    // addi x12,x0,1 (0x88)

        /* ---- Case 5: S-mode routing with mideleg[7]=0 ----
         * addi's 12-bit immediate is signed (range -2048..+2047), so
         * mstatus.MPP=S's own field value (2048 = 1<<11) can't be loaded
         * directly the way every other constant in this file is -- same
         * "li+slli" technique priv_test.s/core_priv_tb.sv already use for
         * this exact field. */
        dut_smode.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                       encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                       encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode.sram0.memory[2] = {encode_shift64(6'b000000, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM),  // slli x28,x28,11 -> x28=2048
                                       encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};                 // addi x28,x0,1
        dut_smode.sram0.memory[3] = {encode_i(32'h28, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),                   // addi x28,x0,0x28 (S_MARKER addr)
                                       encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};   // csrw mstatus,x28 (MPP=S)
        dut_smode.sram0.memory[4] = {`INSTR_HEX_MRET,                                                       // mret (0x24)
                                       encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};      // csrw mepc,x28 (0x20)
        dut_smode.sram0.memory[5] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),                  // addi x2,x0,999 (poison, 0x2C)
                                       encode_i(32'sd555, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM)};                // addi x5,x0,555 (S_MARKER/TRIGGER, 0x28)
        dut_smode.sram0.memory[6] = {32'h0,
                                       {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                                  // ebreak (0x30, safety net)
        dut_smode.sram0.memory[16] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),
                                        encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};   // csrr x10,mcause (0x80)
        dut_smode.sram0.memory[17] = {32'h0,
                                        {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                            // ebreak (0x88)

        /* ---- Case 7: S-mode routing with mideleg[7]=1 (delegated) ----
         * Same MPP=S technique as Case 5, plus: mideleg bit 7 set (delegate
         * MTI), stvec armed (the redirect target once delegated), and
         * mstatus's write combines MPP=S (2048) with SIE=1 (2) in the SAME
         * write, since MRET leaves S-side fields untouched -- SIE must
         * already be set before MRET enters S-mode, not after. */
        dut_smode_deleg.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                             encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_deleg.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                             encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_deleg.sram0.memory[2] = {encode_csr(`CSR_MIDELEG, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM), // mideleg[7]=1
                                             encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_deleg.sram0.memory[3] = {encode_csr(`CSR_STVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),   // stvec=0xC0
                                             encode_i(32'sd192, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_deleg.sram0.memory[4] = {encode_shift64(6'b000000, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM), // slli x28,x28,11 -> 2048
                                             encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};                // addi x28,x0,1
        dut_smode_deleg.sram0.memory[5] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),  // mstatus = 2050 (MPP=S|SIE=1)
                                             encode_i(32'sd2, 5'd28, 3'b000, 5'd28, `OPC_OP_IMM)};               // addi x28,x28,2 -> 2050
        dut_smode_deleg.sram0.memory[6] = {encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),     // mepc=0x3C (S_MARKER addr)
                                             encode_i(32'h3C, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_smode_deleg.sram0.memory[7] = {encode_i(32'sd555, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),                // addi x5,x0,555 (S_MARKER/TRIGGER, 0x3C)
                                             `INSTR_HEX_MRET};                                                  // mret (0x38)
        dut_smode_deleg.sram0.memory[8] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                  // ebreak (0x44, safety net)
                                             encode_i(32'sd999, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};              // addi x2,x0,999 (poison, 0x40)
        dut_smode_deleg.sram0.memory[24] = {encode_csr(`CSR_SEPC, 5'd0, `FUNCT3_CSRRS, 5'd14, `OPC_SYSTEM),    // csrr x14,sepc (0xC4)
                                              encode_csr(`CSR_SCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd13, `OPC_SYSTEM)}; // csrr x13,scause (0xC0)
        dut_smode_deleg.sram0.memory[25] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                 // ebreak (0xCC)
                                              encode_i(32'sd1, 5'd0, 3'b000, 5'd15, `OPC_OP_IMM)};              // addi x15,x0,1 (0xC8, handler ran)

        /* ---- Case 6: EBREAK trap racing a pending timer interrupt ---- */
        dut_halted.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[3] = {32'h0,
                                        {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                            // ebreak (TRIGGER, 0x18)
        dut_halted.sram0.memory[16] = {encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM), // csrr x11,mcause (0x84)
                                         encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)}; // csrr x10,mepc (0x80)
        dut_halted.sram0.memory[17] = {32'h0,
                                         {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                            // ebreak (0x88, handler completion)

        @(posedge clk); #1;
        rst = 0;

        fork
            begin : wait_all
                wait (mask_mie_halted === 1'b1);
                wait (mask_mstatus_halted === 1'b1);
                wait (div_halted === 1'b1);
                wait (mepc_alu_halted === 1'b1);
                wait (mepc_jal_halted === 1'b1);
                wait (mepc_branch_halted === 1'b1);
                wait (mepc_mret_halted === 1'b1);
                wait (smode_halted === 1'b1);
                wait (smode_deleg_x15_done === 1'b1); // strictly later than smode_deleg_halted (0xCC vs 0xC8) --
                                                        // waiting on it also guarantees the earlier snapshots landed
                wait (case6_done === 1'b1);
            end
            begin : timeout
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("TIMEOUT: not every DUT halted");
                $finish;
            end
        join_any
        #1;

        /* ---- Case 1 checks ----
         * No "poison marker never ran" check anymore -- since EBREAK
         * really traps now, this program's own trailing ebreak (reached
         * strictly AFTER the check below already captured state) also
         * bounces into mtvec's own code unconditionally, regardless of
         * whether the interrupt was masked correctly, so that check can
         * no longer distinguish correct from broken masking. The real
         * proof of masking here is structural: mask_mie_halted only ever
         * latches (avoiding the shared timeout) if x1's own write at
         * pc==0x10 was reached at all -- unreachable if the interrupt
         * incorrectly fired first and redirected away before it. */
        check("case1 (mask via mie.MTIE=0): ran to its own marker, x1==111", dut_mask_mie.core0.regfile0.gp_registers[1], 64'd111);
        check("case1: reached its own marker undisturbed (mask held)", {63'b0, mask_mie_halted}, 64'd1);

        /* ---- Case 2 checks (same reasoning as Case 1 above) ---- */
        check("case2 (mask via mstatus.MIE=0): ran to its own marker, x1==222", dut_mask_mstatus.core0.regfile0.gp_registers[1], 64'd222);
        check("case2: reached its own marker undisturbed (mask held)", {63'b0, mask_mstatus_halted}, 64'd1);

        /* ---- Case 3 checks (DIV hold-off) ---- */
        check("case3 (DIV): div's own regfile write landed (x6==14)", dut_div.core0.regfile0.gp_registers[6], 64'd14);
        check("case3: divide's commit was observed (sanity on the monitor itself)", {63'b0, div_committed}, 64'd1);
        check("case3: interrupt_taken never asserted before the divide's own commit", {63'b0, bad_early_interrupt}, 64'd0);
        check("case3: poison marker never ran (x2==0)", dut_div.core0.regfile0.gp_registers[2], 64'd0);
        check("case3: mepc == poison addr (0x24), resumed right after DIV", div_x10_snap, 64'h24);
        check("case3: handler ran (x11==1)", dut_div.core0.regfile0.gp_registers[11], 64'd1);
        check("case3: EBREAK trap fired", {63'b0, div_halted}, 64'd1);

        /* ---- Case 4a checks (mepc after ordinary ALU op) ---- */
        check("case4a: poison marker never ran (x2==0)", dut_mepc_alu.core0.regfile0.gp_registers[2], 64'd0);
        check("case4a: mepc == TRIGGER+4 (0x1C, ordinary pc_plus_len)", mepc_alu_x10_snap, 64'h1C);
        check("case4a: handler ran (x11==1)", dut_mepc_alu.core0.regfile0.gp_registers[11], 64'd1);
        check("case4a: EBREAK trap fired", {63'b0, mepc_alu_halted}, 64'd1);

        /* ---- Case 4b checks (mepc after JAL) ---- */
        check("case4b: poison marker never ran (x2==0)", dut_mepc_jal.core0.regfile0.gp_registers[2], 64'd0);
        check("case4b: decoy never ran (x4==0)", dut_mepc_jal.core0.regfile0.gp_registers[4], 64'd0);
        check("case4b: mepc == JAL's jump target (0x20)", mepc_jal_x10_snap, 64'h20);
        check("case4b: handler ran (x11==1)", dut_mepc_jal.core0.regfile0.gp_registers[11], 64'd1);
        check("case4b: EBREAK trap fired", {63'b0, mepc_jal_halted}, 64'd1);

        /* ---- Case 4c checks (mepc after taken branch) ---- */
        check("case4c: poison marker never ran (x2==0)", dut_mepc_branch.core0.regfile0.gp_registers[2], 64'd0);
        check("case4c: decoy never ran (x4==0)", dut_mepc_branch.core0.regfile0.gp_registers[4], 64'd0);
        check("case4c: mepc == branch target (0x20)", mepc_branch_x10_snap, 64'h20);
        check("case4c: handler ran (x11==1)", dut_mepc_branch.core0.regfile0.gp_registers[11], 64'd1);
        check("case4c: EBREAK trap fired", {63'b0, mepc_branch_halted}, 64'd1);

        /* ---- Case 4d checks (mepc after MRET -- the systematic-bug regression) ---- */
        check("case4d: poison marker never ran (x2==0) -- genuine preemption, not eventually-taken", dut_mepc_mret.core0.regfile0.gp_registers[2], 64'd0);
        check("case4d: decoy never ran (x5==0)", dut_mepc_mret.core0.regfile0.gp_registers[5], 64'd0);
        check("case4d: mepc == MRET's own return address (0x28)", mepc_mret_x10_snap, 64'h28);
        check("case4d: mcause == standard machine-timer-interrupt encoding", mepc_mret_x11_snap, 64'h8000_0000_0000_0007);
        check("case4d: handler ran (x12==1)", dut_mepc_mret.core0.regfile0.gp_registers[12], 64'd1);
        check("case4d: current_priv == M", {62'b0, dut_mepc_mret.core0.current_priv}, 64'(2'b11));
        check("case4d: EBREAK trap fired", {63'b0, mepc_mret_halted}, 64'd1);

        /* ---- Case 5 checks (S-mode routing, mideleg[7]=0) ---- */
        check("case5: S-mode marker genuinely ran (x5==555)", dut_smode.core0.regfile0.gp_registers[5], 64'd555);
        check("case5: poison marker never ran (x2==0)", dut_smode.core0.regfile0.gp_registers[2], 64'd0);
        check("case5: mcause == standard machine-timer-interrupt encoding (routed to M, not S)", smode_x10_snap, 64'h8000_0000_0000_0007);
        check("case5: scause_q untouched (never routed to S)", dut_smode.core0.csr_file0.scause_q, 64'd0);
        check("case5: mtval_q reads 0 after a pure interrupt (i_trap_val masked, not stale trap_val)",
              dut_smode.core0.csr_file0.mtval_q, 64'd0);
        check("case5: M handler ran (x11==1)", dut_smode.core0.regfile0.gp_registers[11], 64'd1);
        check("case5: current_priv == M", {62'b0, dut_smode.core0.current_priv}, 64'(2'b11));
        check("case5: EBREAK trap fired", {63'b0, smode_halted}, 64'd1);

        /* ---- Case 7 checks (S-mode routing, mideleg[7]=1, delegated) ---- */
        check("case7: S-mode marker genuinely ran (x5==555)", dut_smode_deleg.core0.regfile0.gp_registers[5], 64'd555);
        check("case7: poison never ran (x2==0)", dut_smode_deleg.core0.regfile0.gp_registers[2], 64'd0);
        check("case7: scause == standard machine-timer-interrupt encoding (routed to S, not M)",
              smode_deleg_x13_snap, 64'h8000_0000_0000_0007);
        check("case7: sepc == the S-mode marker's own resume address (0x40)",
              smode_deleg_x14_snap, 64'h40);
        check("case7: mcause_q untouched (never routed to M)", smode_deleg_mcauseq_snap, 64'd0);
        check("case7: stval_q reads 0 after a pure interrupt (i_trap_val masked)", smode_deleg_stvalq_snap, 64'd0);
        check("case7: S handler ran (x15==1)", smode_deleg_x15_snap, 64'd1);
        check("case7: current_priv == S", {62'b0, smode_deleg_priv_snap}, 64'(2'b01));
        check("case7: EBREAK trap fired", {63'b0, smode_deleg_halted}, 64'd1);

        /* ---- Case 6 checks (EBREAK trap racing a pending interrupt) ---- */
        check("case6: EBREAK trap fired for real (mcause==3, Breakpoint)", dut_halted.core0.regfile0.gp_registers[11], 64'd3);
        check("case6: mepc == EBREAK's own address (0x18)", case6_x10_snap, 64'h18);
        check("case6: real forward progress -- handler ran to its own completion", {63'b0, case6_done}, 64'd1);
        check("case6: pending interrupt did not spuriously fire racing EBREAK's own trap-entry", {63'b0, bad_interrupt_racing_ebreak}, 64'd0);

        $display("");
        $display("core_interrupt_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_interrupt_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
