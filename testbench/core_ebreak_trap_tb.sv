// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: EBREAK genuinely trapping through the real core (cause 3,
 * Breakpoint) -- the direct proof for the milestone that made EBREAK a
 * real spec-compliant trap instead of a permanent simulation-only halt
 * (see design/core.sv's own comment at the rvfi_intr/pc-register site).
 *
 * Two independent scenarios, each via its own core_wb4_sram_harness
 * instance, mirroring core_priv_tb.sv's own multi-phase style but kept in
 * ONE file since both are squarely "EBREAK's own trap behavior," not
 * separate concerns:
 *
 *  1. M-mode EBREAK: mtvec armed, no delegation. Proves mcause==3, mepc==
 *     the ebreak's own address, mtval==0 (this cause's own decision --
 *     see core.sv's trap_val mux, which deliberately has no explicit
 *     EBREAK arm and falls through to the default 0), PC genuinely lands
 *     at mtvec (not a freeze), a marker inside the handler actually
 *     executes (real forward progress -- categorically untestable before
 *     this milestone), and a SECOND ebreak (the handler's own completion
 *     signal) is correctly observed by this testbench's new sticky-latch
 *     mechanism -- the first real consumer/proof of testbench/
 *     halt_wait.sv's post-milestone contract (see its own header comment).
 *  2. S-mode EBREAK, delegated via medeleg bit 3: proves EBREAK is a real,
 *     ordinary exception as far as delegation is concerned -- scause==3,
 *     sepc==the ebreak's own address, current_priv stays S (never routed
 *     to M), exercising trap_to_s's own EBREAK arm for the first time.
 *
 * Both handlers read mepc/mcause (or sepc/scause) into GPRs via csrr,
 * THEN set a marker, THEN hit their own completion ebreak -- deliberately
 * NOT read live from csr_file0.*_q at check() time. mtvec/stvec stay
 * armed through each scenario's own completion ebreak, which (now a real
 * trap) bounces right back into the same handler and can keep executing
 * indefinitely; GPR values captured by an earlier instruction are stable
 * against that regardless of how many extra bounce-back passes happen
 * afterward, live CSR reads are not -- the exact bug class this
 * milestone's own testbench sweep found and fixed across five other
 * files (core_priv_tb.sv, core_priv_toolchain_tb.sv, core_priv_u_ecall_tb.sv,
 * core_c_illegal_trap_tb.sv, soc_interrupt_tb.sv, plus core_interrupt_tb.sv's
 * own Case 6/etc. redesign) -- see any of their own comments for the full
 * story of why a live post-halt CSR read is no longer safe here.
 */
module core_ebreak_trap_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    /* ----------------------------------------------------------------- *
     * Scenario 1: M-mode EBREAK trap
     * ----------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_m (.clk(clk), .rst(rst));

    /*
     * GPR snapshot, taken on the SAME edge as halted_m's own latch --
     * NOT read live at check() time. mtvec stays armed at HANDLER through
     * the completion ebreak (0x20), which (a real trap now) bounces right
     * back into HANDLER and keeps re-executing it for as long as this
     * testbench's sequential wait_all block is still waiting on the OTHER
     * dut_s's own completion (dut_m keeps running independently in the
     * meantime) -- each extra pass re-executes csrrs x10,mepc with a NEW
     * (now-wrong) mepc value, silently corrupting x10 even though
     * halted_m itself correctly latched on the first, real completion
     * event. Gated on !halted_m so only the first pass is ever captured.
     */
    logic halted_m = 1'b0;
    logic [63:0] m_x1_snap, m_x10_snap, m_x11_snap, m_x12_snap, m_x13_snap;
    always @(posedge clk) if (!halted_m && dut_m.core0.trap_taken && dut_m.core0.is_ebreak
                               && dut_m.core0.pc == 64'h20) begin
        halted_m  <= 1'b1;
        m_x1_snap  <= dut_m.core0.regfile0.gp_registers[1];
        m_x10_snap <= dut_m.core0.regfile0.gp_registers[10];
        m_x11_snap <= dut_m.core0.regfile0.gp_registers[11];
        m_x12_snap <= dut_m.core0.regfile0.gp_registers[12];
        m_x13_snap <= dut_m.core0.regfile0.gp_registers[13];
    end

    /* ----------------------------------------------------------------- *
     * Scenario 2: S-mode EBREAK, delegated via medeleg bit 3
     * ----------------------------------------------------------------- */
    core_wb4_sram_harness #(.NUM_WORDS(32)) dut_s (.clk(clk), .rst(rst));

    // Same reasoning as dut_m's own snapshot above.
    logic halted_s = 1'b0;
    logic [63:0] s_x1_snap, s_x20_snap, s_x21_snap, s_x22_snap;
    logic [1:0]  s_priv_snap;
    always @(posedge clk) if (!halted_s && dut_s.core0.trap_taken && dut_s.core0.is_ebreak
                               && dut_s.core0.pc == 64'h6C) begin
        halted_s   <= 1'b1;
        s_x1_snap  <= dut_s.core0.regfile0.gp_registers[1];
        s_x20_snap <= dut_s.core0.regfile0.gp_registers[20];
        s_x21_snap <= dut_s.core0.regfile0.gp_registers[21];
        s_x22_snap <= dut_s.core0.regfile0.gp_registers[22];
        s_priv_snap <= dut_s.core0.current_priv;
    end

    initial begin
        #1; // run after every wb4_sram sub-instance's own time-0 crt0.hex init

        /*
         * ---- Scenario 1 program (M-mode), addr 0x00-0x23 ----
         * addr  instr                              notes
         *  0x00  addi x28, x0, 0x10 (16)            x28 = HANDLER address
         *  0x04  csrrw x0, mtvec, x28
         *  0x08  ebreak                             TRIGGER -- real trap now
         *  0x0C  addi x1, x0, 999                   poison -- must NEVER run
         *                                            (EBREAK doesn't fall
         *                                            through to the next pc)
         * -- HANDLER (0x10) --
         *  0x10  csrrs x10, mepc, x0
         *  0x14  csrrs x11, mcause, x0
         *  0x18  csrrs x12, mtval, x0
         *  0x1C  addi x13, x0, 1                    marker: real forward progress
         *  0x20  ebreak                             completion signal (2nd ebreak)
         */
        dut_m.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                  encode_i(32'sd16, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_m.sram0.memory[1] = {encode_i(32'sd999, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                  {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // idx 0x08: ebreak
        dut_m.sram0.memory[2] = {encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM),
                                  encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};
        dut_m.sram0.memory[3] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd13, `OPC_OP_IMM),
                                  encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM)};
        dut_m.sram0.memory[4] = {32'h0,
                                  {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // idx 0x20: ebreak (completion)

        /*
         * ---- Scenario 2 program (S-mode, delegated), addr 0x00-0x7B ----
         * addr  instr                              notes
         *  0x00  addi x28, x0, 0x78 (120)           x28 = M_HANDLER addr (safety net)
         *  0x04  csrrw x0, mtvec, x28
         *  0x08  addi x28, x0, 0x60 (96)            x28 = S_HANDLER addr
         *  0x0C  csrrw x0, stvec, x28
         *  0x10  addi x28, x0, 8                    medeleg bit 3 (EBREAK)
         *  0x14  csrrw x0, medeleg, x28
         *  0x18  addi x28, x0, 1
         *  0x1C  slli x28, x28, 11                  x28 = mstatus.MPP field = S
         *  0x20  csrrw x0, mstatus, x28
         *  0x24  addi x28, x0, 0x58 (88)            x28 = addr of TRIGGER2
         *  0x28  csrrw x0, mepc, x28
         *  0x2C  mret                               current_priv <- S, jump to 0x58
         *  0x58  ebreak                              TRIGGER2 -- delegated, real trap
         *  0x5C  addi x1, x0, 888                   poison2 -- must NEVER run
         * -- S_HANDLER (0x60) --
         *  0x60  csrrs x20, sepc, x0
         *  0x64  csrrs x21, scause, x0
         *  0x68  addi x22, x0, 1                    marker2: real forward progress in S
         *  0x6C  ebreak                              completion2 signal
         * -- M_HANDLER (0x78), safety net only -- reached iff delegation is broken --
         *  0x78  ebreak
         */
        dut_s.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                  encode_i(32'sd120, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_s.sram0.memory[1] = {encode_csr(`CSR_STVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                  encode_i(32'sd96, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_s.sram0.memory[2] = {encode_csr(`CSR_MEDELEG, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                  encode_i(32'sd8, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_s.sram0.memory[3] = {encode_shift64(6'b000000, 6'd11, 5'd28, 3'b001, 5'd28, `OPC_OP_IMM),
                                  encode_i(32'sd1, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut_s.sram0.memory[4] = {encode_i(32'sd88, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM),
                                  encode_csr(`CSR_MSTATUS, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut_s.sram0.memory[5] = {`INSTR_HEX_MRET,
                                  encode_csr(`CSR_MEPC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};
        dut_s.sram0.memory[11] = {encode_i(32'sd888, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM),
                                   {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // idx 0x58: ebreak (TRIGGER2)
        dut_s.sram0.memory[12] = {encode_csr(`CSR_SCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd21, `OPC_SYSTEM),
                                   encode_csr(`CSR_SEPC, 5'd0, `FUNCT3_CSRRS, 5'd20, `OPC_SYSTEM)};
        dut_s.sram0.memory[13] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM}, // idx 0x6C: ebreak (completion2)
                                   encode_i(32'sd1, 5'd0, 3'b000, 5'd22, `OPC_OP_IMM)};
        dut_s.sram0.memory[15] = {32'h0,
                                   {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}}; // idx 0x78: ebreak (M_HANDLER safety net)

        @(posedge clk); #1;
        rst = 0;

        fork
            begin : wait_all
                wait (halted_m === 1'b1);
                wait (halted_s === 1'b1);
            end
            begin : timeout
                // 300 cycles: matches halt_wait.sv's own TIMEOUT_CYCLES_SMALL
                // tier (not `include`d here -- its own wait_halted_or_timeout
                // task assumes a single signal literally named `halted`,
                // which doesn't fit this file's two-DUT shape).
                repeat (300) @(posedge clk);
                $display("TIMEOUT: not every DUT halted");
                $finish;
            end
        join_any
        #1;

        /* ---- Scenario 1 checks (M-mode) ---- */
        check("M: mepc == the ebreak's own address (0x08)", m_x10_snap, 64'h08);
        check("M: mcause == 3 (Breakpoint)", m_x11_snap, 64'd3);
        check("M: mtval == 0", m_x12_snap, 64'd0);
        check("M: poison marker never ran -- EBREAK does not fall through (x1==0)", m_x1_snap, 64'd0);
        check("M: handler ran -- real forward progress after the trap (x13==1)", m_x13_snap, 64'd1);
        check("M: second (completion) ebreak observed by the new sticky-latch contract", {63'b0, halted_m}, 64'd1);

        /* ---- Scenario 2 checks (S-mode, delegated) ---- */
        check("S: sepc == TRIGGER2's own address (0x58)", s_x20_snap, 64'h58);
        check("S: scause == 3 (Breakpoint, delegated -- not mcause)", s_x21_snap, 64'd3);
        check("S: poison2 marker never ran (x1==0)", s_x1_snap, 64'd0);
        check("S: handler ran -- real forward progress in S-mode (x22==1)", s_x22_snap, 64'd1);
        check("S: current_priv stayed S (never routed to M)", {62'b0, s_priv_snap}, 64'(2'b01));
        check("S: second (completion) ebreak observed", {63'b0, halted_s}, 64'd1);

        $display("");
        $display("core_ebreak_trap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_ebreak_trap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
