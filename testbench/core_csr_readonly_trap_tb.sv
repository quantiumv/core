// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, a write-attempt to a read-only CSR genuinely trapping
 * through the real core (illegal-instruction, cause 2).
 *
 * Closes a real gap found 2026-08-20 via ACT4's priv/U/U-00 test: once
 * EBREAK became a real, resumable trap (see the EBREAK-real-trap
 * milestone), U-00 ran far enough for the first time to reach its own
 * boot-time `csrrw x0, cycle, a0` (a write-attempt to a genuinely
 * read-only CSR) -- traced via sail_riscv_sim against the real ELF,
 * diffed against this core's own RVFI retirement trace, confirming the
 * exact first divergence: Sail traps (illegal-instruction), this core
 * silently no-op'd the write and fell through instead. Per spec:
 * "Attempts to write a read-only CSR... raise illegal instruction
 * exceptions." design/core.sv's own header comment at
 * csr_readonly_violation has the full derivation.
 *
 * This subtest used to live at the top of core_zicsr_tb.sv (a
 * csrrwi-to-mhartid case expecting a silent ignore) -- retired from
 * there once the real trap landed, replaced by this dedicated file,
 * matching this project's "one file per concern" convention for a
 * trap/exception scenario rather than folding a trap-and-resume
 * sequence into core_zicsr_tb.sv's otherwise straight-line "vanilla CSR
 * round trip" program.
 *
 * Mirrors core_c_illegal_trap_tb.sv's own M_TRAP_HANDLER pattern (read
 * mepc, skip past the faulting instruction, write back, mret) and its
 * point-in-time-snapshot discipline (mtvec stays armed through this
 * file's own terminating ebreak, which -- now a real trap -- bounces
 * back into the handler once it fires; live post-halt CSR reads are not
 * safe against that, see that file's own comment for the full story).
 *
 * Uses mhartid (0xF14, bits[11:10]=='11') as the read-only target --
 * already this project's own established "obviously read-only, always
 * 0" example (see the now-retired core_zicsr_tb.sv subtest this
 * replaces).
 */
module core_csr_readonly_trap_tb;

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
     * mcause_q/mtval_q snapshot, taken at the resume point (pc==0x0C,
     * the marker right after the fixed-up mepc returns) -- NOT read live
     * at check() time. Same reasoning as core_c_illegal_trap_tb.sv's own
     * identical snapshot: mtvec stays armed through this file's own
     * terminating ebreak, which bounces back into the handler once it
     * fires, corrupting mcause_q/mtval_q long after this test's real
     * assertion already happened if read live.
     */
    logic [63:0] mcause_snap, mtval_snap;
    logic resumed = 1'b0;
    always @(posedge clk) if (!resumed && dut.core0.commit_now && dut.core0.pc == 64'h0C) begin
        resumed     <= 1'b1;
        mcause_snap <= dut.core0.csr_file0.mcause_q;
        mtval_snap  <= dut.core0.csr_file0.mtval_q;
    end

    logic [31:0] trigger_insn;

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * addr  instr                                    notes
         *  0x00  addi x28, x0, 0x18 (24)                  x28 = M_TRAP_HANDLER address
         *  0x04  csrrw x0, mtvec, x28
         *  0x08  csrrwi x1, mhartid, 7                    the faulting write-attempt (TRIGGER)
         *  0x0C  addi x5, x0, 555                          resume target -- reached only via the
         *                                                  handler's mepc+4 fix, not by falling
         *                                                  through (the faulting instr never retires)
         *  0x10  csrrs x6, mhartid, x0                     confirm the write never actually landed
         *  0x14  ebreak
         * -- M_TRAP_HANDLER (0x18) --
         *  0x18  csrrs x10, mepc, x0
         *  0x1C  csrrs x11, mcause, x0
         *  0x20  csrrs x12, mtval, x0
         *  0x24  addi x10, x10, 4                          +4 -- the faulting instruction was a
         *                                                   real 32-bit encoding, not compressed
         *  0x28  csrrw x0, mepc, x10
         *  0x2C  mret
         */
        trigger_insn = encode_csr(`CSR_MHARTID, 5'd7, `FUNCT3_CSRRWI, 5'd1, `OPC_SYSTEM);

        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd24, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        dut.sram0.memory[1] = {encode_i(32'sd555, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                trigger_insn};
        dut.sram0.memory[2] = {{11'b0, 1'b1, 13'b0, `OPC_SYSTEM},
                                encode_csr(`CSR_MHARTID, 5'd0, `FUNCT3_CSRRS, 5'd6, `OPC_SYSTEM)};
        dut.sram0.memory[3] = {encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd11, `OPC_SYSTEM),
                                encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd10, `OPC_SYSTEM)};
        dut.sram0.memory[4] = {encode_i(32'sd4, 5'd10, 3'b000, 5'd10, `OPC_OP_IMM),
                                encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd12, `OPC_SYSTEM)};
        dut.sram0.memory[5] = {`INSTR_HEX_MRET,
                                encode_csr(`CSR_MEPC, 5'd10, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        check("x1 never written -- the trapping csrrwi's own rd write is suppressed",
            dut.core0.regfile0.gp_registers[1], 64'd0);
        check("resumed exactly past the faulting csrrwi (x5)",
            dut.core0.regfile0.gp_registers[5], 64'd555);
        check("mhartid write-attempt never actually landed (still reads 0)",
            dut.core0.regfile0.gp_registers[6], 64'd0);
        check("mcause == 2 (illegal instruction)", mcause_snap, 64'd2);
        check("mtval == the faulting csrrwi's own raw 32-bit encoding",
            mtval_snap, {32'b0, trigger_insn});
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_csr_readonly_trap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_csr_readonly_trap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
