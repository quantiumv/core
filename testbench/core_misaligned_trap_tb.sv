// SPDX-License-Identifier: MIT

/* ------------------------------------------------------------------------- */


`include "riscv_encode.sv"


/* ------------------------------------------------------------------------- */


/*
 * Testbench: core, a misaligned load and a misaligned store each
 * genuinely trapping through the real core.
 *
 * Closes a real gap found by this project's riscv-formal suite: core.sv
 * never checked data-access alignment at all -- mem_sel's shift had no
 * carry into a second bus word, so an overflowing access silently
 * truncated and committed corrupted data instead of either handling it
 * or trapping, which the spec requires be one or the other. This file
 * proves the fix: mem_load_misaligned/mem_store_misaligned correctly
 * suppress the bus phase and trap (mcause 4/6) instead.
 *
 * Two independent cases, each with its own trap handler (mtvec is
 * re-pointed between them) so both mcause/mtval pairs survive to the
 * final checks rather than the second trap overwriting the first's CSR
 * snapshot -- mirrors core_c_illegal_trap_tb.sv's M_TRAP_HANDLER
 * pattern (read mepc, skip past the faulting instruction, mret), with
 * mepc+4 here (not +2) since the faulting instructions are ordinary
 * 32-bit LD/SD, not a compressed encoding.
 *
 * Load case additionally proves the destination register is left
 * untouched (the load never happened, not just "happened with a wrong
 * value"). Store case additionally proves the store never reached
 * memory at all -- not even the old partial/truncated write -- by
 * reading back an aligned dword outside this program's own instruction
 * footprint after resume and confirming it still holds a known sentinel
 * value written there before rst is dropped.
 */
module core_misaligned_trap_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    core_wb4_sram_harness #(.NUM_WORDS(24)) dut (.clk(clk), .rst(rst));

    int pass_count = 0;
    int fail_count = 0;
    logic quiet_on_pass = 1'b0;
    `include "check_lib.sv"

    wire halted = dut.core0.halted;
    `include "halt_wait.sv"

    initial begin
        #1; // run after wb4_sram's own time-0 init

        /*
         * addr  instr                                    notes
         *  0x00  addi x28, x0, 0x60                       x28 = LOAD_HANDLER address
         *  0x04  csrrw x0, mtvec, x28
         *  0x08  addi x1, x0, 1                            x1 = 1 -- misaligned dword address
         *  0x0C  addi x5, x0, 555                          sentinel: must survive the trapped load
         *  0x10  ld x5, 0(x1)                               misaligned LOAD -- traps, cause=4
         *  0x14  addi x2, x0, 111                          resume marker #1
         *  0x18  addi x28, x0, 0x80                        x28 = STORE_HANDLER address
         *  0x1C  csrrw x0, mtvec, x28
         *  0x20  addi x3, x0, 1                            x3 = 1 -- misaligned dword address
         *  0x24  addi x6, x0, 777                          value that would be stored, if allowed
         *  0x28  sd x6, 0(x3)                               misaligned STORE -- traps, cause=6
         *  0x2C  addi x7, x0, 222                          resume marker #2
         *  0x30  addi x9, x0, 160                          x9 = 160 -- aligned address outside
         *                                                   this program's own instruction
         *                                                   footprint (memory is shared between
         *                                                   code and data), so a stray write
         *                                                   there is unambiguous
         *  0x34  ld x8, 0(x9)                               readback -- must still be the
         *                                                   sentinel written to word 20 below
         *  0x38  ebreak
         * -- LOAD_HANDLER (0x60) --
         *  0x60  csrrs x20, mepc, x0
         *  0x64  addi x20, x20, 4                          +4 -- LD is a real 32-bit instruction
         *  0x68  csrrs x21, mcause, x0
         *  0x6C  csrrs x22, mtval, x0
         *  0x70  csrrw x0, mepc, x20
         *  0x74  mret
         * -- STORE_HANDLER (0x80) --
         *  0x80  csrrs x23, mepc, x0
         *  0x84  addi x23, x23, 4
         *  0x88  csrrs x24, mcause, x0
         *  0x8C  csrrs x25, mtval, x0
         *  0x90  csrrw x0, mepc, x23
         *  0x94  mret
         */
        dut.sram0.memory[0] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd96, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // 0x60
        dut.sram0.memory[1] = {encode_i(32'sd555, 5'd0, 3'b000, 5'd5, `OPC_OP_IMM),
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd1, `OPC_OP_IMM)};
        dut.sram0.memory[2] = {encode_i(32'sd111, 5'd0, 3'b000, 5'd2, `OPC_OP_IMM),
                                encode_i(32'sd0, 5'd1, 3'b011, 5'd5, `OPC_LOAD)}; // ld x5,0(x1)
        dut.sram0.memory[3] = {encode_csr(`CSR_MTVEC, 5'd28, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM),
                                encode_i(32'sd128, 5'd0, 3'b000, 5'd28, `OPC_OP_IMM)}; // 0x80
        dut.sram0.memory[4] = {encode_i(32'sd777, 5'd0, 3'b000, 5'd6, `OPC_OP_IMM),
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd3, `OPC_OP_IMM)};
        dut.sram0.memory[5] = {encode_i(32'sd222, 5'd0, 3'b000, 5'd7, `OPC_OP_IMM),
                                encode_s(32'sd0, 5'd6, 5'd3, 3'b011, `OPC_STORE)}; // sd x6,0(x3)
        dut.sram0.memory[6] = {encode_i(32'sd0, 5'd9, 3'b011, 5'd8, `OPC_LOAD), // ld x8,0(x9)
                                encode_i(32'sd160, 5'd0, 3'b000, 5'd9, `OPC_OP_IMM)}; // x9=160 (unused, zero-init memory)
        dut.sram0.memory[7] = {encode_i(32'sd0, 5'd0, 3'b000, 5'd0, `OPC_OP_IMM), // padding, never fetched
                                encode_i(32'sd1, 5'd0, 3'b000, 5'd0, `OPC_SYSTEM)}; // ebreak

        /*
         * wb4_sram.sv unconditionally $readmemh's firmware/crt0.hex into
         * the WHOLE memory array at time 0 -- word 20 (byte 160, the
         * readback target above) is NOT actually zero-init, it holds
         * whatever crt0.hex happens to put there. Overwrite it with a
         * known sentinel here (this write, like the program itself, runs
         * after wb4_sram's own initial block per the #1 delay below) so
         * the readback check has an unambiguous baseline to compare
         * against, rather than assuming a "zero-init" that doesn't hold.
         */
        dut.sram0.memory[20] = 64'hDEAD_BEEF_DEAD_BEEF;

        dut.sram0.memory[12] = {encode_i(32'sd4, 5'd20, 3'b000, 5'd20, `OPC_OP_IMM),
                                 encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd20, `OPC_SYSTEM)};
        dut.sram0.memory[13] = {encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd22, `OPC_SYSTEM),
                                 encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd21, `OPC_SYSTEM)};
        dut.sram0.memory[14] = {`INSTR_HEX_MRET,
                                 encode_csr(`CSR_MEPC, 5'd20, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        dut.sram0.memory[16] = {encode_i(32'sd4, 5'd23, 3'b000, 5'd23, `OPC_OP_IMM),
                                 encode_csr(`CSR_MEPC, 5'd0, `FUNCT3_CSRRS, 5'd23, `OPC_SYSTEM)};
        dut.sram0.memory[17] = {encode_csr(`CSR_MTVAL, 5'd0, `FUNCT3_CSRRS, 5'd25, `OPC_SYSTEM),
                                 encode_csr(`CSR_MCAUSE, 5'd0, `FUNCT3_CSRRS, 5'd24, `OPC_SYSTEM)};
        dut.sram0.memory[18] = {`INSTR_HEX_MRET,
                                 encode_csr(`CSR_MEPC, 5'd23, `FUNCT3_CSRRW, 5'd0, `OPC_SYSTEM)};

        @(posedge clk); #1;
        rst = 0;

        wait_halted_or_timeout(`TIMEOUT_CYCLES_SMALL, "dut.core0.halted never went high");

        check("load trap: mcause == 4 (load address misaligned)",
            dut.core0.regfile0.gp_registers[21], 64'd4);
        check("load trap: mtval == the misaligned load address (1)",
            dut.core0.regfile0.gp_registers[22], 64'd1);
        check("load trap: sentinel x5 unchanged (load never happened)",
            dut.core0.regfile0.gp_registers[5], 64'd555);
        check("load trap: resumed exactly past the faulting ld (x2)",
            dut.core0.regfile0.gp_registers[2], 64'd111);

        check("store trap: mcause == 6 (store/AMO address misaligned)",
            dut.core0.regfile0.gp_registers[24], 64'd6);
        check("store trap: mtval == the misaligned store address (1)",
            dut.core0.regfile0.gp_registers[25], 64'd1);
        check("store trap: resumed exactly past the faulting sd (x7)",
            dut.core0.regfile0.gp_registers[7], 64'd222);
        check("store trap: target dword still holds the sentinel (store never reached memory)",
            dut.core0.regfile0.gp_registers[8], 64'hDEAD_BEEF_DEAD_BEEF);

        check("core halted (ebreak reached)", {63'b0, dut.core0.halted}, 64'd1);

        $display("");
        $display("core_misaligned_trap_tb: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count > 0) $display("core_misaligned_trap_tb: FAILURES PRESENT");
        $finish;
    end

endmodule

/* ------------------------------------------------------------------------- */


/* End of file. */
