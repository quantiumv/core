// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, SFENCE.VMA classification + mstatus.TVM enforcement --
 * Milestone 2 of the Sv39 staged plan, via core_wb4_sram_harness (same
 * real-Wishbone-B4-slave harness core_debug_csr_violation_tb.sv/
 * core_pmp_tb.sv already use for this class of illegal-instruction test).
 *
 * Four cases in program order, all executed at TVM=0 in M-mode first
 * (cases A/B), then TVM=1 still in M-mode (cases C/D -- TVM only ever
 * gates S-mode, per spec), then a real M->S transition (mret) and the
 * two cases that must actually trap (E/F, both S-mode + TVM=1):
 *   A. M-mode, TVM=0: SFENCE.VMA -- no trap (baseline).
 *   B. M-mode, TVM=0: CSRRS satp -- no trap (baseline).
 *   C. M-mode, TVM=1: SFENCE.VMA -- no trap (TVM never gates M-mode).
 *   D. M-mode, TVM=1: CSRRS satp -- no trap (same reason).
 *   E. S-mode, TVM=1: SFENCE.VMA -- TRAPS, mcause=2 (illegal instruction).
 *   F. S-mode, TVM=1: CSRRS satp -- TRAPS, mcause=2, same reason.
 *
 * A CSRRS (not CSRRW) is used for every satp access -- per spec, TVM
 * gates "attempts to read OR write" satp, and tvm_violation's own RTL
 * condition (core.sv) checks is_satp_csr independent of write-suppression,
 * so a pure read is already a sufficient, minimal reproduction; no actual
 * satp value ever needs to be written for this milestone's own scope.
 *
 * medeleg is never written (stays 0 from reset), so every trap -- taken
 * from either M-mode (never, in this file) or S-mode -- lands in the
 * same shared M-mode handler, same "no separate S-mode handler
 * infrastructure needed" precedent core_debug_csr_violation_tb.sv already
 * established. That handler's own +4-skip-and-mret pattern is identical
 * to that file's own M_TRAP_HANDLER (every faulting instruction here is a
 * real 32-bit encoding, never compressed).
 *
 * Discriminator: since a trapped instruction's own resume point is still
 * reached (the handler skips past it and mrets back), simply reaching a
 * marker instruction does NOT by itself prove "no trap happened" -- the
 * real proof is trap_count (x28) sampled at the commit-edge boundary
 * right after cases A-D (before the M->S transition even begins) staying
 * 0, and mcause snapshotted right after each of E/F's own resume reading
 * back 2 -- not live reads at check() time (this core's own well-known
 * "the terminal ebreak bounces back through an already-armed handler a
 * second time" corruption class, since mtvec is never disarmed here).
 */
module core_sfence_vma_priv_tb;

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

    /* Point-in-time snapshots -- see the header comment above for why
     * these, and not live post-halt reads, are the real proof here. */
    logic [63:0] trap_count_before_smode;
    logic        captured_before_smode = 1'b0;
    always @(posedge clk) if (!captured_before_smode && dut.core0.commit_now && dut.core0.pc == 64'h34) begin
        captured_before_smode  <= 1'b1;
        trap_count_before_smode <= dut.core0.regfile0.gp_registers[28];
    end

    logic [63:0] mcause_after_e;
    logic        captured_after_e = 1'b0;
    always @(posedge clk) if (!captured_after_e && dut.core0.commit_now && dut.core0.pc == 64'h50) begin
        captured_after_e <= 1'b1;
        mcause_after_e   <= dut.core0.csr_file0.mcause_q;
    end

    logic [63:0] mcause_after_f;
    logic        captured_after_f = 1'b0;
    always @(posedge clk) if (!captured_after_f && dut.core0.commit_now && dut.core0.pc == 64'h58) begin
        captured_after_f <= 1'b1;
        mcause_after_f   <= dut.core0.csr_file0.mcause_q;
    end

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * addr  instr                                       notes
         *  0x00  addi x30, x0, 96 (0x60)                    x30 = M_TRAP_HANDLER address
         *  0x04  csrrw x0, mtvec, x30
         *  0x08  sfence.vma x0, x0                           Case A (M, TVM=0) -- no trap
         *  0x0C  addi x16, x0, 1                             marker A
         *  0x10  csrrs x17, satp, x0                         Case B (M, TVM=0) -- no trap
         *  0x14  addi x18, x0, 1                             marker B
         *  0x18  addi x19, x0, 1
         *  0x1C  slli x19, x19, 20                            x19 = 1<<20 (TVM bit alone)
         *  0x20  csrrw x0, mstatus, x19                       mstatus: TVM=1, everything else listed cleared
         *  0x24  sfence.vma x0, x0                           Case C (M, TVM=1) -- no trap (TVM never gates M)
         *  0x28  addi x20, x0, 1                             marker C
         *  0x2C  csrrs x21, satp, x0                         Case D (M, TVM=1) -- no trap
         *  0x30  addi x22, x0, 1                             marker D
         *  0x34  addi x23, x0, 513 (0x201)
         *  0x38  slli x23, x23, 11                            x23 = 0x100800 (TVM=1 | MPP=S(01)<<11)
         *  0x3C  csrrw x0, mstatus, x23                       mstatus: TVM stays 1, MPP=S, rest cleared
         *  0x40  addi x24, x0, 76 (0x4C)                     x24 = S_ENTRY address
         *  0x44  csrrw x0, mepc, x24
         *  0x48  mret                                        -> S-mode, pc = 0x4C, TVM untouched by mret (stays 1)
         *  0x4C  sfence.vma x0, x0                           Case E (S, TVM=1) -- TRAPS (resumes 0x50)
         *  0x50  addi x25, x0, 1                             marker E
         *  0x54  csrrs x26, satp, x0                         Case F (S, TVM=1) -- TRAPS (resumes 0x58)
         *  0x58  addi x27, x0, 1                             marker F
         *  0x5C  ebreak
         * -- M_TRAP_HANDLER (0x60) --
         *  0x60  csrrs x10, mepc, x0
         *  0x64  addi x10, x10, 4
         *  0x68  csrrw x0, mepc, x10
         *  0x6C  addi x28, x28, 1                             trap_count++
         *  0x70  mret
         */
        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),       // 0x04
                                encode_i(32'sd96, 5'd0, 3'b000, 5'd30, `OPC_OP_IMM)};                   // 0x00
        dut.sram0.memory[1] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd16, `OPC_OP_IMM),                     // 0x0C: marker A
                                encode_r(`FUNCT7_SFENCE_VMA, 5'd0, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM)};   // 0x08: sfence.vma (A)
        dut.sram0.memory[2] = {encode_i(32'sd1, 5'd0, 3'b000, 5'd18, `OPC_OP_IMM),                     // 0x14: marker B
                                encode_csr(12'h180, 5'd0, `FUNCT3_CSRRS, 5'd17, `OPC_SYSTEM)};          // 0x10: csrrs satp (B)
        dut.sram0.memory[3] = {encode_shift64(6'b0, 6'd20, 5'd19, 3'b001, 5'd19, `OPC_OP_IMM),         // 0x1C: slli x19,x19,20
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd19, `OPC_OP_IMM)};                    // 0x18: addi x19,x0,1
        dut.sram0.memory[4] = {encode_r(`FUNCT7_SFENCE_VMA, 5'd0, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM),    // 0x24: sfence.vma (C)
                                encode_csr(`CSR_MSTATUS, 5'd19, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};     // 0x20: csrrw mstatus,x19
        dut.sram0.memory[5] = {encode_csr(12'h180, 5'd0, `FUNCT3_CSRRS, 5'd21, `OPC_SYSTEM),           // 0x2C: csrrs satp (D)
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd20, `OPC_OP_IMM)};                    // 0x28: marker C
        dut.sram0.memory[6] = {encode_i(32'sd513, 5'd0, 3'b000, 5'd23, `OPC_OP_IMM),                   // 0x34: addi x23,x0,513
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd22, `OPC_OP_IMM)};                    // 0x30: marker D
        dut.sram0.memory[7] = {encode_csr(`CSR_MSTATUS, 5'd23, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),      // 0x3C: csrrw mstatus,x23
                                encode_shift64(6'b0, 6'd11, 5'd23, 3'b001, 5'd23, `OPC_OP_IMM)};        // 0x38: slli x23,x23,11
        dut.sram0.memory[8] = {encode_csr(`CSR_MEPC, 5'd24, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),         // 0x44: csrrw mepc,x24
                                encode_i(32'sd76, 5'd0, 3'b000, 5'd24, `OPC_OP_IMM)};                   // 0x40: addi x24,x0,76
        dut.sram0.memory[9] = {encode_r(`FUNCT7_SFENCE_VMA, 5'd0, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM),    // 0x4C: sfence.vma (E)
                                `INSTR_HEX_MRET};                                                       // 0x48: mret
        dut.sram0.memory[10] = {encode_csr(12'h180, 5'd0, `FUNCT3_CSRRS, 5'd26, `OPC_SYSTEM),          // 0x54: csrrs satp (F)
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd25, `OPC_OP_IMM)};                   // 0x50: marker E
        dut.sram0.memory[11] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},                                     // 0x5C: ebreak
                                 encode_i(32'sd1, 5'd0, 3'b000, 5'd27, `OPC_OP_IMM)};                   // 0x58: marker F
        dut.sram0.memory[12] = {encode_i(32'sd4, 5'd10, 3'b000, 5'd10, `OPC_OP_IMM),                   // 0x64
                                 encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};       // 0x60
        dut.sram0.memory[13] = {encode_i(32'sd1, 5'd28, 3'b000, 5'd28, `OPC_OP_IMM),                   // 0x6C
                                 encode_csr(`CSR_MEPC, 5'd10, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};       // 0x68
        dut.sram0.memory[14] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM),                     // 0x74: nop (pad)
                                 `INSTR_HEX_MRET};                                                       // 0x70

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "SFENCE.VMA/TVM trap never fired");

        check("marker A ran (M, TVM=0, sfence.vma)", dut.core0.regfile0.gp_registers[16], 64'd1);
        check("marker B ran (M, TVM=0, satp read)",  dut.core0.regfile0.gp_registers[18], 64'd1);
        check("marker C ran (M, TVM=1, sfence.vma)", dut.core0.regfile0.gp_registers[20], 64'd1);
        check("marker D ran (M, TVM=1, satp read)",  dut.core0.regfile0.gp_registers[22], 64'd1);
        check("marker E ran (S, TVM=1, sfence.vma -- resumed past the trap)",
              dut.core0.regfile0.gp_registers[25], 64'd1);
        check("marker F ran (S, TVM=1, satp read -- resumed past the trap)",
              dut.core0.regfile0.gp_registers[27], 64'd1);

        check("trap_count == 0 after cases A-D -- TVM never traps from M-mode",
              trap_count_before_smode, 64'd0);
        check("mcause == 2 (illegal instruction) after case E (S-mode sfence.vma, TVM=1)",
              mcause_after_e, 64'd2);
        check("mcause == 2 (illegal instruction) after case F (S-mode satp read, TVM=1)",
              mcause_after_f, 64'd2);
        check("trap_count == 2 total -- exactly cases E and F, nothing else",
              dut.core0.regfile0.gp_registers[28], 64'd2);
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_sfence_vma_priv_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_sfence_vma_priv_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
