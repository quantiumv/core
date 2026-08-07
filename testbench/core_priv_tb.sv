// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core's U/S/M privilege-mode support, end to end.
 *
 * Wiring is core_wb4_sram_harness (this program never issues a
 * load/store), same topology as core_zicsr_tb.sv/core_m_ext_tb.sv.
 * Instructions are packed two-per-64-bit-word into dut.sram0.memory[],
 * same convention as every other core-level testbench.
 *
 * Program structure: a linear sequence of "phases", each triggering one
 * kind of trap/mode-transition, followed by a marker instruction
 * (addi xN, x0, <distinct value>) proving control genuinely returned to
 * the right place afterward -- not just that SOME instruction eventually
 * ran. Two small trap handlers (M_TRAP_HANDLER at mtvec, S_TRAP_HANDLER
 * at stvec) sit after the main flow: each reads back its own xEPC,
 * advances it by 4 (skipping the deliberately-trapping instruction,
 * since this is a test program, not real firmware that would need to
 * re-examine the fault), writes it back, and returns (mret/sret) --
 * this is what lets the linear flow below "just continue" after each
 * trap without needing a separate handler per phase.
 *
 * Setup (idx0-5, M-mode): point mtvec/stvec at the two handlers, and set
 * medeleg = {bit 9 only} -- delegates ECALL-from-S (cause 9) to S-mode,
 * leaves illegal-instruction (cause 2) undelegated (routes to M) --
 * deliberately different causes for the two delegation outcomes, so
 * nothing needs an M-mode round-trip mid-test to toggle medeleg.
 *
 * Exercises, in program order:
 *  1. ECALL from M-mode (idx6/7) -- mcause==11, M-mode never delegates
 *     regardless of medeleg. White-box-sampled (mcause_q gets
 *     overwritten by later phases, so this is caught before that).
 *  2. Bootstrap M->S (idx8-14) via mstatus.MPP=S + mepc + mret.
 *  3. Illegal instruction from S-mode (idx15/16), medeleg[2]=0 -> routes
 *     to M, M_TRAP_HANDLER's mret correctly restores S (MPP captured S
 *     at trap-entry) -- white-box-sampled (current_priv==S at the
 *     marker, proving the M-routed trap didn't strand us in the wrong
 *     mode).
 *  4. ECALL from S-mode (idx17/18), medeleg[9]=1 -> delegates to S,
 *     S_TRAP_HANDLER's sret returns to S. scause==9 checked post-halt
 *     (nothing overwrites scause afterward, so no white-box sample
 *     needed here).
 *  5. CSR-privilege violation (idx19-21): csrrw to mscratch (M-only)
 *     attempted from S-mode -- must raise illegal-instruction rather
 *     than silently executing. White-box-sampled: csr_we reads 0 that
 *     cycle, AND mscratch_q is confirmed still 0 post-halt (the write
 *     never landed).
 *  6a. MRET executed from S-mode (idx22/23) -- illegal (MRET requires
 *     exactly M). White-box-sampled: mret_taken reads 0 and trap_taken
 *     reads 1 that cycle -- proves the priv-check gate fired, not a
 *     coincidence of where MPP happened to point.
 *  6b. Bootstrap S->U (idx24-27) via sstatus... actually mstatus is
 *     M-only, so this uses the LEGITIMATE sepc write (sepc is
 *     S-accessible) + a real sret (SPP already 0/U from phase 4's own
 *     sret, which resets SPP to U per spec). Then SRET executed from
 *     U-mode (idx28/29) -- illegal (SRET requires S-or-higher).
 *     White-box-sampled: sret_taken reads 0, trap_taken reads 1.
 *  7. WFI and SFENCE.VMA as bracketed no-ops (idx30-34) -- both are
 *     spec-legal NOPs this milestone (no interrupt source / no TLB to
 *     flush yet); bracketing markers prove they don't disturb control
 *     flow, matching core_isa_coverage_gap_tb.sv's own FENCE/ECALL
 *     bracketing pattern.
 *  8. ebreak (idx35) -- halts. Deliberately NOT wired into the trap
 *     mechanism this milestone (see the project plan / memory
 *     known-gap-ebreak-sim-halt) -- still the plain sim-only halt every
 *     other testbench in this project depends on.
 */
module core_priv_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(32)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    /*
     * White-box monitors. state_t's declared order in core.sv is
     * {S_FETCH, S_EXEC, S_MEM} = {0, 1, 2}, hence the literal 2'd1 below
     * (matching core_zicsr_tb.sv's own precedent).
     */
    localparam logic [63:0] PC_PHASE1_MARKER  = 64'h1C;  // idx7
    localparam logic [63:0] PC_PHASE3_MARKER  = 64'h40;  // idx16
    localparam logic [63:0] PC_PHASE5_TRIGGER = 64'h50;  // idx20
    localparam logic [63:0] PC_PHASE6A_TRIGGER = 64'h58; // idx22
    localparam logic [63:0] PC_PHASE6B_TRIGGER = 64'h70; // idx28

    logic [63:0] mcause_sampled;
    logic mcause_sample_captured;
    pc_trigger_sample_monitor #(.WIDTH(64)) mcause_monitor (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE1_MARKER), .i_sample(dut.core0.csr_file0.mcause_q),
        .o_sampled(mcause_sampled), .o_captured(mcause_sample_captured)
    );

    logic [1:0] priv_sampled_phase3;
    logic priv_sample_phase3_captured;
    pc_trigger_sample_monitor #(.WIDTH(2)) priv_monitor_phase3 (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE3_MARKER), .i_sample(dut.core0.current_priv),
        .o_sampled(priv_sampled_phase3), .o_captured(priv_sample_phase3_captured)
    );

    logic csr_we_sampled_phase5;
    logic csr_we_sample_phase5_captured;
    pc_trigger_sample_monitor csr_we_monitor_phase5 (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE5_TRIGGER), .i_sample(dut.core0.csr_we),
        .o_sampled(csr_we_sampled_phase5), .o_captured(csr_we_sample_phase5_captured)
    );

    logic mret_taken_sampled_phase6a, trap_taken_sampled_phase6a;
    logic mret_taken_sample_phase6a_captured, trap_taken_sample_phase6a_captured;
    pc_trigger_sample_monitor mret_taken_monitor_phase6a (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE6A_TRIGGER), .i_sample(dut.core0.mret_taken),
        .o_sampled(mret_taken_sampled_phase6a), .o_captured(mret_taken_sample_phase6a_captured)
    );
    pc_trigger_sample_monitor trap_taken_monitor_phase6a (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE6A_TRIGGER), .i_sample(dut.core0.trap_taken),
        .o_sampled(trap_taken_sampled_phase6a), .o_captured(trap_taken_sample_phase6a_captured)
    );

    logic sret_taken_sampled_phase6b, trap_taken_sampled_phase6b;
    logic sret_taken_sample_phase6b_captured, trap_taken_sample_phase6b_captured;
    pc_trigger_sample_monitor sret_taken_monitor_phase6b (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE6B_TRIGGER), .i_sample(dut.core0.sret_taken),
        .o_sampled(sret_taken_sampled_phase6b), .o_captured(sret_taken_sample_phase6b_captured)
    );
    pc_trigger_sample_monitor trap_taken_monitor_phase6b (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_PHASE6B_TRIGGER), .i_sample(dut.core0.trap_taken),
        .o_sampled(trap_taken_sampled_phase6b), .o_captured(trap_taken_sample_phase6b_captured)
    );

    initial begin
        #1; // run after wb4_sram's own time-0 init (see header comment)

        /*
         * addr  idx  instruction                            notes
         * -- Setup (M-mode) --
         *  0x00   0  addi x28, x0, 0x90 (144)                x28 = M_TRAP_HANDLER address
         *  0x04   1  csrrw x0, mtvec, x28
         *  0x08   2  addi x28, x0, 0xA0 (160)                x28 = S_TRAP_HANDLER address
         *  0x0C   3  csrrw x0, stvec, x28
         *  0x10   4  addi x28, x0, 512 (bit 9)
         *  0x14   5  csrrw x0, medeleg, x28                  delegate ECALL-from-S only, not illegal-instr
         * -- Phase 1: ECALL from M (never delegates) --
         *  0x18   6  ecall
         *  0x1C   7  addi x1, x0, 111                        marker + mcause white-box sample point
         * -- Phase 2: bootstrap M -> S --
         *  0x20   8  addi x28, x0, 1
         *  0x24   9  slli x28, x28, 11                       x28 = mstatus.MPP field = S
         *  0x28  10  csrrw x0, mstatus, x28
         *  0x2C  11  addi x28, x0, 0x38 (56)                 x28 = addr of idx14
         *  0x30  12  csrrw x0, mepc, x28
         *  0x34  13  mret                                    current_priv <- S, jump to idx14
         *  0x38  14  addi x2, x0, 222                        marker: now S-mode + current_priv white-box sample point
         * -- Phase 3: illegal instruction from S, not delegated (medeleg[2]=0) --
         *  0x3C  15  <all-1s, unrecognized encoding>
         *  0x40  16  addi x3, x0, 333                        marker: back in S (via M_TRAP_HANDLER's mret)
         * -- Phase 4: ECALL from S, delegated (medeleg[9]=1) --
         *  0x44  17  ecall
         *  0x48  18  addi x4, x0, 444                        marker: back in S (via S_TRAP_HANDLER's sret)
         * -- Phase 5: CSR-privilege violation (mscratch is M-only, we're in S) --
         *  0x4C  19  addi x29, x0, 999
         *  0x50  20  csrrw x0, mscratch, x29                 illegal -- csr_we must read 0 this cycle
         *  0x54  21  addi x5, x0, 555                        marker
         * -- Phase 6a: MRET from S (illegal -- MRET requires exactly M) --
         *  0x58  22  mret                                    illegal -- mret_taken=0, trap_taken=1 this cycle
         *  0x5C  23  addi x6, x0, 666                         marker
         * -- Phase 6b: bootstrap S -> U, then SRET from U (illegal) --
         *  0x60  24  addi x28, x0, 0x6C (108)                x28 = addr of idx27
         *  0x64  25  csrrw x0, sepc, x28                     sepc is S-accessible
         *  0x68  26  sret                                    legitimate (SPP already U from phase 4's own sret)
         *  0x6C  27  addi x7, x0, 777                        marker: now U-mode
         *  0x70  28  sret                                    illegal -- sret_taken=0, trap_taken=1 this cycle
         *  0x74  29  addi x8, x0, 888                        marker: back in U (via M_TRAP_HANDLER's mret)
         * -- Phase 7: WFI / SFENCE.VMA as bracketed no-ops --
         *  0x78  30  addi x9, x0, 11
         *  0x7C  31  wfi
         *  0x80  32  addi x10, x0, 22
         *  0x84  33  sfence.vma x0, x0
         *  0x88  34  addi x11, x0, 33
         * -- Phase 8: halt --
         *  0x8C  35  ebreak
         * -- M_TRAP_HANDLER --
         *  0x90  36  csrrs x30, mepc, x0
         *  0x94  37  addi x30, x30, 4
         *  0x98  38  csrrw x0, mepc, x30
         *  0x9C  39  mret
         * -- S_TRAP_HANDLER --
         *  0xA0  40  csrrs x30, sepc, x0
         *  0xA4  41  addi x30, x30, 4
         *  0xA8  42  csrrw x0, sepc, x30
         *  0xAC  43  sret
         */
        dut.sram0.memory[0]  = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd144, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[1]  = {encode_csr(`CSR_STVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd160, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[2]  = {encode_csr(`CSR_MEDELEG, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd512, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[3]  = {encode_i(32'sd111, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                 {11'b0, 1'b0, 13'b0, `OPC_SYSTEM}};
        dut.sram0.memory[4]  = {encode_shift64(6'b000000, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM),
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[5]  = {encode_i(32'sd56, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),
                                 encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[6]  = {`INSTR_HEX_MRET,
                                 encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[7]  = {32'hFFFFFFFF,
                                 encode_i(32'sd222, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM)};
        dut.sram0.memory[8]  = {{11'b0, 1'b0, 13'b0, `OPC_SYSTEM},
                                 encode_i(32'sd333, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut.sram0.memory[9]  = {encode_i(32'sd999, 5'd0, 3'b000, 5'd29, `OPC_OP_IMM),
                                 encode_i(32'sd444, 5'd0, 3'b000, 5'd4, `OPC_OP_IMM)};
        dut.sram0.memory[10] = {encode_i(32'sd555, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                 encode_csr(`CSR_MSCRATCH, 5'd29, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[11] = {encode_i(32'sd666, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM),
                                 `INSTR_HEX_MRET};
        dut.sram0.memory[12] = {encode_csr(`CSR_SEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd108, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[13] = {encode_i(32'sd777, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM),
                                 `INSTR_HEX_SRET};
        dut.sram0.memory[14] = {encode_i(32'sd888, 5'd0, 3'b000, 5'd8, `OPC_OP_IMM),
                                 `INSTR_HEX_SRET};
        dut.sram0.memory[15] = {`INSTR_HEX_WFI,
                                 encode_i(32'sd11, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM)};
        dut.sram0.memory[16] = {encode_r(`FUNCT7_SFENCE_VMA, 5'd0, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM),
                                 encode_i(32'sd22, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM)};
        dut.sram0.memory[17] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                 encode_i(32'sd33, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM)};
        dut.sram0.memory[18] = {encode_i(32'sd4, 5'd30, 3'b000, 5'd30, `OPC_OP_IMM),
                                 encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd30, `OPC_SYSTEM)};
        dut.sram0.memory[19] = {`INSTR_HEX_MRET,
                                 encode_csr(`CSR_MEPC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[20] = {encode_i(32'sd4, 5'd30, 3'b000, 5'd30, `OPC_OP_IMM),
                                 encode_csr(`CSR_SEPC, 5'd0, `FUNCT3_CSRRS, 5'd30, `OPC_SYSTEM)};
        dut.sram0.memory[21] = {`INSTR_HEX_SRET,
                                 encode_csr(`CSR_SEPC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "dut.halted never went high");

        /* Marker registers -- structural proof control flow visited every phase, in order, and returned correctly each time. */
        check("x1 (phase 1 marker -- returned from M-mode ECALL)", dut.core0.regfile0.gp_registers[1], 64'd111);
        check("x2 (phase 2 marker -- now running in S-mode)", dut.core0.regfile0.gp_registers[2], 64'd222);
        check("x3 (phase 3 marker -- back in S after M-routed illegal-instruction trap)", dut.core0.regfile0.gp_registers[3], 64'd333);
        check("x4 (phase 4 marker -- back in S after delegated ECALL)", dut.core0.regfile0.gp_registers[4], 64'd444);
        check("x5 (phase 5 marker -- back in S after blocked CSR-privilege violation)", dut.core0.regfile0.gp_registers[5], 64'd555);
        check("x6 (phase 6a marker -- back in S after illegal MRET-from-S)", dut.core0.regfile0.gp_registers[6], 64'd666);
        check("x7 (phase 6b marker -- now running in U-mode)", dut.core0.regfile0.gp_registers[7], 64'd777);
        check("x8 (phase 6b marker -- back in U after illegal SRET-from-U)", dut.core0.regfile0.gp_registers[8], 64'd888);
        check("x9 (phase 7 before-WFI marker)", dut.core0.regfile0.gp_registers[9], 64'd11);
        check("x10 (phase 7 after-WFI marker -- WFI was a true no-op)", dut.core0.regfile0.gp_registers[10], 64'd22);
        check("x11 (phase 7 after-SFENCE.VMA marker -- SFENCE.VMA was a true no-op)", dut.core0.regfile0.gp_registers[11], 64'd33);

        /* Phase 1: white-box mcause sample, taken before phase 3/5/6a's own M-target traps overwrite mcause_q. */
        check("phase 1 mcause sample was captured (sanity on the monitor itself)", {63'b0, mcause_sample_captured}, 64'd1);
        check("phase 1: mcause == 11 (ECALL from M-mode), M never delegates", mcause_sampled, `WORD_SIZE'(11));

        /* Phase 3: white-box current_priv sample, proving the M-routed trap correctly restored S (not stranded in M/U). */
        check("phase 3 current_priv sample was captured (sanity on the monitor itself)", {63'b0, priv_sample_phase3_captured}, 64'd1);
        check("phase 3: current_priv == S at the marker (M-routed trap correctly restored S via MPP)", {62'b0, priv_sampled_phase3}, `WORD_SIZE'(2'b01));

        /* Phase 4: scause is never touched again after this phase, safe to check post-halt directly. */
        check("phase 4: scause == 9 (ECALL from S, delegated)", dut.core0.csr_file0.scause_q, `WORD_SIZE'(9));

        /* Phase 5: white-box proof the illegal CSR write never actually landed. */
        check("phase 5 csr_we sample was captured (sanity on the monitor itself)", {63'b0, csr_we_sample_phase5_captured}, 64'd1);
        check("phase 5: csr_we reads 0 during the CSR-privilege-violation instruction's S_EXEC (true block, not coincidence)",
              {63'b0, csr_we_sampled_phase5}, 64'd0);
        check("phase 5: mscratch was never actually written (still 0)", dut.core0.csr_file0.mscratch_q, `WORD_SIZE'(0));

        /* Phase 6a: white-box proof MRET's own semantics didn't fire, a trap did instead. */
        check("phase 6a mret_taken sample was captured (sanity on the monitor itself)", {63'b0, mret_taken_sample_phase6a_captured}, 64'd1);
        check("phase 6a: mret_taken reads 0 (MRET-from-S didn't execute normally)", {63'b0, mret_taken_sampled_phase6a}, 64'd0);
        check("phase 6a trap_taken sample was captured (sanity on the monitor itself)", {63'b0, trap_taken_sample_phase6a_captured}, 64'd1);
        check("phase 6a: trap_taken reads 1 (illegal-instruction correctly raised instead)", {63'b0, trap_taken_sampled_phase6a}, 64'd1);

        /* Phase 6b: white-box proof SRET's own semantics didn't fire, a trap did instead. */
        check("phase 6b sret_taken sample was captured (sanity on the monitor itself)", {63'b0, sret_taken_sample_phase6b_captured}, 64'd1);
        check("phase 6b: sret_taken reads 0 (SRET-from-U didn't execute normally)", {63'b0, sret_taken_sampled_phase6b}, 64'd0);
        check("phase 6b trap_taken sample was captured (sanity on the monitor itself)", {63'b0, trap_taken_sample_phase6b_captured}, 64'd1);
        check("phase 6b: trap_taken reads 1 (illegal-instruction correctly raised instead)", {63'b0, trap_taken_sampled_phase6b}, 64'd1);

        /* Final state: current_priv ends at U (phase 6b's illegal SRET's own M-routed trap restored MPP=U, per current_priv at that trap's entry). */
        check("final current_priv == U", {62'b0, dut.core0.current_priv}, `WORD_SIZE'(2'b00));
        /*
         * Final mcause/mtval: the LAST M-target trap overall is phase 6b's
         * illegal SRET-from-U (also cause 2, also undelegated since
         * medeleg[2]=0 -- it runs AFTER phase 6a's illegal MRET-from-S in
         * program order) -- confirms its own raw encoding was captured,
         * not phase 6a's.
         */
        check("final mcause == 2 (illegal instruction, from phase 6b's own M-routed trap)", dut.core0.csr_file0.mcause_q, `WORD_SIZE'(2));
        check("final mtval == the illegal SRET's own raw encoding (phase 6b)", dut.core0.csr_file0.mtval_q, `WORD_SIZE'(`INSTR_HEX_SRET));

        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_priv_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_priv_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
