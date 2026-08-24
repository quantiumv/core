// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, a reserved/illegal compressed instruction genuinely
 * trapping through the real core.
 *
 * Closes a real coverage gap left by the rest of the C-extension milestone:
 * design/c_expand_tb.sv thoroughly unit-tests c_expand.sv's o_illegal
 * detection in isolation (52/52, every reserved codepoint), but nothing
 * exercised the INTEGRATION point -- core.sv's own
 * `is_illegal_instr = ... || (is_compressed && c_expand_illegal)` term,
 * `trap_taken`'s redirect to `trap_vector`, `mcause`==2, and (the one
 * line added specifically for this milestone) `trap_val` reporting the
 * raw 16-bit halfword zero-extended rather than `instruction`'s inert
 * placeholder value -- had zero coverage until this file.
 *
 * M-mode only, no privilege-delegation complexity -- that's already
 * exhaustively covered by testbench/core_priv_tb.sv/core_priv_u_ecall_tb.sv
 * for illegal instructions in general; this file's only new thing is
 * proving the SAME trap mechanism fires correctly when the trigger is a
 * genuinely reserved COMPRESSED encoding specifically. Mirrors
 * core_priv_tb.sv's own M_TRAP_HANDLER pattern (read mepc, skip past the
 * faulting instruction, write back, mret) with one deliberate
 * difference: the handler advances mepc by 2, not 4 -- the faulting
 * instruction here is a real 16-bit compressed encoding, not a 32-bit
 * one, and getting this wrong (copying core_priv_tb.sv's +4 verbatim)
 * would land execution mid-instruction on resume.
 *
 * Uses the bare 16'h0000 pattern (C.ILLEGAL, subsumed by c_expand.sv's
 * C.ADDI4SPN nzuimm=0 check per that file's own header) as the faulting
 * instruction -- already proven illegal at the c_expand.sv unit level;
 * this file's job is only to prove that fact correctly reaches core.sv's
 * trap machinery, not to re-litigate which encodings are illegal.
 */
module core_c_illegal_trap_tb;

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
     * mcause_q/mtval_q snapshot, taken at the resume point (pc==0x0A,
     * `addi x5,x0,999`, the instruction right after the fixed-up mepc
     * returns) -- NOT read live at check() time. mtvec stays armed at
     * M_TRAP_HANDLER for the rest of this program, including this file's
     * own terminating ebreak at 0x0E: since EBREAK is a real trap now,
     * that ebreak bounces right back into M_TRAP_HANDLER (mtvec still
     * points there), which advances mepc by 2 and mrets into whatever
     * follows -- genuinely unwritten memory, causing a cascade of further
     * illegal-instruction traps that keep overwriting mcause_q/mtval_q
     * long after this test's own real assertion already happened. A
     * point-in-time snapshot at the resume point sidesteps all of that,
     * capturing state before the terminating ebreak (and its bounce-back)
     * ever fires.
     */
    logic [63:0] mcause_snap, mtval_snap;
    logic resumed = 1'b0;
    always @(posedge clk) if (!resumed && dut.core0.commit_now && dut.core0.pc == 64'h0A) begin
        resumed    <= 1'b1;
        mcause_snap <= dut.core0.csr_file0.mcause_q;
        mtval_snap  <= dut.core0.csr_file0.mtval_q;
    end

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * addr  instr                                    notes
         *  0x00  addi x28, x0, 0x20 (32)                  x28 = M_TRAP_HANDLER address
         *  0x04  csrrw x0, mtvec, x28
         *  0x08  16'h0000 (C.ILLEGAL)                     the faulting compressed instruction
         *  0x0A  addi x5, x0, 999                         resume target -- reached only via the
         *                                                 handler's mepc+2 fix, not by falling
         *                                                 through (the illegal instr never retires)
         *  0x0E  ebreak
         * -- M_TRAP_HANDLER (0x20) --
         *  0x20  csrrs x30, mepc, x0
         *  0x24  addi x30, x30, 2                         +2, NOT +4 -- the faulting instruction
         *                                                 was 16 bits, not 32
         *  0x28  csrrw x0, mepc, x30
         *  0x2C  mret
         */
        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd32, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)};
        /* bytes 8-9=16'h0000, 10-13=addi x5,x0,999 (32b), 14-15=c.ebreak */
        dut.sram0.memory[1] = {`INSTR_C_EBREAK,
                                encode_i(32'sd999, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                16'h0000};
        dut.sram0.memory[4] = {encode_i(32'sd2, 5'd30, 3'b000, 5'd30, `OPC_OP_IMM),
                                encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd30, `OPC_SYSTEM)};
        dut.sram0.memory[5] = {`INSTR_HEX_MRET,
                                encode_csr(`CSR_MEPC, 5'd30, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "EBREAK trap never fired");

        check("mcause == 2 (illegal instruction)", mcause_snap, 64'd2);
        check("mtval == the raw 16-bit C.ILLEGAL halfword, zero-extended",
            mtval_snap, 64'h0000);
        check("resumed exactly past the 2-byte illegal instruction (x5)",
            dut.core0.regfile0.gp_registers[5], 64'd999);
        check("EBREAK trap fired", {63'b0, halted}, 64'd1);

        $display("");
        $display("core_c_illegal_trap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_c_illegal_trap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
