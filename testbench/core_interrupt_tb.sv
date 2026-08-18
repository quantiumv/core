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

    /* ----------------------------------------------------------------- *
     * Case 2: pending but masked via mstatus.MIE=0 (mie.MTIE=1, i_mtip=1
     * throughout) -- same shape, opposite mask bit.
     * ----------------------------------------------------------------- */
    logic i_mtip_mask_mstatus = 1'b1;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_mask_mstatus (.clk(clk), .rst(rst), .i_mtip(i_mtip_mask_mstatus));

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
    always @(posedge clk) begin
        if (dut_smode_deleg.core0.commit_now && dut_smode_deleg.core0.pc == 64'h3C) i_mtip_smode_deleg <= 1'b1;
    end

    /* ----------------------------------------------------------------- *
     * Case 6: an interrupt pending at the exact cycle EBREAK's commit_now
     * fires must NOT redirect (the !halted guard in interrupt_taken's
     * own definition) -- i_mtip asserts on EBREAK's own commit edge, so
     * by the very next cycle (when interrupt_taken would otherwise be
     * checked) `halted` is ALREADY 1 (set by the same edge, same NBA
     * timing), correctly suppressing the redirect. Checked two ways:
     * the would-be handler's poison marker never runs, AND (stronger,
     * white-box) interrupt_taken itself is never observed high at all.
     * ----------------------------------------------------------------- */
    logic i_mtip_halted = 1'b0;
    core_wb4_sram_harness #(.NUM_WORDS(64)) dut_halted (.clk(clk), .rst(rst), .i_mtip(i_mtip_halted));
    always @(posedge clk) begin
        if (dut_halted.core0.commit_now && dut_halted.core0.pc == 64'h18) i_mtip_halted <= 1'b1;
    end
    logic bad_interrupt_after_halt = 1'b0;
    always @(posedge clk) begin
        if (dut_halted.core0.interrupt_taken) bad_interrupt_after_halt <= 1'b1;
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

        /* ---- Case 6: halted/EBREAK interaction ---- */
        dut_halted.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[1] = {encode_csr(`CSR_MIE, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[2] = {encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                        encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_halted.sram0.memory[3] = {32'h0,
                                        {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                            // ebreak (TRIGGER, 0x18)
        dut_halted.sram0.memory[16] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                              // ebreak (0x84)
                                         encode_i(32'sd999, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM)};          // addi x9,x0,999 (poison, 0x80)

        @(posedge clk); #1;
        rst = 0;

        fork
            begin : wait_all
                wait (dut_mask_mie.core0.halted === 1'b1);
                wait (dut_mask_mstatus.core0.halted === 1'b1);
                wait (dut_div.core0.halted === 1'b1);
                wait (dut_mepc_alu.core0.halted === 1'b1);
                wait (dut_mepc_jal.core0.halted === 1'b1);
                wait (dut_mepc_branch.core0.halted === 1'b1);
                wait (dut_mepc_mret.core0.halted === 1'b1);
                wait (dut_smode.core0.halted === 1'b1);
                wait (dut_smode_deleg.core0.halted === 1'b1);
                wait (dut_halted.core0.halted === 1'b1);
            end
            begin : timeout
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("TIMEOUT: not every DUT halted");
                $finish;
            end
        join_any
        #1;

        /* ---- Case 1 checks ---- */
        check("case1 (mask via mie.MTIE=0): ran to its own ebreak, x1==111", dut_mask_mie.core0.regfile0.gp_registers[1], 64'd111);
        check("case1: poison marker never ran (x2==0)", dut_mask_mie.core0.regfile0.gp_registers[2], 64'd0);
        check("case1: halted normally", {63'b0, dut_mask_mie.core0.halted}, 64'd1);

        /* ---- Case 2 checks ---- */
        check("case2 (mask via mstatus.MIE=0): ran to its own ebreak, x1==222", dut_mask_mstatus.core0.regfile0.gp_registers[1], 64'd222);
        check("case2: poison marker never ran (x2==0)", dut_mask_mstatus.core0.regfile0.gp_registers[2], 64'd0);
        check("case2: halted normally", {63'b0, dut_mask_mstatus.core0.halted}, 64'd1);

        /* ---- Case 3 checks (DIV hold-off) ---- */
        check("case3 (DIV): div's own regfile write landed (x6==14)", dut_div.core0.regfile0.gp_registers[6], 64'd14);
        check("case3: divide's commit was observed (sanity on the monitor itself)", {63'b0, div_committed}, 64'd1);
        check("case3: interrupt_taken never asserted before the divide's own commit", {63'b0, bad_early_interrupt}, 64'd0);
        check("case3: poison marker never ran (x2==0)", dut_div.core0.regfile0.gp_registers[2], 64'd0);
        check("case3: mepc == poison addr (0x24), resumed right after DIV", dut_div.core0.regfile0.gp_registers[10], 64'h24);
        check("case3: handler ran (x11==1)", dut_div.core0.regfile0.gp_registers[11], 64'd1);
        check("case3: halted", {63'b0, dut_div.core0.halted}, 64'd1);

        /* ---- Case 4a checks (mepc after ordinary ALU op) ---- */
        check("case4a: poison marker never ran (x2==0)", dut_mepc_alu.core0.regfile0.gp_registers[2], 64'd0);
        check("case4a: mepc == TRIGGER+4 (0x1C, ordinary pc_plus_len)", dut_mepc_alu.core0.regfile0.gp_registers[10], 64'h1C);
        check("case4a: handler ran (x11==1)", dut_mepc_alu.core0.regfile0.gp_registers[11], 64'd1);
        check("case4a: halted", {63'b0, dut_mepc_alu.core0.halted}, 64'd1);

        /* ---- Case 4b checks (mepc after JAL) ---- */
        check("case4b: poison marker never ran (x2==0)", dut_mepc_jal.core0.regfile0.gp_registers[2], 64'd0);
        check("case4b: decoy never ran (x4==0)", dut_mepc_jal.core0.regfile0.gp_registers[4], 64'd0);
        check("case4b: mepc == JAL's jump target (0x20)", dut_mepc_jal.core0.regfile0.gp_registers[10], 64'h20);
        check("case4b: handler ran (x11==1)", dut_mepc_jal.core0.regfile0.gp_registers[11], 64'd1);
        check("case4b: halted", {63'b0, dut_mepc_jal.core0.halted}, 64'd1);

        /* ---- Case 4c checks (mepc after taken branch) ---- */
        check("case4c: poison marker never ran (x2==0)", dut_mepc_branch.core0.regfile0.gp_registers[2], 64'd0);
        check("case4c: decoy never ran (x4==0)", dut_mepc_branch.core0.regfile0.gp_registers[4], 64'd0);
        check("case4c: mepc == branch target (0x20)", dut_mepc_branch.core0.regfile0.gp_registers[10], 64'h20);
        check("case4c: handler ran (x11==1)", dut_mepc_branch.core0.regfile0.gp_registers[11], 64'd1);
        check("case4c: halted", {63'b0, dut_mepc_branch.core0.halted}, 64'd1);

        /* ---- Case 4d checks (mepc after MRET -- the systematic-bug regression) ---- */
        check("case4d: poison marker never ran (x2==0) -- genuine preemption, not eventually-taken", dut_mepc_mret.core0.regfile0.gp_registers[2], 64'd0);
        check("case4d: decoy never ran (x5==0)", dut_mepc_mret.core0.regfile0.gp_registers[5], 64'd0);
        check("case4d: mepc == MRET's own return address (0x28)", dut_mepc_mret.core0.regfile0.gp_registers[10], 64'h28);
        check("case4d: mcause == standard machine-timer-interrupt encoding", dut_mepc_mret.core0.regfile0.gp_registers[11], 64'h8000_0000_0000_0007);
        check("case4d: handler ran (x12==1)", dut_mepc_mret.core0.regfile0.gp_registers[12], 64'd1);
        check("case4d: current_priv == M", {62'b0, dut_mepc_mret.core0.current_priv}, 64'(2'b11));
        check("case4d: halted", {63'b0, dut_mepc_mret.core0.halted}, 64'd1);

        /* ---- Case 5 checks (S-mode routing, mideleg[7]=0) ---- */
        check("case5: S-mode marker genuinely ran (x5==555)", dut_smode.core0.regfile0.gp_registers[5], 64'd555);
        check("case5: poison marker never ran (x2==0)", dut_smode.core0.regfile0.gp_registers[2], 64'd0);
        check("case5: mcause == standard machine-timer-interrupt encoding (routed to M, not S)", dut_smode.core0.regfile0.gp_registers[10], 64'h8000_0000_0000_0007);
        check("case5: scause_q untouched (never routed to S)", dut_smode.core0.csr_file0.scause_q, 64'd0);
        check("case5: mtval_q reads 0 after a pure interrupt (i_trap_val masked, not stale trap_val)",
              dut_smode.core0.csr_file0.mtval_q, 64'd0);
        check("case5: M handler ran (x11==1)", dut_smode.core0.regfile0.gp_registers[11], 64'd1);
        check("case5: current_priv == M", {62'b0, dut_smode.core0.current_priv}, 64'(2'b11));
        check("case5: halted", {63'b0, dut_smode.core0.halted}, 64'd1);

        /* ---- Case 7 checks (S-mode routing, mideleg[7]=1, delegated) ---- */
        check("case7: S-mode marker genuinely ran (x5==555)", dut_smode_deleg.core0.regfile0.gp_registers[5], 64'd555);
        check("case7: poison never ran (x2==0)", dut_smode_deleg.core0.regfile0.gp_registers[2], 64'd0);
        check("case7: scause == standard machine-timer-interrupt encoding (routed to S, not M)",
              dut_smode_deleg.core0.regfile0.gp_registers[13], 64'h8000_0000_0000_0007);
        check("case7: sepc == the S-mode marker's own resume address (0x40)",
              dut_smode_deleg.core0.regfile0.gp_registers[14], 64'h40);
        check("case7: mcause_q untouched (never routed to M)", dut_smode_deleg.core0.csr_file0.mcause_q, 64'd0);
        check("case7: stval_q reads 0 after a pure interrupt (i_trap_val masked)",
              dut_smode_deleg.core0.csr_file0.stval_q, 64'd0);
        check("case7: S handler ran (x15==1)", dut_smode_deleg.core0.regfile0.gp_registers[15], 64'd1);
        check("case7: current_priv == S", {62'b0, dut_smode_deleg.core0.current_priv}, 64'(2'b01));
        check("case7: halted", {63'b0, dut_smode_deleg.core0.halted}, 64'd1);

        /* ---- Case 6 checks (halted/EBREAK interaction) ---- */
        check("case6: halted via its own ebreak", {63'b0, dut_halted.core0.halted}, 64'd1);
        check("case6: pc frozen at ebreak's own address (0x18)", dut_halted.core0.pc, 64'h18);
        check("case6: poison marker never ran (x9==0)", dut_halted.core0.regfile0.gp_registers[9], 64'd0);
        check("case6: interrupt_taken never asserted (the !halted guard held)", {63'b0, bad_interrupt_after_halt}, 64'd0);

        $display("");
        $display("core_interrupt_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_interrupt_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
