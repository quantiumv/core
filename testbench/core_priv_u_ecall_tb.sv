// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "defaults/defaults.sv"
`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: ECALL-from-U-mode, and SFENCE.VMA with real (non-x0) operands.
 *
 * A separate, small file rather than an addition to the already-passing
 * core_priv_tb.sv -- this project's own convention this session is one
 * file per new concern, not patching an already-verified file. Same
 * core_wb4_sram_harness + check_lib.sv + halt_wait.sv + pc_trigger_
 * sample_monitor.sv pattern core_priv_tb.sv itself established; read that
 * file first for the exact conventions this mirrors.
 *
 * core_priv_tb.sv exercises ECALL from M-mode (cause 11) and ECALL from
 * S-mode (cause 9, delegated) but never from U-mode (cause 8) -- this
 * closes that gap. It also only ever calls SFENCE.VMA with rs1=x0/rs2=x0
 * (the trivial "flush everything" case); this exercises real, distinct,
 * non-zero rs1/rs2 operands, proving decode extracts them as genuine
 * register-address fields rather than silently behaving as though they
 * were hardwired to x0 -- SFENCE.VMA reuses decoder.sv's general
 * `OUTPUT_R_TYPE_INSTR macro unchanged (the same mechanism already
 * proven for the base ALU ops, the *W family, and all 13 M-extension
 * instructions -- see decoder.sv's own comment just above its
 * SFENCE.VMA arm), so this is a decode-plumbing proof, not a
 * behavioral one: SFENCE.VMA is presently an unconditional NOP
 * regardless of operands (no TLB exists yet -- see core.sv's own
 * comment on why SFENCE.VMA is deliberately excluded from the
 * illegal-instruction privilege check, unlike every other privileged
 * instruction this milestone).
 *
 * Register allocation discipline (this project's own hard requirement,
 * hit by name in an earlier testbench's own bug history): every register
 * checked via check() below is written EXACTLY ONCE by this program and
 * never touched again. x28 (bootstrap scratch) and x30 (trap-handler
 * scratch, shared by M_TRAP_HANDLER/S_TRAP_HANDLER) are the only
 * registers reused -- neither is ever passed to check().
 *
 * Program structure, in order:
 *  1. Setup (M-mode, idx0-4): point mtvec at M_TRAP_HANDLER and stvec at
 *     S_TRAP_HANDLER (the latter wired up harmlessly, matching the task's
 *     own ask, even though this program's control flow never actually
 *     reaches U-mode via S -- it goes straight M -> U). medeleg is
 *     deliberately left at its reset value of 0 throughout (never
 *     written) -- this is what makes ECALL-from-U route to M
 *     unconditionally rather than delegating: trap_to_s = trap_taken &&
 *     (current_priv != PRIV_M) && medeleg_w[exc_code], and
 *     medeleg_w[8] == 0. csrrw x0, mstatus, x0 explicitly zeroes
 *     mstatus (including MPP) rather than relying on mstatus's reset
 *     value already being 0 -- self-documenting, and robust to a future
 *     change in reset behavior.
 *  2. Bootstrap M -> U (idx5-7): mepc <- address of the first U-mode
 *     instruction (idx8, the ECALL below), mret. mstatus.MPP is already
 *     U (2'b00) from step 1, so this single mret lands directly in
 *     U-mode -- simpler than the two-hop M->S->U core_priv_tb.sv itself
 *     uses, and sufficient here since S-mode plays no other role in this
 *     test.
 *  3. ECALL from U-mode (idx8/9): traps with mcause == 8 (ECALL from
 *     U -- see core.sv's exc_code wire: is_ecall && current_priv ==
 *     PRIV_U -> 4'd8), routes to M (medeleg[8] == 0, and even if it were
 *     set, current_priv wasn't M so that path isn't what forces this --
 *     it's the undelegated bit that does). M_TRAP_HANDLER's mret
 *     restores current_priv from mstatus.MPP, which trap-entry captured
 *     as U (the current_priv AT THE TIME of the ECALL) -- so control
 *     genuinely returns to U-mode, not M. mcause is checked directly
 *     post-halt (this program's only trap; nothing overwrites mcause_q
 *     afterward, same reasoning core_priv_tb.sv itself uses for its own
 *     post-halt scause check). current_priv is checked via a white-box
 *     pc_trigger_sample_monitor at the marker's own PC (mirroring
 *     core_priv_tb.sv's own phase-3 current_priv sample) rather than
 *     post-halt, since that is the specific instant the task asks this
 *     to be confirmed at -- even though nothing in this particular
 *     program later changes current_priv again either.
 *  4. SFENCE.VMA with real operands (idx10-14), still in U-mode: x5 <-
 *     1200 (an address-shaped value -- large enough to not look like a
 *     small flag/count), x6 <- 7 (an ASID-shaped value -- small, the
 *     typical shape of a real ASID), then sfence.vma x5, x6 (rs1=x5,
 *     rs2=x6, per the ISA's own asm operand order). Bracketed by a
 *     before-marker (x9) and after-marker (x10) proving it's still a
 *     clean no-op with real operands, not just the trivial x0,x0 case
 *     core_priv_tb.sv's own phase 7 already covers. White-box-sampled at
 *     the SFENCE.VMA instruction's own PC (matching core_priv_tb.sv's
 *     own phase-5 csr_we_monitor precedent -- sampling the instruction's
 *     own PC, not a marker after it): core.sv's read_gpr_A_sel/
 *     read_gpr_B_sel (the decoded register-address fields feeding the
 *     register file's two read ports, driven by decoder.sv's
 *     `OUTPUT_R_TYPE_INSTR -> `PASS_REG_A_IN_IMM_1/`PASS_REG_B_IN_IMM_2)
 *     must read 5 and 6 respectively that cycle -- proves decode
 *     genuinely extracted rs1=x5/rs2=x6 from the encoding, not a
 *     coincidental match with some other field defaulting to the right
 *     value. x5/x6 are also confirmed still holding their original
 *     values post-halt, direct extra confirmation the NOP didn't
 *     clobber them.
 *  5. ebreak (idx15) -- halts. Deliberately NOT wired into the trap
 *     mechanism this milestone (see the project plan / memory
 *     known-gap-ebreak-sim-halt) -- still the plain sim-only halt every
 *     other testbench in this project depends on.
 */
module core_priv_u_ecall_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(32)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    logic halted = 1'b0;
    always @(posedge clk) if (dut.core0.trap_taken && dut.core0.is_ebreak) halted <= 1'b1;
    `include "halt_wait.sv"

    /*
     * mcause_q/current_priv snapshot, taken on the SAME edge the terminal
     * ebreak's own trap_taken first fires -- NOT read live at check()
     * time. mtvec stays armed at M_TRAP_HANDLER through the terminal
     * ebreak (idx15), which now really traps and bounces right back into
     * it, corrupting mcause_q/current_priv afterward (same class of bug
     * as core_priv_tb.sv/core_priv_toolchain_tb.sv -- see their own
     * comments). mcause_q's own always_ff writes non-blocking on
     * i_trap_taken, so reading it on this identical edge sees the
     * PRE-edge value -- whatever it held from phase 1's own trap, before
     * this ebreak's own entry overwrites it.
     */
    logic [63:0] final_mcause_snap;
    logic [1:0]  final_priv_snap;
    logic final_state_captured = 1'b0;
    always @(posedge clk) if (!final_state_captured && dut.core0.trap_taken && dut.core0.is_ebreak) begin
        final_state_captured <= 1'b1;
        final_mcause_snap <= dut.core0.csr_file0.mcause_q;
        final_priv_snap   <= dut.core0.current_priv;
    end

    /*
     * White-box monitors. state_t's declared order in core.sv is
     * {S_FETCH, S_EXEC, S_MEM} = {0, 1, 2}, hence the literal 2'd1 below
     * (matching core_priv_tb.sv/core_zicsr_tb.sv's own precedent).
     */
    localparam logic [63:0] PC_ECALL_U_MARKER  = 64'h24; // idx9
    localparam logic [63:0] PC_SFENCE_TRIGGER  = 64'h34; // idx13

    logic [1:0] priv_sampled_ecall_u;
    logic priv_sample_ecall_u_captured;
    pc_trigger_sample_monitor #(.WIDTH(2)) priv_monitor_ecall_u (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_ECALL_U_MARKER), .i_sample(dut.core0.current_priv),
        .o_sampled(priv_sampled_ecall_u), .o_captured(priv_sample_ecall_u_captured)
    );

    logic [4:0] rs1_sel_sampled_sfence, rs2_sel_sampled_sfence;
    logic rs1_sel_sample_sfence_captured, rs2_sel_sample_sfence_captured;
    pc_trigger_sample_monitor #(.WIDTH(5)) rs1_sel_monitor_sfence (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_SFENCE_TRIGGER), .i_sample(dut.core0.read_gpr_A_sel),
        .o_sampled(rs1_sel_sampled_sfence), .o_captured(rs1_sel_sample_sfence_captured)
    );
    pc_trigger_sample_monitor #(.WIDTH(5)) rs2_sel_monitor_sfence (
        .clk(clk), .i_state(dut.core0.state), .i_state_target(2'd1),
        .i_pc(dut.core0.pc), .i_pc_target(PC_SFENCE_TRIGGER), .i_sample(dut.core0.read_gpr_B_sel),
        .o_sampled(rs2_sel_sampled_sfence), .o_captured(rs2_sel_sample_sfence_captured)
    );

    initial begin
        #1; // run after wb4_sram's own time-0 init (see header comment)

        /*
         * addr  idx  instruction                            notes
         * -- Setup (M-mode) --
         *  0x00   0  addi x28, x0, 0x40 (64)                 x28 = M_TRAP_HANDLER address
         *  0x04   1  csrrw x0, mtvec, x28
         *  0x08   2  addi x28, x0, 0x50 (80)                 x28 = S_TRAP_HANDLER address
         *  0x0C   3  csrrw x0, stvec, x28
         *  0x10   4  csrrw x0, mstatus, x0                   explicit mstatus <- 0 (MPP = U)
         * -- Bootstrap M -> U --
         *  0x14   5  addi x28, x0, 0x20 (32)                 x28 = addr of idx8
         *  0x18   6  csrrw x0, mepc, x28
         *  0x1C   7  mret                                    current_priv <- U (MPP), jump to idx8
         * -- Phase 1: ECALL from U (never delegated: medeleg is untouched, stays 0) --
         *  0x20   8  ecall
         *  0x24   9  addi x1, x0, 811                        marker + current_priv white-box sample point
         * -- Phase 2: SFENCE.VMA with real, non-x0 operands --
         *  0x28  10  addi x9, x0, 344                        before marker
         *  0x2C  11  addi x5, x0, 1200                        x5 = address-shaped operand (rs1)
         *  0x30  12  addi x6, x0, 7                           x6 = ASID-shaped operand (rs2)
         *  0x34  13  sfence.vma x5, x6                        real operands -- rs1/rs2 white-box sample point
         *  0x38  14  addi x10, x0, 455                        after marker
         * -- Phase 3: halt --
         *  0x3C  15  ebreak
         * -- M_TRAP_HANDLER --
         *  0x40  16  csrrs x30, mepc, x0
         *  0x44  17  addi x30, x30, 4
         *  0x48  18  csrrw x0, mepc, x30
         *  0x4C  19  mret
         * -- S_TRAP_HANDLER (wired up, never actually reached by this program) --
         *  0x50  20  csrrs x30, sepc, x0
         *  0x54  21  addi x30, x30, 4
         *  0x58  22  csrrw x0, sepc, x30
         *  0x5C  23  sret
         */
        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd64, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[1] = {encode_csr(`CSR_STVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd80, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[2] = {encode_i(32'sd32, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),
                                encode_csr(`CSR_MSTATUS, 5'd0, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[3] = {`INSTR_HEX_MRET,
                                encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[4] = {encode_i(32'sd811, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                {11'b0, 1'b0, 13'b0, `OPC_SYSTEM}}; // idx8: ecall
        dut.sram0.memory[5] = {encode_i(32'sd1200, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                encode_i(32'sd344, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM)};
        dut.sram0.memory[6] = {encode_r(`FUNCT7_SFENCE_VMA, 5'd6, 5'd5, 3'b000, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd7, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM)};
        dut.sram0.memory[7] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // idx15: ebreak
                                encode_i(32'sd455, 5'd0, 3'b000, 5'd10, `OPC_OP_IMM)};
        dut.sram0.memory[8] = {encode_i(32'sd4, 5'd30, 3'b000, 5'd30, `OPC_OP_IMM),
                                encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd30, `OPC_SYSTEM)};
        dut.sram0.memory[9] = {`INSTR_HEX_MRET,
                                encode_csr(`CSR_MEPC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut.sram0.memory[10] = {encode_i(32'sd4, 5'd30, 3'b000, 5'd30, `OPC_OP_IMM),
                                 encode_csr(`CSR_SEPC, 5'd0, `FUNCT3_CSRRS, 5'd30, `OPC_SYSTEM)};
        dut.sram0.memory[11] = {`INSTR_HEX_SRET,
                                 encode_csr(`CSR_SEPC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_TINY, "EBREAK trap never fired");

        /* Marker registers -- structural proof control flow visited every phase, in order, and returned correctly each time. */
        check("x1 (phase 1 marker -- returned from U-mode ECALL)", dut.core0.regfile0.gp_registers[1], 64'd811);
        check("x9 (phase 2 before-SFENCE.VMA marker)", dut.core0.regfile0.gp_registers[9], 64'd344);
        check("x10 (phase 2 after-SFENCE.VMA marker -- SFENCE.VMA with real operands was a true no-op)", dut.core0.regfile0.gp_registers[10], 64'd455);

        check("final-state sample was captured (sanity on the monitor itself)", {63'b0, final_state_captured}, 64'd1);
        /* Phase 1: mcause is this program's only trap, never overwritten afterward -- safe to check directly, post-halt. */
        check("phase 1: mcause == 8 (ECALL from U-mode)", final_mcause_snap, `WORD_SIZE'(8));

        /* Phase 1: white-box current_priv sample at the marker's own PC, proving control genuinely returned to U (not stranded in M). */
        check("phase 1 current_priv sample was captured (sanity on the monitor itself)", {63'b0, priv_sample_ecall_u_captured}, 64'd1);
        check("phase 1: current_priv == U at the marker (M-routed U-mode ECALL correctly restored U via MPP)", {62'b0, priv_sampled_ecall_u}, `WORD_SIZE'(2'b00));

        /* Phase 2: white-box proof decode extracted SFENCE.VMA's real rs1/rs2 fields, not hardwired zero. */
        check("phase 2 rs1_sel sample was captured (sanity on the monitor itself)", {63'b0, rs1_sel_sample_sfence_captured}, 64'd1);
        check("phase 2: read_gpr_A_sel == x5 during SFENCE.VMA's own S_EXEC (real rs1, not hardwired to x0)", {59'b0, rs1_sel_sampled_sfence}, `WORD_SIZE'(5));
        check("phase 2 rs2_sel sample was captured (sanity on the monitor itself)", {63'b0, rs2_sel_sample_sfence_captured}, 64'd1);
        check("phase 2: read_gpr_B_sel == x6 during SFENCE.VMA's own S_EXEC (real rs2, not hardwired to x0)", {59'b0, rs2_sel_sampled_sfence}, `WORD_SIZE'(6));

        /* Phase 2: x5/x6 themselves are never touched again after idx11/12 -- direct extra confirmation the NOP didn't clobber its own operands. */
        check("x5 (SFENCE.VMA's rs1 operand, address-shaped) unchanged after the no-op", dut.core0.regfile0.gp_registers[5], 64'd1200);
        check("x6 (SFENCE.VMA's rs2 operand, ASID-shaped) unchanged after the no-op", dut.core0.regfile0.gp_registers[6], 64'd7);

        /* Final state: current_priv stays U for the rest of the program (nothing after phase 1 changes it). */
        check("final current_priv == U", {62'b0, final_priv_snap}, `WORD_SIZE'(2'b00));

        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_priv_u_ecall_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_priv_u_ecall_tb: FAILURES PRESENT");
        $finish;
    end

endmodule
