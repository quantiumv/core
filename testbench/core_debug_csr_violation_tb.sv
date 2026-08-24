// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, an ordinary CSR access to any Debug-mode CSR
 * (dcsr/dpc/dscratch0/dscratch1) genuinely trapping as illegal-
 * instruction (cause 2) outside Debug Mode.
 *
 * Milestone 3 of the EBREAK/JTAG staged plan: in_debug_mode is tied 0
 * in design/core.sv until Milestone 4 builds the real halt/resume FSM,
 * so EVERY access to these four addresses traps right now, from any
 * privilege level -- this file proves exactly that (the only testable
 * half this milestone; the inside-Debug-Mode-legal half needs M4's real
 * in_debug_mode). Coverage, in program order:
 *   - M-mode READ access to all 4 addresses traps (dcsr/dpc/dscratch0/
 *     dscratch1).
 *   - M-mode WRITE access (csrrw, a genuine, non-suppressed write --
 *     unlike the csrrs-with-rs1=x0 reads above) traps too --
 *     debug_csr_violation is deliberately NOT gated on write-suppression
 *     the way csr_readonly_violation is.
 *   - Two negative controls proving debug_csr_violation doesn't
 *     over-fire: an ordinary CSR (mscratch) access succeeds normally,
 *     and accesses to the addresses immediately adjacent to the 4-CSR
 *     block (0x7AF below, 0x7B4 above) do NOT trap -- pins down
 *     is_debug_csr_addr's exact range-check boundary.
 *   - Privilege is then dropped M -> S (via mret) and S -> U (via sret,
 *     the established core_priv_tb.sv-precedented mechanism), and a
 *     debug-CSR access is repeated from each level. Both of these also
 *     exercise the DUAL-violation case for free: csr_priv_violation
 *     (imm_2[9:8]==2'b11, a magnitude comparison against current_priv)
 *     is independently true from S/U for these same addresses, so this
 *     is the only place in the suite where csr_priv_violation and
 *     debug_csr_violation are simultaneously true, proving the OR-
 *     composition in is_illegal_instr doesn't need them to be mutually
 *     exclusive.
 *
 * Mirrors core_csr_readonly_trap_tb.sv's own M_TRAP_HANDLER pattern
 * (read mepc, skip past the faulting instruction, write back, mret) and
 * its point-in-time-snapshot discipline (mtvec stays armed through this
 * file's own terminating ebreak, which -- a real trap since the EBREAK
 * milestone -- bounces back into the handler once it fires; live
 * post-halt CSR reads are not safe against that). medeleg is never
 * written (stays 0 from reset), so every trap -- regardless of which
 * privilege it's taken FROM -- targets M-mode and lands in the same
 * shared handler; no separate S-mode handler infrastructure is needed.
 */
module core_debug_csr_violation_tb;

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
     * mcause_q/mtval_q snapshot, taken at the resume point right after
     * the LAST trap (the U-mode dpc access) resolves (pc==0x58, before
     * ebreak executes) -- NOT read live at check() time. Same reasoning
     * as core_csr_readonly_trap_tb.sv's own identical snapshot.
     */
    logic [63:0] mcause_snap, mtval_snap;
    logic resumed_last = 1'b0;
    always @(posedge clk) if (!resumed_last && dut.core0.commit_now && dut.core0.pc == 64'h58) begin
        resumed_last <= 1'b1;
        mcause_snap  <= dut.core0.csr_file0.mcause_q;
        mtval_snap   <= dut.core0.csr_file0.mtval_q;
    end

    logic [31:0] dpc_u_insn;

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * addr  instr                                    notes
         *  0x00  addi x30, x0, 92 (0x5C)                 x30 = M_TRAP_HANDLER address
         *  0x04  csrrw x0, mtvec, x30
         *  0x08  csrrs x1, dcsr, x0                       TRAP -- M-mode read (resumes 0x0C)
         *  0x0C  csrrs x2, dpc, x0                        TRAP -- M-mode read (resumes 0x10)
         *  0x10  csrrs x3, dscratch0, x0                  TRAP -- M-mode read (resumes 0x14)
         *  0x14  csrrs x4, dscratch1, x0                  TRAP -- M-mode read (resumes 0x18)
         *  0x18  addi x6, x0, 85 (0x55)                   write payload
         *  0x1C  csrrw x0, dcsr, x6                       TRAP -- M-mode WRITE, not suppressed (resumes 0x20)
         *  0x20  csrrs x5, mscratch, x0                   NOT a trap -- ordinary CSR, negative control
         *  0x24  csrrs x7, 0x7AF, x0                       NOT a trap -- one below the block, negative control
         *  0x28  csrrs x8, 0x7B4, x0                       NOT a trap -- one above the block, negative control
         *  0x2C  addi x11, x0, 2047 (0x7FF)
         *  0x30  addi x11, x11, 1                          x11 = 0x800 (mstatus.MPP = S, bit 11)
         *  0x34  csrrw x0, mstatus, x11
         *  0x38  addi x12, x0, 68 (0x44)                   S-mode continuation address
         *  0x3C  csrrw x0, mepc, x12
         *  0x40  mret                                      -> S-mode, pc = 0x44
         *  0x44  csrrs x13, dcsr, x0                        TRAP -- S-mode read, DUAL violation (resumes 0x48)
         *  0x48  addi x14, x0, 84 (0x54)                    U-mode continuation address
         *  0x4C  csrrw x0, sepc, x14
         *  0x50  sret                                       -> U-mode, pc = 0x54 (SPP still 0/U, never set)
         *  0x54  csrrs x15, dpc, x0                         TRAP -- U-mode read, DUAL violation (resumes 0x58)
         *  0x58  ebreak
         * -- M_TRAP_HANDLER (0x5C) --
         *  0x5C  csrrs x10, mepc, x0
         *  0x60  addi x10, x10, 4                          +4 -- every faulting instruction here is a
         *                                                   real 32-bit encoding, not compressed
         *  0x64  csrrw x0, mepc, x10
         *  0x68  addi x28, x28, 1                           trap_count++
         *  0x6C  mret
         */
        dpc_u_insn = encode_csr(12'h7B1, 5'd0, `FUNCT3_CSRRS, 5'd15, `OPC_SYSTEM);

        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),      // 0x04
                                encode_i(32'sd92, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)};                 // 0x00
        dut.sram0.memory[1] = {encode_csr(12'h7B1, 5'd0, `FUNCT3_CSRRS, 5'd2, `OPC_SYSTEM),          // 0x0C: dpc
                                encode_csr(12'h7B0, 5'd0, `FUNCT3_CSRRS, 5'd1, `OPC_SYSTEM)};         // 0x08: dcsr
        dut.sram0.memory[2] = {encode_csr(12'h7B3, 5'd0, `FUNCT3_CSRRS, 5'd4, `OPC_SYSTEM),          // 0x14: dscratch1
                                encode_csr(12'h7B2, 5'd0, `FUNCT3_CSRRS, 5'd3, `OPC_SYSTEM)};         // 0x10: dscratch0
        dut.sram0.memory[3] = {encode_csr(12'h7B0, 5'd6, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),          // 0x1C: csrrw x0,dcsr,x6
                                encode_i(32'sd85, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM)};                  // 0x18
        dut.sram0.memory[4] = {encode_csr(12'h7AF, 5'd0, `FUNCT3_CSRRS, 5'd7, `OPC_SYSTEM),          // 0x24: 0x7AF (below)
                                encode_csr(`CSR_MSCRATCH, 5'd0, `FUNCT3_CSRRS, 5'd5, `OPC_SYSTEM)};   // 0x20: mscratch
        dut.sram0.memory[5] = {encode_i(32'sd2047, 5'd0, 3'b000, 5'd11, `OPC_OP_IMM),                // 0x2C
                                encode_csr(12'h7B4, 5'd0, `FUNCT3_CSRRS, 5'd8, `OPC_SYSTEM)};         // 0x28: 0x7B4 (above)
        dut.sram0.memory[6] = {encode_csr(`CSR_MSTATUS, 5'd11, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),    // 0x34
                                encode_i(32'sd1, 5'd11, 3'b000, 5'd11, `OPC_OP_IMM)};                 // 0x30
        dut.sram0.memory[7] = {encode_csr(`CSR_MEPC, 5'd12, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),       // 0x3C
                                encode_i(32'sd68, 5'd0, 3'b000, 5'd12, `OPC_OP_IMM)};                 // 0x38
        dut.sram0.memory[8] = {encode_csr(12'h7B0, 5'd0, `FUNCT3_CSRRS, 5'd13, `OPC_SYSTEM),         // 0x44: dcsr, S-mode
                                `INSTR_HEX_MRET};                                                     // 0x40
        dut.sram0.memory[9] = {encode_csr(`CSR_SEPC, 5'd14, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),       // 0x4C
                                encode_i(32'sd84, 5'd0, 3'b000, 5'd14, `OPC_OP_IMM)};                 // 0x48
        dut.sram0.memory[10] = {dpc_u_insn,                                                           // 0x54: dpc, U-mode
                                 `INSTR_HEX_SRET};                                                    // 0x50
        dut.sram0.memory[11] = {encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM),      // 0x5C
                                 {11'b0, 1'b1, 13'b0, `OPC_SYSTEM}};                                  // 0x58: ebreak
        dut.sram0.memory[12] = {encode_csr(`CSR_MEPC, 5'd10, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),      // 0x64
                                 encode_i(32'sd4, 5'd10, 3'b000, 5'd10, `OPC_OP_IMM)};                // 0x60
        dut.sram0.memory[13] = {`INSTR_HEX_MRET,                                                      // 0x6C
                                 encode_i(32'sd1, 5'd28, 3'b000, 5'd28, `OPC_OP_IMM)};                // 0x68

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        check("x1 never written -- dcsr M-mode read trapped", dut.core0.regfile0.gp_registers[1], 64'd0);
        check("x2 never written -- dpc M-mode read trapped", dut.core0.regfile0.gp_registers[2], 64'd0);
        check("x3 never written -- dscratch0 M-mode read trapped", dut.core0.regfile0.gp_registers[3], 64'd0);
        check("x4 never written -- dscratch1 M-mode read trapped", dut.core0.regfile0.gp_registers[4], 64'd0);
        check("x6 == 85 -- write payload register itself unaffected by the trapped csrrw",
            dut.core0.regfile0.gp_registers[6], 64'd85);
        check("x5 == 0 -- ordinary mscratch access did NOT trap (negative control)",
            dut.core0.regfile0.gp_registers[5], 64'd0);
        check("x7 == 0 -- 0x7AF (below the block) did NOT trap (boundary control)",
            dut.core0.regfile0.gp_registers[7], 64'd0);
        check("x8 == 0 -- 0x7B4 (above the block) did NOT trap (boundary control)",
            dut.core0.regfile0.gp_registers[8], 64'd0);
        check("x13 never written -- dcsr S-mode read trapped (dual-violation path)",
            dut.core0.regfile0.gp_registers[13], 64'd0);
        check("x15 never written -- dpc U-mode read trapped (dual-violation path)",
            dut.core0.regfile0.gp_registers[15], 64'd0);
        check("trap_count == 7 -- 4 M-reads + 1 M-write + 1 S-read + 1 U-read, nothing else",
            dut.core0.regfile0.gp_registers[28], 64'd7);
        check("mcause == 2 (illegal instruction) for the last (U-mode dpc) trap",
            mcause_snap, 64'd2);
        check("mtval == the U-mode dpc csrrs's own raw 32-bit encoding",
            mtval_snap, {32'b0, dpc_u_insn});
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_debug_csr_violation_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_debug_csr_violation_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
